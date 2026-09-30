defmodule SalixMeet.RouterSummary do
  @moduledoc "Durable, input-versioned Router summary requests; publication remains Delivery-owned."

  alias SalixMeet.{OwnerAttributionSnapshot, Store}

  @attempt_ms 10 * 60 * 1000
  @max_attempts 3
  @page_chars 16_000
  @fields ~w(transcript captions_transcript asr_transcript)
  @list_fields ~w(attendees key_points decisions open_questions blockers)

  def enabled?(state) do
    not is_nil(Application.get_env(:salix_meet, :router_summary_mod)) and
      state["status"] == "done" and state["provider"] in ["slack", "feishu"]
  end

  def source_fingerprint(state) do
    state
    |> Map.take(~w(title meeting_agent_id captions chats artifacts joined_at left_at))
    |> OwnerAttributionSnapshot.fingerprint()
  end

  def cached_context(state) do
    request = get_in(state, ["delivery", "router_summary"]) || %{}
    if request["source_fingerprint"] == source_fingerprint(state), do: request["context"]
  end

  def generate(state, context, claim) do
    id = state["meeting_id"]
    now = System.system_time(:millisecond)
    fingerprint = source_fingerprint(state)

    with {:ok, %{"state" => live}, _} <-
           Store.update_delivery_state(id, claim, fn live ->
             existing = get_in(live, ["delivery", "router_summary"]) || %{}

             cond do
               source_fingerprint(live) != fingerprint ->
                 live

               existing["source_fingerprint"] == fingerprint and
                   (existing["status"] == "submitted" or
                      (existing["expires_at"] || 0) > now or
                      (existing["attempt"] || 0) >= @max_attempts) ->
                 live

               true ->
                 attempt =
                   if existing["source_fingerprint"] == fingerprint,
                     do: (existing["attempt"] || 0) + 1,
                     else: 1

                 request = %{
                   "request_id" =>
                     Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
                   "source_fingerprint" => fingerprint,
                   "status" => "pending",
                   "attempt" => attempt,
                   "expires_at" => now + @attempt_ms,
                   "context" => context
                 }

                 put_in(live, ["delivery", "router_summary"], request)
             end
           end) do
      request = get_in(live, ["delivery", "router_summary"]) || %{}

      cond do
        source_fingerprint(live) != fingerprint or request["source_fingerprint"] != fingerprint ->
          {:error, :summary_source_changed}

        request["status"] == "submitted" ->
          {:ok, request["summary"]}

        request["expires_at"] <= now ->
          {:error, :router_summary_timeout}

        true ->
          # Retrying enqueue uses the same source id, including after a lost ACK.
          # The request is durable before Router can receive it or submit.
          mod = Application.fetch_env!(:salix_meet, :router_summary_mod)

          case mod.request(Map.put(live, "meeting_id", id), request) do
            :ok -> {:error, :router_summary_pending}
            {:error, _} = error -> error
          end
      end
    end
  end

  def read(group_id, params) do
    with {:ok, %{"state" => state}, _} <- Store.get(params["meeting_id"]),
         :ok <- validate_request(state, group_id, params, false),
         field when field in @fields <- params["field"] || "transcript",
         offset when is_integer(offset) and offset >= 0 <- params["offset"] || 0 do
      context = get_in(state, ["delivery", "router_summary", "context"])
      text = context[field] || ""
      total = String.length(text)
      page = String.slice(text, offset, @page_chars)
      next = offset + String.length(page)

      {:ok,
       %{
         "meeting_id" => params["meeting_id"],
         "request_id" => params["request_id"],
         "title" => state["title"],
         "duration_seconds" => context["duration_seconds"],
         "fields" => @fields,
         "field" => field,
         "offset" => offset,
         "text" => page,
         "total_chars" => total,
         "next_offset" => if(next < total, do: next),
         "calibration" => context["calibration"]
       }, state}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_summary_materials_page}
    end
  end

  def submit(group_id, params), do: submit(group_id, params, 8)

  defp submit(group_id, params, retries) do
    with {:ok, summary} <- validate_summary(params["summary"]),
         {:ok, %{"state" => state}, etag} <- Store.get(params["meeting_id"]),
         :ok <- validate_request(state, group_id, params, true) do
      request = get_in(state, ["delivery", "router_summary"])

      summary =
        Map.put(
          summary,
          "duration_minutes",
          div((request["context"]["duration_seconds"] || 0) + 59, 60)
        )

      cond do
        request["status"] == "submitted" and request["summary"] == summary ->
          {:ok, %{"status" => "accepted", "publication" => "server_owned"}}

        request["status"] == "submitted" ->
          {:error, :summary_already_submitted}

        true ->
          case Store.update_state(params["meeting_id"], etag, fn live ->
                 put_in(
                   live,
                   ["delivery", "router_summary"],
                   Map.merge(request, %{"status" => "submitted", "summary" => summary})
                 )
               end) do
            {:ok, _, _} -> {:ok, %{"status" => "accepted", "publication" => "server_owned"}}
            {:error, :lost} when retries > 0 -> submit(group_id, params, retries - 1)
            {:error, _} = error -> error
          end
      end
    end
  end

  defp validate_request(state, group_id, params, allow_submitted?) do
    request = get_in(state, ["delivery", "router_summary"]) || %{}

    cond do
      state["group_id"] != group_id ->
        {:error, :not_found}

      not is_binary(params["request_id"]) or request["request_id"] != params["request_id"] ->
        {:error, :stale_summary_request}

      request["source_fingerprint"] != source_fingerprint(state) ->
        {:error, :summary_source_changed}

      allow_submitted? and request["status"] == "submitted" ->
        :ok

      state["status"] != "done" or
          get_in(state, ["delivery", "status"]) in ["published", "failed_terminal"] ->
        {:error, :summary_request_closed}

      request["status"] != "pending" or
          (request["expires_at"] || 0) <= System.system_time(:millisecond) ->
        {:error, :summary_request_expired}

      true ->
        :ok
    end
  end

  def validate_summary(summary) when is_map(summary) do
    keys =
      ~w(title attendees timeline key_points action_items decisions open_questions blockers)

    valid =
      Map.keys(summary) -- keys == [] and is_binary(summary["title"]) and
        String.trim(summary["title"]) != "" and
        Enum.all?(@list_fields, fn field -> strings?(summary[field]) end) and
        records?(summary["timeline"], ~w(time summary)) and
        records?(summary["action_items"], ~w(description owner deadline)) and
        byte_size(Jason.encode!(summary)) <= 100_000

    if valid,
      do: {:ok, OwnerAttributionSnapshot.sanitize_summary(summary)},
      else: {:error, :invalid_summary_schema}
  end

  def validate_summary(_), do: {:error, :invalid_summary_schema}

  defp strings?(values) when is_list(values),
    do: length(values) <= 200 and Enum.all?(values, &is_binary/1)

  defp strings?(_), do: false

  defp records?(values, keys) when is_list(values) do
    length(values) <= 200 and
      Enum.all?(values, fn value ->
        is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys) and
          Enum.all?(keys, &is_binary(value[&1]))
      end)
  end

  defp records?(_, _), do: false
end
