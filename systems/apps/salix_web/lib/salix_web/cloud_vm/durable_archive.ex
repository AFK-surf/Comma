defmodule SalixWeb.CloudVM.DurableArchive do
  @moduledoc """
  Moves a Cloud VM's archive between its station and object storage.

  The Group Workload remains the only archive owner. Out, the station packs
  its root as a zstd tar straight into R2 through signed part URLs
  (`archive_export`, followed with `archive_status`, stopped with
  `archive_cancel`) over its connection: `call` sends one request to the VM's
  current station. Back, no station takes an archive: the Container that a
  wake starts is given one signed read URL, of a manifest that lists the
  archive's parts (`restore_instruction/2`), and its image unpacks them onto
  the empty disk before it starts the station. The station that then connects holds that
  restore's receipt (`archive_status`, kind `import`). The operation ID fences retries and keeps
  incomplete chunk generations invisible to restore. Archives the retired
  connector wrote as gzip, or kept in Salix S3, cannot be restored for a
  station: under the Cloud VM data policy that VM starts empty.
  """

  alias SalixWeb.CloudVM.ArchiveR2
  alias SalixStore.S3
  require Logger

  @chunk_size 4 * 1024 * 1024
  @max_bytes 4 * 1024 * 1024 * 1024
  @polls 900
  @request_ms 30_000
  @restore_url_seconds 3_600

  @type call :: (String.t(), map(), pos_integer() -> {:ok, map()} | {:error, term()})

  @spec export(call(), String.t(), String.t(), (map() -> :ok | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def export(call, group_id, operation, progress \\ fn _ -> :ok end) do
    started_at = SystemsClock.monotonic_time(:millisecond)

    result =
      with :ok <- progress.(%{"phase" => "starting", "packed_bytes" => 0, "uploaded_bytes" => 0}),
           {:ok, transfers} <- upload_transfers(group_id, operation),
           {:ok, _} <-
             call.(
               "archive_export",
               %{"operation" => operation, "scope" => "full", "transfers" => transfers},
               @request_ms
             ),
           {:ok, %{"phase" => "exported", "bytes" => bytes, "sessions" => sessions}} <-
             await_export(call, operation, @polls, progress),
           true <-
             is_integer(bytes) and bytes > 0 and bytes <= @max_bytes and
               is_integer(sessions) and sessions >= 0 do
        Logger.info(
          "cloud_vm_archive stage=complete group=#{group_id} operation=#{operation} bytes=#{bytes} duration_ms=#{SystemsClock.monotonic_time(:millisecond) - started_at}"
        )

        {:ok,
         %{
           "type" => "connector_tar_zst_chunks",
           "storage" => "r2",
           "scope" => "full",
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
          "cloud_vm_archive stage=failed group=#{group_id} operation=#{operation} duration_ms=#{SystemsClock.monotonic_time(:millisecond) - started_at} reason=#{inspect(result)}"
        )

    if result in [{:error, :archive_cancel_requested}, {:error, :archive_operation_lost}] do
      case cancel(call, operation) do
        :ok -> {:error, :archive_cancelled}
        error -> error
      end
    else
      result
    end
  end

  defp upload_transfers(group_id, operation) do
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

  defp await_export(_call, _operation, 0, _progress),
    do: {:error, :durable_archive_export_timeout}

  defp await_export(call, operation, remaining, progress) do
    case call.("archive_status", %{"operation" => operation}, @request_ms) do
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
            SystemsClock.sleep(1_000)
            await_export(call, operation, remaining - 1, progress)

          error ->
            error
        end

      {:ok, %{"phase" => "cancelled"}} ->
        {:error, :archive_cancelled}

      {:ok, %{"phase" => "failed"} = state} ->
        Logger.warning(
          "cloud_vm_archive stage=export_failed operation=#{operation} error=#{inspect(state["error"])}"
        )

        {:error, :durable_archive_export_failed}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_durable_archive_export}
    end
  end

  @spec cancel(call(), String.t()) :: :ok | {:error, :archive_cancel_unconfirmed}
  def cancel(call, operation) do
    case call.("archive_cancel", %{"operation" => operation}, @request_ms) do
      {:ok, _} -> await_cancelled(call, operation, 30)
      {:error, _} -> {:error, :archive_cancel_unconfirmed}
    end
  end

  defp await_cancelled(_call, _operation, 0), do: {:error, :archive_cancel_unconfirmed}

  defp await_cancelled(call, operation, remaining) do
    case call.("archive_status", %{"operation" => operation}, @request_ms) do
      {:ok, %{"phase" => "cancelled"}} ->
        :ok

      {:ok, %{"phase" => phase}} when phase in ["preparing", "exported", "cancelling"] ->
        SystemsClock.sleep(1_000)
        await_cancelled(call, operation, remaining - 1)

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

  def valid_manifest?(
        %{
          "type" => type,
          "storage" => storage,
          "operation" => operation,
          "byte_size" => bytes,
          "chunk_size" => @chunk_size,
          "chunk_count" => count,
          "sessions" => sessions
        } = archive
      ) do
    type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] and
      storage in ["salix_s3", "r2"] and is_binary(operation) and operation != "" and
      is_integer(bytes) and bytes > 0 and
      bytes <= @max_bytes and is_integer(count) and
      count == div(bytes + @chunk_size - 1, @chunk_size) and
      is_integer(sessions) and sessions >= 0 and archive["scope"] in [nil, "full", "recovery"]
  end

  def valid_manifest?(_), do: false

  def check_chunks(archive, group_id, check \\ fn -> :ok end) do
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
            with :ok <- check.() do
              if archive["storage"] == "r2" do
                ArchiveR2.head(chunk_key(group_id, operation, index))
              else
                case S3.head(chunk_key(group_id, operation, index)) do
                  {:ok, %{size: size}} -> {:ok, size}
                  error -> error
                end
              end
            end

          case result do
            {:ok, ^expected} -> {:cont, :ok}
            {:ok, _} -> {:halt, {:error, :durable_archive_chunk_size_mismatch}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      if archive["storage"] == "r2" and match?({:error, _}, result) and
           s3_generation_complete?(archive, group_id, check),
         do: :ok,
         else: result
    else
      {:error, :invalid_durable_archive_manifest}
    end
  end

  @doc "Whether a station can restore this archive: a zstd archive in R2."
  def restorable?(archive),
    do:
      valid_manifest?(archive) and archive["type"] == "connector_tar_zst_chunks" and
        archive["storage"] == "r2"

  @doc """
  What a Container's start is given so that its disk is `archive` before its
  station starts: one small environment value, the same size for every
  archive (base64 of the JSON `operation`, `bytes`, `manifest_url`).

  The archive's parts are listed in a manifest object written now, next to
  them in R2: each part's read URL, signed for an hour. The value carries one
  read URL for that manifest, signed for the same hour. Nothing the Container
  is given outlives the hour, and Salix signs with its own key only. An
  archive from before manifests gets its manifest the same way, here.
  """
  @spec restore_instruction(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def restore_instruction(group_id, archive) do
    with true <- restorable?(archive) || {:error, :durable_archive_format_retired},
         %{"operation" => operation, "byte_size" => bytes, "chunk_count" => count} <- archive,
         {:ok, parts} <- signed_restore_parts(group_id, operation, bytes, count),
         key = manifest_key(group_id, operation),
         manifest = Jason.encode!(%{"operation" => operation, "bytes" => bytes, "parts" => parts}),
         :ok <- ArchiveR2.put(key, manifest),
         {:ok, url} <- ArchiveR2.read_url(key, @restore_url_seconds) do
      {:ok,
       Base.encode64(
         Jason.encode!(%{"operation" => operation, "bytes" => bytes, "manifest_url" => url})
       )}
    end
  end

  @doc "The restore manifest of an archive generation: under its prefix, so it is deleted with it."
  def manifest_key(group_id, operation),
    do: chunk_prefix(group_id, operation) <> "restore-manifest"

  defp signed_restore_parts(group_id, operation, bytes, count) do
    0..(count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, parts} ->
      case ArchiveR2.read_url(chunk_key(group_id, operation, index), @restore_url_seconds) do
        {:ok, url} ->
          part = %{"get_url" => url, "bytes" => min(@chunk_size, bytes - index * @chunk_size)}
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

  defp s3_generation_complete?(archive, group_id, check) do
    %{"operation" => operation, "byte_size" => bytes, "chunk_count" => count} = archive

    Enum.all?(0..(count - 1), fn index ->
      with :ok <- check.(),
           {:ok, %{size: size}} <- S3.head(chunk_key(group_id, operation, index)) do
        size == min(@chunk_size, bytes - index * @chunk_size)
      else
        _ -> false
      end
    end)
  end
end
