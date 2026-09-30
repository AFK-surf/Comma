defmodule SalixAgent.PreparedBlobCleanup do
  @moduledoc """
  Bounded durable reconciliation for uncommitted workspace blob preparations.

  Meeting artifact ingestion stores a cleanup intent before it starts writing a
  body.  A successful workspace manifest commit deletes that intent.  If the
  preparing process crashes, is killed, loses an idempotency race, or cannot
  delete immediately, this worker waits past the maximum transfer window and
  then either adopts a manifest/operation-referenced blob or removes the
  uncommitted body and every incomplete multipart upload for its exact blob
  key. Storage failures retain the intent for the next pass.
  """

  use GenServer
  require Logger

  alias SalixAgent.AgentWorkspace
  alias SalixStore.{Ids, Keys, S3}

  @default_interval_ms 60_000
  @default_grace_seconds 10 * 60
  @default_batch_size 64
  @max_uploads_per_intent 8

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def nudge do
    if pid = Process.whereis(__MODULE__), do: send(pid, :sweep)
    :ok
  end

  @doc false
  def sweep_once(opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    grace = Keyword.get(opts, :grace_seconds, configured_grace_seconds())
    batch_size = Keyword.get(opts, :batch_size, configured_batch_size())

    with {:ok, cursor} <- read_cursor(),
         {:ok, %{objects: objects}} <- list_rotating_page(cursor, batch_size) do
      summary =
        Enum.reduce(objects, %{examined: 0, cleaned: 0, retained: 0}, fn object, acc ->
          result = reconcile_key(object.key, now, grace)
          emit_outcome(result)

          acc
          |> Map.update!(:examined, &(&1 + 1))
          |> Map.update!(if(result == :cleaned, do: :cleaned, else: :retained), &(&1 + 1))
        end)

      case persist_cursor(objects) do
        :ok ->
          {:ok, summary}

        {:error, _} = error ->
          emit_outcome(:scan_error)
          error
      end
    else
      {:error, _} = error ->
        emit_outcome(:scan_error)
        error
    end
  end

  defp list_rotating_page(cursor, batch_size) do
    opts = [max_keys: batch_size]
    opts = if is_binary(cursor), do: Keyword.put(opts, :start_after, cursor), else: opts

    case S3.list(Keys.prepared_blob_cleanup_prefix(), opts) do
      {:ok, %{objects: []}} when is_binary(cursor) ->
        S3.list(Keys.prepared_blob_cleanup_prefix(), max_keys: batch_size)

      result ->
        result
    end
  end

  defp read_cursor do
    case S3.get(Keys.prepared_blob_cleanup_cursor()) do
      {:ok, %{body: body}} ->
        with {:ok, %{"last_key" => key}} when is_binary(key) <- Jason.decode(body),
             true <- String.starts_with?(key, Keys.prepared_blob_cleanup_prefix()) do
          {:ok, key}
        else
          _ -> {:error, :invalid_prepared_blob_cleanup_cursor}
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  defp persist_cursor([]), do: :ok

  defp persist_cursor(objects) do
    last_key = objects |> List.last() |> Map.fetch!(:key)

    case S3.put(
           Keys.prepared_blob_cleanup_cursor(),
           Jason.encode!(%{"version" => 1, "last_key" => last_key})
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, configured_interval_ms())
    {:ok, %{interval_ms: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep_once() do
      {:ok, _summary} -> :ok
      {:error, reason} -> Logger.warning("prepared blob cleanup sweep failed: #{inspect(reason)}")
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp reconcile_key(key, now, grace) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} <- Jason.decode(body),
         :ok <- validate_record(record),
         true <- expired?(record, now, grace),
         {:ok, committed?} <- committed_or_workspace?(record) do
      if committed? do
        finish_intent(key)
      else
        cleanup_unreferenced(key, record)
      end
    else
      false ->
        :retained

      {:error, :not_found} ->
        :cleaned

      {:error, reason} ->
        Logger.warning("prepared blob cleanup retained #{key}: #{inspect(reason)}")
        :retained
    end
  rescue
    exception ->
      Logger.warning("prepared blob cleanup retained #{key}: #{Exception.message(exception)}")
      :retained
  end

  defp cleanup_unreferenced(intent_key, record) do
    results = [abort_uploads(record), delete_blob(record)]

    if Enum.all?(results, &(&1 == :ok)) do
      finish_intent(intent_key)
    else
      :retained
    end
  end

  defp abort_uploads(%{"blob_key" => blob_key} = record) do
    with {:ok, %{uploads: uploads, next: next}} <-
           S3.multipart_uploads(blob_key, max_uploads: @max_uploads_per_intent) do
      upload_ids =
        [
          record["upload_id"]
          | for(%{key: ^blob_key, upload_id: upload_id} <- uploads, do: upload_id)
        ]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      results = Enum.map(upload_ids, &normalize_cleanup_result(S3.multipart_abort(blob_key, &1)))

      cond do
        Enum.any?(results, &match?({:error, _}, &1)) ->
          Enum.find(results, &match?({:error, _}, &1))

        not is_nil(next) ->
          {:error, :multipart_page_truncated}

        true ->
          :ok
      end
    end
  end

  defp delete_blob(%{"blob_key" => blob_key}),
    do: normalize_cleanup_result(S3.delete(blob_key))

  defp finish_intent(key) do
    case normalize_cleanup_result(S3.delete(key)) do
      :ok -> :cleaned
      {:error, _} -> :retained
    end
  end

  defp normalize_cleanup_result(:ok), do: :ok
  defp normalize_cleanup_result({:error, :not_found}), do: :ok
  defp normalize_cleanup_result({:error, _} = error), do: error

  defp manifest_references?(vfs, uuid) do
    Enum.any?(vfs || %{}, fn {_path, entry} ->
      ref = entry["ref"] || entry[:ref] || %{}
      (ref["uuid"] || ref[:uuid]) == uuid
    end)
  end

  defp committed_or_workspace?(%{"status" => "committed"}), do: {:ok, true}

  defp committed_or_workspace?(record) do
    case AgentWorkspace.read_state(record["agent_id"]) do
      {:ok, state} ->
        {:ok,
         manifest_references?(state.vfs, record["blob_uuid"]) or
           operation_references?(state.operations, record["blob_uuid"])}

      {:error, _} = error ->
        error
    end
  end

  defp operation_references?(operations, uuid) do
    Enum.any?(operations || %{}, fn {_operation_id, operation} ->
      uuid in (operation["managed_blob_uuids"] || [])
    end)
  end

  defp validate_record(record) do
    if Ids.valid_agent_id?(record["agent_id"]) and
         is_binary(record["blob_uuid"]) and
         Regex.match?(~r/\A[0-9a-f]{32}\z/, record["blob_uuid"]) and
         record["blob_key"] == Keys.blob(record["blob_uuid"]) and
         is_integer(record["updated_at"]) do
      :ok
    else
      {:error, :invalid_cleanup_record}
    end
  end

  defp expired?(record, now, grace), do: now - record["updated_at"] >= grace

  defp schedule(interval) do
    if timer = Process.get({__MODULE__, :timer}), do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), :sweep, interval)
    Process.put({__MODULE__, :timer}, timer)
  end

  defp configured_interval_ms,
    do:
      Application.get_env(:salix_agent, :prepared_blob_cleanup_interval_ms, @default_interval_ms)

  defp configured_grace_seconds,
    do:
      Application.get_env(
        :salix_agent,
        :prepared_blob_cleanup_grace_seconds,
        @default_grace_seconds
      )

  defp configured_batch_size,
    do: Application.get_env(:salix_agent, :prepared_blob_cleanup_batch_size, @default_batch_size)

  defp emit_outcome(outcome) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "prepared_blob_cleanup",
      "system",
      Atom.to_string(outcome),
      0
    )
  end
end
