defmodule SalixAgent.LlmMockTest do
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.Mock

  setup do
    start_supervised!(Mock)
    Mock.script([])
    :ok
  end

  test "legacy final fixtures normalize to explicit done without losing metadata" do
    trace_meta = %{"model" => "test-model", "usage" => %{"total_tokens" => 7}}
    provider_meta = %{"responses_items" => [%{"id" => "msg_1", "type" => "message"}]}

    Mock.script([
      {:final, "plain"},
      {:final, "trace only", trace_meta},
      {:final, "provider and trace", provider_meta, trace_meta},
      {:reasoning, "private reasoning", {:final, "nested", provider_meta, trace_meta}}
    ])

    assert {:assistant, "plain", [plain_call]} = Mock.complete([], [])
    assert plain_call.name == "end_turn"
    assert plain_call.args == %{"outcome" => "done"}
    assert is_binary(plain_call.id) and plain_call.id != ""

    assert {:assistant, "trace only", [_call], nil, ^trace_meta} = Mock.complete([], [])

    assert {:assistant, "provider and trace", [_call], ^provider_meta, ^trace_meta} =
             Mock.complete([], [])

    assert {:assistant, "nested", [_call], ^provider_meta, ^trace_meta} = Mock.complete([], [])
  end

  test "raw assistant fixtures remain missing-decision responses" do
    response = {:assistant, "I will continue next", []}
    Mock.script([response])

    assert Mock.complete([], []) == response
  end

  test "raw fixture escape preserves an LLM seam response" do
    Mock.script([{:raw, {:final, "provider prose"}}])
    assert Mock.complete([], []) == {:final, "provider prose"}
  end

  test "an exhausted script defaults to explicit done with unique call ids" do
    Mock.script([])

    assert {:assistant, "done", [%{id: first_id, name: "end_turn"}]} = Mock.complete([], [])
    assert {:assistant, "done", [%{id: second_id, name: "end_turn"}]} = Mock.complete([], [])
    refute first_id == second_id
  end
end
