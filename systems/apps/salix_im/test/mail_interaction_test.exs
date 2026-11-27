defmodule SalixIM.MailInteractionTest do
  use SystemsClock.Case, async: true

  alias SalixIM.MailInteraction

  @owner "user-1"
  @minute 60 * 1000

  # A reserve request carries an assessment that earns it: the owner must
  # act on a cost due within the hour.
  defp present(conversation, thread, urgency, now, pool \\ nil, key \\ nil) do
    run(conversation, now, %{
      "action" => "present",
      "automatic" => true,
      "urgency" => urgency,
      "pool" => pool,
      "assessment" =>
        case pool do
          "reserve" -> due_in(now, 60 * @minute)
          "code" -> Map.put(due_in(now, 10 * @minute), "code", true)
          _ -> nil
        end,
      "key" => key || MailInteraction.key("internal", thread),
      "request_id" => "check:" <> thread,
      "account_id" => "internal",
      "thread_id" => thread,
      "message_id" => "m1",
      "text" => "Review " <> thread
    })
  end

  defp due_in(now, ms, reversible \\ true) do
    %{
      "role" => "act",
      "cost" => "The owner's account stays at risk",
      "due" => (now + ms) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
      "reversible" => reversible
    }
  end

  defp decide(conversation, thread, action, request, now) do
    key = MailInteraction.key("internal", thread)
    value = MailInteraction.entries(conversation)[key]

    run(conversation, now, %{
      "action" => action,
      "key" => key,
      "generation" => value["generation"],
      "request_id" => request
    })
  end

  # Reserves one command, then settles its pending effect as the actor does.
  defp run(conversation, now, command) do
    case MailInteraction.reserve(conversation, @owner, command, now, "t") do
      %{} = reserved ->
        entry = MailInteraction.entries(reserved)[command["key"]]
        MailInteraction.commit(reserved, command["key"], Map.delete(entry, "pending"), "t")

      error ->
        error
    end
  end

  test "handoffs spend only their daily cap and quiet decisions spend no notification" do
    now = 1_000_000_000
    conversation = %{"metadata" => %{}}

    conversation = present(conversation, "a", "high", now)
    conversation = present(conversation, "b", "high", now + 1)
    assert {:open, 18} = MailInteraction.automatic_budget(conversation, @owner, now + 1)

    conversation = decide(conversation, "a", "quiet", "d1", now + 2)
    assert {:open, 10} = MailInteraction.notification_budget(conversation, @owner, now + 2)

    assert %{"state" => "quiet", "decision" => %{"decision" => "quiet", "decided_at" => decided}} =
             MailInteraction.entries(conversation)[MailInteraction.key("internal", "a")]

    assert decided == now + 2
  end

  test "notifications are spaced and capped per day; only reserve-eligible matters skip the spacing" do
    now = 1_000_000_000
    conversation = %{"metadata" => %{}}

    conversation =
      Enum.reduce(["a" | Enum.map(1..13, &"r#{&1}")], conversation, fn thread, acc ->
        present(acc, thread, "critical", now, if(thread == "a", do: "ordinary", else: "reserve"))
      end)

    conversation = decide(conversation, "a", "notify", "d-a", now)
    assert {:closed, next_at} = MailInteraction.notification_budget(conversation, @owner, now)
    assert next_at == now + 30 * @minute

    # A critical label alone waits for the spacing; a reserve-eligible matter
    # skips it.
    assert {:error, :proactive_notification_budget_exhausted} =
             decide(
               present(conversation, "g", "critical", now, "ordinary"),
               "g",
               "notify",
               "d-g",
               now + @minute
             )

    conversation =
      Enum.reduce(Enum.map(1..9, &"r#{&1}"), conversation, fn thread, acc ->
        decide(acc, thread, "notify", "d-" <> thread, now + @minute)
      end)

    # The ordinary daily cap is spent; the reserve still serves an eligible
    # matter, and nothing else.
    assert {:closed, _} = MailInteraction.notification_budget(conversation, @owner, now + 2)
    assert {:open, 4} = MailInteraction.notification_budget(conversation, @owner, now + 2, true)

    assert {:error, :proactive_notification_budget_exhausted} =
             decide(
               present(conversation, "h", "critical", now, "ordinary"),
               "h",
               "notify",
               "d-h",
               now + 2 * @minute
             )

    conversation =
      Enum.reduce(~w(r10 r11 r12), conversation, fn thread, acc ->
        decide(acc, thread, "notify", "d-" <> thread, now + 2 * @minute)
      end)

    conversation = present(conversation, "i", "critical", now + 3 * @minute, "reserve")
    conversation = decide(conversation, "i", "notify", "d-i", now + 3 * @minute)

    # The reserve has its own cap.
    assert {:closed, _} =
             MailInteraction.notification_budget(conversation, @owner, now + 4 * @minute, true)

    assert %{"notified_at" => ordinary, "reserve_notified_at" => reserve} =
             conversation["metadata"]["proactive"][@owner]

    assert {length(ordinary), length(reserve)} == {10, 4}

    assert {:open, 1} =
             MailInteraction.notification_budget(conversation, @owner, now + 24 * 60 * @minute)
  end

  test "the reserve goes by the cost, its time and whether it can be undone, not by the label" do
    now = 1_000_000_000
    day = 24 * 60 * @minute
    eligible? = &MailInteraction.reserve_eligible?(&1, now)

    assert eligible?.(due_in(now, 2 * 60 * @minute))
    # Due at once, or overdue by less than a day.
    assert eligible?.(due_in(now, 0))
    assert eligible?.(due_in(now, -day + @minute))
    refute eligible?.(due_in(now, 2 * day))
    # A cost that cannot be undone waits less: three days ahead, or no time at
    # all, such as a sign-in the owner may not recognize.
    assert eligible?.(due_in(now, 2 * day, false))
    assert eligible?.(%{due_in(now, 0, false) | "due" => nil})
    # A meeting a week ahead that cannot be repeated is not urgent yet.
    refute eligible?.(due_in(now, 7 * day, false))
    # A reversible cost with no time can wait for the briefing.
    refute eligible?.(%{due_in(now, 0) | "due" => nil})
    # No cost, or not the owner's move.
    refute eligible?.(%{due_in(now, 0) | "cost" => ""})
    refute eligible?.(%{due_in(now, 0) | "role" => "waiting"})
  end

  test "spent ordinary handoffs leave the reserve to eligible matters, and a scheduled briefing spends none" do
    now = 1_000_000_000

    conversation =
      Enum.reduce(1..20, %{"metadata" => %{}}, fn i, acc ->
        present(acc, "o#{i}", "high", now + i)
      end)

    assert {:closed, opens} = MailInteraction.automatic_budget(conversation, @owner, now + 30)
    assert opens == now + 1 + 24 * 60 * @minute

    # An ordinary matter, however rated, waits for the ordinary pool.
    assert {:error, :proactive_budget_exhausted} =
             present(conversation, "late", "critical", now + 30, "ordinary")

    # A caller's reserve request without an assessment that earns it is an
    # ordinary handoff.
    assert {:error, :proactive_budget_exhausted} =
             run(conversation, now + 30, %{
               "action" => "present",
               "automatic" => true,
               "urgency" => "critical",
               "pool" => "reserve",
               "assessment" => %{due_in(now, 7 * 24 * 60 * @minute) | "reversible" => false},
               "key" => MailInteraction.key("internal", "meeting"),
               "request_id" => "check:meeting",
               "account_id" => "internal",
               "thread_id" => "meeting",
               "message_id" => "m1",
               "text" => "Meeting next week"
             })

    # The scheduled briefing does not compete for handoffs. It has its own key
    # and a small cap of its own.
    briefing = MailInteraction.key("routine", "briefing")

    assert {:error, :invalid_mail_source} =
             present(conversation, "not-briefing", "normal", now + 31, "scheduled")

    conversation = present(conversation, "briefing", "normal", now + 31, "scheduled", briefing)

    conversation =
      Enum.reduce(1..6, conversation, fn i, acc ->
        present(acc, "r#{i}", "critical", now + 40 + i, "reserve")
      end)

    assert {:error, :proactive_budget_exhausted} =
             present(conversation, "r7", "critical", now + 50, "reserve")

    assert %{"sent_at" => ordinary, "reserve_sent_at" => reserve} =
             conversation["metadata"]["proactive"][@owner]

    assert {length(ordinary), length(reserve)} == {20, 6}
  end

  test "codes spend their own pool and leave the others to other matters" do
    now = 1_000_000_000
    codes = Enum.map(1..6, &"code#{&1}")

    conversation =
      Enum.reduce(codes, %{"metadata" => %{}}, fn thread, acc ->
        present(acc, thread, "high", now, "code")
      end)

    # Codes skip the spacing, one after another.
    conversation =
      Enum.reduce(codes, conversation, fn thread, acc ->
        decide(acc, thread, "notify", "d-" <> thread, now + 1)
      end)

    assert {:closed, _} = MailInteraction.code_budget(conversation, @owner, :handoff, now + 2)

    assert {:closed, _} =
             MailInteraction.code_budget(conversation, @owner, :notification, now + 2)

    assert {:error, :proactive_budget_exhausted} =
             present(conversation, "code7", "high", now + 2, "code")

    # The ordinary pools and the reserve stay whole.
    assert {:open, 20} = MailInteraction.automatic_budget(conversation, @owner, now + 2)
    assert {:open, 10} = MailInteraction.notification_budget(conversation, @owner, now + 2)

    assert {:open, 4} =
             MailInteraction.reserve_budget(conversation, @owner, :notification, now + 2)

    # A caller's code pool without an assessment that says code is ordinary.
    conversation =
      run(conversation, now + 3, %{
        "action" => "present",
        "automatic" => true,
        "urgency" => "high",
        "pool" => "code",
        "assessment" => due_in(now, 10 * @minute),
        "key" => MailInteraction.key("internal", "alert"),
        "request_id" => "check:alert",
        "account_id" => "internal",
        "thread_id" => "alert",
        "message_id" => "m1",
        "text" => "Sign-in alert"
      })

    assert {:open, 19} = MailInteraction.automatic_budget(conversation, @owner, now + 3)
  end

  test "agent and agent_code pools isolate station_task and task matters from passive inbox and OTP code pools" do
    now = 1_000_000_000

    present_agent = fn conv, account, thread, pool, assessment, at, message_id ->
      key = MailInteraction.key(account, thread)
      current = MailInteraction.entries(conv)[key]

      command = %{
        "action" => "present",
        "automatic" => true,
        "urgency" => "high",
        "pool" => pool,
        "assessment" => assessment,
        "key" => key,
        "request_id" => "agent:" <> account <> ":" <> thread <> ":" <> message_id,
        "account_id" => account,
        "thread_id" => thread,
        "message_id" => message_id,
        "text" => "Agent stop " <> thread <> " " <> message_id
      }

      command =
        if is_map(current),
          do: Map.put(command, "generation", current["generation"]),
          else: command

      run(conv, at, command)
    end

    notify_agent = fn conv, account, thread, req, at ->
      key = MailInteraction.key(account, thread)
      value = MailInteraction.entries(conv)[key]

      run(conv, at, %{
        "action" => "notify",
        "key" => key,
        "generation" => value["generation"],
        "request_id" => req
      })
    end

    # Exhaust ordinary passive inbox handoffs and email OTP codes first.
    conversation =
      Enum.reduce(1..20, %{"metadata" => %{}}, fn i, acc ->
        present(acc, "inbox-#{i}", "high", now + i)
      end)

    conversation =
      Enum.reduce(1..6, conversation, fn i, acc ->
        present(acc, "otp-#{i}", "high", now + 20 + i, "code")
      end)

    assert {:closed, _} = MailInteraction.automatic_budget(conversation, @owner, now + 30)
    assert {:closed, _} = MailInteraction.code_budget(conversation, @owner, :handoff, now + 30)

    # Both station_task and task stops still succeed on their dedicated agent
    # pool (120 handoffs, 30 back-to-back notifications with zero spacing).
    # Reuse active chat threads for stops beyond 31 so tracked matter count
    # stays within the Home conversation's 128-entry tracking cap.
    conversation =
      Enum.reduce(1..120, conversation, fn i, acc ->
        account = if i == 1, do: "task", else: "station_task"
        thread = if i <= 31, do: "ag-#{i}", else: "ag-#{rem(i - 32, 30) + 2}"
        present_agent.(acc, account, thread, "agent", nil, now + 30 + i, "m-#{i}")
      end)

    assert {:closed, _} = MailInteraction.agent_budget(conversation, @owner, :handoff, now + 180)

    assert {:error, :proactive_budget_exhausted} =
             present_agent.(
               conversation,
               "station_task",
               "ag-121",
               "agent",
               nil,
               now + 180,
               "m1"
             )

    # Back-to-back notifications succeed without the 30-minute passive spacing
    # up to the 30/day cap.
    conversation =
      Enum.reduce(1..30, conversation, fn i, acc ->
        account = if i == 1, do: "task", else: "station_task"
        notify_agent.(acc, account, "ag-#{i}", "n-ag-#{i}", now + 190)
      end)

    assert {:closed, _} =
             MailInteraction.agent_budget(conversation, @owner, :notification, now + 191)

    assert {:error, :proactive_notification_budget_exhausted} =
             notify_agent.(conversation, "station_task", "ag-31", "n-ag-31", now + 191)

    # Passive notification pool remains untouched at 10/10.
    assert {:open, 10} = MailInteraction.notification_budget(conversation, @owner, now + 191)

    # Expiring interactive agent cards still break through via agent_code even
    # when ordinary, email code, and agent pools are all exhausted.
    code_assessment = Map.put(due_in(now, 10 * @minute), "code", true)

    conversation =
      present_agent.(
        conversation,
        "station_task",
        "login-1",
        "agent_code",
        code_assessment,
        now + 195,
        "m1"
      )

    conversation =
      notify_agent.(conversation, "station_task", "login-1", "n-login-1", now + 196)

    assert {:open, 39} =
             MailInteraction.agent_code_budget(conversation, @owner, :handoff, now + 197)

    assert {:open, 39} =
             MailInteraction.agent_code_budget(conversation, @owner, :notification, now + 197)

    # A non-agent account cannot claim agent or agent_code pools; it falls back
    # to the exhausted ordinary pool.
    assert {:error, :proactive_budget_exhausted} =
             present_agent.(
               conversation,
               "internal",
               "spoof-agent",
               "agent",
               nil,
               now + 198,
               "m1"
             )

    assert {:error, :proactive_budget_exhausted} =
             present_agent.(
               conversation,
               "internal",
               "spoof-code",
               "agent_code",
               code_assessment,
               now + 198,
               "m1"
             )

    # A station_task requesting agent_code without assessment.code == true also
    # falls back to the ordinary pool instead of spending agent_code.
    assert {:error, :proactive_budget_exhausted} =
             present_agent.(
               conversation,
               "station_task",
               "no-code-flag",
               "agent_code",
               due_in(now, 10 * @minute),
               now + 199,
               "m1"
             )
  end

  test "a full store drops the oldest settled matter for a new one and never a followed one" do
    now = 1_000_000_000

    value = fn thread, state, changed ->
      %{
        "owner_id" => @owner,
        "account_id" => "internal",
        "thread_id" => thread,
        "state" => state,
        "generation" => 1,
        "changed_at" => changed
      }
    end

    # 127 followed matters and one handled matter, the oldest of all.
    full =
      for(
        i <- 1..127,
        into: %{},
        do: {MailInteraction.key("internal", "t#{i}"), value.("t#{i}", "active", now + i)}
      )
      |> Map.put(MailInteraction.key("internal", "done"), value.("done", "handled", now))

    conversation =
      present(%{"metadata" => %{"mail_interactions" => full}}, "new", "high", now + 500)

    entries = MailInteraction.entries(conversation)

    assert map_size(entries) == 128
    assert Map.has_key?(entries, MailInteraction.key("internal", "new"))
    refute Map.has_key?(entries, MailInteraction.key("internal", "done"))

    # With only followed matters, nothing is dropped and the new matter fails.
    followed =
      Map.put(full, MailInteraction.key("internal", "done"), value.("done", "active", now))

    assert {:error, :mail_tracking_capacity} =
             present(
               %{"metadata" => %{"mail_interactions" => followed}},
               "new",
               "high",
               now + 500
             )
  end

  test "stillfail notification level defaults to action_needed, filters kinds monotonically, and persists independently of enabled" do
    conversation = %{"metadata" => %{}}
    assert MailInteraction.stillfail_notification_level(conversation, @owner) == "action_needed"

    refute MailInteraction.stillfail_notification_allows?("off", "need")
    refute MailInteraction.stillfail_notification_allows?("off", "failed")
    refute MailInteraction.stillfail_notification_allows?("off", "done")

    assert MailInteraction.stillfail_notification_allows?("action_needed", "need")
    refute MailInteraction.stillfail_notification_allows?("action_needed", "failed")
    refute MailInteraction.stillfail_notification_allows?("action_needed", "done")

    assert MailInteraction.stillfail_notification_allows?("issues", "need")
    assert MailInteraction.stillfail_notification_allows?("issues", "failed")
    refute MailInteraction.stillfail_notification_allows?("issues", "done")

    assert MailInteraction.stillfail_notification_allows?("all", "need")
    assert MailInteraction.stillfail_notification_allows?("all", "failed")
    assert MailInteraction.stillfail_notification_allows?("all", "done")

    updated =
      MailInteraction.configure_stillfail_notifications(
        conversation,
        @owner,
        "issues",
        "req-1",
        "t1"
      )

    assert MailInteraction.stillfail_notification_level(updated, @owner) == "issues"
    assert MailInteraction.enabled?(updated, @owner)

    # Idempotent replay with same request_id succeeds; conflicting level is rejected.
    assert updated ==
             MailInteraction.configure_stillfail_notifications(
               updated,
               @owner,
               "issues",
               "req-1",
               "t2"
             )

    assert {:error, :mail_request_conflict} =
             MailInteraction.configure_stillfail_notifications(
               updated,
               @owner,
               "all",
               "req-1",
               "t2"
             )

    assert {:error, :invalid_proactive_settings} =
             MailInteraction.configure_stillfail_notifications(
               updated,
               @owner,
               "bogus",
               "req-2",
               "t2"
             )

    # Toggling enabled preserves stillfail_notification_level and uses its own request_id.
    toggled = MailInteraction.configure(updated, @owner, false, "req-1", "t3")
    refute MailInteraction.enabled?(toggled, @owner)
    assert MailInteraction.stillfail_notification_level(toggled, @owner) == "issues"
  end

  test "signals spend their own strict pool (2/24h, 2h spacing), never touch reserve or ordinary pools" do
    now = 1_000_000_000
    hour = 60 * @minute

    signal_present = fn conv, thread, at ->
      run(conv, at, %{
        "action" => "present",
        "automatic" => true,
        "urgency" => "normal",
        "pool" => "signal",
        "assessment" => %{
          "role" => "reference",
          "link" => "portrait",
          "cost" => "",
          "due" => nil,
          "reversible" => true,
          "signal" => true
        },
        "key" => MailInteraction.key("internal", thread),
        "request_id" => "check:" <> thread,
        "account_id" => "internal",
        "thread_id" => thread,
        "message_id" => "m1",
        "text" => "Signal " <> thread
      })
    end

    # A signal never qualifies for the emergency reserve even if given a cost/due.
    refute MailInteraction.reserve_eligible?(Map.put(due_in(now, @minute), "signal", true), now)

    conv = %{"metadata" => %{}}
    conv = signal_present.(conv, "sig1", now)
    conv = signal_present.(conv, "sig2", now + 1)
    conv = signal_present.(conv, "sig3", now + 2)
    conv = signal_present.(conv, "sig4", now + 3)

    # Handoff cap is 4 in 24h; 5th handoff fails while ordinary pool stays whole.
    assert {:closed, _} = MailInteraction.signal_budget(conv, @owner, :handoff, now + 4)

    assert {:error, :proactive_budget_exhausted} = signal_present.(conv, "sig5", now + 4)
    assert {:open, 20} = MailInteraction.automatic_budget(conv, @owner, now + 4)

    # Notification 1 succeeds; a second notification within 2 hours is blocked by spacing.
    conv = decide(conv, "sig1", "notify", "d-sig1", now + 10)

    assert {:closed, next_at} =
             MailInteraction.signal_budget(conv, @owner, :notification, now + 10)

    assert next_at == now + 10 + 2 * hour

    assert {:error, :proactive_notification_budget_exhausted} =
             decide(conv, "sig2", "notify", "d-sig2-early", now + hour)

    # After 2 hours, notification 2 succeeds; notification 3 is capped for 24h.
    conv = decide(conv, "sig2", "notify", "d-sig2", now + 10 + 2 * hour)

    assert {:error, :proactive_notification_budget_exhausted} =
             decide(conv, "sig3", "notify", "d-sig3", now + 10 + 5 * hour)

    # Ordinary and reserve notification pools stay completely untouched.
    assert {:open, 10} = MailInteraction.notification_budget(conv, @owner, now + 10 + 5 * hour)

    assert {:open, 4} =
             MailInteraction.reserve_budget(conv, @owner, :notification, now + 10 + 5 * hour)

    # A caller claiming pool "signal" without assessment.signal == true spends ordinary, not signal.
    spoofed =
      run(conv, now + 10 + 5 * hour, %{
        "action" => "present",
        "automatic" => true,
        "urgency" => "normal",
        "pool" => "signal",
        "assessment" => %{"role" => "act", "cost" => "x"},
        "key" => MailInteraction.key("internal", "spoof"),
        "request_id" => "check:spoof",
        "account_id" => "internal",
        "thread_id" => "spoof",
        "message_id" => "m1",
        "text" => "Spoof"
      })

    assert {:open, 19} = MailInteraction.automatic_budget(spoofed, @owner, now + 10 + 5 * hour)
  end

  test "last_command stores a compact digest witness while preserving replay, conflict, and legacy compatibility" do
    now = 1_000_000_000
    key = MailInteraction.key("internal", "compact-1")
    large_text = String.duplicate("Evidence line about release checklist.\n", 120)

    command = %{
      "action" => "present",
      "automatic" => false,
      "key" => key,
      "request_id" => "req-compact-1",
      "account_id" => "internal",
      "thread_id" => "compact-1",
      "message_id" => "m1",
      "text" => large_text
    }

    reserved = MailInteraction.reserve(%{"metadata" => %{}}, @owner, command, now, "t1")
    pending_entry = MailInteraction.entries(reserved)[key]

    # In-flight pending command stays verbatim for resume/retry; last_command is compact.
    assert pending_entry["pending"]["command"] == command
    assert pending_entry["last_command"]["action"] == "present"
    assert pending_entry["last_command"]["generation"] == nil
    assert pending_entry["last_command"]["request_id"] == "req-compact-1"
    assert is_binary(pending_entry["last_command"]["command_sha256"])
    refute Map.has_key?(pending_entry["last_command"], "text")

    finalized =
      MailInteraction.commit(reserved, key, Map.delete(pending_entry, "pending"), "t2", now)

    entry = MailInteraction.entries(finalized)[key]
    assert is_nil(entry["pending"])
    refute Map.has_key?(entry["last_command"], "text")

    # Exact replay with the same request_id and payload succeeds as unchanged.
    assert {:ok, :unchanged} = MailInteraction.plan(finalized, @owner, command, now + 1)

    # Reusing request_id with any altered field is still rejected as a conflict.
    assert {:error, :mail_request_conflict} =
             MailInteraction.plan(
               finalized,
               @owner,
               Map.put(command, "text", large_text <> "tampered"),
               now + 1
             )

    # Legacy entries storing the full uncompacted last_command remain replay-compatible.
    legacy_key = MailInteraction.key("internal", "legacy-1")
    legacy_cmd = Map.merge(command, %{"key" => legacy_key, "request_id" => "req-legacy-1"})

    legacy_conv = %{
      "metadata" => %{
        "mail_interactions" => %{
          legacy_key => %{
            "owner_id" => @owner,
            "account_id" => "internal",
            "thread_id" => "legacy-1",
            "state" => "active",
            "generation" => 1,
            "changed_at" => now,
            "request_id" => "req-legacy-1",
            "last_command" => legacy_cmd
          }
        }
      }
    }

    assert {:ok, :unchanged} = MailInteraction.plan(legacy_conv, @owner, legacy_cmd, now + 1)

    assert {:error, :mail_request_conflict} =
             MailInteraction.plan(
               legacy_conv,
               @owner,
               Map.put(legacy_cmd, "text", "different"),
               now + 1
             )
  end

  test "at byte capacity, legacy finalized last_command payloads compact in place without evicting entries" do
    now = 1_000_000_000
    bloated_text = String.duplicate("x", 4_500)

    legacy_entries =
      for i <- 1..55, into: %{} do
        key = MailInteraction.key("internal", "leg-#{i}")

        {key,
         %{
           "owner_id" => @owner,
           "account_id" => "internal",
           "thread_id" => "leg-#{i}",
           "state" => "active",
           "generation" => 1,
           "changed_at" => now + i,
           "request_id" => "req-leg-#{i}",
           "last_command" => %{
             "action" => "present",
             "key" => key,
             "request_id" => "req-leg-#{i}",
             "text" => bloated_text
           }
         }}
      end

    assert byte_size(Jason.encode!(legacy_entries)) > 250_000

    updated =
      run(
        %{"metadata" => %{"mail_interactions" => legacy_entries}},
        now + 100,
        %{
          "action" => "present",
          "automatic" => false,
          "key" => MailInteraction.key("internal", "fresh-new"),
          "request_id" => "req-fresh-new",
          "account_id" => "internal",
          "thread_id" => "fresh-new",
          "message_id" => "m-fresh",
          "text" => String.duplicate("y", 4_000)
        }
      )

    entries = MailInteraction.entries(updated)
    assert map_size(entries) == 56
    assert Map.has_key?(entries, MailInteraction.key("internal", "fresh-new"))
    assert byte_size(Jason.encode!(entries)) < 40_000

    # Compacted legacy entry still supports exact replay and conflict checks.
    leg1_key = MailInteraction.key("internal", "leg-1")
    refute Map.has_key?(entries[leg1_key]["last_command"], "text")

    assert {:ok, :unchanged} =
             MailInteraction.plan(
               updated,
               @owner,
               %{
                 "action" => "present",
                 "key" => leg1_key,
                 "request_id" => "req-leg-1",
                 "text" => bloated_text
               },
               now + 101
             )
  end

  test "at 128 capacity, stale >=14d active and settled task matters evict after Tier-1, while recent active, scheduled, pending, and active task matters never evict" do
    day = 24 * 60 * @minute
    now = 30 * day

    make_entry = fn account, thread, state, changed_at, extra ->
      Map.merge(
        %{
          "owner_id" => @owner,
          "account_id" => account,
          "thread_id" => thread,
          "state" => state,
          "generation" => 1,
          "changed_at" => changed_at
        },
        extra
      )
    end

    # 124 recent active (<14d) + 1 Tier-1 settled unlinked (1d) + 1 stale active (20d)
    # + 1 stale handled with task_id (18d) + 1 stale closed `left:` task matter (16d).
    base =
      for i <- 1..124, into: %{} do
        {MailInteraction.key("internal", "recent-#{i}"),
         make_entry.("internal", "recent-#{i}", "active", now - 2 * day + i, %{})}
      end
      |> Map.put(
        MailInteraction.key("internal", "tier1-settled"),
        make_entry.("internal", "tier1-settled", "handled", now - day, %{})
      )
      |> Map.put(
        MailInteraction.key("internal", "stale-active"),
        make_entry.("internal", "stale-active", "active", now - 20 * day, %{})
      )
      |> Map.put(
        MailInteraction.key("internal", "stale-handled-task"),
        make_entry.("internal", "stale-handled-task", "handled", now - 18 * day, %{
          "task_id" => "tsk_old"
        })
      )
      |> Map.put(
        MailInteraction.key("task", "tsk_left"),
        make_entry.("task", "tsk_left", "handled", now - 16 * day, %{
          "task_id" => "tsk_left",
          "message_id" => "left:4"
        })
      )

    # First new matter evicts Tier-1 settled unlinked matter before any Tier-2 stale matter.
    conv1 = present(%{"metadata" => %{"mail_interactions" => base}}, "new-1", "high", now)
    entries1 = MailInteraction.entries(conv1)
    assert map_size(entries1) == 128
    refute Map.has_key?(entries1, MailInteraction.key("internal", "tier1-settled"))
    assert Map.has_key?(entries1, MailInteraction.key("internal", "stale-active"))

    # Second new matter has no Tier-1 left -> evicts oldest Tier-2 (stale-active at 20d).
    conv2 = present(conv1, "new-2", "high", now + 1)
    entries2 = MailInteraction.entries(conv2)
    assert map_size(entries2) == 128
    refute Map.has_key?(entries2, MailInteraction.key("internal", "stale-active"))
    assert Map.has_key?(entries2, MailInteraction.key("internal", "stale-handled-task"))

    # Third new matter evicts stale-handled-task at 18d.
    conv3 = present(conv2, "new-3", "high", now + 2)
    entries3 = MailInteraction.entries(conv3)
    assert map_size(entries3) == 128
    refute Map.has_key?(entries3, MailInteraction.key("internal", "stale-handled-task"))
    assert Map.has_key?(entries3, MailInteraction.key("task", "tsk_left"))

    # Fourth new matter evicts stale closed `left:` task matter at 16d.
    conv4 = present(conv3, "new-4", "high", now + 3)
    entries4 = MailInteraction.entries(conv4)
    assert map_size(entries4) == 128
    refute Map.has_key?(entries4, MailInteraction.key("task", "tsk_left"))

    # Fifth new matter fails: only recent (<14d) active matters remain.
    assert {:error, :mail_tracking_capacity} = present(conv4, "new-5", "high", now + 4)

    # Protected old (>=14d) matters must NEVER evict: scheduled, pending, active
    # task-linked, handled `task` awaiting `left:` leave, recent closed `left:` task (<14d),
    # and active watched matters (via protected_keys or loop_requests fail-closed).
    watched_key = MailInteraction.key("internal", "old-watched")

    protected =
      for i <- 1..122, into: %{} do
        {MailInteraction.key("internal", "r-#{i}"),
         make_entry.("internal", "r-#{i}", "active", now - day + i, %{})}
      end
      |> Map.put(
        MailInteraction.key("internal", "old-scheduled"),
        make_entry.("internal", "old-scheduled", "active", now - 30 * day, %{
          "schedule_id" => "sch_1"
        })
      )
      |> Map.put(
        MailInteraction.key("internal", "old-pending"),
        make_entry.("internal", "old-pending", "active", now - 30 * day, %{
          "pending" => %{"command" => %{"action" => "present"}}
        })
      )
      |> Map.put(
        MailInteraction.key("internal", "old-active-task"),
        make_entry.("internal", "old-active-task", "active", now - 30 * day, %{
          "task_id" => "tsk_live"
        })
      )
      |> Map.put(
        MailInteraction.key("task", "tsk_escalated_waiting_leave"),
        make_entry.("task", "tsk_escalated_waiting_leave", "handled", now - 30 * day, %{
          "task_id" => "tsk_escalated_waiting_leave",
          "message_id" => "escalated:7"
        })
      )
      |> Map.put(
        MailInteraction.key("task", "tsk_left_recent"),
        make_entry.("task", "tsk_left_recent", "handled", now - 2 * day, %{
          "task_id" => "tsk_left_recent",
          "message_id" => "left:2"
        })
      )
      |> Map.put(
        watched_key,
        make_entry.("internal", "old-watched", "active", now - 30 * day, %{
          "loop_requests" => ["loop:abc123"]
        })
      )

    # Without explicit protected_keys, loop_requests fails closed and protects the watched matter.
    assert {:error, :mail_tracking_capacity} =
             present(%{"metadata" => %{"mail_interactions" => protected}}, "new-6", "high", now)

    # With explicit protected_keys containing the watch key, it is still protected.
    cmd = %{
      "action" => "present",
      "automatic" => false,
      "key" => MailInteraction.key("internal", "new-7"),
      "request_id" => "req-new-7",
      "account_id" => "internal",
      "thread_id" => "new-7",
      "message_id" => "m1",
      "text" => "New matter"
    }

    assert {:error, :mail_tracking_capacity} =
             MailInteraction.reserve(
               %{"metadata" => %{"mail_interactions" => protected}},
               @owner,
               cmd,
               now,
               "t1",
               protected_keys: MapSet.new([watched_key])
             )

    # Once the watch is no longer active (not in protected_keys), the 30d untouched matter can evict.
    assert %{} =
             evicted_retired_watch =
             MailInteraction.reserve(
               %{"metadata" => %{"mail_interactions" => protected}},
               @owner,
               cmd,
               now,
               "t1",
               protected_keys: MapSet.new()
             )

    refute Map.has_key?(MailInteraction.entries(evicted_retired_watch), watched_key)
    assert Map.has_key?(MailInteraction.entries(evicted_retired_watch), cmd["key"])
  end

  test "active watches are protected from Tier-1 eviction and watch lookup failure fails closed in both Tier-1 and Tier-2" do
    day = 24 * 60 * @minute
    now = 30 * day

    make_entry = fn thread, state, changed_at, extra ->
      Map.merge(
        %{
          "owner_id" => @owner,
          "account_id" => "internal",
          "thread_id" => thread,
          "state" => state,
          "generation" => 1,
          "changed_at" => changed_at
        },
        extra
      )
    end

    watched_quiet_key = MailInteraction.key("internal", "watched-quiet")
    fresh_watch_active_key = MailInteraction.key("internal", "fresh-watch-no-wakes")
    plain_handled_key = MailInteraction.key("internal", "plain-handled")

    entries =
      for i <- 1..125, into: %{} do
        {MailInteraction.key("internal", "recent-#{i}"),
         make_entry.("recent-#{i}", "active", now - day + i, %{})}
      end
      |> Map.put(
        watched_quiet_key,
        make_entry.("watched-quiet", "quiet", now - 25 * day, %{"loop_requests" => ["loop:w1"]})
      )
      |> Map.put(
        fresh_watch_active_key,
        make_entry.("fresh-watch-no-wakes", "active", now - 20 * day, %{})
      )
      |> Map.put(
        plain_handled_key,
        make_entry.("plain-handled", "handled", now - 2 * day, %{})
      )

    cmd = %{
      "action" => "present",
      "automatic" => false,
      "key" => MailInteraction.key("internal", "incoming"),
      "request_id" => "req-incoming",
      "account_id" => "internal",
      "thread_id" => "incoming",
      "message_id" => "m1",
      "text" => "Incoming"
    }

    # With active watches resolved: Tier-1 skips the older watched quiet entry and evicts plain-handled instead.
    protected = MapSet.new([watched_quiet_key, fresh_watch_active_key])

    assert %{} =
             reserved =
             MailInteraction.reserve(
               %{"metadata" => %{"mail_interactions" => entries}},
               @owner,
               cmd,
               now,
               "t1",
               protected_keys: protected
             )

    result_entries = MailInteraction.entries(reserved)
    assert Map.has_key?(result_entries, watched_quiet_key)
    assert Map.has_key?(result_entries, fresh_watch_active_key)
    refute Map.has_key?(result_entries, plain_handled_key)

    # With watch lookup `:unavailable`: fails closed in BOTH Tier-1 (plain-handled) and
    # Tier-2 (brand-new 20d active watch with empty loop_requests) — nothing is dropped.
    assert {:error, :mail_tracking_capacity} =
             MailInteraction.reserve(
               %{"metadata" => %{"mail_interactions" => entries}},
               @owner,
               cmd,
               now,
               "t1",
               protected_keys: :unavailable
             )

    tier2_only =
      entries
      |> Map.delete(plain_handled_key)
      |> Map.put(
        MailInteraction.key("internal", "recent-126"),
        make_entry.("recent-126", "active", now - day + 126, %{})
      )

    assert {:error, :mail_tracking_capacity} =
             MailInteraction.reserve(
               %{"metadata" => %{"mail_interactions" => tier2_only}},
               @owner,
               cmd,
               now,
               "t1",
               protected_keys: :unavailable
             )
  end

  test "at 256 KB byte capacity with <128 entries, Tier-2 stale active matters evict after compaction" do
    day = 24 * 60 * @minute
    now = 30 * day
    big_subject = String.duplicate("s", 5_500)

    entries =
      for i <- 1..42, into: %{} do
        {MailInteraction.key("internal", "rec-#{i}"),
         %{
           "owner_id" => @owner,
           "account_id" => "internal",
           "thread_id" => "rec-#{i}",
           "state" => "active",
           "generation" => 1,
           "changed_at" => now - day + i,
           "subject" => big_subject
         }}
      end
      |> Map.put(
        MailInteraction.key("internal", "stale-byte"),
        %{
          "owner_id" => @owner,
          "account_id" => "internal",
          "thread_id" => "stale-byte",
          "state" => "active",
          "generation" => 1,
          "changed_at" => now - 20 * day,
          "subject" => String.duplicate("z", 14_000)
        }
      )

    updated =
      run(%{"metadata" => %{"mail_interactions" => entries}}, now, %{
        "action" => "present",
        "automatic" => false,
        "key" => MailInteraction.key("internal", "fresh-byte"),
        "request_id" => "req-fresh-byte",
        "account_id" => "internal",
        "thread_id" => "fresh-byte",
        "message_id" => "m1",
        "subject" => big_subject,
        "text" => "Needs space"
      })

    result_entries = MailInteraction.entries(updated)
    assert Map.has_key?(result_entries, MailInteraction.key("internal", "fresh-byte"))
    refute Map.has_key?(result_entries, MailInteraction.key("internal", "stale-byte"))
  end
end
