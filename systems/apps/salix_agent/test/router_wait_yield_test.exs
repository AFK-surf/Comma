defmodule SalixAgent.RouterWaitYieldTest do
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession, as: Session
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.Waits

  test "an unfinished Comma human request yields before Telegram is admitted" do
    waiting = waiting_source("telegram")

    comma = %{
      hd(waiting.messages)
      | trusted_origin: Map.put(origin("internal", "A"), "source_actor_type", "user")
    }

    waiting = %{waiting | messages: [comma]}

    assert materialize(waiting) == {[], false, 0}
    assert yieldable?(waiting)

    yielded = SessionData.apply_events(waiting, yield_events(waiting, waiting))

    assert yielded.last_ack_message_id == 1
    assert yielded.messages == [comma]
    {events, true, _} = materialize(yielded)
    admitted = SessionData.apply_events(yielded, events)

    assert Session.current_source_message_ids(Session.open(admitted)) == ["B"]
  end

  test "Comma human requests form a boundary but worker and no-wake context do not" do
    for {actor_type, wake, deferred?} <- [
          {"user", true, true},
          {"agent", true, false},
          {"user", false, false}
        ] do
      waiting = waiting_source("telegram")
      item = hd(waiting.input_queue)

      payload =
        put_in(item["payload"], ["trusted_origin"], %{
          "provider" => "internal",
          "source_actor_type" => actor_type
        })

      waiting = %{waiting | input_queue: [%{item | "payload" => payload, "wake" => wake}]}
      {events, _, _} = materialize(waiting)
      assert Enum.any?(events, &(&1["type"] == "delivery")) == not deferred?
    end
  end

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

  test "generic wait yields without cancelling a running callback or changing its source" do
    pending = %{
      "tool_call_id" => "background-A",
      "tool_name" => "background.work",
      "completion_mode" => "external_callback",
      "status" => "running",
      "trusted_origin" => origin("slack", "A"),
      "trusted_origin_source_message_ids" => ["A"]
    }

    waiting = %{waiting_source("telegram") | async_tool_calls: %{"background-A" => pending}}
    session = Session.open(waiting)
    assert Session.yieldable_provider_wait?(session)
    events = yield_events(session, session)
    yielded = Session.apply_events(session, events)
    assert Session.export(yielded).async_tool_calls == waiting.async_tool_calls
    assert Session.lookup_async_call(yielded, "background-A") == {:ok, pending}

    {inputs, true, _} = Session.materialize_pending_input_events(yielded)
    admitted = Session.apply_events(yielded, inputs)
    assert Session.current_source_message_ids(admitted) == ["B"]

    # Reopen the stored value before the old callback arrives.
    restored = Session.open(Session.export(admitted))
    result = %{content: "background result", status: "completed", error: false}
    completion = SalixAgent.AsyncToolResults.internal_events(pending, result)
    completed = Session.apply_events(restored, completion)
    assert {:ok, record} = Session.lookup_async_call(completed, "background-A")
    assert record["status"] == "completed"
    assert record["trusted_origin_source_message_ids"] == ["A"]
    assert record["trusted_origin"] == pending["trusted_origin"]
    [notification] = Session.export(completed).input_queue
    assert notification["payload"]["trusted_origin_source_message_ids"] == ["A"]

    repeated = Session.apply_events(completed, completion)
    assert Session.export(repeated).async_results == Session.export(completed).async_results
    assert Session.export(repeated).input_queue == Session.export(completed).input_queue
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

  test "real work, repair and card constraints cannot be retired as an ordinary wait" do
    waiting = waiting_source("slack")

    guarded = [
      %{waiting | status: :active},
      %{waiting | wait: Waits.build("tool", 60, "auto_wait")},
      %{waiting | visible_reply_repair: %{"status" => "required", "attempts" => 0}},
      %{waiting | provider_reply_obligations: %{"card" => %{"kind" => "task_card"}}},
      %{waiting | input_queue: []},
      %{waiting | input_queue: [%{hd(waiting.input_queue) | "wake" => false}]}
    ]

    for current <- guarded do
      session = Session.open(current)
      refute Session.yieldable_provider_wait?(session)
      assert yield_events(session, session) == []
    end
  end

  test "current-source runtime input gets processed before any yield" do
    waiting = waiting_source("telegram")

    runtime = %{
      "queue_id" => 2,
      "kind" => "runtime_message",
      "wake" => true,
      "dedupe_key" => "completion",
      "payload" => %{
        "type" => "tool_call_completed",
        "content" => "current result",
        "trusted_origin_source_message_ids" => ["A"]
      }
    }

    current = %{waiting | input_queue: waiting.input_queue ++ [runtime], next_queue_id: 3}
    refute yieldable?(current)
    assert yield_events(current, waiting) == []
    {events, true, _} = materialize(current)
    refute Enum.any?(events, &(&1["type"] == "delivery"))
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
