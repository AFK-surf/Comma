defmodule SalixAgent.Colab.Transfer do
  @moduledoc """
  Command execution and atomic binary streaming file transfer over OTP `:ssh`
  exec channels for Google Colab VMs (up to 1 GiB, zero SFTP dependency).

  Invariants:
  - `exec/3` delegates to `SalixAgent.SSH.Channels.exec/4` (256 KiB stdout/stderr
    caps + UTF-8 scrub + `SystemsClock.vreceive`) when `stdin == ""`, and checks
    `:ssh_connection.send` return values when `stdin != ""`.
  - `upload/6` streams 64 KiB chunks into a remote `mktemp` staging file with
    `trap 'rm -f -- "$tmp"' EXIT INT TERM`, verifies exact remote byte count
    with `wc -c` BEFORE committing, and uses atomic `ln` (`overwrite: false`) or
    `mv -f` (`overwrite: true`).
  - `download/6` passes a `Stream.resource` to `FileBackend.prepare_write_stream/4`
    (with `if_none_match: not overwrite?` for Drive) that reads through
    `{:closed, ch}` and confirms `exit_status == 0` BEFORE returning `{:halt, state}`;
    any non-zero exit, signal, disconnect, overflow, or timeout throws
    `{:colab_download_failed, reason}` inside the stream so `DriveMount.spool` /
    VFS aborts with ZERO partial file persisted.
  """

  require SystemsClock

  alias SalixAgent.FileBackend
  alias SalixAgent.SSH.Channels

  @window 262_144
  @packet 32_768
  @op_timeout_ms 30_000
  @chunk_bytes 65_536
  @max_transfer_bytes 1024 * 1024 * 1024
  @max_stream_bytes 262_144
  @max_err_bytes 16_384

  @doc "Maximum bytes one upload or download moves (1 GiB)."
  def max_transfer_bytes, do: @max_transfer_bytes

  @doc "Single-quote POSIX shell escaping."
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(str) when is_binary(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  # ---- exec ----

  @doc """
  Execute `command` on `conn`, prefixed with `cd -- <escaped_cwd> && `.
  Returns separate stdout/stderr (256 KiB cap each, UTF-8 scrubbed),
  `exit_status`, `exit_signal`, and `timed_out`.
  """
  @spec exec(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exec(conn, command, opts \\ []) when is_pid(conn) and is_binary(command) do
    cwd = Keyword.get(opts, :cwd) || "/content"
    stdin = Keyword.get(opts, :stdin) || ""
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)

    full_command = "cd -- " <> shell_escape(cwd) <> " && " <> command

    if stdin == "" do
      Channels.exec(conn, full_command, "", timeout_ms)
    else
      exec_with_checked_stdin(conn, full_command, stdin, timeout_ms)
    end
  end

  defp exec_with_checked_stdin(conn, command, stdin, timeout_ms) do
    deadline = SystemsClock.monotonic_time(:millisecond) + timeout_ms

    case :ssh_connection.session_channel(conn, @window, @packet, @op_timeout_ms) do
      {:ok, channel} ->
        try do
          with :success <-
                 :ssh_connection.exec(conn, channel, String.to_charlist(command), @op_timeout_ms),
               :ok <- send_chunks(conn, channel, stdin) do
            :ssh_connection.send_eof(conn, channel)

            result =
              collect_exec(conn, channel, deadline, %{
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
        after
          safe_close_channel(conn, channel)
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp collect_exec(conn, channel, deadline, acc) do
    remaining = max(deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsClock.vreceive do
      {:ssh_cm, ^conn, {:data, ^channel, type, data}} ->
        :ssh_connection.adjust_window(conn, channel, byte_size(data))
        stream = if type == 1, do: :stderr, else: :stdout
        collect_exec(conn, channel, deadline, append_exec(acc, stream, data))

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect_exec(conn, channel, deadline, %{acc | exit_status: status})

      {:ssh_cm, ^conn, {:exit_signal, ^channel, signal, _message, _lang}} ->
        collect_exec(conn, channel, deadline, %{acc | exit_signal: to_string(signal)})

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect_exec(conn, channel, deadline, acc)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        finish_exec(acc)
    after
      remaining ->
        :ssh_connection.close(conn, channel)
        finish_exec(%{acc | timed_out: true})
    end
  end

  defp append_exec(acc, stream, data) do
    size_key = if stream == :stdout, do: :stdout_size, else: :stderr_size
    size = Map.fetch!(acc, size_key)
    keep = binary_part(data, 0, min(byte_size(data), max(@max_stream_bytes - size, 0)))

    acc
    |> Map.update!(stream, &[&1, keep])
    |> Map.put(size_key, size + byte_size(data))
  end

  defp finish_exec(acc) do
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

  # ---- upload ----

  @doc """
  Stream a file from VFS/Drive (`source`) to `destination` on the Colab VM
  using a POSIX exec receiver with exact remote `wc -c` verification and atomic
  commit (`ln` when `overwrite?: false`, `mv -f` when `overwrite?: true`).
  """
  @spec upload(pid(), map(), String.t(), String.t(), boolean(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def upload(conn, ctx, source, destination, overwrite?, timeout_ms \\ 600_000)
      when is_pid(conn) and is_map(ctx) and is_binary(source) and is_binary(destination) and
             is_boolean(overwrite?) do
    with :ok <- validate_remote_path(destination),
         resolved_dest = resolve_remote_path(destination),
         {:ok, stream, size} <- vfs_source(ctx, source),
         :ok <- within_limit(size) do
      if is_nil(size) do
        with_spooled_upload(stream, fn spooled_stream, measured_size ->
          do_upload(
            conn,
            spooled_stream,
            measured_size,
            source,
            resolved_dest,
            overwrite?,
            timeout_ms
          )
        end)
      else
        do_upload(conn, stream, size, source, resolved_dest, overwrite?, timeout_ms)
      end
    end
  end

  @doc false
  def upload_script(destination, size, overwrite?) do
    parent = remote_parent(destination)
    template = Path.join(parent, ".comma-upload.XXXXXX")
    esc_dst = shell_escape(destination)
    esc_parent = shell_escape(parent)
    esc_template = shell_escape(template)

    commit =
      if overwrite? do
        # GNU coreutils `mv -fT` atomically refuses a directory destination (EISDIR)
        # instead of moving `$tmp` inside it; fall back to `mv -f` only on non-GNU
        # hosts when `$dest` is confirmed not a directory.
        "if mv --version >/dev/null 2>&1; then if mv -fT -- \"$tmp\" #{esc_dst} 2>/dev/null; then :; elif [ -d #{esc_dst} ]; then exit 21; else exit 25; fi; else if [ -d #{esc_dst} ]; then exit 21; else mv -f -- \"$tmp\" #{esc_dst} || exit 25; fi; fi"
      else
        "if ln --version >/dev/null 2>&1; then if ln -T -- \"$tmp\" #{esc_dst} 2>/dev/null; then rm -f -- \"$tmp\"; elif [ -d #{esc_dst} ]; then exit 21; else exit 17; fi; else if [ -d #{esc_dst} ]; then exit 21; elif ln -- \"$tmp\" #{esc_dst} 2>/dev/null; then rm -f -- \"$tmp\"; else exit 17; fi; fi"
      end

    Enum.join(
      [
        "if [ -d #{esc_dst} ]; then exit 21; fi",
        "mkdir -p -- #{esc_parent} || exit 22",
        "tmp=$(mktemp #{esc_template}) || exit 23",
        "trap 'rm -f -- \"$tmp\"' EXIT INT TERM",
        "cat > \"$tmp\" || exit 24",
        "if [ \"$(wc -c < \"$tmp\" | tr -d '[:space:]')\" -ne #{size} ]; then exit 3; fi",
        commit
      ],
      "; "
    )
  end

  defp do_upload(conn, stream, size, source, destination, overwrite?, timeout_ms) do
    deadline = SystemsClock.monotonic_time(:millisecond) + timeout_ms
    script = upload_script(destination, size, overwrite?)

    case :ssh_connection.session_channel(conn, @window, @packet, @op_timeout_ms) do
      {:ok, channel} ->
        try do
          case :ssh_connection.exec(conn, channel, String.to_charlist(script), @op_timeout_ms) do
            :success ->
              case stream_to_channel(conn, channel, stream, size) do
                {:ok, ^size} ->
                  case :ssh_connection.send_eof(conn, channel) do
                    :ok ->
                      await_upload_exit(conn, channel, deadline, source, destination, size)

                    {:error, :closed} ->
                      drain_early_upload_exit(conn, channel, deadline, source, destination, size)

                    {:error, reason} ->
                      {:error, {:remote_write_failed, reason}}
                  end

                {:ok, sent} ->
                  {:error, {:size_mismatch, size, sent}}

                {:error, :closed} ->
                  drain_early_upload_exit(conn, channel, deadline, source, destination, size)

                {:error, {:too_large, _} = err} ->
                  {:error, err}

                {:error, reason} ->
                  {:error, {:remote_write_failed, reason}}
              end

            :failure ->
              {:error, :exec_refused}

            {:error, reason} ->
              {:error, reason}

            other ->
              {:error, other}
          end
        after
          safe_close_channel(conn, channel)
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp drain_early_upload_exit(conn, channel, deadline, source, destination, size) do
    drain_deadline = min(deadline, SystemsClock.monotonic_time(:millisecond) + 5_000)

    case await_upload_exit(conn, channel, drain_deadline, source, destination, size) do
      {:error, :timeout} -> {:error, {:remote_write_failed, :closed}}
      other -> other
    end
  end

  defp with_spooled_upload(stream, fun) do
    dir = Path.join(System.tmp_dir!(), "salix-colab-upload-spool")
    File.mkdir_p!(dir)

    spooled =
      Path.join(
        dir,
        "#{SystemsRuntime.Proc.unique_integer([:positive])}-#{:erlang.phash2(SystemsRuntime.Proc.self())}"
      )

    try do
      size =
        File.open!(spooled, [:write, :binary], fn io ->
          Enum.reduce(stream, 0, fn chunk, acc ->
            bin = IO.iodata_to_binary(chunk)
            next = acc + byte_size(bin)

            if next > @max_transfer_bytes,
              do: throw({:colab_upload_too_large, @max_transfer_bytes})

            IO.binwrite(io, bin)
            next
          end)
        end)

      fun.(File.stream!(spooled, @chunk_bytes), size)
    catch
      {:colab_upload_too_large, max} -> {:error, {:too_large, max}}
    after
      File.rm(spooled)
    end
  end

  defp safe_close_channel(conn, channel) do
    :ssh_connection.close(conn, channel)
  catch
    _, _ -> :ok
  end

  defp stream_to_channel(conn, channel, stream, max_size) do
    Enum.reduce_while(stream, {:ok, 0}, fn chunk, {:ok, sent} ->
      bin = IO.iodata_to_binary(chunk)
      next_sent = sent + byte_size(bin)

      if next_sent > max_size do
        {:halt, {:error, {:too_large, max_size}}}
      else
        case send_chunks(conn, channel, bin) do
          :ok -> {:cont, {:ok, next_sent}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp send_chunks(conn, channel, <<chunk::binary-size(@chunk_bytes), rest::binary>>) do
    case :ssh_connection.send(conn, channel, chunk, @op_timeout_ms) do
      :ok -> send_chunks(conn, channel, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_chunks(_conn, _channel, <<>>), do: :ok

  defp send_chunks(conn, channel, chunk) do
    :ssh_connection.send(conn, channel, chunk, @op_timeout_ms)
  end

  defp await_upload_exit(conn, channel, deadline, source, destination, size) do
    case collect_exit(conn, channel, deadline, %{
           exit_status: nil,
           exit_signal: nil,
           stderr: [],
           stderr_size: 0,
           timed_out: false
         }) do
      %{timed_out: true} ->
        {:error, :timeout}

      %{exit_status: 0, exit_signal: nil} ->
        {:ok, %{"source" => source, "destination" => destination, "bytes" => size}}

      %{exit_status: 17} ->
        {:error, {:remote_exists, destination}}

      %{exit_status: 21} ->
        {:error, {:remote_is_directory, destination}}

      %{exit_status: 3} ->
        {:error, {:size_mismatch, size}}

      %{exit_status: status, exit_signal: sig, stderr: stderr} ->
        err_text = stderr |> IO.iodata_to_binary() |> SalixAgent.Utf8.scrub()
        {:error, {:remote_write_failed, status || sig, err_text}}
    end
  end

  defp collect_exit(conn, channel, deadline, acc) do
    remaining = max(deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsClock.vreceive do
      {:ssh_cm, ^conn, {:data, ^channel, 1, data}} ->
        :ssh_connection.adjust_window(conn, channel, byte_size(data))
        collect_exit(conn, channel, deadline, append_err(acc, data))

      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        :ssh_connection.adjust_window(conn, channel, byte_size(data))
        collect_exit(conn, channel, deadline, acc)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect_exit(conn, channel, deadline, %{acc | exit_status: status})

      {:ssh_cm, ^conn, {:exit_signal, ^channel, signal, _msg, _lang}} ->
        collect_exit(conn, channel, deadline, %{acc | exit_signal: to_string(signal)})

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect_exit(conn, channel, deadline, acc)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        acc
    after
      remaining ->
        :ssh_connection.close(conn, channel)
        %{acc | timed_out: true}
    end
  end

  # ---- download ----

  @doc """
  Stream a remote file (`source`) into VFS or `/drive/...` (`destination`) with
  atomic failure isolation: any non-zero exit, signal, disconnect, size overflow,
  or timeout throws `{:colab_download_failed, reason}` inside the stream BEFORE
  `:halt`, preventing any partial file from being committed to Drive or VFS.
  """
  @spec download(pid(), map(), String.t(), String.t(), boolean(), pos_integer()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def download(conn, ctx, source, destination, overwrite?, timeout_ms \\ 600_000)
      when is_pid(conn) and is_map(ctx) and is_binary(source) and is_binary(destination) and
             is_boolean(overwrite?) do
    with :ok <- validate_remote_path(source),
         resolved_src = resolve_remote_path(source),
         :ok <- vfs_absent(ctx, destination, overwrite?) do
      counter = :atomics.new(1, signed: false)
      stream = remote_download_stream(conn, resolved_src, timeout_ms, counter)
      opts = [if_none_match: not overwrite?]

      try do
        case FileBackend.prepare_write_stream(ctx, destination, stream, opts) do
          {:ok, nil} ->
            bytes = :atomics.get(counter, 1)
            {:ok, %{"source" => resolved_src, "destination" => destination, "bytes" => bytes}, []}

          {:ok, event} ->
            bytes = event["size"] || :atomics.get(counter, 1)

            {:ok, %{"source" => resolved_src, "destination" => destination, "bytes" => bytes},
             [event]}

          {:error, :destination_exists} ->
            {:error, {:destination_exists, destination}}

          {:error, {:throw, {:colab_download_failed, reason}}} ->
            {:error, reason}

          {:error, reason} ->
            {:error, {:vfs_write_failed, reason}}
        end
      catch
        {:colab_download_failed, reason} ->
          {:error, reason}
      end
    end
  end

  defp remote_download_stream(conn, source, timeout_ms, counter) do
    Stream.resource(
      fn ->
        deadline = SystemsClock.monotonic_time(:millisecond) + timeout_ms
        esc_src = shell_escape(source)
        cmd = "[ -f #{esc_src} ] || exit 2; cat -- #{esc_src}"
        mon = SystemsRuntime.Proc.monitor(conn)

        case :ssh_connection.session_channel(conn, @window, @packet, @op_timeout_ms) do
          {:ok, channel} ->
            case :ssh_connection.exec(conn, channel, String.to_charlist(cmd), @op_timeout_ms) do
              :success ->
                _ = :ssh_connection.send_eof(conn, channel)

                %{
                  conn: conn,
                  mon: mon,
                  channel: channel,
                  deadline: deadline,
                  bytes: 0,
                  exit_status: nil,
                  exit_signal: nil,
                  stderr: [],
                  stderr_size: 0,
                  closed: false,
                  source: source,
                  counter: counter
                }

              :failure ->
                safe_close_channel(conn, channel)
                SystemsRuntime.Proc.demonitor(mon, [:flush])
                throw({:colab_download_failed, :exec_refused})

              {:error, reason} ->
                safe_close_channel(conn, channel)
                SystemsRuntime.Proc.demonitor(mon, [:flush])
                throw({:colab_download_failed, {:remote_read_failed, reason}})

              other ->
                safe_close_channel(conn, channel)
                SystemsRuntime.Proc.demonitor(mon, [:flush])
                throw({:colab_download_failed, {:remote_read_failed, other}})
            end

          {:error, reason} ->
            SystemsRuntime.Proc.demonitor(mon, [:flush])
            throw({:colab_download_failed, {:remote_read_failed, reason}})

          other ->
            SystemsRuntime.Proc.demonitor(mon, [:flush])
            throw({:colab_download_failed, {:remote_read_failed, other}})
        end
      end,
      &next_download_chunk/1,
      fn state ->
        SystemsRuntime.Proc.demonitor(state.mon, [:flush])

        if not state.closed do
          try do
            :ssh_connection.close(state.conn, state.channel)
          catch
            _, _ -> :ok
          end
        end
      end
    )
  end

  defp next_download_chunk(%{closed: true} = state), do: {:halt, state}

  defp next_download_chunk(%{conn: conn, channel: ch, mon: mon, deadline: deadline} = state) do
    remaining = max(deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsClock.vreceive do
      {:ssh_cm, ^conn, {:data, ^ch, 0, data}} ->
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        new_bytes = state.bytes + byte_size(data)

        if new_bytes > @max_transfer_bytes do
          :ssh_connection.close(conn, ch)
          throw({:colab_download_failed, {:too_large, @max_transfer_bytes}})
        end

        :atomics.put(state.counter, 1, new_bytes)
        {[data], %{state | bytes: new_bytes}}

      {:ssh_cm, ^conn, {:data, ^ch, 1, data}} ->
        :ssh_connection.adjust_window(conn, ch, byte_size(data))
        next_download_chunk(append_err(state, data))

      {:ssh_cm, ^conn, {:exit_status, ^ch, status}} ->
        next_download_chunk(%{state | exit_status: status})

      {:ssh_cm, ^conn, {:exit_signal, ^ch, signal, _msg, _lang}} ->
        next_download_chunk(%{state | exit_signal: to_string(signal)})

      {:ssh_cm, ^conn, {:eof, ^ch}} ->
        next_download_chunk(state)

      {:ssh_cm, ^conn, {:closed, ^ch}} ->
        done_state = %{state | closed: true}

        cond do
          done_state.exit_status == 0 and is_nil(done_state.exit_signal) ->
            {:halt, done_state}

          done_state.exit_status == 2 ->
            throw({:colab_download_failed, {:remote_not_found, state.source}})

          true ->
            err_text = done_state.stderr |> IO.iodata_to_binary() |> SalixAgent.Utf8.scrub()

            throw(
              {:colab_download_failed,
               {:remote_exit, done_state.exit_status, done_state.exit_signal, err_text}}
            )
        end

      {:DOWN, ^mon, :process, ^conn, reason} ->
        throw({:colab_download_failed, {:disconnected, reason}})
    after
      remaining ->
        :ssh_connection.close(conn, ch)
        throw({:colab_download_failed, :timeout})
    end
  end

  # ---- helpers ----

  defp append_err(acc, data) do
    keep = binary_part(data, 0, min(byte_size(data), max(@max_err_bytes - acc.stderr_size, 0)))

    acc
    |> Map.update!(:stderr, &[&1, keep])
    |> Map.put(:stderr_size, acc.stderr_size + byte_size(data))
  end

  defp validate_remote_path(path) do
    cond do
      path == "" -> {:error, :invalid_remote_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_remote_path}
      true -> :ok
    end
  end

  defp resolve_remote_path("/" <> _ = path), do: path
  defp resolve_remote_path(path), do: Path.join("/content", path)

  defp remote_parent(destination) do
    case Path.dirname(destination) do
      "" -> "."
      dir -> dir
    end
  end

  defp vfs_source(ctx, path) do
    case FileBackend.stream_with_optional_size(ctx, path) do
      {:ok, stream, size} -> {:ok, stream, size}
      {:error, :not_found} -> {:error, {:vfs_not_found, path}}
      {:error, reason} -> {:error, {:vfs_read_failed, reason}}
    end
  end

  defp vfs_absent(_ctx, _path, true), do: :ok

  defp vfs_absent(ctx, path, false) do
    case FileBackend.stat(ctx, path) do
      {:ok, _} -> {:error, {:destination_exists, path}}
      {:error, :not_found} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:vfs_stat_failed, reason}}
    end
  end

  defp within_limit(size) when is_integer(size) and size > @max_transfer_bytes,
    do: {:error, {:too_large, @max_transfer_bytes}}

  defp within_limit(_size), do: :ok
end
