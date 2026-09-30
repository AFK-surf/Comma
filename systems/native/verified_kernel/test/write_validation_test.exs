defmodule SalixVerifiedKernel.WriteValidationTest do
  # Every Session write passes `validate_events`. The first invalid event
  # names the reason, and the write applies nothing.
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  defp validate(events),
    do:
      Session.query(
        Session.open(%{__struct__: SalixAgent.InternalSession.State}),
        :validate_events,
        events
      )

  test "a valid batch passes, and the first invalid event names its reason" do
    append = %{"type" => "queue_append", "kind" => "user_message", "source_message_id" => "m1"}
    assert :ok = validate([append, %{"type" => "status", "status" => :idle}])

    assert {:error, :runtime_message_must_come_from_queue} =
             validate([append, %{type: "runtime_message"}, %{"type" => "delivery"}])

    assert {:error, :invalid_events} = validate(:not_a_list)
    assert {:error, :invalid_event} = validate(["not a map"])
  end

  test "queue input carries an identity, and a summary does not wake" do
    assert {:error, :user_message_identity_required} =
             validate([
               %{
                 "type" => "queue_append",
                 "kind" => "user_message",
                 "payload" => %{"source_message_id" => " "}
               }
             ])

    assert {:error, :summary_message_must_be_no_wake} =
             validate([
               %{
                 "type" => "queue_append",
                 "kind" => "user_message",
                 "dedupe_key" => "d",
                 "payload" => %{role: "summary"}
               }
             ])

    assert {:error, {:invalid_queue_kind, "other"}} =
             validate([%{"type" => "queue_append", "kind" => "other"}])
  end

  test "a stored tool result must match its content" do
    json = ~s({"ok":true})

    stored = %{
      "type" => "tool_result_stored",
      "session_id" => "ses1_0000000000000000001",
      "result_ref" => "trf1_0000000000000000001",
      "tool_call_id" => "t",
      "tool_name" => "x",
      "result_json" => json,
      "result_sha256" => :crypto.hash(:sha256, json) |> Base.encode16(case: :lower),
      "result_bytes" => byte_size(json),
      "result_chars" => String.length(json),
      "status" => "ok",
      "is_error" => false,
      "stored_at_ms" => 0
    }

    assert :ok = validate([stored])
    assert {:error, :invalid_tool_result_bytes} = validate([%{stored | "result_bytes" => 1}])

    assert {:error, :invalid_tool_result_sha256} =
             validate([%{stored | "result_sha256" => String.duplicate("0", 64)}])
  end

  test "removed event types are refused" do
    assert {:error, :redact_session_event_removed} = validate([%{"type" => "redact"}])

    assert {:error, :standalone_context_provider_event_removed} =
             validate([%{"type" => "runtime_context_version"}])
  end
end
