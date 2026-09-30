defmodule SalixVerifiedKernel.AgentLoopTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.AgentLoop, as: Kernel

  test "activation admission pauses for any pending dependency" do
    for llm <- [false, true], compaction <- [false, true], backoff <- [false, true] do
      assert Kernel.activation(llm, compaction, backoff) ==
               if(llm or compaction or backoff, do: :pause, else: :process)
    end
  end

  test "actual BEAM references retain exact identity and stale events cannot consume the owner" do
    token = make_ref()
    copy = token |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    stale = make_ref()

    for {event, command} <- [result: :accept_result, timeout: :accept_timeout, down: :accept_down] do
      assert Kernel.dependency_step({:running, token}, {copy, event}) ==
               {{:retained, token}, command}

      assert Kernel.dependency_step({:running, token}, {stale, event}) ==
               {{:running, token}, :ignore}

      assert Kernel.dependency_step({:retained, token}, {copy, event}) ==
               {{:retained, token}, :ignore}

      assert Kernel.dependency_step(:retired, {copy, event}) == {:retired, :ignore}
    end

    assert Kernel.dependency_step({:running, token}, {token, :irrelevant}) ==
             {{:running, token}, :ignore}

    assert {:error, :wire, _} =
             SalixVerifiedKernel.invoke(
               :agent_loop,
               :dependency_step,
               {{:running, token}, {token, :result}}
             )
  end

  test "retained retries win, late unowned retries drop, and exhaustion is bounded" do
    for attempts <- [0, 1, 2, 100, Integer.pow(2, 80)], budget <- [0, 1, 2, 100] do
      assert Kernel.retry_admission(true, attempts) == :retained
      assert Kernel.retry_admission(:invalid, attempts) == :ignore

      assert Kernel.retry_admission(false, attempts) ==
               if(attempts == 0, do: :initial, else: :ignore)

      assert Kernel.retry_failure(attempts, budget) ==
               if(attempts + 1 <= budget, do: :retry, else: :exhausted)
    end
  end

  test "both terminal identity components must match, including missing identity" do
    for os <- [nil, "", "session"],
        oc <- [nil, "", "call"],
        s <- [nil, "", "session"],
        c <- [nil, "", "call"] do
      assert Kernel.terminal_owner(os, oc, s, c) == (os === s and oc === c)
    end
  end

  test "invalid explicit schema fails closed" do
    for {operation, payload} <- [
          {:activation, {false, nil, false}},
          {:retry_failure, {-1, 3}},
          {:terminal_owner, {123, nil, 123, nil}}
        ] do
      assert {:error, :agent_loop, _} =
               SalixVerifiedKernel.invoke(:agent_loop, operation, payload)
    end
  end

  test "a pending sibling holds the completion wake and speculation; direct polls never activate" do
    notice = %{"type" => "queue_append", "kind" => "runtime_message", "wake" => true}
    completion = %{"type" => "async_tool_call_completed", "tool_call_id" => "a"}
    events = [completion, notice]

    assert Kernel.completion_wake(nil, [], events) == {events, true, true}
    assert Kernel.completion_wake(nil, ["direct_poll"], events) == {events, true, true}

    assert Kernel.completion_wake(nil, ["direct_poll", nil], events) ==
             {[completion, %{notice | "wake" => false}], true, false}

    assert Kernel.completion_wake("direct_poll", [], events) == {events, false, false}
  end
end
