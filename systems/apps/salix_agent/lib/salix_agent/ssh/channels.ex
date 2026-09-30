defmodule SalixAgent.SSH.Channels do
  @moduledoc """
  Extra channels on an open SSH session's connection: one-shot `exec` and
  SFTP file transfer. They run in the calling tool job and close with it; the
  session's PTY shell is not involved.

  Transfers move one regular file between the Agent's file system
  (`SalixAgent.FileBackend`, `/drive` included) and the remote host in 64 KiB
  SFTP requests, up to #{1024} MiB. Without `overwrite`, an existing
  destination is refused; the check and the write are not atomic.
  """

  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias SalixAgent.FileBackend

  @window 262_144
  @packet 32_768
  @op_timeout_ms 30_000
  @chunk_bytes 65_536
  @max_transfer_bytes 1024 * 1024 * 1024
  @max_stream_bytes 262_144
  @max_list_entries 1_000

  @doc "Maximum bytes one upload or download moves."
  def max_transfer_bytes, do: @max_transfer_bytes

  # ---- exec ----------------------------------------------------------------------

  @doc """
  Run one command on a new exec channel. Returns separate stdout and stderr
  (each capped at 256 KiB, with truncation flags), the exit status or signal,
  and whether the deadline ended the command.
  """
  @spec exec(pid(), String.t(), binary(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def exec(conn, command, stdin, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, channel} <- :ssh_connection.session_channel(conn, @window, @packet, @op_timeout_ms),
         :success <-
           :ssh_connection.exec(conn, channel, String.to_charlist(command), @op_timeout_ms) do
      if stdin != "", do: :ssh_connection.send(conn, channel, stdin, @op_timeout_ms)
      :ssh_connection.send_eof(conn, channel)

      result =
        collect(conn, channel, deadline, %{
          stdout: [],
          stdout_size: 0,
          stderr: [],
          stderr_size: 0,
          exit_status: nil,
          exit_signal: nil,
          timed_out: false
        })

      {:ok, result}
    else
      :failure -> {:error, :exec_refused}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp collect(conn, channel, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ssh_cm, ^conn, {:data, ^channel, type, data}} ->
        :ssh_connection.adjust_window(conn, channel, byte_size(data))
        stream = if type == 1, do: :stderr, else: :stdout
        collect(conn, channel, deadline, append(acc, stream, data))

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect(conn, channel, deadline, %{acc | exit_status: status})

      {:ssh_cm, ^conn, {:exit_signal, ^channel, signal, _message, _lang}} ->
        collect(conn, channel, deadline, %{acc | exit_signal: to_string(signal)})

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect(conn, channel, deadline, acc)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        finish(acc)
    after
      remaining ->
        :ssh_connection.close(conn, channel)
        finish(%{acc | timed_out: true})
    end
  end

  defp append(acc, stream, data) do
    size_key = if stream == :stdout, do: :stdout_size, else: :stderr_size
    size = Map.fetch!(acc, size_key)
    keep = binary_part(data, 0, min(byte_size(data), max(@max_stream_bytes - size, 0)))

    acc
    |> Map.update!(stream, &[&1, keep])
    |> Map.put(size_key, size + byte_size(data))
  end

  defp finish(acc) do
    %{
      "stdout" => acc.stdout |> IO.iodata_to_binary() |> SalixAgent.Utf8.scrub(),
      "stderr" => acc.stderr |> IO.iodata_to_binary() |> SalixAgent.Utf8.scrub(),
      "stdout_truncated" => acc.stdout_size > @max_stream_bytes,
      "stderr_truncated" => acc.stderr_size > @max_stream_bytes,
      "exit_status" => acc.exit_status,
      "exit_signal" => acc.exit_signal,
      "timed_out" => acc.timed_out
    }
  end

  # ---- SFTP ----------------------------------------------------------------------

  @doc "Copy a file from the Agent file system to the remote host."
  @spec upload(pid(), map(), String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def upload(conn, ctx, source, destination, overwrite?) do
    with {:ok, stream, size} <- vfs_source(ctx, source),
         :ok <- within_limit(size) do
      with_sftp(conn, fn sftp ->
        remote = String.to_charlist(destination)

        with :ok <- remote_absent(sftp, remote, overwrite?),
             {:ok, handle} <- :ssh_sftp.open(sftp, remote, [:write, :binary], @op_timeout_ms) do
          written =
            try do
              Enum.reduce_while(stream, {:ok, 0}, fn chunk, {:ok, written} ->
                case write_chunks(sftp, handle, chunk) do
                  :ok -> {:cont, {:ok, written + byte_size(chunk)}}
                  {:error, reason} -> {:halt, {:error, {:remote_write_failed, reason}}}
                end
              end)
            after
              :ssh_sftp.close(sftp, handle, @op_timeout_ms)
            end

          with {:ok, bytes} <- written do
            {:ok, %{"source" => source, "destination" => destination, "bytes" => bytes}}
          end
        end
      end)
    end
  end

  defp write_chunks(sftp, handle, <<chunk::binary-size(@chunk_bytes), rest::binary>>) do
    with :ok <- :ssh_sftp.write(sftp, handle, chunk, @op_timeout_ms),
         do: write_chunks(sftp, handle, rest)
  end

  defp write_chunks(_sftp, _handle, ""), do: :ok
  defp write_chunks(sftp, handle, chunk), do: :ssh_sftp.write(sftp, handle, chunk, @op_timeout_ms)

  @doc """
  Copy a remote file into the Agent file system. Returns the result and the
  journal events of the write.
  """
  @spec download(pid(), map(), String.t(), String.t(), boolean()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def download(conn, ctx, source, destination, overwrite?) do
    with :ok <- vfs_absent(ctx, destination, overwrite?) do
      with_sftp(conn, fn sftp ->
        remote = String.to_charlist(source)

        with {:ok, info} <- :ssh_sftp.read_file_info(sftp, remote, @op_timeout_ms),
             :ok <- regular(info),
             :ok <- within_limit(file_info(info, :size)),
             {:ok, handle} <- :ssh_sftp.open(sftp, remote, [:read, :binary], @op_timeout_ms) do
          try do
            case FileBackend.prepare_write_stream(ctx, destination, remote_stream(sftp, handle)) do
              {:ok, nil} ->
                {:ok, transfer_result(source, destination, file_info(info, :size)), []}

              {:ok, event} ->
                {:ok, transfer_result(source, destination, event["size"]), [event]}

              {:error, reason} ->
                {:error, {:vfs_write_failed, reason}}
            end
          after
            :ssh_sftp.close(sftp, handle, @op_timeout_ms)
          end
        end
      end)
    end
  catch
    {:remote_read_failed, reason} -> {:error, {:remote_read_failed, reason}}
    :too_large -> {:error, {:too_large, @max_transfer_bytes}}
  end

  defp remote_stream(sftp, handle) do
    Stream.resource(
      fn -> 0 end,
      fn
        :done ->
          {:halt, :done}

        read ->
          case :ssh_sftp.read(sftp, handle, @chunk_bytes, @op_timeout_ms) do
            {:ok, data} ->
              read = read + byte_size(data)
              if read > @max_transfer_bytes, do: throw(:too_large)
              {[data], read}

            :eof ->
              {:halt, :done}

            {:error, reason} ->
              throw({:remote_read_failed, reason})
          end
      end,
      fn _ -> :ok end
    )
  end

  defp transfer_result(source, destination, bytes),
    do: %{"source" => source, "destination" => destination, "bytes" => bytes}

  @doc "One bounded page of a remote directory."
  @spec list_files(pid(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def list_files(conn, path, limit) do
    limit = min(limit, @max_list_entries)

    with_sftp(conn, fn sftp ->
      with {:ok, handle} <- :ssh_sftp.opendir(sftp, String.to_charlist(path), @op_timeout_ms) do
        try do
          {entries, complete?} = read_dir(sftp, handle, limit, [])

          {:ok,
           %{
             "path" => path,
             "entries" =>
               entries
               |> Enum.reject(fn {name, _} -> name in [~c".", ~c".."] end)
               |> Enum.map(&entry/1)
               |> Enum.sort_by(& &1["name"]),
             "truncated" => not complete?
           }}
        after
          :ssh_sftp.close(sftp, handle, @op_timeout_ms)
        end
      end
    end)
  end

  # `readdir` returns the server's batches; stop once the page is full.
  defp read_dir(_sftp, _handle, limit, acc) when length(acc) >= limit,
    do: {Enum.take(acc, limit), false}

  defp read_dir(sftp, handle, limit, acc) do
    case :ssh_sftp.readdir(sftp, handle, @op_timeout_ms) do
      {:ok, batch} -> read_dir(sftp, handle, limit, acc ++ batch)
      :eof -> {acc, true}
      {:error, :eof} -> {acc, true}
      {:error, reason} -> throw({:remote_read_failed, reason})
    end
  end

  # `readdir` reports SFTP attributes; convert them like `read_file_info`.
  defp entry({name, attributes}) do
    info = :ssh_sftp.attr_to_info(attributes)

    %{
      "name" => SalixAgent.Utf8.scrub(List.to_string(name)),
      "type" => to_string(file_info(info, :type)),
      "size" => file_info(info, :size),
      "mode" => mode(file_info(info, :mode)),
      "modified_at" => timestamp(file_info(info, :mtime))
    }
  end

  defp mode(mode) when is_integer(mode),
    do: "0" <> Integer.to_string(Bitwise.band(mode, 0o7777), 8)

  defp mode(_mode), do: nil

  defp timestamp({{_, _, _}, {_, _, _}} = datetime) do
    datetime
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  rescue
    _ -> nil
  end

  defp timestamp(_), do: nil

  # ---- helpers ------------------------------------------------------------------------

  # The SFTP channel is linked to the calling job: a cancelled or timed-out
  # tool call takes the channel down with it.
  defp with_sftp(conn, fun) do
    case :ssh_sftp.start_channel(conn, timeout: @op_timeout_ms) do
      {:ok, sftp} ->
        Process.link(sftp)

        try do
          fun.(sftp)
        catch
          {:remote_read_failed, reason} -> {:error, {:remote_read_failed, reason}}
        after
          Process.unlink(sftp)
          :ssh_sftp.stop_channel(sftp)
        end

      {:error, reason} ->
        {:error, {:sftp_unavailable, reason}}
    end
  end

  defp vfs_source(ctx, path) do
    case FileBackend.stream(ctx, path) do
      {:ok, stream, size} -> {:ok, stream, size}
      {:error, :not_found} -> {:error, {:vfs_not_found, path}}
      {:error, reason} -> {:error, {:vfs_read_failed, reason}}
    end
  end

  defp vfs_absent(_ctx, _path, true), do: :ok

  defp vfs_absent(ctx, path, false) do
    case FileBackend.stat(ctx, path) do
      {:ok, _} -> {:error, {:destination_exists, path}}
      _ -> :ok
    end
  end

  defp remote_absent(_sftp, _path, true), do: :ok

  defp remote_absent(sftp, path, false) do
    case :ssh_sftp.read_file_info(sftp, path, @op_timeout_ms) do
      {:ok, _} -> {:error, {:destination_exists, List.to_string(path)}}
      _ -> :ok
    end
  end

  defp regular(info) do
    if file_info(info, :type) == :regular,
      do: :ok,
      else: {:error, {:not_a_regular_file, file_info(info, :type)}}
  end

  defp within_limit(size) when is_integer(size) and size > @max_transfer_bytes,
    do: {:error, {:too_large, @max_transfer_bytes}}

  defp within_limit(_size), do: :ok
end
