defmodule SalixWeb.CloudVM.DurableArchive do
  @moduledoc """
  Transfers a quiesced Connector archive into the existing Salix object store.

  The Group Workload remains the only archive owner. The operation ID fences
  retries and keeps incomplete chunk generations invisible to restore.
  """

  alias SalixEnv.VM.Providers.Cloudflare.Client
  alias SalixWeb.CloudVM.{ArchiveR2, ArchiveDiagnostics}
  alias SalixStore.S3
  require Logger

  @chunk_size 4 * 1024 * 1024
  @max_bytes 4 * 1024 * 1024 * 1024
  @polls 900
  # Export can consume 15 minutes. Leave time inside the 70-minute quiesce
  # lease for the final owner check and release after the transfer completes.
  @transfer_budget_ms 45 * 60_000
  @restore_budget_ms 45 * 60_000
  @r2_upload_concurrency 8

  def export(%Client{} = client, sandbox_id, group_id, operation, progress \\ fn _ -> :ok end) do
    started_at = System.monotonic_time(:millisecond)

    format =
      if get_in(Application.get_env(:salix_web, :cloud_vm_archive_r2), ["zstd_enabled"]) == true,
        do: "tar_zst",
        else: "tar_gz"

    result =
      with :ok <- progress.(%{"phase" => "starting", "packed_bytes" => 0, "uploaded_bytes" => 0}),
           {:ok, transfers} <- stream_upload_transfers(format, group_id, operation),
           {:ok, _} <-
             Client.archive_export(client, sandbox_id, operation, :post, format, transfers),
           {:ok, %{"phase" => "exported", "bytes" => bytes, "sessions" => sessions} = exported} <-
             await_export(client, sandbox_id, group_id, operation, @polls, progress),
           true <- (exported["format"] || "tar_gz") == format,
           true <-
             is_integer(bytes) and bytes > 0 and bytes <= @max_bytes and
               is_integer(sessions) and sessions >= 0,
           {:ok, storage} <-
             if(format == "tar_zst",
               do: {:ok, "r2"},
               else:
                 transfer_chunks(
                   client,
                   sandbox_id,
                   group_id,
                   operation,
                   bytes,
                   System.monotonic_time(:millisecond) + @transfer_budget_ms,
                   progress
                 )
             ) do
        Logger.info(
          "cloud_vm_archive stage=complete group=#{group_id} operation=#{operation} storage=#{storage} bytes=#{bytes} duration_ms=#{System.monotonic_time(:millisecond) - started_at}"
        )

        {:ok,
         %{
           "type" =>
             if(format == "tar_zst",
               do: "connector_tar_zst_chunks",
               else: "connector_tar_gz_chunks"
             ),
           "storage" => storage,
           "operation" => operation,
           "byte_size" => bytes,
           "chunk_size" => @chunk_size,
           "chunk_count" => div(bytes + @chunk_size - 1, @chunk_size),
           "sessions" => sessions
         }}
      else
        false -> {:error, :invalid_durable_archive_export}
        {:error, _} = error -> error
        _ -> {:error, :invalid_durable_archive_export}
      end

    if match?({:error, _}, result),
      do:
        Logger.warning(
          "cloud_vm_archive stage=failed group=#{group_id} operation=#{operation} duration_ms=#{System.monotonic_time(:millisecond) - started_at} reason=#{inspect(result)}"
        )

    ArchiveDiagnostics.observe(group_id, operation, "export", %{
      "salix_duration_ms" => System.monotonic_time(:millisecond) - started_at,
      "outcome" =>
        if(match?({:ok, _}, result),
          do: "ok",
          else:
            if(result in [{:error, :archive_cancel_requested}, {:error, :archive_cancelled}],
              do: "cancelled",
              else: "error"
            )
        )
    })

    if result in [{:error, :archive_cancel_requested}, {:error, :archive_operation_lost}],
      do: cancel_export(client, sandbox_id, operation),
      else: result
  end

  defp stream_upload_transfers("tar_gz", _group_id, _operation), do: {:ok, nil}

  defp stream_upload_transfers("tar_zst", group_id, operation) do
    count = div(@max_bytes + @chunk_size - 1, @chunk_size)

    0..(count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, transfers} ->
      case ArchiveR2.transfer_urls(chunk_key(group_id, operation, index), 3_600) do
        {:ok, urls} -> {:cont, {:ok, [urls | transfers]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, transfers} -> {:ok, Enum.reverse(transfers)}
      error -> error
    end
  end

  defp await_export(_client, _sandbox_id, _group_id, _operation, 0, _progress),
    do: {:error, :durable_archive_export_timeout}

  defp await_export(client, sandbox_id, group_id, operation, remaining, progress) do
    case observe_response(
           group_id,
           operation,
           "export",
           Client.archive_export(client, sandbox_id, operation)
         ) do
      {:ok, %{"phase" => "exported"} = result} ->
        case progress.(%{
               "phase" => "exported",
               "packed_bytes" => result["bytes"],
               "packed_at" => result["progress_at"],
               "uploaded_bytes" => result["uploaded_bytes"] || 0,
               "total_bytes" => result["bytes"]
             }) do
          :ok -> {:ok, result}
          error -> error
        end

      {:ok, %{"phase" => "preparing"} = state} ->
        case progress.(%{
               "phase" => "exporting",
               "packed_bytes" => state["packed_bytes"] || 0,
               "packed_at" => state["progress_at"],
               "uploaded_bytes" => state["uploaded_bytes"] || 0
             }) do
          :ok ->
            Process.sleep(1_000)
            await_export(client, sandbox_id, group_id, operation, remaining - 1, progress)

          error ->
            error
        end

      {:ok, %{"phase" => "cancelled"}} ->
        {:error, :archive_cancelled}

      {:ok, %{"phase" => "failed"}} ->
        {:error, :durable_archive_export_failed}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_durable_archive_export}
    end
  end

  defp transfer_chunks(client, sandbox_id, group_id, operation, bytes, deadline, progress) do
    case upload_chunks(client, sandbox_id, group_id, operation, bytes, deadline, progress) do
      :ok ->
        {:ok, "r2"}

      {:error, :archive_direct_transfer_unsupported} ->
        with :ok <-
               upload_s3_chunks(
                 client,
                 sandbox_id,
                 group_id,
                 operation,
                 bytes,
                 deadline,
                 progress
               ),
             do: {:ok, "salix_s3"}

      {:error, _} = error ->
        error
    end
  end

  defp upload_chunks(client, sandbox_id, group_id, operation, bytes, deadline, progress) do
    count = div(bytes + @chunk_size - 1, @chunk_size)
    started_at = System.monotonic_time(:millisecond)

    # The first request discovers an older Connector before any parallel work
    # starts, so only the unsupported response may select the S3 fallback.
    with :ok <- report_transfer(progress, bytes, 0),
         :ok <- upload_r2_part(client, sandbox_id, group_id, operation, bytes, deadline, 0),
         :ok <- report_transfer(progress, bytes, min(bytes, @chunk_size)),
         :ok <-
           upload_r2_remaining(
             client,
             sandbox_id,
             group_id,
             operation,
             bytes,
             count,
             deadline,
             progress
           ) do
      Logger.info(
        "cloud_vm_archive stage=r2_upload group=#{group_id} operation=#{operation} bytes=#{bytes} parts=#{count} concurrency=#{@r2_upload_concurrency} duration_ms=#{System.monotonic_time(:millisecond) - started_at}"
      )

      :ok
    end
  end

  defp upload_r2_remaining(
         _client,
         _sandbox_id,
         _group_id,
         _operation,
         _bytes,
         1,
         _deadline,
         _progress
       ),
       do: :ok

  defp upload_r2_remaining(
         client,
         sandbox_id,
         group_id,
         operation,
         bytes,
         count,
         deadline,
         progress
       ) do
    1..(count - 1)
    |> Enum.chunk_every(@r2_upload_concurrency)
    |> Enum.reduce_while(:ok, fn indexes, :ok ->
      results =
        Task.async_stream(
          indexes,
          fn index ->
            upload_r2_part(client, sandbox_id, group_id, operation, bytes, deadline, index)
          end,
          max_concurrency: @r2_upload_concurrency,
          timeout: 90_000,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      case Enum.find(results, &(&1 != {:ok, :ok})) do
        nil ->
          uploaded = min(bytes, (List.last(indexes) + 1) * @chunk_size)

          case report_transfer(progress, bytes, uploaded) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        {:ok, {:error, _} = error} ->
          {:halt, error}

        _ ->
          {:halt, {:error, :durable_archive_transfer_failed}}
      end
    end)
  end

  defp upload_r2_part(client, sandbox_id, group_id, operation, bytes, deadline, index) do
    offset = index * @chunk_size

    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :durable_archive_transfer_expired}
    else
      with {:ok, urls} <- ArchiveR2.transfer_urls(chunk_key(group_id, operation, index)),
           {:ok, %{"operation" => ^operation, "next_offset" => next}} <-
             Client.archive_export_signed_part(client, sandbox_id, operation, offset, urls),
           true <- next == offset + min(@chunk_size, bytes - offset) do
        :ok
      else
        false ->
          {:error, :durable_archive_chunk_size_mismatch}

        {:error, {:api_error, status, _}} when index == 0 and status in [405, 501] ->
          {:error, :archive_direct_transfer_unsupported}

        {:error, {:api_error, status, _, _}} when index == 0 and status in [405, 501] ->
          {:error, :archive_direct_transfer_unsupported}

        {:error, _} = error ->
          error

        _ ->
          {:error, :invalid_durable_archive_chunk}
      end
    end
  end

  defp report_transfer(progress, bytes, uploaded) do
    progress.(%{
      "phase" => "transferring",
      "packed_bytes" => bytes,
      "uploaded_bytes" => uploaded,
      "total_bytes" => bytes
    })
  end

  defp upload_s3_chunks(client, sandbox_id, group_id, operation, bytes, deadline, progress) do
    count = div(bytes + @chunk_size - 1, @chunk_size)

    Enum.reduce_while(0..(count - 1), :ok, fn index, :ok ->
      offset = index * @chunk_size

      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, {:error, :durable_archive_transfer_expired}}
      else
        with :ok <-
               progress.(%{
                 "phase" => "transferring",
                 "packed_bytes" => bytes,
                 "uploaded_bytes" => offset,
                 "total_bytes" => bytes
               }),
             {:ok, %{"operation" => ^operation, "offset" => ^offset, "data" => encoded}} <-
               Client.archive_export_part(client, sandbox_id, operation, offset),
             {:ok, data} <- Base.decode64(encoded),
             true <- byte_size(data) == min(@chunk_size, bytes - offset),
             :ok <- put_exact_s3(chunk_key(group_id, operation, index), data),
             :ok <-
               progress.(%{
                 "phase" => "transferring",
                 "packed_bytes" => bytes,
                 "uploaded_bytes" => offset + byte_size(data),
                 "total_bytes" => bytes
               }) do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :durable_archive_chunk_size_mismatch}}
          :error -> {:halt, {:error, :invalid_durable_archive_chunk}}
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, {:error, :invalid_durable_archive_chunk}}
        end
      end
    end)
  end

  defp put_exact_s3(key, data) do
    case S3.put(key, data, if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> compare_s3_chunk(key, data)
      {:error, {:ambiguous, _}} -> compare_s3_chunk(key, data)
      {:error, _} = error -> error
    end
  end

  defp compare_s3_chunk(key, data) do
    case S3.get(key) do
      {:ok, %{body: ^data}} -> :ok
      {:ok, _} -> {:error, :durable_archive_chunk_conflict}
      {:error, _} = error -> error
    end
  end

  def cancel(%Client{} = client, sandbox_id, operation) do
    case Client.archive_export(client, sandbox_id, operation, :delete) do
      {:ok, _} -> await_cancelled(client, sandbox_id, operation, 30)
      {:error, _} -> {:error, :archive_cancel_unconfirmed}
    end
  end

  defp cancel_export(client, sandbox_id, operation) do
    case cancel(client, sandbox_id, operation) do
      :ok -> {:error, :archive_cancelled}
      error -> error
    end
  end

  defp await_cancelled(_client, _sandbox_id, _operation, 0),
    do: {:error, :archive_cancel_unconfirmed}

  defp await_cancelled(client, sandbox_id, operation, remaining) do
    case Client.archive_export(client, sandbox_id, operation) do
      {:ok, %{"phase" => "cancelled"}} ->
        :ok

      {:ok, %{"phase" => phase}} when phase in ["preparing", "exported", "cancelling"] ->
        Process.sleep(1_000)
        await_cancelled(client, sandbox_id, operation, remaining - 1)

      _ ->
        {:error, :archive_cancel_unconfirmed}
    end
  end

  def chunk_key(group_id, operation, index)
      when is_binary(group_id) and is_binary(operation) and is_integer(index) and index >= 0 do
    "compute/cloudflare-archives/#{URI.encode(group_id)}/#{URI.encode(operation)}/#{index}"
  end

  def chunk_prefix(group_id, operation)
      when is_binary(group_id) and is_binary(operation) do
    "compute/cloudflare-archives/#{URI.encode(group_id)}/#{URI.encode(operation)}/"
  end

  def valid_manifest?(%{
        "type" => type,
        "storage" => storage,
        "operation" => operation,
        "byte_size" => bytes,
        "chunk_size" => @chunk_size,
        "chunk_count" => count,
        "sessions" => sessions
      }) do
    type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] and
      storage in ["salix_s3", "r2"] and is_binary(operation) and operation != "" and
      is_integer(bytes) and bytes > 0 and
      bytes <= @max_bytes and is_integer(count) and
      count == div(bytes + @chunk_size - 1, @chunk_size) and
      is_integer(sessions) and sessions >= 0
  end

  def valid_manifest?(_), do: false

  def read_chunks(%{"type" => type} = archive, group_id, fun)
      when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] and is_function(fun, 2) do
    with true <- valid_manifest?(archive),
         %{"operation" => operation, "byte_size" => bytes, "chunk_count" => count} <- archive do
      Enum.reduce_while(0..(count - 1), :ok, fn index, :ok ->
        with {:ok, %{body: data}} <- S3.get(chunk_key(group_id, operation, index)),
             true <- byte_size(data) == min(@chunk_size, bytes - index * @chunk_size),
             :ok <- fun.(index * @chunk_size, data) do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :durable_archive_chunk_size_mismatch}}
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, {:error, :durable_archive_restore_failed}}
        end
      end)
    else
      false -> {:error, :invalid_durable_archive_manifest}
      _ -> {:error, :invalid_durable_archive_manifest}
    end
  end

  def check_chunks(archive, group_id) do
    if valid_manifest?(archive) do
      %{
        "operation" => operation,
        "byte_size" => bytes,
        "chunk_size" => chunk_size,
        "chunk_count" => count
      } = archive

      result =
        Enum.reduce_while(0..(count - 1), :ok, fn index, :ok ->
          expected = min(chunk_size, bytes - index * chunk_size)

          result =
            if archive["storage"] == "r2" do
              ArchiveR2.head(chunk_key(group_id, operation, index))
            else
              case S3.head(chunk_key(group_id, operation, index)) do
                {:ok, %{size: size}} -> {:ok, size}
                error -> error
              end
            end

          case result do
            {:ok, ^expected} -> {:cont, :ok}
            {:ok, _} -> {:halt, {:error, :durable_archive_chunk_size_mismatch}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      if archive["storage"] == "r2" and match?({:error, _}, result) and
           s3_generation_complete?(archive, group_id),
         do: :ok,
         else: result
    else
      {:error, :invalid_durable_archive_manifest}
    end
  end

  def restore(
        %Client{} = client,
        sandbox_id,
        group_id,
        %{"type" => type} = archive,
        opts \\ []
      )
      when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] do
    deadline = System.monotonic_time(:millisecond) + @restore_budget_ms

    result =
      with true <- valid_manifest?(archive),
           %{"operation" => operation, "byte_size" => bytes, "sessions" => sessions} <- archive,
           :ok <-
             restore_or_confirm(
               client,
               sandbox_id,
               group_id,
               archive,
               operation,
               bytes,
               sessions,
               Keyword.get(opts, :require_new, false),
               Keyword.get(opts, :on_transfer_complete, fn -> :ok end),
               deadline
             ) do
        :ok
      else
        false -> {:error, :invalid_durable_archive_manifest}
        {:error, _} = error -> error
        _ -> {:error, :invalid_durable_archive_manifest}
      end

    ArchiveDiagnostics.observe(group_id, archive["operation"], "restore", %{
      "salix_duration_ms" => System.monotonic_time(:millisecond) + @restore_budget_ms - deadline,
      "outcome" => if(result == :ok, do: "ok", else: "error")
    })

    result
  end

  defp observed_import(client, sandbox_id, group_id, body) do
    observe_response(
      group_id,
      body["operation"],
      "restore",
      Client.archive_import(client, sandbox_id, body)
    )
  end

  defp observe_response(group, operation, direction, {:ok, response} = result)
       when is_map(response) do
    diagnostics = if is_map(response["diagnostics"]), do: response["diagnostics"], else: %{}

    if response["phase"] in ~w(exported restored failed cancelled) or
         diagnostics["outcome"] in ~w(failed cancelled) do
      ArchiveDiagnostics.observe(
        group,
        operation,
        direction,
        diagnostics
        |> Map.put("connector_outcome", diagnostics["outcome"] || response["phase"])
        |> Map.delete("outcome")
      )
    end

    result
  rescue
    _ -> result
  catch
    _, _ -> result
  end

  defp observe_response(_, _, _, result), do: result

  defp restore_or_confirm(
         client,
         sandbox_id,
         group_id,
         archive,
         operation,
         bytes,
         sessions,
         require_new,
         on_transfer_complete,
         deadline
       ) do
    case observed_import(client, sandbox_id, group_id, %{
           "operation" => operation,
           "action" => "status"
         }) do
      {:ok, %{"phase" => "restored", "next_offset" => ^bytes, "sessions" => ^sessions}} ->
        if require_new, do: {:error, :durable_archive_already_restored}, else: :ok

      {:ok, %{"phase" => "restored"}} ->
        {:error, :durable_archive_restore_mismatch}

      {:ok, %{"phase" => phase}} when phase in [nil, "", "pending", "receiving"] ->
        replay_restore(
          client,
          sandbox_id,
          group_id,
          archive,
          operation,
          bytes,
          sessions,
          on_transfer_complete,
          deadline
        )

      {:ok, %{"phase" => "restoring"}} ->
        {:error, :durable_archive_partial_target}

      {:ok, _} ->
        {:error, :durable_archive_restore_mismatch}

      {:error, _} = error ->
        error
    end
  end

  defp replay_restore(
         client,
         sandbox_id,
         group_id,
         archive,
         operation,
         bytes,
         sessions,
         on_transfer_complete,
         deadline
       ) do
    if archive["type"] == "connector_tar_zst_chunks" and archive["storage"] == "r2" do
      stream_restore(
        client,
        sandbox_id,
        group_id,
        archive,
        operation,
        bytes,
        sessions,
        on_transfer_complete,
        deadline
      )
    else
      replay_restore_parts(
        client,
        sandbox_id,
        group_id,
        archive,
        operation,
        bytes,
        sessions,
        on_transfer_complete,
        deadline
      )
    end
  end

  defp stream_restore(
         client,
         sandbox_id,
         group_id,
         archive,
         operation,
         bytes,
         sessions,
         on_transfer_complete,
         deadline
       ) do
    started_at = System.monotonic_time(:millisecond)
    count = archive["chunk_count"]

    result =
      with :ok <- within_restore_budget(deadline),
           {:ok, parts} <- signed_restore_parts(group_id, operation, bytes, count),
           :ok <- within_restore_budget(deadline),
           {:ok, %{"phase" => "restored", "bytes" => ^bytes, "sessions" => ^sessions}} <-
             observed_import(client, sandbox_id, group_id, %{
               "operation" => operation,
               "action" => "stream",
               "format" => "tar_zst",
               "bytes" => bytes,
               "sessions" => sessions,
               "parts" => parts,
               "runtime_paths" => []
             }) do
        :ok
      else
        {:error, _} = error ->
          case observed_import(client, sandbox_id, group_id, %{
                 "operation" => operation,
                 "action" => "status"
               }) do
            {:ok, %{"phase" => "restored", "next_offset" => ^bytes, "sessions" => ^sessions}} ->
              :ok

            _ ->
              error
          end

        _ ->
          {:error, :durable_archive_restore_mismatch}
      end

    with :ok <- result,
         :ok <- on_transfer_complete.() do
      Logger.info(
        "cloud_vm_archive stage=stream_restore group=#{group_id} operation=#{operation} bytes=#{bytes} parts=#{count} duration_ms=#{System.monotonic_time(:millisecond) - started_at}"
      )

      :ok
    end
  end

  defp signed_restore_parts(group_id, operation, bytes, count) do
    0..(count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, parts} ->
      case ArchiveR2.read_url(chunk_key(group_id, operation, index), 1_800) do
        {:ok, url} ->
          part = %{"source_url" => url, "bytes" => min(@chunk_size, bytes - index * @chunk_size)}
          {:cont, {:ok, [part | parts]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp replay_restore_parts(
         client,
         sandbox_id,
         group_id,
         archive,
         operation,
         bytes,
         sessions,
         on_transfer_complete,
         deadline
       ) do
    with :ok <-
           transfer_restore_chunks(archive, group_id, fn offset, part ->
             with :ok <- within_restore_budget(deadline) do
               body =
                 Map.merge(
                   %{"operation" => operation, "action" => "part", "offset" => offset},
                   part
                 )

               expected_next = offset + part["bytes"]

               case Client.archive_import(client, sandbox_id, body) do
                 {:ok, %{"next_offset" => next}} when next >= expected_next -> :ok
                 {:ok, _} -> {:error, :durable_archive_import_offset_mismatch}
                 {:error, _} = error -> error
               end
             end
           end),
         :ok <- on_transfer_complete.(),
         :ok <- within_restore_budget(deadline),
         {:ok, %{"phase" => "restored", "bytes" => ^bytes, "sessions" => ^sessions}} <-
           observed_import(client, sandbox_id, group_id, %{
             "operation" => operation,
             "action" => "finish",
             "format" =>
               if(archive["type"] == "connector_tar_zst_chunks", do: "tar_zst", else: "tar_gz"),
             "bytes" => bytes,
             "sessions" => sessions,
             "runtime_paths" => []
           }) do
      :ok
    else
      {:ok, _} -> {:error, :durable_archive_restore_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :durable_archive_restore_mismatch}
    end
  end

  defp transfer_restore_chunks(%{"storage" => "r2"} = archive, group_id, fun) do
    case stream_r2_chunks(archive, group_id, fun) do
      :ok ->
        :ok

      {:error, _} = error ->
        # Fallback is a complete copy of this same archive generation only.
        if s3_generation_complete?(archive, group_id) do
          read_chunks(archive, group_id, fn offset, data ->
            fun.(offset, %{"data" => Base.encode64(data), "bytes" => byte_size(data)})
          end)
        else
          error
        end
    end
  end

  defp transfer_restore_chunks(archive, group_id, fun) do
    read_chunks(archive, group_id, fn offset, data ->
      fun.(offset, %{"data" => Base.encode64(data), "bytes" => byte_size(data)})
    end)
  end

  defp stream_r2_chunks(
         %{"operation" => operation, "byte_size" => bytes, "chunk_count" => count},
         group_id,
         fun
       ) do
    Enum.reduce_while(0..(count - 1), :ok, fn index, :ok ->
      with {:ok, url} <- ArchiveR2.read_url(chunk_key(group_id, operation, index)),
           :ok <-
             fun.(index * @chunk_size, %{
               "source_url" => url,
               "bytes" => min(@chunk_size, bytes - index * @chunk_size)
             }) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :durable_archive_restore_failed}}
      end
    end)
  end

  defp s3_generation_complete?(archive, group_id) do
    %{"operation" => operation, "byte_size" => bytes, "chunk_count" => count} = archive

    Enum.all?(0..(count - 1), fn index ->
      case S3.head(chunk_key(group_id, operation, index)) do
        {:ok, %{size: size}} -> size == min(@chunk_size, bytes - index * @chunk_size)
        _ -> false
      end
    end)
  end

  defp within_restore_budget(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, :durable_archive_restore_expired}
  end
end
