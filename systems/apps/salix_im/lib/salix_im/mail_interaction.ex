defmodule SalixIM.MailInteraction do
  @moduledoc "Bounded mail interaction values owned by the Home Conversation."
  @key "mail_interactions"
  @limit 128
  @max_bytes 256_000
  @stale_evict_ms 14 * 24 * 60 * 60 * 1000

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
  #
  # A login or verification code (`"pool" => "code"`, with `code` true in the
  # stored assessment) spends its own cap instead of the ordinary pools and
  # the reserve: a code lapses in minutes, so it cannot wait for spacing, and
  # a run of codes must not use up what other matters need that day.
  #
  # A high-signal proactive insight (`"pool" => "signal"`, with `signal` true
  # in the stored assessment) spends its own strict cap (at most two
  # notifications in 24 hours, spaced two hours apart) instead of the ordinary
  # pools or the reserve, so non-obligation insights cannot spam or starve
  # urgent reminders.
  #
  # Owner-initiated agent stops (`account_id` in `@agent_accounts`: Tasks and
  # still.fail station chats) spend their own pools instead of the passive
  # inbox budgets: `"agent"` for ordinary agent stops (high cap, no spacing)
  # and `"agent_code"` (with `code` true in the stored assessment) for expiring
  # interactive agent cards (login, vault/secret approval, sign-in, device
  # grant) so active agent work neither starves nor is starved by external
  # inbox mail/Slack/GitHub traffic or email OTP limits.
  @window_ms 24 * 60 * 60 * 1000
  @budgets %{
    "sent_at" => %{spacing_ms: 0, limit: 20},
    "reserve_sent_at" => %{spacing_ms: 0, limit: 6},
    "scheduled_sent_at" => %{spacing_ms: 0, limit: 2},
    "code_sent_at" => %{spacing_ms: 0, limit: 6},
    "signal_sent_at" => %{spacing_ms: 0, limit: 4},
    "agent_sent_at" => %{spacing_ms: 0, limit: 120},
    "agent_code_sent_at" => %{spacing_ms: 0, limit: 40},
    "notified_at" => %{spacing_ms: 30 * 60 * 1000, limit: 10},
    "reserve_notified_at" => %{spacing_ms: 0, limit: 4},
    "code_notified_at" => %{spacing_ms: 0, limit: 6},
    "signal_notified_at" => %{spacing_ms: 2 * 60 * 60 * 1000, limit: 2},
    "agent_notified_at" => %{spacing_ms: 0, limit: 30},
    "agent_code_notified_at" => %{spacing_ms: 0, limit: 40}
  }
  @code %{"sent_at" => "code_sent_at", "notified_at" => "code_notified_at"}
  @signal %{"sent_at" => "signal_sent_at", "notified_at" => "signal_notified_at"}
  @agent %{"sent_at" => "agent_sent_at", "notified_at" => "agent_notified_at"}
  @agent_code %{"sent_at" => "agent_code_sent_at", "notified_at" => "agent_code_notified_at"}
  @agent_accounts ~w(station_task task)
  @stillfail_notification_levels ~w(off action_needed issues all)
  @default_stillfail_notification_level "action_needed"
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

  @doc "Valid proactive notification levels for still.fail station chats, from quietest to broadest."
  def stillfail_notification_levels, do: @stillfail_notification_levels

  @doc "The owner's still.fail proactive notification level; defaults to `\"action_needed\"`."
  def stillfail_notification_level(conversation, owner) do
    case get_in(conversation, ["metadata", "proactive", owner, "stillfail_notification_level"]) do
      level when level in @stillfail_notification_levels -> level
      _ -> @default_stillfail_notification_level
    end
  end

  @doc "Whether a still.fail proactive notification level admits the given stop kind (`need`, `failed`, `done`)."
  def stillfail_notification_allows?("off", _kind), do: false
  def stillfail_notification_allows?("action_needed", "need"), do: true
  def stillfail_notification_allows?("action_needed", _kind), do: false
  def stillfail_notification_allows?("issues", kind) when kind in ~w(need failed), do: true
  def stillfail_notification_allows?("issues", _kind), do: false
  def stillfail_notification_allows?("all", kind) when kind in ~w(need failed done), do: true
  def stillfail_notification_allows?(_, _), do: false

  def configure_stillfail_notifications(conversation, owner, level, request_id, timestamp)
      when is_binary(owner) and level in @stillfail_notification_levels and
             is_binary(request_id) and byte_size(request_id) in 1..128 do
    owners = get_in(conversation, ["metadata", "proactive"]) || %{}
    current = owners[owner] || %{}

    cond do
      current["stillfail_request_id"] == request_id and
          current["stillfail_notification_level"] != level ->
        {:error, :mail_request_conflict}

      current["stillfail_request_id"] == request_id ->
        conversation

      map_size(owners) >= 16 and not Map.has_key?(owners, owner) ->
        {:error, :mail_tracking_capacity}

      true ->
        preference =
          Map.merge(current, %{
            "stillfail_notification_level" => level,
            "stillfail_request_id" => request_id,
            "revision" => (current["revision"] || 0) + 1
          })

        conversation
        |> put_owner(owners, owner, preference)
        |> Map.put("updated_at", timestamp)
    end
  end

  def configure_stillfail_notifications(_, _, _, _, _),
    do: {:error, :invalid_proactive_settings}

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

  @doc """
  The code pool of `:handoff` or `:notification`, in the shape of
  `automatic_budget/4`: what a login or verification code spends instead of
  the ordinary pools and the reserve.
  """
  def code_budget(conversation, owner, kind, now) do
    field = @code[if(kind == :handoff, do: "sent_at", else: "notified_at")]
    budget(conversation, owner, field, now, true)
  end

  @doc """
  The signal pool of `:handoff` or `:notification`, in the shape of
  `automatic_budget/4`: what a non-obligation proactive insight (`pool`
  `"signal"`, with `signal` true in the stored assessment) spends instead of
  the ordinary pools and the reserve.
  """
  def signal_budget(conversation, owner, kind, now) do
    field = @signal[if(kind == :handoff, do: "sent_at", else: "notified_at")]
    budget(conversation, owner, field, now, false)
  end

  @doc """
  The agent pool of `:handoff` or `:notification`, in the shape of
  `automatic_budget/4`: what owner-initiated agent stops (`station_task` and
  `task`) spend instead of the passive inbox pools.
  """
  def agent_budget(conversation, owner, kind, now) do
    field = @agent[if(kind == :handoff, do: "sent_at", else: "notified_at")]
    budget(conversation, owner, field, now, true)
  end

  @doc """
  The agent code pool of `:handoff` or `:notification`, in the shape of
  `automatic_budget/4`: what expiring interactive agent cards (CLI login,
  vault/secret approval, sign-in, device grant) spend instead of email OTP or
  passive inbox pools.
  """
  def agent_code_budget(conversation, owner, kind, now) do
    field = @agent_code[if(kind == :handoff, do: "sent_at", else: "notified_at")]
    budget(conversation, owner, field, now, true)
  end

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
    with false <- assessment["signal"] == true,
         "act" <- assessment["role"],
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

      [latest | _] when spacing > 0 and now - latest < spacing ->
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
  def reserve(conversation, owner, command, now, timestamp, opts \\ []) do
    current = entries(conversation)[command["key"]]

    case plan(conversation, owner, command, now, opts) do
      {:ok, :unchanged} ->
        conversation

      {:ok, next} ->
        with %{} = updated <- commit(conversation, command["key"], next, timestamp, now, opts) do
          cond do
            next == current ->
              updated

            automatic_present?(command) and command["pool"] == "scheduled" ->
              record_spend(updated, owner, "scheduled_sent_at", now)

            automatic_present?(command) and agent_code?(command, current) ->
              record_spend(updated, owner, @agent_code["sent_at"], now)

            automatic_present?(command) and agent?(command, current) ->
              record_spend(updated, owner, @agent["sent_at"], now)

            automatic_present?(command) and code?(command) ->
              record_spend(updated, owner, @code["sent_at"], now)

            automatic_present?(command) and signal?(command) ->
              record_spend(updated, owner, @signal["sent_at"], now)

            automatic_present?(command) ->
              field = spend_field(conversation, owner, "sent_at", now, reserve?(command, now))
              record_spend(updated, owner, field, now)

            automatic_notify?(command, current) and agent_code?(current, current) ->
              record_spend(updated, owner, @agent_code["notified_at"], now)

            automatic_notify?(command, current) and agent?(current, current) ->
              record_spend(updated, owner, @agent["notified_at"], now)

            automatic_notify?(command, current) and code?(current) ->
              record_spend(updated, owner, @code["notified_at"], now)

            automatic_notify?(command, current) and signal?(current) ->
              record_spend(updated, owner, @signal["notified_at"], now)

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

  # A code spends the code pool only when its stored assessment says it is one.
  defp code?(value),
    do: value["pool"] == "code" and get_in(value, ["assessment", "code"]) == true

  # A signal spends the signal pool only when its stored assessment says it is one.
  defp signal?(value),
    do: value["pool"] == "signal" and get_in(value, ["assessment", "signal"]) == true

  # Agent pools are valid only for owner-initiated agent accounts (`station_task`
  # and `task`), anchored to the stored `account_id` once a matter exists.
  defp agent_account?(command, current) do
    account = (is_map(current) and current["account_id"]) || command["account_id"]
    account in @agent_accounts
  end

  defp agent?(value, current),
    do: value["pool"] == "agent" and agent_account?(value, current)

  defp agent_code?(value, current),
    do:
      value["pool"] == "agent_code" and agent_account?(value, current) and
        get_in(value, ["assessment", "code"]) == true

  defp automatic_present?(command),
    do: command["automatic"] == true and command["action"] == "present"

  # The stored matter, not the caller, says whether a notification is automatic.
  defp automatic_notify?(command, current),
    do: command["action"] == "notify" and is_map(current) and current["automatic"] == true

  def plan(conversation, owner, command, now, opts \\ []) do
    values = entries(conversation)
    key = command["key"]
    current = values[key]
    protected_keys = Keyword.get(opts, :protected_keys, :loop_requests_only)

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
        if same_command?(current["last_command"], command),
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

      automatic_present?(command) and agent_code?(command, current) and
          match?({:closed, _}, agent_code_budget(conversation, owner, :handoff, now)) ->
        {:error, :proactive_budget_exhausted}

      automatic_present?(command) and agent?(command, current) and
          match?({:closed, _}, agent_budget(conversation, owner, :handoff, now)) ->
        {:error, :proactive_budget_exhausted}

      automatic_present?(command) and code?(command) and
          match?({:closed, _}, code_budget(conversation, owner, :handoff, now)) ->
        {:error, :proactive_budget_exhausted}

      automatic_present?(command) and signal?(command) and
          match?({:closed, _}, signal_budget(conversation, owner, :handoff, now)) ->
        {:error, :proactive_budget_exhausted}

      automatic_present?(command) and command["pool"] != "scheduled" and
        not agent_code?(command, current) and not agent?(command, current) and
        not code?(command) and not signal?(command) and
          match?(
            {:closed, _},
            automatic_budget(conversation, owner, now, reserve?(command, now))
          ) ->
        {:error, :proactive_budget_exhausted}

      automatic_notify?(command, current) and agent_code?(current, current) and
          match?({:closed, _}, agent_code_budget(conversation, owner, :notification, now)) ->
        {:error, :proactive_notification_budget_exhausted}

      automatic_notify?(command, current) and agent?(current, current) and
          match?({:closed, _}, agent_budget(conversation, owner, :notification, now)) ->
        {:error, :proactive_notification_budget_exhausted}

      automatic_notify?(command, current) and code?(current) and
          match?({:closed, _}, code_budget(conversation, owner, :notification, now)) ->
        {:error, :proactive_notification_budget_exhausted}

      automatic_notify?(command, current) and signal?(current) and
          match?({:closed, _}, signal_budget(conversation, owner, :notification, now)) ->
        {:error, :proactive_notification_budget_exhausted}

      automatic_notify?(command, current) and
        not agent_code?(current, current) and not agent?(current, current) and
        not code?(current) and not signal?(current) and
          match?(
            {:closed, _},
            notification_budget(conversation, owner, now, reserve?(current, now))
          ) ->
        {:error, :proactive_notification_budget_exhausted}

      not is_binary(command["request_id"]) or byte_size(command["request_id"]) not in 1..128 ->
        {:error, :mail_request_id_required}

      is_nil(current) and command["action"] not in ~w(present track) ->
        {:error, :mail_source_not_found}

      is_nil(current) and map_size(values) >= @limit and
          evictable(values, now, protected_keys) == [] ->
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
        "present" ->
          is_map(command["direct_home"]) or
            (is_binary(command["text"]) and byte_size(command["text"]) in 1..8000)

        "snooze" ->
          is_integer(command["run_at"]) and command["run_at"] > 0

        "handled" ->
          true

        "track" ->
          true

        "failed" ->
          is_binary(command["error"])

        "quiet" ->
          true

        "notify" ->
          true

        "link_task" ->
          is_binary(command["task_id"])

        _ ->
          false
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
          "last_command" => compact_command(command),
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

              action == "present" and is_map(command["direct_home"]) ->
                %{
                  "decision" => "notify",
                  "reason" => "direct_station_task",
                  "decided_at" => now
                }

              # A new handoff awaits a new decision.
              action == "present" ->
                nil

              true ->
                base["decision"]
            end,
          "home_message_id" => if(action == "handled", do: nil, else: base["home_message_id"]),
          "pending" => %{"command" => command, "old_schedule_id" => old_schedule}
        })

      {:ok, next}
    else
      {:error, :invalid_mail_action}
    end
  end

  @doc false
  def near_capacity?(conversation, command \\ nil) do
    values = entries(conversation)
    command_bytes = if is_map(command), do: byte_size(Jason.encode!(command)), else: 0

    map_size(values) >= @limit - 1 or
      byte_size(Jason.encode!(values)) + command_bytes * 2 + 8_192 >= @max_bytes
  end

  @doc false
  def active_watched_keys(agent_id, owner) when is_binary(agent_id) and is_binary(owner) do
    case SalixStore.Loops.proactive_monitors(agent_id) do
      {:ok, rows} ->
        for %{"status" => "active", "config" => config} <- rows,
            watch_owner(config) == owner,
            is_binary(config["source_ref"]),
            into: MapSet.new(),
            do: key(watch_source_account(config["source"] || %{}), config["source_ref"])

      _ ->
        :unavailable
    end
  end

  def active_watched_keys(_agent_id, _owner), do: :unavailable

  defp watch_owner(config) when is_map(config) do
    get_in(config, ["comma_proactive", "user_id"]) || get_in(config, ["comma_mail", "user_id"])
  end

  defp watch_owner(_config), do: nil

  defp watch_source_account(%{"tool" => "recommendation.read", "arguments" => args})
       when is_map(args),
       do: args["source_id"] || "internal"

  defp watch_source_account(%{"tool" => tool}) when tool in ~w(web.search web.read_pages),
    do: "web"

  defp watch_source_account(read) when is_map(read),
    do: get_in(read, ["arguments", "connected_account_id"]) || "internal"

  defp watch_source_account(_read), do: "internal"

  def commit(conversation, key, value, timestamp, now \\ nil, opts \\ []) do
    protected_keys = Keyword.get(opts, :protected_keys, :loop_requests_only)

    values =
      conversation
      |> entries()
      |> Map.put(key, compact_entry_if_finalized(value))
      |> fit(key, now, protected_keys)

    metadata = Map.put(conversation["metadata"] || %{}, @key, values)

    if map_size(values) <= @limit and byte_size(Jason.encode!(values)) <= @max_bytes,
      do: conversation |> Map.put("metadata", metadata) |> Map.put("updated_at", timestamp),
      else: {:error, :mail_tracking_capacity}
  end

  # A full store first compacts legacy finalized `last_command` payloads in place,
  # then makes room by dropping Tier-1 settled matters (handled, quiet or failed,
  # with nothing pending, no Schedule, no Task, and not actively watched) oldest
  # first, and only if none remain drops Tier-2 stale matters untouched for at
  # least 14 days (unlinked active matters or settled matters retaining an old
  # task_id, excluding active watches and owned `task` matters still awaiting a
  # `left:` leave observation). Pending, scheduled, active task-linked, watched,
  # and recent (<14d) active matters are never dropped; when active watch lookup
  # is `:unavailable`, eviction fails closed rather than dropping a potentially
  # watched matter.
  defp fit(values, key, now, protected_keys) do
    if fits?(values) do
      values
    else
      compacted = compact_legacy_entries(values)

      if fits?(compacted) do
        compacted
      else
        evict_until_fits(compacted, key, now, protected_keys)
      end
    end
  end

  defp evict_until_fits(values, key, now, protected_keys) do
    if fits?(values) do
      values
    else
      case values |> Map.delete(key) |> evictable(now, protected_keys) do
        [oldest | _] ->
          values |> Map.delete(oldest) |> evict_until_fits(key, now, protected_keys)

        [] ->
          values
      end
    end
  end

  defp fits?(values),
    do: map_size(values) <= @limit and byte_size(Jason.encode!(values)) <= @max_bytes

  defp evictable(values, now, protected_keys) do
    tier1 =
      values
      |> Enum.filter(fn {key, value} -> tier1_evictable?(key, value, protected_keys) end)
      |> Enum.sort_by(fn {_key, value} -> value["changed_at"] || 0 end)
      |> Enum.map(&elem(&1, 0))

    if tier1 != [] or not is_integer(now) do
      tier1
    else
      values
      |> Enum.filter(fn {key, value} -> tier2_evictable?(key, value, now, protected_keys) end)
      |> Enum.sort_by(fn {_key, value} -> value["changed_at"] || 0 end)
      |> Enum.map(&elem(&1, 0))
    end
  end

  defp tier1_evictable?(key, value, protected_keys) when is_map(value) do
    value["state"] in ~w(handled quiet failed) and is_nil(value["pending"]) and
      is_nil(value["schedule_id"]) and is_nil(value["task_id"]) and
      not watched_entry?(key, value, protected_keys)
  end

  defp tier1_evictable?(_key, _value, _protected_keys), do: false

  defp tier2_evictable?(key, value, now, protected_keys) when is_map(value) and is_integer(now) do
    changed_at = value["changed_at"]

    key != @briefing_key and is_nil(value["pending"]) and is_nil(value["schedule_id"]) and
      not watched_entry?(key, value, protected_keys) and
      not pending_task_leave?(value) and
      is_integer(changed_at) and now - changed_at >= @stale_evict_ms and
      ((value["state"] == "active" and is_nil(value["task_id"])) or
         value["state"] in ~w(handled quiet failed))
  end

  defp tier2_evictable?(_key, _value, _now, _protected_keys), do: false

  defp watched_entry?(key, _value, %MapSet{} = protected), do: MapSet.member?(protected, key)
  defp watched_entry?(_key, _value, :unavailable), do: true

  defp watched_entry?(_key, value, :loop_requests_only),
    do: is_list(value["loop_requests"]) and value["loop_requests"] != []

  defp watched_entry?(_key, _value, _other), do: true

  # `ProactiveTask` relies on `["task", task_id]` keeping its non-`left:`
  # observation until the Task leaves escalated/failed (`DOMAIN_CONCEPTS.md:3308`).
  defp pending_task_leave?(value) do
    value["account_id"] == "task" and
      not String.starts_with?(value["message_id"] || "", "left:")
  end

  # Compact idempotency witness for `last_command`: preserves the small fields
  # read by Home/Notebook (`action`, `generation`, `request_id`) plus a
  # deterministic canonical JSON SHA-256 digest of the full command for exact
  # replay/conflict checks without persisting duplicate multi-KB payloads.
  # Idempotency witness only; not a security or authenticity boundary.
  defp compact_command(
         %{
           "action" => _,
           "generation" => _,
           "request_id" => _,
           "command_sha256" => digest
         } = command
       )
       when map_size(command) == 4 and is_binary(digest),
       do: command

  defp compact_command(command) when is_map(command) do
    %{
      "action" => command["action"],
      "generation" => command["generation"],
      "request_id" => command["request_id"],
      "command_sha256" => command_digest(command)
    }
  end

  defp compact_command(other), do: other

  defp compact_entry_if_finalized(%{"pending" => nil, "last_command" => cmd} = entry)
       when is_map(cmd),
       do: Map.put(entry, "last_command", compact_command(cmd))

  defp compact_entry_if_finalized(%{"last_command" => cmd} = entry)
       when not is_map_key(entry, "pending") and is_map(cmd),
       do: Map.put(entry, "last_command", compact_command(cmd))

  defp compact_entry_if_finalized(entry), do: entry

  defp compact_legacy_entries(values) do
    Map.new(values, fn {key, value} ->
      {key, if(is_map(value), do: compact_entry_if_finalized(value), else: value)}
    end)
  end

  defp same_command?(
         %{
           "action" => _,
           "generation" => _,
           "request_id" => _,
           "command_sha256" => digest
         } = stored,
         command
       )
       when map_size(stored) == 4 and is_binary(digest) and is_map(command) do
    digest == command_digest(command)
  end

  defp same_command?(stored, command), do: stored == command

  defp command_digest(command) do
    command
    |> canonical_json()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {k, canonical_json(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(list) when is_list(list), do: Enum.map(list, &canonical_json/1)
  defp canonical_json(other), do: other

  def public(value),
    do:
      value
      |> Map.drop(~w(pending last_command))
      |> Map.put("saving", not is_nil(value["pending"]))
end
