defmodule SalixIM.MailInteraction do
  @moduledoc "Bounded mail interaction values owned by the Home Conversation."
  @key "mail_interactions"
  @limit 128

  # Two budgets per owner. Automatic handoffs wake the Router with evidence;
  # their daily cap bounds its cost. Notifications are the Router's decisions to
  # interrupt the owner about an automatic matter; they bound a Router that is
  # wrong about what must be known now. A critical matter skips the spacing but
  # not the daily cap. A decision to stay quiet spends no notification. Replies
  # and reminders the owner asked for are not automatic and are not limited.
  @window_ms 24 * 60 * 60 * 1000
  @budgets %{
    "sent_at" => %{spacing_ms: 0, limit: 12},
    "notified_at" => %{spacing_ms: 30 * 60 * 1000, limit: 5}
  }

  def entries(conversation), do: get_in(conversation, ["metadata", @key]) || %{}
  def key(account, thread), do: Jason.encode!([account, thread])

  # The owner's switch for automatic messages lives beside their budget. An
  # absent preference is on; an explicit off stays until the owner turns it on.
  def enabled?(conversation, owner),
    do: get_in(conversation, ["metadata", "proactive", owner, "enabled"]) != false

  def configure(conversation, owner, enabled, request_id, timestamp)
      when is_binary(owner) and is_boolean(enabled) and is_binary(request_id) and
             byte_size(request_id) in 1..128 do
    owners = get_in(conversation, ["metadata", "proactive"]) || %{}
    current = owners[owner] || %{}

    cond do
      current["request_id"] == request_id and current["enabled"] != enabled ->
        {:error, :mail_request_conflict}

      current["request_id"] == request_id ->
        conversation

      map_size(owners) >= 16 and not Map.has_key?(owners, owner) ->
        {:error, :mail_tracking_capacity}

      true ->
        preference =
          Map.merge(current, %{
            "enabled" => enabled,
            "request_id" => request_id,
            "revision" => (current["revision"] || 0) + 1
          })

        conversation
        |> put_owner(owners, owner, preference)
        |> Map.put("updated_at", timestamp)
    end
  end

  def configure(_, _, _, _, _), do: {:error, :invalid_proactive_settings}

  defp put_owner(conversation, owners, owner, value),
    do:
      Map.put(
        conversation,
        "metadata",
        Map.put(conversation["metadata"] || %{}, "proactive", Map.put(owners, owner, value))
      )

  @doc """
  The owner's automatic handoff budget: `{:open, remaining}`, or
  `{:closed, next_at}` with the Unix millisecond time it opens again.
  """
  def automatic_budget(conversation, owner, now), do: budget(conversation, owner, "sent_at", now)

  @doc "The owner's notification budget, in the shape of `automatic_budget/3`."
  def notification_budget(conversation, owner, now, urgency \\ nil),
    do: budget(conversation, owner, "notified_at", now, urgency)

  defp budget(conversation, owner, field, now, urgency \\ nil) do
    %{spacing_ms: spacing, limit: limit} = @budgets[field]
    spacing = if urgency == "critical", do: 0, else: spacing

    case spends(conversation, owner, field, now) do
      sent when length(sent) >= limit ->
        {:closed, max(List.last(sent) + @window_ms, hd(sent) + spacing)}

      [latest | _] when now - latest < spacing ->
        {:closed, latest + spacing}

      sent ->
        {:open, limit - length(sent)}
    end
  end

  # Newest first, only spends inside the window. Other owners' values stay.
  defp spends(conversation, owner, field, now) do
    (get_in(conversation, ["metadata", "proactive", owner, field]) || [])
    |> Enum.filter(&(is_integer(&1) and now - &1 < @window_ms))
    |> Enum.sort(:desc)
  end

  defp record_spend(conversation, owner, field, now) do
    owners = get_in(conversation, ["metadata", "proactive"]) || %{}

    if map_size(owners) >= 16 and not Map.has_key?(owners, owner) do
      {:error, :mail_tracking_capacity}
    else
      sent = Enum.take([now | spends(conversation, owner, field, now)], @budgets[field].limit)
      put_owner(conversation, owners, owner, Map.put(owners[owner] || %{}, field, sent))
    end
  end

  @doc """
  Plans one command and stores its pending value in the conversation. A new
  automatic message spends its budget in the same write.
  """
  def reserve(conversation, owner, command, now, timestamp) do
    current = entries(conversation)[command["key"]]

    case plan(conversation, owner, command, now) do
      {:ok, :unchanged} ->
        conversation

      {:ok, next} ->
        with %{} = updated <- commit(conversation, command["key"], next, timestamp) do
          cond do
            next == current ->
              updated

            automatic_present?(command) ->
              record_spend(updated, owner, "sent_at", now)

            automatic_notify?(command, current) ->
              record_spend(updated, owner, "notified_at", now)

            true ->
              updated
          end
        end

      error ->
        error
    end
  end

  defp automatic_present?(command),
    do: command["automatic"] == true and command["action"] == "present"

  # The stored matter, not the caller, says whether a notification is automatic.
  defp automatic_notify?(command, current),
    do: command["action"] == "notify" and is_map(current) and current["automatic"] == true

  def plan(conversation, owner, command, now) do
    values = entries(conversation)
    key = command["key"]
    current = values[key]

    cond do
      not is_binary(key) or byte_size(key) > 600 ->
        {:error, :invalid_mail_source}

      is_map(current) and current["owner_id"] != owner ->
        {:error, :mail_owner_mismatch}

      is_map(current) and current["pending"] != nil ->
        if current["pending"]["command"] == command,
          do: {:ok, current},
          else: {:error, :mail_operation_pending}

      is_map(current) and current["request_id"] == command["request_id"] ->
        if current["last_command"] == command,
          do: {:ok, :unchanged},
          else: {:error, :mail_request_conflict}

      automatic_present?(command) and not enabled?(conversation, owner) ->
        {:error, :proactive_disabled}

      automatic_present?(command) and
          match?({:closed, _}, automatic_budget(conversation, owner, now)) ->
        {:error, :proactive_budget_exhausted}

      automatic_notify?(command, current) and
          match?(
            {:closed, _},
            notification_budget(conversation, owner, now, current["urgency"])
          ) ->
        {:error, :proactive_notification_budget_exhausted}

      not is_binary(command["request_id"]) or byte_size(command["request_id"]) not in 1..128 ->
        {:error, :mail_request_id_required}

      is_nil(current) and command["action"] not in ~w(present track) ->
        {:error, :mail_source_not_found}

      is_nil(current) and map_size(values) >= @limit ->
        {:error, :mail_tracking_capacity}

      is_map(current) and command["generation"] != current["generation"] ->
        {:error, :mail_source_changed}

      is_map(current) and current["state"] == "handled" and command["action"] in ~w(present track) and
          command["message_id"] == current["message_id"] ->
        {:error, :mail_source_handled}

      true ->
        transition(current, owner, command, now)
    end
  end

  defp transition(current, owner, command, now) do
    base =
      current ||
        Map.merge(
          Map.take(command, ~w(account_id thread_id message_id subject source_url read)),
          %{
            "owner_id" => owner,
            "generation" => 0,
            "state" => "active",
            "delegate_request_id" => SalixStore.Ids.new_message_id()
          }
        )

    base =
      if (base["state"] == "handled" or
            (is_binary(base["task_id"]) and command["retire_task_id"] == base["task_id"])) and
           command["action"] in ~w(present track) and
           command["message_id"] != base["message_id"] do
        base
        |> Map.put("task_id", nil)
        |> Map.put("delegate_request_id", SalixStore.Ids.new_message_id())
      else
        base
      end

    base =
      if is_nil(base["task_id"]) and is_binary(command["task_id"]),
        do: Map.put(base, "task_id", command["task_id"]),
        else: base

    action = command["action"]

    valid =
      case action do
        "present" -> is_binary(command["text"]) and byte_size(command["text"]) in 1..8000
        "snooze" -> is_integer(command["run_at"]) and command["run_at"] > 0
        "handled" -> true
        "track" -> true
        "failed" -> is_binary(command["error"])
        "quiet" -> true
        "notify" -> true
        "link_task" -> is_binary(command["task_id"])
        _ -> false
      end

    if valid do
      state =
        case action do
          "handled" -> "handled"
          "snooze" -> "snoozed"
          "failed" -> "failed"
          "quiet" -> "quiet"
          "link_task" -> base["state"]
          "notify" -> base["state"]
          _ -> "active"
        end

      {schedule_id, run_at, old_schedule} =
        case action do
          "snooze" -> {SalixStore.Ids.new_schedule_id(), command["run_at"], base["schedule_id"]}
          # Linking a Task or notifying keeps a pending recheck.
          action when action in ~w(link_task notify) -> {base["schedule_id"], base["run_at"], nil}
          _ -> {nil, nil, base["schedule_id"]}
        end

      next =
        Map.merge(base, %{
          # Linking a Task or recording a notification keeps the generation, so a
          # pending recheck scheduled at that generation still fires.
          "generation" => base["generation"] + if(action in ~w(link_task notify), do: 0, else: 1),
          "state" => state,
          "error" => command["error"],
          "task_id" => if(action == "link_task", do: command["task_id"], else: base["task_id"]),
          "request_id" => command["request_id"],
          "last_command" => command,
          "followup_reason" =>
            if(action == "snooze",
              do: command["reason"] || base["followup_reason"],
              else: base["followup_reason"]
            ),
          "message_id" => command["message_id"] || base["message_id"],
          "subject" => command["subject"] || base["subject"],
          "source_url" => command["source_url"] || base["source_url"],
          "read" => command["read"] || base["read"],
          "run_at" => run_at,
          "schedule_id" => schedule_id,
          # Whether the latest handoff was automatic. The Router's decision on
          # an automatic matter spends the notification budget.
          "automatic" =>
            if(action == "present", do: command["automatic"] == true, else: base["automatic"]),
          "urgency" => if(action == "present", do: command["urgency"], else: base["urgency"]),
          # The Router's latest decision and its reason, shown to the owner.
          "decision" =>
            if(action in ~w(notify quiet),
              do: %{"decision" => action, "reason" => command["reason"], "decided_at" => now},
              else: base["decision"]
            ),
          "pending" => %{"command" => command, "old_schedule_id" => old_schedule}
        })

      {:ok, next}
    else
      {:error, :invalid_mail_action}
    end
  end

  def commit(conversation, key, value, timestamp) do
    metadata =
      Map.put(conversation["metadata"] || %{}, @key, Map.put(entries(conversation), key, value))

    if byte_size(Jason.encode!(metadata[@key])) <= 256_000,
      do: conversation |> Map.put("metadata", metadata) |> Map.put("updated_at", timestamp),
      else: {:error, :mail_tracking_capacity}
  end

  def public(value),
    do:
      value
      |> Map.drop(~w(pending last_command))
      |> Map.put("saving", not is_nil(value["pending"]))
end
