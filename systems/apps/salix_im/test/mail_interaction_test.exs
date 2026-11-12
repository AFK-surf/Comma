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
      "assessment" => if(pool == "reserve", do: due_in(now, 60 * @minute)),
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
    assert {:open, 10} = MailInteraction.automatic_budget(conversation, @owner, now + 1)

    conversation = decide(conversation, "a", "quiet", "d1", now + 2)
    assert {:open, 5} = MailInteraction.notification_budget(conversation, @owner, now + 2)

    assert %{"state" => "quiet", "decision" => %{"decision" => "quiet", "decided_at" => decided}} =
             MailInteraction.entries(conversation)[MailInteraction.key("internal", "a")]

    assert decided == now + 2
  end

  test "notifications are spaced and capped per day; only reserve-eligible matters skip the spacing" do
    now = 1_000_000_000
    conversation = %{"metadata" => %{}}

    conversation =
      Enum.reduce(~w(a b c d e f), conversation, fn thread, acc ->
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
      Enum.reduce(~w(b c d e), conversation, fn thread, acc ->
        decide(acc, thread, "notify", "d-" <> thread, now + @minute)
      end)

    # The ordinary daily cap is spent; the reserve still serves an eligible
    # matter, and nothing else.
    assert {:closed, _} = MailInteraction.notification_budget(conversation, @owner, now + 2)
    assert {:open, 2} = MailInteraction.notification_budget(conversation, @owner, now + 2, true)

    assert {:error, :proactive_notification_budget_exhausted} =
             decide(
               present(conversation, "h", "critical", now, "ordinary"),
               "h",
               "notify",
               "d-h",
               now + 2 * @minute
             )

    conversation = decide(conversation, "f", "notify", "d-f", now + 2 * @minute)
    conversation = present(conversation, "i", "critical", now + 3 * @minute, "reserve")
    conversation = decide(conversation, "i", "notify", "d-i", now + 3 * @minute)

    # The reserve has its own cap.
    assert {:closed, _} =
             MailInteraction.notification_budget(conversation, @owner, now + 4 * @minute, true)

    assert %{"notified_at" => ordinary, "reserve_notified_at" => reserve} =
             conversation["metadata"]["proactive"][@owner]

    assert {length(ordinary), length(reserve)} == {5, 2}

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
      Enum.reduce(1..12, %{"metadata" => %{}}, fn i, acc ->
        present(acc, "o#{i}", "high", now + i)
      end)

    assert {:closed, opens} = MailInteraction.automatic_budget(conversation, @owner, now + 20)
    assert opens == now + 1 + 24 * 60 * @minute

    # An ordinary matter, however rated, waits for the ordinary pool.
    assert {:error, :proactive_budget_exhausted} =
             present(conversation, "late", "critical", now + 20, "ordinary")

    # A caller's reserve request without an assessment that earns it is an
    # ordinary handoff.
    assert {:error, :proactive_budget_exhausted} =
             run(conversation, now + 20, %{
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
             present(conversation, "not-briefing", "normal", now + 21, "scheduled")

    conversation = present(conversation, "briefing", "normal", now + 21, "scheduled", briefing)

    conversation =
      Enum.reduce(1..4, conversation, fn i, acc ->
        present(acc, "r#{i}", "critical", now + 30 + i, "reserve")
      end)

    assert {:error, :proactive_budget_exhausted} =
             present(conversation, "r5", "critical", now + 40, "reserve")

    assert %{"sent_at" => ordinary, "reserve_sent_at" => reserve} =
             conversation["metadata"]["proactive"][@owner]

    assert {length(ordinary), length(reserve)} == {12, 4}
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
end
