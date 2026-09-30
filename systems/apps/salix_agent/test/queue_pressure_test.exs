defmodule SalixAgent.QueuePressureTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{ContextProviders, InternalSession, InternalSessionStore, QueuePressure}

  @now ~U[2026-09-14 08:00:00Z]
  @now_ms 1_789_372_800_000
  @router %{role: "router"}

  defp item(id, origin, extra \\ %{}) do
    %{
      "queue_id" => id,
      "kind" => "user_message",
      "wake" => true,
      "dedupe_key" => "m#{id}",
      "payload" =>
        Map.merge(
          %{
            "source_message_id" => "m#{id}",
            "content" => "request #{id}",
            "trusted_origin" => origin,
            "delivered_at_ms" => @now_ms - 190_000
          },
          extra
        )
    }
  end

  defp slack, do: %{"provider" => "slack", "source_actor_type" => "provider_user"}
  defp comma_user, do: %{"provider" => "internal", "source_actor_type" => "user"}
  defp comma_agent, do: %{"provider" => "internal", "source_actor_type" => "agent"}

  test "a Router with queued human requests receives one message naming them" do
    session = %{
      input_queue: [
        item(1, slack()),
        item(2, comma_user(), %{"delivered_at_ms" => @now_ms - 5_000})
      ]
    }

    {[message], state} = QueuePressure.prepare(session, @router, %{}, @now)

    assert message["runtime_message_type"] == "queue_pressure"
    assert message["content_kind"] == "model_context"
    assert message["content"] =~ "2 human requests are queued"
    assert message["content"] =~ "- slack request, waiting 3m10s"
    assert message["content"] =~ "- internal request, waiting 5s"
    assert message["content"] =~ "task.create"
    assert state == %{"queued" => [1, 2], "emitted_at_ms" => @now_ms}
  end

  test "the message refreshes when the queued set changes or a minute passes, not every round" do
    session = %{input_queue: [item(1, slack())]}
    {[_], state} = QueuePressure.prepare(session, @router, %{}, @now)
    known = %{"queue_pressure" => state}

    assert {[], ^state} = QueuePressure.prepare(session, @router, known, DateTime.add(@now, 59))
    assert {[_], _} = QueuePressure.prepare(session, @router, known, DateTime.add(@now, 60))

    grown = %{input_queue: [item(1, slack()), item(2, slack())]}
    assert {[message], _} = QueuePressure.prepare(grown, @router, known, DateTime.add(@now, 1))
    assert message["content"] =~ "2 human requests"

    # The queue drained: nothing to say, and the last state stays adopted.
    assert {[], ^state} = QueuePressure.prepare(%{input_queue: []}, @router, known, @now)
  end

  test "runtime notifications, no-wake items and agent sources never count even when unacked" do
    ignored = [
      %{item(1, slack()) | "kind" => "runtime_message"},
      %{item(2, slack()) | "wake" => false},
      item(3, comma_agent())
    ]

    for queued <- ignored do
      session = %{input_queue: [queued], queue_ack_id: 0}
      assert {[], %{}} = QueuePressure.prepare(session, @router, %{}, @now)
    end
  end

  test "acked human requests do not count, but newer human requests do" do
    session = %{input_queue: [item(4, comma_user())], queue_ack_id: 4}
    assert {[], %{}} = QueuePressure.prepare(session, @router, %{}, @now)

    session = %{session | input_queue: [item(4, comma_user()), item(5, slack())]}
    assert {[message], state} = QueuePressure.prepare(session, @router, %{}, @now)
    assert message["content"] =~ "1 human request is queued"
    assert state["queued"] == [5]
  end

  test "atom-keyed false wake is preserved" do
    queued = %{
      queue_id: 1,
      kind: "user_message",
      wake: false,
      payload: %{trusted_origin: %{provider: "slack", source_actor_type: "provider_user"}}
    }

    session = %{input_queue: [queued]}
    assert {[], %{}} = QueuePressure.prepare(session, @router, %{}, @now)

    session = %{session | input_queue: [%{queued | wake: true}]}
    assert {[_], _} = QueuePressure.prepare(session, @router, %{}, @now)
  end

  test "only Routers are told; Workers and unknown roles get nothing" do
    session = %{input_queue: [item(1, slack())]}
    assert {[], %{}} = QueuePressure.prepare(session, %{role: "worker"}, %{}, @now)
    assert {[], %{}} = QueuePressure.prepare(session, %{}, %{}, @now)
  end

  test "an external reply obligation counts as a human source" do
    queued = item(1, comma_agent())
    assert {[], %{}} = QueuePressure.prepare(%{input_queue: [queued]}, @router, %{}, @now)

    item =
      put_in(queued, ["payload", "provider_reply_obligation"], %{"provider" => "telegram"})

    assert {[message], _} = QueuePressure.prepare(%{input_queue: [item]}, @router, %{}, @now)
    assert message["content"] =~ "1 human request is queued"
  end

  describe "on a resident kernel session" do
    setup do
      prev = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

      if Process.whereis(SalixStore.S3.Fake),
        do: SalixStore.S3.Fake.reset(),
        else: start_supervised!(SalixStore.S3.Fake)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:salix_store, :s3_backend, prev),
          else: Application.delete_env(:salix_store, :s3_backend)
      end)

      :ok
    end

    test "queued human input behind an open activation reaches the activation delta and is adopted once" do
      agent_id = SalixAgent.TestSupport.new_agent_id()
      session_id = "ses1_0000000000000000778"

      queue_append = fn id, origin ->
        %{
          "type" => "queue_append",
          "session_id" => session_id,
          "kind" => "user_message",
          "dedupe_key" => id,
          "payload" => %{
            "source_message_id" => id,
            "content" => "request #{id}",
            "trusted_origin" => origin,
            "delivered_at_ms" => System.system_time(:millisecond) - 120_000
          }
        }
      end

      {:ok, state} =
        InternalSessionStore.prepare_commit(agent_id, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          queue_append.("A", slack())
        ])

      {events, _wake?, _hwm} = InternalSession.materialize_pending_input_events(state)
      {:ok, _} = InternalSessionStore.prepare_commit(agent_id, session_id, events)

      {:ok, _} =
        InternalSessionStore.prepare_commit(agent_id, session_id, [
          queue_append.("B", comma_user())
        ])

      {:ok, session} = InternalSessionStore.read(agent_id, session_id)
      assert InternalSession.has_unacked_wakeable_input?(session)

      config = %{role: "router", tool_disclosure: %{"tools" => []}}
      assert {:delta, delta} = ContextProviders.prepare_activation_delta(session, config)
      messages = ContextProviders.model_messages(delta)
      assert [queue] = Enum.filter(messages, &(&1.type == "queue_pressure"))
      assert queue.content =~ "1 human request is queued"
      assert queue.content =~ "- internal request, waiting 2m"

      adopted_state = ContextProviders.adopted_provider_state(delta)
      assert %{"queued" => [_], "emitted_at_ms" => _} = adopted_state["queue_pressure"]

      # The round commits the adopted state on its assistant turn; the next
      # activation reads it back through the kernel and says nothing new
      # while the same request is still the only one waiting.
      {:ok, _} =
        InternalSessionStore.prepare_commit(agent_id, session_id, [
          %{
            "type" => "assistant",
            "session_id" => session_id,
            "message_id" => InternalSession.next_message_id(session),
            "content" => "working",
            "do_not_send_to_llm" => %{"context_provider_states" => adopted_state}
          }
        ])

      {:ok, adopted} = InternalSessionStore.read(agent_id, session_id)

      assert ContextProviders.provider_states(adopted)["queue_pressure"] ==
               adopted_state["queue_pressure"]

      assert :none = ContextProviders.prepare_activation_delta(adopted, config)
    end
  end
end
