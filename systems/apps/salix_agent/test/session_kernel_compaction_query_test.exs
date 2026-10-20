defmodule SalixAgent.SessionKernelCompactionQueryTest do
  @moduledoc """
  Coverage for the compaction query catalog.

  The request window keeps the current activation's project knowledge in
  place, once, and drops project knowledge from earlier activations.
  """
  use SystemsClock.Case, async: true

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  defp ask(state, name, args \\ nil), do: Resident.query(Resident.open(state), name, args)

  defp base(attrs) do
    struct(State, Map.merge(%{agent_id: "agent-1", session_id: "session-1"}, attrs))
  end

  defp user_message(id, extra \\ %{}),
    do: Map.merge(%{id: id, role: "user", content: "hello #{id}"}, extra)

  defp assistant_message(id),
    do: %{id: id, role: "assistant", content: "reply #{id}", tool_calls: []}

  defp tool_message(id), do: %{id: id, role: "tool", content: ~s({"ok":true})}

  defp runtime_message(id, extra),
    do: Map.merge(%{id: id, role: "runtime", content: "note", type: "wait_expired"}, extra)

  test "live windows leave out duplicate project knowledge" do
    state =
      base(%{
        next_message_id: 8,
        messages: [
          user_message(1),
          runtime_message(2, %{type: "project_knowledge", content: "facts-a"}),
          assistant_message(3),
          tool_message(4),
          runtime_message(5, %{type: "project_knowledge", content: "facts-a"}),
          user_message(6, %{no_wake: true}),
          runtime_message(7, %{type: "project_knowledge", content: "facts-b"})
        ]
      })

    assert Enum.map(ask(state, :request_live_messages), & &1.id) == [1, 2, 3, 4, 6, 7]
    assert Enum.map(ask(state, :compaction_live_messages), & &1.id) == [1, 2, 3, 4, 6, 7]
  end

  test "the conversation tail is what people and Agents received and sent, not raw model text" do
    send = fn id, tool, params ->
      %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}
    end

    state =
      base(%{
        next_message_id: 9,
        compacted_through: 1,
        messages: [
          user_message(1, %{content: "compacted away"}),
          user_message(2, %{content: "Ship 2.4 on Friday."}),
          %{
            id: 3,
            role: "assistant",
            content: "private reasoning text",
            tool_calls: [
              send.("c1", "im_api.internal.send_message", %{
                "conversation_id" => "conv-1",
                "content" => [%{"type" => "text", "text" => "On it."}]
              }),
              send.("c2", "fs.read_file", %{"path" => "/plan.md"}),
              send.("c3", "im_api.internal.task.create", %{"content" => "Draft release notes."})
            ]
          },
          tool_message(4),
          runtime_message(5, %{content: "note"}),
          user_message(6, %{
            content: [%{"type" => "text", "text" => "Notes drafted."}],
            trusted_origin: %{"source_actor_type" => "agent"}
          }),
          user_message(7, %{content: [%{"type" => "image", "url" => "x"}]}),
          %{
            id: 8,
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                id: "c4",
                name: "end_turn",
                args: %{
                  "outcome" => "done",
                  "reply" => %{
                    "tool" => "im_api.slack.reply_message",
                    "params" => %{"text" => "Done: notes are ready."}
                  }
                }
              }
            ]
          }
        ]
      })

    assert ask(state, :request_conversation_tail, 16) == [
             %{"direction" => "in", "from" => "user", "text" => "Ship 2.4 on Friday."},
             %{
               "direction" => "out",
               "tool" => "im_api.internal.send_message",
               "text" => "On it."
             },
             %{
               "direction" => "out",
               "tool" => "im_api.internal.task.create",
               "text" => "Draft release notes."
             },
             %{"direction" => "in", "from" => "agent", "text" => "Notes drafted."},
             %{
               "direction" => "out",
               "tool" => "im_api.slack.reply_message",
               "text" => "Done: notes are ready."
             }
           ]

    assert [%{"text" => "Notes drafted."}, %{"text" => "Done: notes are ready."}] =
             ask(state, :request_conversation_tail, 2)

    assert ask(state, :request_conversation_tail, 0) == []
  end
end
