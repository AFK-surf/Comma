defmodule SalixAgent.SessionKernelRepairQueryTest do
  @moduledoc """
  Coverage for the `repair_scan` Session query in the Lean kernel.

  The scan reports tool calls that have neither a result nor an async record,
  and the async records that are still running.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  defp scan(state), do: Resident.query(Resident.open(state), :repair_scan, nil)

  defp session(overrides \\ %{}) do
    struct!(
      %State{
        agent_id: "agt1_0000000000000000001_0000000000000000002_0000000000000000003",
        session_id: "ses1_0000000000000000001"
      },
      overrides
    )
  end

  test "repair_scan finds nothing in an empty transcript" do
    assert %{"missing_calls" => [], "running_async" => []} = scan(session())
  end

  test "repair_scan keeps only calls without a result or an async record" do
    state =
      session(%{
        messages: [
          %{
            id: 1,
            role: "assistant",
            tool_calls: [
              %{"id" => "answered", "name" => "fs.read_file", "args" => %{"path" => "a"}},
              %{"id" => "async", "name" => "sh.run", "args" => %{}},
              %{"id" => "missing", "name" => "fs.write_file", "args" => %{"path" => "b"}}
            ]
          },
          %{id: 2, role: "tool", tool_call_id: "answered", content: "{}"}
        ],
        async_tool_calls: %{
          "async" => %{"tool_call_id" => "async", "status" => "running", "tool_name" => "sh.run"}
        }
      })

    assert %{"missing_calls" => [%{id: "missing"}]} = scan(state)
  end

  test "repair_scan stringifies running async records and skips terminal ones" do
    state =
      session(%{
        async_tool_calls: %{
          "a" => %{"tool_call_id" => "a", "status" => "running", "tool_name" => "sh.run"},
          "b" => %{"tool_call_id" => "b", "status" => "completed"},
          "c" => %{tool_call_id: "c", status: :running, completion_mode: "external_callback"},
          "d" => %{
            "tool_call_id" => "d",
            "status" => :running,
            "completion_owner" => "direct_poll"
          },
          "e" => %{tool_call_id: "e", status: "running"},
          "f" => %{"tool_call_id" => "f"},
          "g" => :not_a_map
        }
      })

    assert %{"running_async" => running} = scan(state)
    assert length(running) == 4
  end
end
