defmodule SalixIM.MailInteraction do
  @moduledoc "Bounded mail interaction values owned by the Home Conversation."
  @key "mail_interactions"
  @limit 128
  @max_bytes 256_000

  # Two budgets per owner, each split into an ordinary pool and a reserve.
  # Automatic handoffs wake the Router with evidence; their daily cap bounds
  # its cost. Notifications are the Router's decisions to interrupt the owner
  # about an automatic matter; they bound a Router that is wrong about what
  # must be known now. A decision to stay quiet spends no notification.
  # Replies and reminders the owner asked for are not automatic and are not
  # limited.
  #
  # Only a reserve-eligible matter (`reserve_eligible?/2`) may spend the
  # reserve, and only after the ordinary pool is closed; it also skips the
  # notification spacing. Eligibility is checked again at each spend from the
  # stored assessment, never taken from the caller's `pool` alone, and an
  # urgency label never grants it. The scheduled Routine briefing (`"pool" =>
  # "scheduled"`, only on its own key) spends its own small cap instead of a
  # handoff.
  @window_ms 24 * 60 * 60 * 1000
  @budgets %{
    "sent_at" => %{spacing_ms: 0, limit: 12},
    "reserve_sent_at" => %{spacing_ms: 0, limit: 4},
    "scheduled_sent_at" => %{spacing_ms: 0, limit: 2},
    "notified_at" => %{spacing_ms: 30 * 60 * 1000, limit: 5},
    "reserve_notified_at" => %{spacing_ms: 0, limit: 2}
  }
  @reserve %{"sent_at" => "reserve_sent_at", "notified_at" => "reserve_notified_at"}
  @briefing_key Jason.encode!(["routine", "briefing"])
  # The action window of the reserve: a cost due from a day ago to a day
  # ahead, or three days ahead when it cannot be undone. A cost that cannot be
  # undone and names no time cannot be shown to wait.
  @reserve_window_ms 24 * 60 * 60 * 1000
  @reserve_irreversible_ms 72 * 60 * 60 * 1000

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
  `{:closed, next_at}` with the Unix millisecond time it opens again. With
  `reserve` true, a closed ordinary pool falls back to the reserve.
  """
  def automatic_budget(conversation, owner, now, reserve \\ false),
    do: pooled(conversation, owner, "sent_at", now, reserve)

  @doc """
  The owner's notification budget, in the shape of `automatic_budget/4`. A
  reserve-eligible matter skips the spacing and falls back to the reserve.
  """
  def notification_budget(conversation, owner, now, reserve \\ false),
    do: pooled(conversation, owner, "notified_at", now, reserve)

  @doc "The reserve pool alone of `:handoff` or `:notification`, for status views."
  def reserve_budget(conversation, owner, kind, now) do
    field = @reserve[if(kind == :handoff, do: "sent_at", else: "notified_at")]
    budget(conversation, owner, field, now, false)
  end

  @doc """
  Whether an assessment makes its matter reserve-eligible at `now` (Unix
  milliseconds): the owner must act (`role` `act`), there is a cost, and it
  lands inside the action window or cannot be undone and names no time.
  """
  def reserve_eligible?(assessment, now) when is_map(assessment) do
    with "act" <- assessment["role"],
         cost when is_binary(cost) and cost != "" <- assessment["cost"] do
      case DateTime.from_iso8601(assessment["due"] || "") do
        {:ok, due, _offset} ->
          left = DateTime.to_unix(due, :millisecond) - now

          window =
            if assessment["reversible"] == false,
              do: @reserve_irreversible_ms,
              else: @reserve_window_ms

          left >= -@reserve_window_ms and left <= window

        _ ->
          is_nil(assessment["due"]) and assessment["reversible"] == false
      end
    else
      _ -> false
    end
  end

  def reserve_eligible?(_assessment, _now), do: false

  @doc "When an eligible-later assessment enters the reserve window, or nil."
  def reserve_window_at(assessment, now) when is_map(assessment) do
    with {:ok, due, _offset} <- DateTime.from_iso8601(assessment["due"] || "") do
      window =
        if assessment["reversible"] == false,
          do: @reserve_irreversible_ms,
          else: @reserve_window_ms

      at = DateTime.to_unix(due, :millisecond) - window
      if at > now, do: at
    else
      _ -> nil
    end
  end

  def reserve_window_at(_assessment, _now), do: nil

  defp pooled(conversation, owner, field, now, reserve) do
    case {budget(conversation, owner, field, now, reserve), reserve} do
      {{:open, _} = open, _} ->
        open

      {{:closed, _} = closed, false} ->
        closed

      {{:closed, ordinary_at}, true} ->
        case budget(conversation, owner, @reserve[field], now, true) do
          {:open, _} = open -> open
          {:closed, reserve_at} -> {:closed, min(ordinary_at, reserve_at)}
        end
    end
  end

  # The pool a spend of `field` comes from: the ordinary pool while it is
  # open, else the reserve for a reserve-eligible matter.
  defp spend_field(conversation, owner, field, now, reserve) do
    case budget(conversation, owner, field, now, reserve) do
      {:open, _} -> field
      {:closed, _} -> if(reserve, do: @reserve[field], else: field)
    end
  end

  defp budget(conversation, owner, field, now, skip_spacing) do
    %{spacing_ms: spacing, limit: limit} = @budgets[field]
    spacing = if skip_spacing, do: 0, else: spacing

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

            automatic_present?(command) and command["pool"] == "scheduled" ->
              record_spend(updated, owner, "scheduled_sent_at", now)

            automatic_present?(command) ->
              field = spend_field(conversation, owner, "sent_at", now, reserve?(command, now))
              record_spend(updated, owner, field, now)

            automatic_notify?(command, current) ->
              field = spend_field(conversation, owner, "notified_at", now, reserve?(current, now))
              record_spend(updated, owner, field, now)

            true ->
              updated
          end
        end

      error ->
        error
    end
  end

  # The caller's pool asks for the reserve; the stored assessment must still
  # earn it now.
  defp reserve?(value, now),
    do: value["pool"] == "reserve" and reserve_eligible?(value["assessment"], now)

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

      automatic_present?(command) and command["pool"] == "scheduled" and
          command["key"] != @briefing_key ->
        {:error, :invalid_mail_source}

      automatic_present?(command) and command["pool"] == "scheduled" and
          match?({:closed, _}, budget(conversation, owner, "scheduled_sent_at", now, false)) ->
        {:error, :proactive_budget_exhausted}

      automatic_present?(command) and command["pool"] != "scheduled" and
          match?(
            {:closed, _},
            automatic_budget(conversation, owner, now, reserve?(command, now))
          ) ->
        {:error, :proactive_budget_exhausted}

      automatic_notify?(command, current) and
          match?(
            {:closed, _},
            notification_budget(conversation, owner, now, reserve?(current, now))
          ) ->
        {:error, :proactive_notification_budget_exhausted}

      not is_binary(command["request_id"]) or byte_size(command["request_id"]) not in 1..128 ->
        {:error, :mail_request_id_required}

      is_nil(current) and command["action"] not in ~w(present track) ->
        {:error, :mail_source_not_found}

      is_nil(current) and map_size(values) >= @limit and evictable(values) == [] ->
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
          # When the matter last changed, for the owner's notebook.
          "changed_at" => now,
          # Whether the latest handoff was automatic. The Router's decision on
          # an automatic matter spends the notification budget.
          "automatic" =>
            if(action == "present", do: command["automatic"] == true, else: base["automatic"]),
          "urgency" => if(action == "present", do: command["urgency"], else: base["urgency"]),
          # The pool the latest automatic handoff may spend: the Router's
          # notification on a reserve-eligible matter may use the reserve.
          "pool" => if(action == "present", do: command["pool"], else: base["pool"]),
          # What happens if the owner does nothing, and the earlier matter this
          # one continues, as the latest automatic handoff judged them.
          "assessment" =>
            if(action == "present", do: command["assessment"], else: base["assessment"]),
          "continues" =>
            if(action == "present",
              do: command["continues"] || base["continues"],
              else: base["continues"]
            ),
          # The latest Loop wakes on this matter, so a redelivered older wake is
          # recognized as a duplicate instead of re-presenting the matter.
          "loop_requests" =>
            if(String.starts_with?(command["request_id"] || "", "loop:"),
              do: Enum.take(Enum.uniq([command["request_id"] | base["loop_requests"] || []]), 8),
              else: base["loop_requests"]
            ),
          # The Router's latest decision and its reason, shown to the owner.
          "decision" =>
            cond do
              action in ~w(notify quiet) ->
                %{"decision" => action, "reason" => command["reason"], "decided_at" => now}
                |> then(
                  &if(action == "quiet" and command["reason_kind"] == "new_evidence",
                    do: Map.put(&1, "reason_kind", "new_evidence"),
                    else: &1
                  )
                )

              # A new handoff awaits a new decision.
              action == "present" ->
                nil

              true ->
                base["decision"]
            end,
          "pending" => %{"command" => command, "old_schedule_id" => old_schedule}
        })

      {:ok, next}
    else
      {:error, :invalid_mail_action}
    end
  end

  def commit(conversation, key, value, timestamp) do
    values = conversation |> entries() |> Map.put(key, value) |> fit(key)
    metadata = Map.put(conversation["metadata"] || %{}, @key, values)

    if byte_size(Jason.encode!(values)) <= @max_bytes,
      do: conversation |> Map.put("metadata", metadata) |> Map.put("updated_at", timestamp),
      else: {:error, :mail_tracking_capacity}
  end

  # A full store makes room for a new matter by dropping the oldest settled
  # matters: handled, quiet or failed, with nothing pending, scheduled or
  # linked to a Task. Matters still followed are never dropped.
  defp fit(values, key) do
    if map_size(values) <= @limit and byte_size(Jason.encode!(values)) <= @max_bytes do
      values
    else
      case values |> Map.delete(key) |> evictable() do
        [oldest | _] -> values |> Map.delete(oldest) |> fit(key)
        [] -> values
      end
    end
  end

  defp evictable(values) do
    values
    |> Enum.filter(fn {_key, value} ->
      value["state"] in ~w(handled quiet failed) and is_nil(value["pending"]) and
        is_nil(value["schedule_id"]) and is_nil(value["task_id"])
    end)
    |> Enum.sort_by(fn {_key, value} -> value["changed_at"] || 0 end)
    |> Enum.map(&elem(&1, 0))
  end

  def public(value),
    do:
      value
      |> Map.drop(~w(pending last_command))
      |> Map.put("saving", not is_nil(value["pending"]))
end
