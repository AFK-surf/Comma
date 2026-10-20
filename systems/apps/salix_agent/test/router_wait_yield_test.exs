defmodule SalixAgent.RouterWaitYieldTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.InternalSession, as: Session
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.Waits

  test "yield settles only A and leaves B queued with its own authority across providers" do
    for provider <- ~w(telegram slack feishu wechat) do
      waiting = waiting_source(provider)

      assert materialize(waiting) == {[], false, 0}

      assert yieldable?(waiting)
      events = yield_events(waiting, waiting)
      assert length(events) == 3
      yielded = SessionData.apply_events(waiting, events)
      assert yielded.last_ack_message_id == 1
      assert yielded.wait == nil
      assert yielded.messages == waiting.messages
      assert yielded.next_message_id == waiting.next_message_id
      assert yielded.input_queue == waiting.input_queue
      assert yielded.queue_ack_id == waiting.queue_ack_id
      assert yielded.active_source_message_ids == []
      assert yielded.visible_reply_egress_facts == %{}

      {input_events, true, _} = materialize(yielded)

      [input] = Enum.filter(input_events, &(&1["type"] == "delivery"))
      assert input["source_message_id"] == "B"
      assert input["trusted_origin"]["provider"] == provider
      assert input["trusted_origin"]["source_message_id"] == "B"
      assert yield_events(yielded, waiting) == []
    end
  end

  test "a late plan never clears a replacement wait or acknowledges a newer transcript" do
    waiting = waiting_source("telegram")

    replacements = [
      %{waiting | wait: Waits.build("new wait", 60, "wait_for")},
      %{waiting | wait: nil},
      %{waiting | next_message_id: 3},
      %{waiting | last_ack_message_id: 1},
      %{
        waiting
        | messages: [
            %{
              hd(waiting.messages)
              | source_message_id: "C",
                trusted_origin: origin("telegram", "C")
            }
          ]
      }
    ]

    for current <- replacements do
      assert yield_events(current, waiting) == []
    end
  end

  defp materialize(state),
    do: state |> Session.open() |> Session.materialize_pending_input_events()

  defp yieldable?(state), do: state |> Session.open() |> Session.yieldable_provider_wait?()

  # The yield events for `current` while the wait `expected` still holds.
  defp yield_events(%State{} = current, %State{} = expected),
    do: yield_events(Session.open(current), Session.open(expected))

  defp yield_events(current, expected) do
    Session.query(current, :provider_wait_yield_events, %{
      "wait_identity" => Session.wait_identity(expected),
      "next_message_id" => Session.next_message_id(expected),
      "last_ack_message_id" => Session.last_ack_message_id(expected),
      "active_human_source_ids" => Session.active_human_source_ids(expected)
    })
  end

  defp waiting_source(provider) do
    %State{
      Session.export(Session.new("agent", "session"))
      | status: :idle,
        wait: Waits.build("waiting for user", 1800, "wait_for"),
        messages: [
          %{id: 1, role: "user", source_message_id: "A", trusted_origin: origin(provider, "A")}
        ],
        next_message_id: 2,
        active_source_message_ids: ["A"],
        input_queue: [
          %{
            "queue_id" => 1,
            "kind" => "user_message",
            "wake" => true,
            "dedupe_key" => "B",
            "payload" => %{
              "source_message_id" => "B",
              "content" => "new request",
              "trusted_origin" => origin(provider, "B")
            }
          }
        ],
        next_queue_id: 2
    }
  end

  defp origin(provider, source) do
    %{
      "provider" => provider,
      "source_actor_type" => "provider_user",
      "source_message_id" => source
    }
  end
end
