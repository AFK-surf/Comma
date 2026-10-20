defmodule SalixAgent.QueuePressureTest do
  use SystemsClock.Case, async: false

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
    assert state == %{"queued" => [1, 2], "emitted_at_ms" => @now_ms}
  end

  describe "on a resident kernel session" do
    setup do
      prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
      SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

      if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
        do: SalixStore.S3.Fake.reset(),
        else: start_supervised!(SalixStore.S3.Fake)

      on_exit(fn ->
        if prev,
          do: SystemsRuntime.put_env(:salix_store, :s3_backend, prev),
          else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
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
            "delivered_at_ms" => SystemsClock.system_time(:millisecond) - 120_000
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

      # The prose tail leaves the turn open, so only that notice is new.
      assert {:delta, delta} = ContextProviders.prepare_activation_delta(adopted, config)
      assert [%{type: "unsettled_reply"}] = ContextProviders.model_messages(delta)
    end
  end
end
