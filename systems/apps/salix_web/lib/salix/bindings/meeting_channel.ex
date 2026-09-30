defmodule Salix.Bindings.MeetingChannel do
  @moduledoc false

  @behaviour SalixMeet.Ports.MeetingChannel

  alias SalixIM.Provider.Slack.API
  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixMeet.Store, as: MeetingStore
  alias SalixStore.Crypto

  @reconcile_grace_seconds 30
  @reconcile_min_attempts 1
  @max_history_pages 10

  @impl true
  def resolve(group) do
    with {:ok, target, _connect} <- resolve_with_connect(group), do: {:ok, target}
  end

  defp resolve_with_connect(group) do
    tenant_id = trim(group["tenant_id"])
    group_id = trim(group["group_id"])

    with {:ok, canonical_group} <- GroupDirectory.get_group(group_id, tenant_id),
         canonical_tenant_id when canonical_tenant_id != "" <-
           trim(canonical_group["tenant_id"]),
         canonical_group_id when canonical_group_id != "" <- trim(canonical_group["group_id"]),
         router_agent_id when router_agent_id != "" <- trim(canonical_group["router_agent_id"]),
         {:ok, target} <- configured_target(group),
         connect_id when connect_id != "" <- trim(target["connect_id"]),
         {:ok, connect} <-
           ProviderConnects.get_agent_visible_connect_by_id(
             %{group_id: canonical_group_id, agent_id: router_agent_id},
             connect_id,
             "slack"
           ),
         :ok <-
           validate_resolved_connect(
             connect,
             canonical_tenant_id,
             canonical_group_id,
             connect_id,
             target["workspace_id"]
           ) do
      {:ok, target, connect}
    else
      "" -> {:error, :router_agent_not_configured}
      {:error, _} = error -> error
      _ -> {:error, :meeting_slack_target_not_configured}
    end
  end

  defp validate_resolved_connect(connect, tenant_id, group_id, connect_id, workspace_id) do
    cond do
      trim(connect["tenant_id"]) != tenant_id or trim(connect["group_id"]) != group_id or
          trim(connect["connect_id"]) != connect_id ->
        {:error, :meeting_slack_target_scope_mismatch}

      trim(connect["workspace_id"]) != workspace_id ->
        {:error, :meeting_slack_workspace_mismatch}

      trim(connect["bot_token"]) == "" or not positive?(connect["oauth_completed_at"]) ->
        {:error, :configured_slack_connect_not_available}

      true ->
        :ok
    end
  end

  @impl true
  def ensure_root(group, meeting_id, event, target) do
    with {:ok, configured, connect} <- resolve_with_connect(group),
         :ok <- same_target(configured, target),
         bot_token when bot_token != "" <- trim(connect["bot_token"]) do
      reuse_or_ensure_root(meeting_id, event, configured, API.installation(connect))
    else
      "" -> {:error, :meeting_slack_token_missing}
      {:error, _} = error -> error
      _ -> {:error, :meeting_slack_target_not_available}
    end
  end

  # Revalidate the current durable target/connect on every resume, but avoid a
  # no-op state CAS when the root is already checkpointed. A needless ETag
  # change here can fence a live Meeting process just before join dispatch.
  defp reuse_or_ensure_root(meeting_id, event, target, token) do
    case MeetingStore.get(meeting_id) do
      {:ok, doc, _etag} ->
        case get_in(doc, ["state", "slack_ref", "thread_ts"]) |> trim() do
          "" -> ensure_root_message(meeting_id, event, target, token)
          thread_ts -> {:ok, thread_ts}
        end

      {:error, _} = error ->
        error
    end
  end

  defp configured_target(group) do
    connect_id = trim(group["connect_id"])
    workspace_id = trim(group["workspace_id"])
    channel_id = trim(group["channel_id"])

    if connect_id != "" and workspace_id != "" and channel_id != "" do
      {:ok,
       %{
         "connect_id" => connect_id,
         "workspace_id" => workspace_id,
         "channel_id" => channel_id
       }}
    else
      {:error, :meeting_slack_target_not_configured}
    end
  end

  defp same_target(left, right) do
    keys = ~w(connect_id workspace_id channel_id)

    if Enum.all?(keys, &(trim(left[&1]) != "" and trim(left[&1]) == trim(right[&1]))),
      do: :ok,
      else: {:error, :meeting_slack_target_changed}
  end

  defp ensure_root_message(meeting_id, event, target, token) do
    ensure_root_message(meeting_id, event, target, token, true)
  end

  defp ensure_root_message(meeting_id, event, target, token, allow_repost?) do
    attempt_id = random_ref()
    event_type = root_event_type(meeting_id)
    now = System.system_time(:second)

    intent = %{
      "attempt_id" => attempt_id,
      "event_type" => event_type,
      "metadata" => %{
        "event_type" => event_type,
        "event_payload" => %{"meeting_id" => meeting_id, "kind" => "calendar_root"}
      },
      "status" => "posting",
      "started_at" => now,
      "reconcile_attempts" => 0
    }

    with {:ok, doc, _etag} <-
           MeetingStore.update_state_retrying(meeting_id, fn state ->
             stage_root_attempt(state, intent)
           end) do
      state = doc["state"] || %{}
      thread_ts = get_in(state, ["slack_ref", "thread_ts"]) |> trim()
      stored = as_map(state["calendar_root"])

      cond do
        thread_ts != "" ->
          {:ok, thread_ts}

        stored["attempt_id"] == attempt_id and stored["status"] == "posting" ->
          post_root_once(meeting_id, event, target, token, stored)

        stored["status"] in ["posting", "unknown", "created"] ->
          case reconcile_root(meeting_id, target, token, stored) do
            {:retry, :meeting_root_not_found} when allow_repost? ->
              ensure_root_message(meeting_id, event, target, token, false)

            {:retry, :meeting_root_not_found} ->
              {:error, :meeting_root_retryable}

            result ->
              result
          end

        stored["status"] == "conflict" ->
          {:error, :meeting_root_conflict}

        true ->
          {:error, {:meeting_root_unresolved, stored["status"]}}
      end
    end
  end

  defp stage_root_attempt(state, intent) do
    thread_ts = get_in(state, ["slack_ref", "thread_ts"]) |> trim()
    current = as_map(state["calendar_root"])

    cond do
      thread_ts != "" -> state
      current == %{} -> Map.put(state, "calendar_root", intent)
      current["status"] == "retryable" -> Map.put(state, "calendar_root", intent)
      true -> state
    end
  end

  defp post_root_once(meeting_id, event, target, token, intent) do
    try do
      response =
        API.post_message(token, target["channel_id"], root_text(event),
          metadata: intent["metadata"]
        )

      case trim(response["ts"]) do
        "" ->
          mark_root_unknown(meeting_id, intent, "chat.postMessage returned no ts")

        thread_ts ->
          checkpoint_root(meeting_id, intent, thread_ts)
      end
    rescue
      error in API.Error -> root_post_failed(meeting_id, intent, error)
    end
  end

  defp root_post_failed(meeting_id, intent, error) do
    if ambiguous_write?(error) do
      mark_root_unknown(meeting_id, intent, API.error_message(error))
    else
      retryable =
        intent
        |> Map.put("status", "retryable")
        |> Map.put("last_error", API.error_message(error))

      with {:ok, _doc, _etag} <- update_root(meeting_id, intent, retryable) do
        {:error, API.error_message(error)}
      end
    end
  end

  defp mark_root_unknown(meeting_id, intent, reason) do
    unknown =
      intent
      |> Map.put("status", "unknown")
      |> Map.put("last_error", reason)

    with {:ok, _doc, _etag} <- update_root(meeting_id, intent, unknown) do
      {:error, {:meeting_root_unknown, reason}}
    end
  end

  defp reconcile_root(meeting_id, target, token, intent) do
    try do
      with {:ok, messages} <- list_history(token, target["channel_id"], intent, "", 0, []) do
        matches =
          messages
          |> Enum.filter(&(get_in(&1, ["metadata", "event_type"]) == intent["event_type"]))
          |> Enum.map(&trim(&1["ts"]))
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        case matches do
          [thread_ts] -> checkpoint_root(meeting_id, intent, thread_ts)
          [] -> root_not_found(meeting_id, intent)
          _ -> mark_root_conflict(meeting_id, intent)
        end
      end
    rescue
      error in API.Error -> {:error, API.error_message(error)}
    end
  end

  defp list_history(token, channel, intent, cursor, page, acc)
       when page < @max_history_pages do
    opts =
      [cursor: cursor, limit: 100]
      |> put_oldest(intent["started_at"])

    {messages, next_cursor} = API.conversation_history(token, channel, opts)
    acc = acc ++ List.wrap(messages)

    case trim(next_cursor) do
      "" -> {:ok, acc}
      next -> list_history(token, channel, intent, next, page + 1, acc)
    end
  end

  defp list_history(_token, _channel, _intent, _cursor, _page, _acc),
    do: {:error, :meeting_root_history_incomplete}

  defp root_not_found(meeting_id, intent) do
    attempts = (intent["reconcile_attempts"] || 0) + 1
    now = System.system_time(:second)
    started_at = intent["started_at"] || now

    if attempts >= @reconcile_min_attempts and now - started_at >= @reconcile_grace_seconds do
      retryable =
        intent
        |> Map.put("status", "retryable")
        |> Map.put("reconcile_attempts", attempts)
        |> Map.put("last_error", "Slack root post was not found during bounded reconciliation")

      with {:ok, _doc, _etag} <- update_root(meeting_id, intent, retryable) do
        {:retry, :meeting_root_not_found}
      end
    else
      unknown =
        intent
        |> Map.put("status", "unknown")
        |> Map.put("reconcile_attempts", attempts)
        |> Map.put("last_reconciled_at", now)

      with {:ok, _doc, _etag} <- update_root(meeting_id, intent, unknown) do
        {:error, :meeting_root_pending_reconciliation}
      end
    end
  end

  defp mark_root_conflict(meeting_id, intent) do
    conflict =
      intent
      |> Map.put("status", "conflict")
      |> Map.update("reconcile_attempts", 1, &(&1 + 1))

    with {:ok, _doc, _etag} <- update_root(meeting_id, intent, conflict) do
      {:error, :meeting_root_conflict}
    end
  end

  defp checkpoint_root(meeting_id, intent, thread_ts) do
    created =
      intent
      |> Map.put("status", "created")
      |> Map.put("thread_ts", thread_ts)

    with {:ok, doc, _etag} <-
           MeetingStore.update_state_retrying(meeting_id, fn state ->
             current = as_map(state["calendar_root"])

             if same_intent?(current, intent) do
               state
               |> Map.put("calendar_root", created)
               |> put_thread_ts(thread_ts)
             else
               state
             end
           end),
         ^thread_ts <- get_in(doc, ["state", "slack_ref", "thread_ts"]) do
      {:ok, thread_ts}
    else
      {:error, _} = error -> error
      _ -> {:error, :meeting_root_checkpoint_lost}
    end
  end

  defp update_root(meeting_id, expected, replacement) do
    MeetingStore.update_state_retrying(meeting_id, fn state ->
      current = as_map(state["calendar_root"])

      if same_intent?(current, expected),
        do: Map.put(state, "calendar_root", replacement),
        else: state
    end)
  end

  defp same_intent?(left, right) do
    trim(left["attempt_id"]) != "" and left["attempt_id"] == right["attempt_id"] and
      left["event_type"] == right["event_type"]
  end

  defp put_thread_ts(state, thread_ts) do
    slack_ref = state |> Map.get("slack_ref") |> as_map() |> Map.put("thread_ts", thread_ts)
    Map.put(state, "slack_ref", slack_ref)
  end

  defp root_text(event) do
    title =
      event["title"]
      |> trim()
      |> blank_default("Calendar meeting")
      |> String.slice(0, 300)
      |> escape_slack_text()

    ":calendar: Joining #{title}. The meeting summary will be posted in this thread."
  end

  defp root_event_type(meeting_id) do
    digest = ["comma-calendar-root-v1", meeting_id] |> Crypto.hex() |> binary_part(0, 32)
    "comma_calendar_meeting_root_" <> digest
  end

  defp ambiguous_write?(%API.Error{status: nil, body: nil}), do: true
  defp ambiguous_write?(%API.Error{status: 408}), do: true
  defp ambiguous_write?(%API.Error{status: status}) when status in 500..599, do: true

  defp ambiguous_write?(%API.Error{message: message})
       when message in [
              "internal_error",
              "fatal_error",
              "timeout",
              "request_timeout",
              "service_unavailable",
              "temporarily_unavailable"
            ],
       do: true

  defp ambiguous_write?(_error), do: false

  defp escape_slack_text(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp put_oldest(opts, started_at) when is_integer(started_at) and started_at > 0,
    do: Keyword.put(opts, :oldest, Integer.to_string(started_at))

  defp put_oldest(opts, _started_at), do: opts

  defp random_ref, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp positive?(value) when is_integer(value), do: value > 0

  defp positive?(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number > 0
      _ -> false
    end
  end

  defp positive?(_value), do: false

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
