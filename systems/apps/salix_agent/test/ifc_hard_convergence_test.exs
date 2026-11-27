defmodule SalixAgent.IFCHardConvergenceTest do
  use ExUnit.Case, async: true
  alias SalixAgent.IFC.HardConvergence, as: Cap

  defp input, do: %{role: "user", content: "answer here"}

  defp failed(n) do
    [
      %{
        role: "assistant",
        tool_calls: [
          %{
            id: "c#{n}",
            name: "call",
            args: %{"tool" => "history.search", "params" => %{"query" => "q#{n}"}}
          }
        ]
      },
      %{
        role: "tool",
        tool_call_id: "c#{n}",
        content:
          Jason.encode!(%{
            "status" => "withheld_by_visibility",
            "message" =>
              "This tool result is not visible in the current audience and was omitted."
          })
      }
    ]
  end

  defp view(n), do: [input() | Enum.flat_map(1..n, &failed/1)]

  test "eight consecutive visible unsuccessful rounds narrow only this request" do
    refute Cap.finish?(%{messages: view(7), aliases: %{}}, %{})
    assert Cap.finish?(%{messages: view(8), aliases: %{}}, %{})
    assert Cap.streak(view(8) ++ [input()]) == 0
  end

  test "new useful evidence and pending receipts preserve exploration" do
    ms =
      view(7) ++
        [
          %{
            role: "assistant",
            tool_calls: [
              %{id: "fresh", name: "call", args: %{"tool" => "history.search", "params" => %{}}}
            ]
          },
          %{role: "tool", tool_call_id: "fresh", content: ~s({"results":[{"text":"new fact"}]})}
        ]

    assert Cap.streak(ms) == 0

    page =
      List.update_at(
        ms,
        -1,
        &Map.put(&1, :content, ~s({"results":[],"next_cursor":"page2","has_more":true}))
      )

    assert Cap.streak(page) == 0
  end

  test "only visible active call ids block a cap; foreign work cannot change it" do
    p = %{messages: view(8), aliases: %{"src:t-c8" => "src:t-owned"}}
    refute Cap.finish?(p, %{"owned" => %{status: "running"}})
    assert Cap.finish?(p, %{"foreign" => %{status: "running"}})
  end

  test "unknown or pending visible delegation conservatively keeps tools" do
    create = [
      %{
        role: "assistant",
        tool_calls: [
          %{
            id: "task",
            name: "call",
            args: %{"tool" => "im_api.internal.task.create", "params" => %{}}
          }
        ]
      },
      %{
        role: "tool",
        tool_call_id: "task",
        content: ~s({"conversation_id":"task-a","status":"active"})
      }
    ]

    refute Cap.finish?(
             %{messages: [input()] ++ create ++ Enum.flat_map(1..8, &failed/1), aliases: %{}},
             %{}
           )
  end

  test "an asynchronous unavailable help receipt counts without consulting host history" do
    ms = [
      input(),
      %{
        role: "assistant",
        tool_calls: [
          %{id: "h", name: "call", args: %{"tool" => "help", "params" => %{"tool" => "missing"}}}
        ]
      },
      %{
        role: "tool",
        tool_call_id: "h",
        content: ~s({"status":"running","tool_call_id":"original"})
      },
      %{
        role: "runtime",
        content:
          Jason.encode!(%{
            "type" => "tool_call_completed",
            "tool_call_id" => "original",
            "result" => %{"content" => Jason.encode!(%{"guidance_reason" => "not_callable"})}
          })
      }
    ]

    assert Cap.streak(ms) == 1
  end
end
