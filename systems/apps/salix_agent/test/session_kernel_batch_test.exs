defmodule SalixAgent.SessionKernelBatchTest do
  use ExUnit.Case, async: true
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State

  defp state do
    %State{
      agent_id: "agent",
      session_id: "session",
      status: :active,
      activity_status: :thinking,
      storage_format: 3,
      async_tool_calls: %{"call" => %{"status" => "running", "tool_name" => "shell"}}
    }
  end

  defp events do
    [
      %{"type" => "session_system_prompt", "prompt" => "system"},
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 1,
        "role" => "user",
        "content" => "hello",
        "source_message_id" => "src-1",
        "created_at" => 10
      },
      %{
        "type" => "async_tool_call_completed",
        "tool_call_id" => "call",
        "result" => %{"content" => "done"}
      },
      %{"type" => "status", "status" => "idle", "created_at" => 12}
    ]
  end

  test "a batch over a resident state equals applying each event in turn" do
    sequential =
      Enum.reduce(events(), InternalSession.open(state()), &InternalSession.apply_event(&2, &1))

    batched = InternalSession.apply_events(InternalSession.open(state()), events())

    assert InternalSession.export(batched) === InternalSession.export(sequential)
    assert InternalSession.get(batched, :system_prompt) == "system"
    assert InternalSession.status(batched) == :idle
    assert InternalSession.get(batched, :async_result_refs) == %{"call" => 2}
    assert InternalSession.total_message_count(batched) == 1
  end

  test "an empty batch returns the same handle" do
    original = InternalSession.open(state())
    assert InternalSession.apply_events(original, []) === original
  end

  test "handles are immutable: an earlier handle is unaffected by later batches" do
    first = InternalSession.apply_events(InternalSession.open(state()), Enum.take(events(), 1))
    second = InternalSession.apply_events(first, Enum.drop(events(), 1))

    assert InternalSession.status(first) == :active
    assert InternalSession.status(second) == :idle

    assert InternalSession.export(second) ===
             InternalSession.export(
               InternalSession.apply_events(InternalSession.open(state()), events())
             )
  end

  test "a failing event in a batch raises and leaves the earlier handle untouched" do
    first = InternalSession.apply_events(InternalSession.open(state()), Enum.take(events(), 1))

    assert_raise ArgumentError, fn ->
      InternalSession.apply_events(first, [%{"type" => "status", "status" => 42}])
    end

    assert InternalSession.get(first, :system_prompt) == "system"
  end
end
