defmodule SalixAgent.SessionKernelStartTest do
  use ExUnit.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.InternalSession.State

  defp state(calls \\ %{}) do
    %State{
      agent_id: "agent-start",
      session_id: "session-start",
      status: :active,
      activity_status: :thinking,
      async_tool_calls: calls,
      async_results: [],
      async_result_refs: %{},
      last_seq: 10,
      messages: [%{"measurements" => [1.25, -0.0]}],
      billing_context: %{"nested" => [%{"ratio" => 0.125}]},
      storage_revision: "revision-start"
    }
  end

  defp event(id, fields \\ %{}) do
    Map.merge(
      %{
        "type" => "async_tool_call_started",
        "session_id" => "session-start",
        "tool_call_id" => id
      },
      fields
    )
  end

  defp assert_start(before, ev, expected) do
    assert Driver.step(before, ev) === {:done, expected}
    assert SessionData.apply_event(before, ev) === expected
  end

  defp assert_lookup(before, id, expected) do
    assert SessionData.query(before, :lookup_async_call, id) === expected
  end

  test "a live nonterminal record shadows terminal pointers and result records" do
    live = %{"status" => "running"}
    terminal = %{"status" => "completed", "seq" => 4, "tool_call_id" => "selected"}

    before = %State{
      state(%{"selected" => live})
      | async_result_refs: %{"selected" => 4},
        async_results: [terminal]
    }

    assert_lookup(before, "selected", {:ok, live})

    expected = %State{
      before
      | async_tool_calls: %{"selected" => %{"tool_call_id" => "selected", "status" => "running"}}
    }

    assert_start(before, event("selected"), expected)
  end

  test "legacy terminal records and truthy archived pointers block late starts" do
    for status <- ["completed", "failed", "cancelled"] do
      before = state(%{"selected" => %{"status" => status}})
      assert_start(before, event("selected"), before)
    end

    for pointer <- [4, 0, -1, 1.25, [], "opaque"] do
      before = %State{state() | async_result_refs: %{"selected" => pointer}}
      assert_lookup(before, "selected", {:archived, pointer})
      assert_start(before, event("selected"), before)
    end
  end

  test "a pointer-selected nonterminal result shadows fallback terminal matches" do
    pointed = %{"status" => "running", "seq" => 4, "result_ref" => "another"}
    fallback = %{"status" => "completed", "result_ref" => "selected"}

    before = %State{
      state()
      | async_result_refs: %{"selected" => 4},
        async_results: [fallback, pointed]
    }

    assert_lookup(before, "selected", {:ok, pointed})

    expected = %State{
      before
      | async_tool_calls: %{"selected" => %{"tool_call_id" => "selected", "status" => "running"}}
    }

    assert_start(before, event("selected"), expected)

    numeric_first = %{"seq" => 4.0, "status" => "running", "label" => "first"}

    assert_lookup(
      %State{before | async_results: [numeric_first, pointed]},
      "selected",
      {:ok, numeric_first}
    )
  end

  test "result references precede call identities and each search keeps its first match" do
    by_id = %{"tool_call_id" => "selected", "label" => "id"}
    first = %{"result_ref" => "selected", "label" => "first"}
    second = %{"result_ref" => "selected", "label" => "second"}
    before = %State{state() | async_results: [by_id, first, second]}
    assert_lookup(before, "selected", {:ok, first})

    assert_lookup(
      %State{before | async_results: [by_id, %{"tool_call_id" => "selected"}]},
      "selected",
      {:ok, by_id}
    )

    for fallback <- [nil, false] do
      assert_lookup(
        %State{
          before
          | async_tool_calls: %{"selected" => fallback},
            async_result_refs: %{"selected" => fallback}
        },
        "selected",
        {:ok, first}
      )

      empty = %State{state(fallback) | async_results: fallback, async_result_refs: fallback}
      assert_lookup(empty, "selected", :not_found)

      expected = %State{
        empty
        | async_tool_calls: %{
            "selected" => %{"tool_call_id" => "selected", "status" => "running"}
          }
      }

      assert_start(empty, event("selected"), expected)
    end
  end

  test "empty and nonbinary start identities bypass terminal lookup without an extra key guard" do
    for id <- ["", nil, false, [], 7, 1.25, <<1::size(1)>>, %{"key" => true}] do
      before = %State{
        state(%{id => %{"status" => "completed"}})
        | async_results: :unusable_results,
          async_result_refs: :unusable_refs
      }

      record = %{"tool_call_id" => id, "status" => "running"}
      assert_start(before, event(id), %State{before | async_tool_calls: %{id => record}})
    end

    before = state()
    ev = Map.delete(event(nil), "tool_call_id")

    assert_start(before, ev, %State{before | async_tool_calls: %{nil => %{"status" => "running"}}})
  end
end
