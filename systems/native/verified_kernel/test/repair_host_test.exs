defmodule SalixVerifiedKernel.RepairHostTest do
  # Crash repair and activation host data: the kernel classifies capability
  # requests, encodes repair events, settles a runtime failure reply, and plans
  # an activation. A host answers only the reads.
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  @sid "ses1_0000000000000000001"

  defp session(patch \\ %{}) do
    Session.new("agent", @sid)
    |> Session.export()
    |> Map.merge(patch)
    |> Session.open()
  end

  defp observe(record, reply),
    do: Session.query(session(), :capability_observation, record, &read(&1, reply))

  defp read(:clock, _reply), do: System.system_time(:millisecond)
  defp read({:reconcile_capability, "c1", _result}, reply), do: reply

  test "a capability request is absent, pending, retried, or exhausted" do
    record = %{
      "tool_call_id" => "c1",
      "tool_name" => "oauth.request_authorization",
      "status" => "running",
      "completion_mode" => "external_callback"
    }

    assert {%{"state" => "absent", "events" => [sync]}, nil} =
             observe(record, {:ok, :not_found})

    assert %{"type" => "capability_request_sync", "tool_call_id" => "c1", "settled" => true} =
             sync

    assert {%{"state" => "pending", "record" => pending}, nil} =
             observe(record, {:ok, %{"request_id" => "r1", "expires_at" => 10}})

    assert %{"capability_request_id" => "r1", "capability_deadline_ms" => 10_000} = pending

    now = System.system_time(:millisecond)

    assert {%{"state" => "unavailable", "record" => retry}, nil} =
             observe(record, {:error, "down"})

    assert retry["capability_retry_at_ms"] >= now + 5_000

    exhausted = Map.put(record, "capability_error_since_ms", now - 30_000)

    assert {%{
              "state" => "unknown",
              "result" => %{"error_class" => "capability_request_unavailable"}
            }, "down"} = observe(exhausted, {:error, "down"})
  end

  test "repair events for a missing result and a pending external callback" do
    missing = %{id: "c1", name: "fs.read", content: "x", output: "x", error: true}

    assert %{"tool_call_id" => "c1", "message_id" => 7, "output" => nil, "error" => true} =
             Session.query(session(), :restart_encode, {"encode_missing", {7, missing}})

    call = %{id: "c2", name: "oauth.request_authorization", args: %{"z" => 1, "a" => 2}}

    assert [started, result] =
             Session.query(
               session(),
               :restart_encode,
               {"encode_external", {call, 8, %{"capability_request_id" => "r2", "other" => 1}}}
             )

    assert %{"type" => "async_tool_call_started", "capability_request_id" => "r2"} = started
    refute Map.has_key?(started, "other")
    assert started["input"] == ~s({"a":2,"z":1})

    assert %{"status" => "async_running", "tool_call_id" => "c2"} =
             JSON.decode!(result["content"])
  end

  test "guard recovery reads nothing without an open runtime failure reply" do
    read = fn request -> flunk("unexpected read #{inspect(request)}") end
    assert [] = Session.query(session(), :guard_recovery, [], read)

    reply = %{"tool_call_id" => "c1", "notification_outcome" => "delivered"}
    assert [] = Session.query(session(%{runtime_failure_reply: reply}), :guard_recovery, [], read)

    live = %{"tool_call_id" => "c1"}

    assert [] =
             Session.query(session(%{runtime_failure_reply: live}), :guard_recovery, ["c1"], read)
  end

  test "an activation compacts first when the observed prompt fills the window" do
    messages = [
      %{id: 1, seq: 1, role: "user", content: "hi"},
      %{id: 2, seq: 2, role: "assistant", content: "ok", model: "claude-x", input_tokens: 190_000}
    ]

    state = session(%{status: :idle, next_message_id: 3, last_seq: 2, messages: messages})

    assert %{"compact" => true, "args" => {[], nil, "prompt", true}, "sequential" => false} =
             Session.query(state, :activation_plan, {"prompt", %{"context_tokens" => 200_000}})

    assert %{"compact" => false} =
             Session.query(state, :activation_plan, {"prompt", %{"context_tokens" => 1_000_000}})
  end
end
