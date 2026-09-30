defmodule SalixAgent.SessionKernelSchemaTest do
  use ExUnit.Case, async: true
  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session

  defmodule CustomData do
    defstruct [:value]

    def fetch(_, key) do
      send(self(), {:custom_protocol_called, key})
      raise "custom Access must not run"
    end
  end

  @events ~w(async_tool_call_progress async_tool_call_started async_tool_call_completed
    async_tool_call_failed async_tool_call_cancelled status activity_status session_created
    session_system_prompt session_update compaction_failure compaction_recovery queue_append
    queue_ack queue_consume visible_reply_repair visible_reply_intent visible_reply_committed
    visible_reply_aborted visible_reply_activation_started visible_reply_activation_finished
    provider_reply_obligation_resolved provider_card_obligation_added ack wait_set wait_clear
    tool_result assistant session_log_message transcript_seed runtime_message delivery
    session_event session_microcompact compaction provider_compaction session_compact_result
    archive_advance tool_result_stored)

  test "every Session operation rejects unknown structs before transitions or observations" do
    for kind <- @events do
      event = %{"type" => kind, "unused" => %CustomData{value: "data"}}

      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Session.step(%State{}, event)
      end

      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Session.step(%State{summary: %CustomData{}}, %{"type" => kind})
      end
    end

    refute_received {:custom_protocol_called, _}
  end

  test "runtime identities are rejected even in unused values and map keys" do
    for identity <- [self(), make_ref(), fn -> :value end, &Enum.map/2],
        payload <- [identity, %{identity => "value"}, {"nested", [identity]}] do
      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Session.step(%State{}, %{"type" => "unknown", "unused" => payload})
      end
    end
  end

  test "schema admission precedes the session filter and custom field access" do
    custom = Map.merge(%CustomData{}, %{"type" => "session_update", "session_id" => "other"})

    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Session.step(%State{session_id: "s"}, custom)
    end

    refute_received {:custom_protocol_called, _}
  end

  test "State and MapSet have explicit data representations and other structs are rejected" do
    state = %State{status: :active, activity_status: :thinking}
    assert {:done, ^state} = Session.step(state, %{"type" => "unknown"})

    for value <- [
          %URI{},
          %State{},
          %{__struct__: MapSet, map: %{1 => true}},
          %{__struct__: MapSet, map: %{}, extra: 1}
        ] do
      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Session.step(%State{summary: value}, %{})
      end
    end
  end

  test "ordinary pure data retains exact keys without protocol dispatch" do
    for id <- [nil, [], 7, 1.25, %{"identity" => true}, {"tuple", 1}, <<1::1>>] do
      state = %State{
        status: :active,
        activity_status: :thinking,
        async_tool_calls: %{id => %{"status" => "running"}}
      }

      event = %{"type" => "async_tool_call_progress", "tool_call_id" => id, "updated_at" => 2}
      assert {:done, next} = Session.step(state, event)
      assert next.async_tool_calls[id]["updated_at"] == 2
    end
  end

  test "configuration observations cannot import custom data into the kernel" do
    assert {:observe_config, :salix_agent, _, _, token} = Session.step(%State{}, %{})

    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Session.step(token, {:observed_config, %CustomData{}})
    end
  end
end
