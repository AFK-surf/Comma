defmodule SalixAgent.SessionKernelStorageQueryTest do
  @moduledoc """
  Coverage for the storage/migration query catalog.

  Each case runs `SalixVerifiedKernel.Session.query/3` over a legacy snapshot
  and asserts the certified terminal async results: which statuses count,
  their order by `completed_at`, and the expected seq after the covered
  messages and facts.
  """
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  @session "ses1_0000000000000000910"

  defp base(overrides \\ %{}) do
    struct(
      %State{InternalSession.export(InternalSession.new("agent", @session)) | storage_format: 1},
      overrides
    )
  end

  defp terminal(state),
    do: Resident.query(Resident.open(state), :terminal_results_from_backup, nil)

  defp call(overrides),
    do: Map.merge(%{"tool_call_id" => "c", "status" => "completed"}, overrides)

  test "an empty snapshot has nothing to certify" do
    assert terminal(base()) == []
    assert terminal(%State{}) == []
    assert terminal(base(%{async_tool_calls: nil, messages: nil, events: nil})) == []
  end

  test "only terminal statuses are certified, and running ones are skipped" do
    state =
      base(%{
        async_tool_calls: %{
          "done" => call(%{"status" => "completed", "completed_at" => 10}),
          "failed" => call(%{"status" => "failed", "completed_at" => 11}),
          "cancelled" => call(%{"status" => "cancelled", "completed_at" => 12}),
          "running" => call(%{"status" => "running", "completed_at" => 13}),
          "blank" => call(%{"status" => nil}),
          "shaped" => %{"result" => "no status at all"}
        }
      })

    certified = terminal(state)
    assert Enum.map(certified, fn {id, _call, _seq} -> id end) == ["done", "failed", "cancelled"]
    assert Enum.map(certified, fn {_id, _call, seq} -> seq end) == [1, 2, 3]
  end

  test "the expected seq starts after the covered messages and every fact" do
    state =
      base(%{
        compacted_through: 2,
        messages: [
          %{id: 1, role: "user", content: "covered"},
          %{"id" => 2, "role" => "user", "content" => "covered, string key"},
          %{id: 3, role: "user", content: "live"}
        ],
        events: [%{"kind" => "a"}, %{"kind" => "b"}],
        async_tool_calls: %{"c" => call(%{"completed_at" => 5})}
      })

    assert [{"c", _call, 5}] = terminal(state)
  end

  test "terminal calls order by completed_at then tool call id" do
    state =
      base(%{
        async_tool_calls: %{
          "b" => call(%{"completed_at" => 5}),
          "a" => call(%{"completed_at" => 5}),
          "c" => call(%{"completed_at" => 1}),
          "d" => call(%{})
        }
      })

    certified = terminal(state)
    assert Enum.map(certified, fn {id, _call, _seq} -> id end) == ["d", "c", "a", "b"]
    assert Enum.map(certified, fn {_id, _call, seq} -> seq end) == [1, 2, 3, 4]
  end

  test "the whole terminal record travels, not a projection of it" do
    record =
      call(%{
        "completed_at" => 2_000,
        "status" => "failed",
        "result" => nil,
        "error" => "boom",
        "diagnostics" => %{"attempts" => [1, 2], "unicode" => "完整结果"}
      })

    assert [{"call-failed", ^record, 1}] =
             terminal(base(%{async_tool_calls: %{"call-failed" => record}}))
  end
end
