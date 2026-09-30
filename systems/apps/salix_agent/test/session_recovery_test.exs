defmodule SalixAgent.SessionRecoveryTest do
  use ExUnit.Case, async: true
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.Recovery

  defp session(fields \\ []) do
    InternalSession.new("agent", "session")
    |> InternalSession.export()
    |> Map.merge(Map.new(fields))
    |> InternalSession.open()
  end

  defp retry(tag), do: Recovery.round_failure(nil, {tag, :unavailable}).checkpoint

  test "a materialized input retains recovery until acknowledgement, not queue drain" do
    checkpoint = retry(:visible_reply_authorization_retry)
    state = session(messages: [%{id: 1, role: "user", content: "reply"}], queue_ack_id: 1)

    assert %Recovery{action: :continue, checkpoint: ^checkpoint} =
             Recovery.observe(state, checkpoint)

    assert %Recovery{action: :continue, checkpoint: nil} = Recovery.observe(session(), checkpoint)
  end

  test "legacy settlement survives a lost intent write, then resumes outstanding input" do
    checkpoint = retry(:visible_reply_append_retry)
    active = session(status: :active, messages: [%{id: 1, role: "user", content: "reply"}])

    assert %Recovery{action: :continue, checkpoint: ^checkpoint} =
             Recovery.observe(active, checkpoint)

    repaired = session(messages: [%{id: 1, role: "user", content: "reply"}])
    assert %Recovery{action: :continue, checkpoint: next} = Recovery.observe(repaired, checkpoint)
    assert next == retry(:visible_reply_authorization_retry)
    assert %Recovery{action: :settled} = Recovery.observe(session(), checkpoint)
  end

  test "a durable intent takes precedence over an earlier authorization failure" do
    state = session(visible_reply_intent: %{"idempotency_key" => "reply", "scope" => %{}})

    assert %Recovery{action: :continue, checkpoint: checkpoint} =
             Recovery.observe(state, retry(:visible_reply_authorization_retry))

    assert checkpoint == retry(:visible_reply_append_retry)
  end

  test "a failed read preserves known recovery without inventing work for an unknown session" do
    checkpoint = retry(:visible_reply_append_retry)
    reason = {:visible_reply_pre_llm_error, :activation_read, {:http, 503}}

    assert %Recovery{
             action: :retry,
             checkpoint: ^checkpoint,
             stage: :activation_read,
             reason: {:http, 503}
           } =
             Recovery.round_failure(checkpoint, reason)

    assert %Recovery{action: :error, checkpoint: nil} = Recovery.round_failure(nil, reason)
  end

  test "a failed provider readback retains its exact presentation obligation" do
    assert %Recovery{action: :retry} = Recovery.handoff(%{visible_reply_scope: %{}}, :unavailable)
    assert %Recovery{action: :continue, checkpoint: nil} = Recovery.handoff(%{}, :unavailable)
  end
end
