defmodule SalixIM.MailInteractionTest do
  use ExUnit.Case, async: true

  alias SalixIM.MailInteraction

  @owner "user-1"
  @minute 60 * 1000

  defp present(conversation, thread, urgency, now) do
    run(conversation, now, %{
      "action" => "present",
      "automatic" => true,
      "urgency" => urgency,
      "key" => MailInteraction.key("internal", thread),
      "request_id" => "check:" <> thread,
      "account_id" => "internal",
      "thread_id" => thread,
      "message_id" => "m1",
      "text" => "Review " <> thread
    })
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

  test "notifications are spaced unless critical and capped per day" do
    now = 1_000_000_000
    conversation = %{"metadata" => %{}}

    conversation =
      Enum.reduce(~w(a b c d e f), conversation, fn thread, acc ->
        present(acc, thread, if(thread == "a", do: "high", else: "critical"), now)
      end)

    conversation = decide(conversation, "a", "notify", "d-a", now)
    assert {:closed, next_at} = MailInteraction.notification_budget(conversation, @owner, now)
    assert next_at == now + 30 * @minute

    # A high matter waits for the spacing; a critical one skips it.
    assert {:error, :proactive_notification_budget_exhausted} =
             decide(present(conversation, "g", "high", now), "g", "notify", "d-g", now + @minute)

    conversation =
      Enum.reduce(~w(b c d e), conversation, fn thread, acc ->
        decide(acc, thread, "notify", "d-" <> thread, now + @minute)
      end)

    # The daily cap holds for critical matters too.
    assert {:error, :proactive_notification_budget_exhausted} =
             decide(conversation, "f", "notify", "d-f", now + 2 * @minute)

    assert {:open, 1} =
             MailInteraction.notification_budget(conversation, @owner, now + 24 * 60 * @minute)
  end

  test "notifying keeps a pending recheck" do
    now = 1_000_000_000
    key = MailInteraction.key("internal", "later")
    conversation = present(%{"metadata" => %{}}, "later", "high", now)
    value = MailInteraction.entries(conversation)[key]

    conversation =
      run(conversation, now, %{
        "action" => "snooze",
        "key" => key,
        "generation" => value["generation"],
        "request_id" => "snooze-1",
        "run_at" => now + 60 * @minute,
        "reason" => "Before the deadline"
      })

    %{"schedule_id" => schedule} = MailInteraction.entries(conversation)[key]
    conversation = decide(conversation, "later", "notify", "d1", now + @minute)

    assert %{"state" => "snoozed", "schedule_id" => ^schedule, "run_at" => run_at} =
             MailInteraction.entries(conversation)[key]

    assert run_at == now + 60 * @minute
  end

  test "notifying about a matter the owner asked for spends nothing" do
    now = 1_000_000_000
    key = MailInteraction.key("internal", "asked")

    conversation =
      run(%{"metadata" => %{}}, now, %{
        "action" => "track",
        "key" => key,
        "request_id" => "track-1",
        "account_id" => "internal",
        "thread_id" => "asked",
        "message_id" => "m1"
      })

    # A caller cannot claim the matter is automatic.
    value = MailInteraction.entries(conversation)[key]

    conversation =
      run(conversation, now, %{
        "action" => "notify",
        "automatic" => true,
        "key" => key,
        "generation" => value["generation"],
        "request_id" => "d1"
      })

    assert {:open, 5} = MailInteraction.notification_budget(conversation, @owner, now)
  end
end
