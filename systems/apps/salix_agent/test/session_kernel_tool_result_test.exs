defmodule SalixAgent.SessionKernelToolResultTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  defp event(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "tool_result",
        "message_id" => 4,
        "tool_call_id" => "call",
        "content" => "done",
        "created_at" => "now"
      },
      extra
    )
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp check(state, event) do
    outcome(fn ->
      {:done, next} = Driver.step(state, event)
      next
    end)
  end

  test "tool result stamps appends accounts and bumps all owning fields" do
    initial = %State{
      messages: [%{id: 1, content: "old"}],
      last_seq: 8,
      live_context_bytes: 30,
      next_message_id: 2,
      last_activity_at: "before",
      input_queue: :unvisited,
      async_results: [:untouched]
    }

    assert {:returned, next} = check(initial, event())

    assert List.last(next.messages) === %{
             id: 4,
             role: "tool",
             tool_call_id: "call",
             content: "done",
             created_at: "now",
             seq: 9
           }

    assert next.last_seq === 9
    assert next.live_context_bytes === 34
    assert next.next_message_id === 5
    assert next.last_activity_at === "now"
    written = [:messages, :last_seq, :live_context_bytes, :next_message_id, :last_activity_at]
    assert Map.drop(next, written) === Map.drop(initial, written)
  end

  test "new nonbinary content retains full JSON accounting beyond the Lean profile" do
    for content <- [false, 17, %{"result" => [1, 2]}, ["a", "b"]] do
      assert {:returned, next} =
               check(
                 %State{live_context_bytes: 0},
                 event(%{"content" => content})
               )

      assert next.live_context_bytes === byte_size(Jason.encode!(content))
    end
  end

  test "content JSON error uses bounded Inspect fallback" do
    content = {:opaque, :data}
    assert {:error, _} = Jason.encode(content)

    assert {:returned, next} =
             check(
               %State{live_context_bytes: 0},
               event(%{"content" => content})
             )

    assert next.live_context_bytes ===
             byte_size(inspect(content, limit: 20, printable_limit: 4096))
  end

  test "tool-call JSON error contributes zero rather than Inspect bytes" do
    calls = [{:opaque, :data}]
    assert {:error, _} = Jason.encode(calls)

    initial = %State{
      live_context_bytes: nil,
      summary: nil,
      provider_compaction: nil,
      compacted_through: 0,
      messages: [%{id: 1, content: nil, tool_calls: calls}]
    }

    assert {:returned, next} = check(initial, event())
    assert next.live_context_bytes === 4
  end

  test "uncached summary retains String.Chars conversion and false omission" do
    for {summary, bytes} <- [{123, 3}, {false, 0}, {nil, 0}, {"é", 2}] do
      assert {:returned, next} =
               check(
                 %State{live_context_bytes: nil, summary: summary},
                 event()
               )

      assert next.live_context_bytes === bytes + 4
    end
  end

  test "only nonnegative integer message IDs trigger HWM update" do
    for id <- [nil, false, -1, 4.0, "4"] do
      initial = %State{
        status: :active,
        activity_status: :thinking,
        live_context_bytes: 0,
        next_message_id: :untouched
      }

      assert {:returned, next} =
               check(
                 initial,
                 event(%{"message_id" => id})
               )

      assert next.next_message_id === :untouched

      # The idle outer classifier still reads the malformed counter.
      assert {:raised, :error, %ArithmeticError{}} =
               check(%State{initial | status: :idle}, event(%{"message_id" => id}))
    end

    for previous <- [nil, false, 12] do
      assert {:returned, next} =
               check(
                 %State{live_context_bytes: 0, next_message_id: previous},
                 event(%{"message_id" => 0})
               )

      assert next.next_message_id === max(previous || 1, 1)
    end
  end

  test "sync result fingerprints count equal business outcomes and ignore placeholders" do
    ev =
      event(%{
        "tool_name" => "query",
        "input" => %{"x" => 1},
        "status" => "error",
        "error_class" => "failure",
        "error_message" => "same",
        "output" => "done"
      })

    assert {:returned, first} = check(%State{}, ev)
    assert first.repeated_tool_result_streak["count"] == 1
    assert {:returned, second} = check(first, Map.put(ev, "status", "failed"))
    assert second.repeated_tool_result_streak["count"] == 2

    for ignored <- ["running", "async_running"] do
      assert {:returned, next} = check(second, Map.put(ev, "status", ignored))
      assert next.repeated_tool_result_streak == second.repeated_tool_result_streak
    end

    assert {:returned, changed} = check(second, Map.put(ev, "output", "different"))
    assert changed.repeated_tool_result_streak["count"] == 1
  end
end
