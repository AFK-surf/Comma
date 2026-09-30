defmodule Salix.Bindings.GoogleCalendarWatch do
  @moduledoc """
  Google push ingress with low-frequency incremental-sync repair.

  Notifications contain no event data; after verification they only mark the
  source dirty. Event truth always comes from the source syncToken.
  """

  alias Salix.Bindings.GoogleCalendarSource
  alias SalixCalendar.{Server, SourceActor, SourceSyncOutcome}
  alias SalixStore.{Crypto, Ids}

  @repair_interval_ms 6 * 60 * 60 * 1_000
  @repair_jitter_ms 60 * 60 * 1_000
  @bootstrap_retry_interval_ms 60_000
  @source_attrs ~w(adapter adapter_contract_id source_locator access_profile audience sync_policy)

  def maintain(group_id, calendar_id, source_id) do
    with {:ok, _watch} <- ensure(group_id, calendar_id, source_id),
         do: repair(group_id, calendar_id, source_id)
  end

  def ensure(group_id, calendar_id, source_id, now \\ System.system_time(:millisecond)) do
    callback =
      SalixWeb.Application.public_base_url() <>
        "/v1/calendar/google/notifications/#{group_id}/#{calendar_id}/#{source_id}"

    with {:ok, source} <- Server.get_source(group_id, calendar_id, source_id) do
      if watch_due?(source["watch"], callback, now),
        do: create(source, callback),
        else: {:ok, source["watch"]}
    end
  end

  def repair(group_id, calendar_id, source_id, now \\ System.system_time(:millisecond)) do
    with {:ok, source} <- Server.get_source(group_id, calendar_id, source_id) do
      last_error = SourceSyncOutcome.last_error(source)

      cond do
        repair_due?(source, now) ->
          Server.refresh_source(group_id, calendar_id, source_id, query(source))

        match?({:error, _reason}, last_error) ->
          last_error

        SourceSyncOutcome.unsettled?(source) ->
          {:error, :calendar_source_refresh_unsettled}

        bootstrap_required?(source) ->
          {:error, {:calendar_source_bootstrap_pending, next_repair_at(source)}}

        true ->
          {:ok, %{"sync_status" => "unchanged"}}
      end
    end
  end

  def receive(group_id, calendar_id, source_id, headers) when is_list(headers) do
    with true <-
           Ids.valid_group_id?(group_id) and Ids.valid_calendar_id?(calendar_id) and
             Ids.valid_calendar_source_id?(source_id),
         {:ok, source} <- SourceActor.read_source(group_id, calendar_id, source_id),
         true <- valid_notification?(source["watch"], Map.new(headers)) do
      Server.notify_source_changed(group_id, calendar_id, source_id, query(source))
    else
      false -> {:error, :invalid_notification}
      {:error, _} = error -> error
    end
  end

  def receive(_, _, _, _), do: {:error, :invalid_notification}

  defp create(source, callback) do
    started_at = System.monotonic_time()
    result = create_and_rotate(source, callback)

    Salix.Telemetry.emit_operation(
      "salix_calendar",
      "watch",
      "system",
      if(match?({:ok, _}, result), do: "ok", else: "error"),
      System.monotonic_time() - started_at
    )

    result
  end

  defp create_and_rotate(source, callback) do
    channel_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, watch} <- GoogleCalendarSource.start_watch(source, callback, channel_id, token),
         watch <-
           watch
           |> Map.put("callback_url", callback)
           |> Map.put("token_hash", Crypto.hex(token)),
         attrs <- source |> Map.take(@source_attrs) |> Map.put("watch", watch) do
      case Server.ensure_source(source["group_id"], source["calendar_id"], attrs) do
        {:ok, updated} ->
          stop_replaced_watch(source, source["watch"])
          {:ok, updated["watch"]}

        {:error, _} = error ->
          _ = GoogleCalendarSource.stop_watch(source, watch)
          error
      end
    end
  end

  defp stop_replaced_watch(_source, nil), do: :ok

  defp stop_replaced_watch(source, watch) do
    _ = GoogleCalendarSource.stop_watch(source, watch)
    :ok
  end

  defp valid_notification?(watch, headers) when is_map(watch) do
    token_hash = Crypto.hex(headers["x-goog-channel-token"] || "")
    expected_hash = watch["token_hash"]

    headers["x-goog-channel-id"] == watch["channel_id"] and
      headers["x-goog-resource-id"] == watch["resource_id"] and
      headers["x-goog-resource-state"] in ~w(sync exists not_exists) and
      is_binary(expected_hash) and byte_size(token_hash) == byte_size(expected_hash) and
      Plug.Crypto.secure_compare(token_hash, expected_hash)
  end

  defp valid_notification?(_watch, _headers), do: false

  defp query(source),
    do: %{
      "group_id" => source["group_id"],
      "object_type" => "Event",
      "page_size" => get_in(source, ["sync_policy", "page_size"]) || 100
    }

  defp watch_due?(
         %{"expiration" => expiration, "callback_url" => callback},
         callback,
         now
       )
       when is_integer(expiration),
       do: expiration <= now + 24 * 60 * 60 * 1_000

  defp watch_due?(_watch, _callback, _now), do: true

  defp repair_due?(source, now) do
    next_repair_at(source) <= now
  end

  defp next_repair_at(source) do
    sync = source["sync"] || %{}
    last_attempt_at = max(sync["attempted_at"] || 0, sync["completed_at"] || 0)

    cond do
      last_attempt_at == 0 ->
        0

      bootstrap_required?(source) ->
        last_attempt_at + @bootstrap_retry_interval_ms

      true ->
        jitter = :erlang.phash2(source["source_id"], @repair_jitter_ms)
        last_attempt_at + @repair_interval_ms + jitter
    end
  end

  defp bootstrap_required?(source),
    do: not (is_integer(source["active_generation"]) and source["active_generation"] > 0)
end
