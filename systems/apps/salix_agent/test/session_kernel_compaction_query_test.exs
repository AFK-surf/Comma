defmodule SalixAgent.SessionKernelCompactionQueryTest do
  @moduledoc """
  Coverage for the compaction query catalog.

  The request window keeps the current activation's project knowledge in
  place, once, and drops project knowledge from earlier activations.
  """
  use ExUnit.Case, async: true

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

  test "the request keeps the current activation's project knowledge in place, once" do
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
    assert Enum.map(ask(state, :compaction_live_messages), & &1.id) == [1, 3, 4, 6]

    state =
      base(%{
        next_message_id: 6,
        messages: [
          user_message(1),
          runtime_message(2, %{type: "project_knowledge", content: "facts-a"}),
          assistant_message(3),
          user_message(4),
          runtime_message(5, %{type: "project_knowledge", content: "facts-a"})
        ]
      })

    assert Enum.map(ask(state, :request_live_messages), & &1.id) == [1, 3, 4, 5]
  end

  test "a selected provider context equals the same selection of the full context" do
    state =
      base(%{
        next_message_id: 8,
        messages: [
          user_message(1),
          %{
            id: 2,
            role: "assistant",
            content: "checking",
            tool_calls: [
              %{id: "call-1", name: "call", args: %{}},
              %{id: "call-2", name: "call", args: %{}}
            ]
          },
          %{id: 3, role: "tool", tool_call_id: "call-1", content: ~s({"ok":true})},
          %{id: 4, role: "tool", tool_call_id: "call-2", content: "plain text"},
          runtime_message(5, %{runtime_message_id: "rtm-5", content: "first"}),
          runtime_message(6, %{"runtime_message_id" => "rtm-6", content: "second"}),
          user_message(7)
        ]
      })

    session = Resident.open(state)
    context = Resident.query(session, :provider_context, nil)

    for selector <- [
          {:tool_ids, [3, 4]},
          {:tool_ids, [4]},
          {:tool_ids, [1, 99]},
          {:runtime_message_id, "rtm-5"},
          {:runtime_message_id, "rtm-6"},
          {:runtime_message_id, "missing"}
        ] do
      expected = Enum.filter(context, &selected?(selector, &1))
      assert Resident.query(session, :provider_context_where, selector) == expected
    end

    assert [%{id: 3}, %{id: 4}] =
             Resident.query(session, :provider_context_where, {:tool_ids, [3, 4]})
  end

  defp selected?({:runtime_message_id, id}, message),
    do: (message["runtime_message_id"] || message[:runtime_message_id]) == id

  defp selected?({:tool_ids, ids}, message) do
    field = fn name -> Map.get(message, name, Map.get(message, Atom.to_string(name))) end
    field.(:role) == "tool" and field.(:id) in ids
  end
end
