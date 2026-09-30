defmodule SalixAgent.SettleReasonReviewTest do
  # Issue #2070, M4: owner review of the reasons that settle a turn without a
  # visible reply. Each test drives the kernel directly.
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSession, ProviderReplyObligation}

  @sid "ses1_0000000000000000913"
  @source "im_provider:slack:slack-1:C0AQ0C0KVMH:1787628850.000001"

  setup do
    previous = Application.get_env(:salix_agent, :llm_activation_retry_base_ms)
    # A long base delay keeps the retry deadline in the future.
    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 600_000)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_agent, :llm_activation_retry_base_ms),
        else: Application.put_env(:salix_agent, :llm_activation_retry_base_ms, previous)
    end)
  end

  # `llmFailureAck` (Query/Round.lean) keeps a source for retries or one
  # notification. Before the fix, its no-destination branch ACKed on the first
  # retryable failure. That ACK cleared the Slack reminder and the active
  # source while the retry still ran later. Now only a final failure ACKs.
  test "a retryable model failure without a destination retains the source through retries" do
    session =
      InternalSession.new("agent-settle-review", @sid)
      |> InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "source_message_id" => @source,
          "content" => "Slack channel=C0AQ0C0KVMH thread_ts=1787626579.346779\nplease answer",
          # A source whose destination cannot be resolved.
          "trusted_origin" => %{
            "provider" => "slack",
            "source_actor_type" => "provider_user",
            "source_message_id" => @source,
            "provider_context" => %{}
          },
          "provider_reply_obligation" => %{
            "provider" => "slack",
            "connect_id" => "slack-1",
            "channel" => "C0AQ0C0KVMH",
            "thread_ts" => "1787626579.346779"
          }
        }
      ])

    assert ProviderReplyObligation.pending_count(session) == 1
    assert InternalSession.query(session, :guard_disposition_binding, 2) == nil

    {:error, meta} =
      SalixAgent.LLM.Error.http("anthropic", 529, ~s({"error":{"message":"overloaded"}}))

    facts = %{"id_snapshot" => 2, "guard" => :clean, "vphase" => :clean, "nonce" => 1}
    {machine, _} = step(session, nil, {:model_response, {:error, meta}, facts})
    {_, [_draft, {:commit, events, _, _}, :continue]} = step(session, machine, :continue)
    failed = InternalSession.apply_events(session, events)

    # The failure is retryable: activation schedules another model request.
    assert {_, [{:set_timer, :retry, _at}, {:stop, :wait}]} =
             step(failed, nil, {:activate, %{"ceiling_ms" => 1_800_000}})

    # Contract: the source and its reminder survive until the retries end.
    refute Enum.any?(events, &(&1["type"] == "ack")),
           "the first retryable failure ACKed the source: #{inspect(events)}"

    assert InternalSession.get(failed, :last_ack_message_id) == 0
    assert ProviderReplyObligation.pending_count(failed) == 1
  end

  # `TerminalReply.admit` binds the outcome of the lifecycle, not of the
  # model's `end_turn` decision: a channel welcome is `done` and a Telegram
  # interactive card is `blocked`. Both admissions are reachable with the
  # opposite decision outcome.
  test "channel welcomes and Telegram cards override the end_turn outcome" do
    welcome = %{
      "name" => "im_api.slack.post_channel_message",
      "args" => %{"connect_id" => "slack-1", "channel" => "C_JOIN", "text" => "Welcome"},
      "id" => "welcome",
      "reply_intent" => nil
    }

    onboarding = %{
      "kind" => "channel_onboarding",
      "connect_id" => "slack-1",
      "chat_id" => "C_JOIN",
      "eligible" => true
    }

    assert {:ok, _args, %{"outcome" => "done"}} =
             SalixVerifiedKernel.AgentLoop.terminal_reply_admission(
               welcome,
               onboarding,
               flags("blocked")
             )

    question = %{
      "name" => "question.request",
      "args" => %{"question" => "Which option?"},
      "id" => "question",
      "reply_intent" => nil
    }

    telegram = %{
      "kind" => "telegram",
      "connect_id" => "telegram-1",
      "chat_id" => "42",
      "eligible" => true
    }

    assert {:ok, _args, %{"outcome" => "blocked"}} =
             SalixVerifiedKernel.AgentLoop.terminal_reply_admission(
               question,
               telegram,
               flags("done")
             )
  end

  defp flags(outcome),
    do: %{
      "llm_tool_envelope" => true,
      "runtime_failure_delivery" => false,
      "terminal_decision_outcome" => outcome
    }

  defp step(session, machine, event),
    do: InternalSession.query(session, :loop_step, {machine, event})
end
