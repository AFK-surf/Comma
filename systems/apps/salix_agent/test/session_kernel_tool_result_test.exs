defmodule SalixAgent.SessionKernelToolResultTest do
  use ExUnit.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  @traces ~w(execution_timing tool_name status duration_ms input output error_class
    error_message guidance_reason diagnostic_visibility public_summary repair_outcome
    visible_reply_origin turn_id round_id request_id trace_id started_at completed_at)

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

  test "every trace field survives and only nil fields are removed" do
    traces = Map.new(@traces, &{&1, false})

    assert {:returned, next} =
             check(
               %State{live_context_bytes: 0},
               event(Map.merge(traces, %{"created_at" => nil, "tool_call_id" => nil}))
             )

    message = hd(next.messages)
    for name <- @traces, do: assert(Map.fetch!(message, String.to_existing_atom(name)) === false)
    refute Map.has_key?(message, :created_at)
    refute Map.has_key?(message, :tool_call_id)
  end

  test "IFC copies nonempty maps and ignores nil false scalar and empty map" do
    for ifc <- [nil, false, "not-a-map", %{}, %{"audience" => ["a"]}] do
      assert {:returned, next} = check(%State{live_context_bytes: 0}, event(%{"ifc" => ifc}))
      message = hd(next.messages)

      if is_map(ifc) and map_size(ifc) > 0 do
        assert message.ifc === ifc
      else
        refute Map.has_key?(message, :ifc)
      end
    end
  end

  test "cached integer accounting is lazy and accepts negative native cache" do
    initial = %State{
      live_context_bytes: -7,
      summary: %{unsupported_summary: :unvisited},
      provider_compaction: :unused,
      compacted_through: :unused,
      messages: [%{id: :unused, content: :unused}]
    }

    assert {:returned, next} = check(initial, event())
    assert next.live_context_bytes === -3
  end

  test "uncached accounting includes summary provider content calls attachments and metadata" do
    calls = [%{"id" => "call", "name" => "tool", "args" => %{}}]

    old = %{
      id: 2,
      content: %{"answer" => 1},
      tool_calls: calls,
      trusted_attachment_refs: ["attachment"],
      provider_meta: %{"usage" => 2}
    }

    initial = %State{
      live_context_bytes: nil,
      summary: "sum",
      provider_compaction: %{"items" => [%{"chunk" => "provider"}]},
      compacted_through: 1,
      messages: [%{id: 1, content: "excluded"}, old]
    }

    assert {:returned, next} = check(initial, event())
    encoded = fn value -> byte_size(Jason.encode!(value)) end

    expected =
      3 + encoded.(initial.provider_compaction["items"]) +
        encoded.(old.content) + encoded.(calls) + encoded.(old.trusted_attachment_refs) +
        encoded.(old.provider_meta) + 4

    assert next.live_context_bytes === expected
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

  test "provider compaction binary key presence masks atom key including nil" do
    initial = %State{
      live_context_bytes: nil,
      provider_compaction: %{"items" => nil, :items => "not-counted"}
    }

    assert {:returned, next} = check(initial, event())
    assert next.live_context_bytes === 4
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

  test "accounting aliases visit binary keys only after nil or false atom values" do
    for omitted <- [nil, false] do
      old = %{
        "trusted_attachment_refs" => "attachment",
        "provider_meta" => "metadata",
        id: 1,
        content: nil,
        tool_calls: nil,
        trusted_attachment_refs: omitted,
        provider_meta: omitted
      }

      state = %State{live_context_bytes: nil, messages: [old]}
      assert {:returned, next} = check(state, event())
      assert next.live_context_bytes === 10 + 8 + 4
    end

    old = %{
      "trusted_attachment_refs" => {:raise, "unvisited attachment alias"},
      "provider_meta" => {:raise, "unvisited provider alias"},
      id: 1,
      content: nil,
      tool_calls: nil,
      trusted_attachment_refs: "atom attachment",
      provider_meta: "atom metadata"
    }

    assert {:returned, next} = check(%State{live_context_bytes: nil, messages: [old]}, event())
    assert next.live_context_bytes === 15 + 13 + 4
  end

  test "messages append has no nil or false fallback" do
    for messages <- [nil, false, [:head | :improper]] do
      result = check(%State{messages: messages, live_context_bytes: 0}, event())
      assert match?({:raised, _, _}, result)
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
