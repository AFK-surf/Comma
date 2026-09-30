defmodule SalixAgent.SessionKernelProvenanceQueryTest do
  @moduledoc """
  Coverage for the provenance query catalog
  (`runtime/VerifiedKernel/Session/Query/Provenance.lean`).

  The callers `SalixAgent.IFC.Context` and `SalixAgent.ToolCallProvenance`
  read these queries through the kernel from both a handle and a state map.
  An empty session answers the fail-closed activation.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  defp ask(state, name, args \\ nil), do: Resident.query(Resident.open(state), name, args)

  ## Fixtures ---------------------------------------------------------------

  defp base(attrs \\ %{}) do
    struct(State, Map.merge(%{agent_id: "agent-1", session_id: "session-1"}, attrs))
  end

  defp human_origin(extra \\ %{}) do
    Map.merge(
      %{
        "provider" => "internal",
        "conversation_kind" => "user_chat",
        "source_actor_type" => "user",
        "agent_group_id" => "group-1",
        "conversation_id" => "conv-1",
        "participant_id" => "participant-1",
        "message_id" => "m-1",
        "source_message_id" => "s1"
      },
      extra
    )
  end

  defp sealed(label, extra \\ %{}) do
    Map.merge(%{"integrity" => "command", "label" => label}, extra)
  end

  defp user(id, source_id, extra) do
    Map.merge(
      %{id: id, role: "user", content: "hello #{id}", source_message_id: source_id},
      extra
    )
  end

  ## `SalixAgent.IFC.Context` -----------------------------------------------

  test "ifc_context answers an empty session with the fail-closed activation" do
    assert ask(base(), :ifc_context, {nil, [], nil}) == %{
             "items" => [],
             "input_refs" => %{},
             "requester" => nil,
             "source_scope" => ["agent_private"],
             "consumed_refs" => [],
             "request" => nil
           }
  end

  test "IFC.Context.build/2 goes through the kernel from both a handle and a map" do
    messages = [
      user(1, "s1", %{trusted_origin: human_origin(%{"ifc" => sealed(["conversation|conv-1"])})})
    ]

    opts = [source_message_id: "s1", source_message_ids: ["s1"]]
    state = base(%{messages: messages})
    expected = SalixAgent.IFC.Context.build(state, opts)

    assert SalixAgent.IFC.Context.build(SalixAgent.InternalSession.open(state), opts) == expected
    assert expected["request"] == "src:q-1"
    assert expected["consumed_refs"] == ["src:q-1"]
  end

  test "IFC.Context.organization_scopes/3 goes through the kernel" do
    messages = [
      user(1, "s1", %{
        trusted_origin:
          human_origin(%{
            "ifc" => %{"integrity" => "command"},
            "meeting_preparation" => %{"scope" => "team"}
          })
      })
    ]

    state = base(%{messages: messages})

    assert SalixAgent.IFC.Context.organization_scopes(state, ["s1"]) == [%{"scope" => "team"}]

    assert SalixAgent.IFC.Context.organization_scopes(
             SalixAgent.InternalSession.open(state),
             ["s1"]
           ) == [%{"scope" => "team"}]
  end

  ## `SalixAgent.ToolCallProvenance` ----------------------------------------

  test "ToolCallProvenance.current_source_ids/1 goes through the kernel" do
    state = base(%{messages: [user(1, "s1", %{trusted_origin: human_origin()})]})

    assert SalixAgent.ToolCallProvenance.current_source_ids(state) == ["s1"]

    assert SalixAgent.ToolCallProvenance.current_source_ids(
             SalixAgent.InternalSession.open(state)
           ) == ["s1"]

    assert SalixAgent.ToolCallProvenance.current_source_ids(%{}) == []
    assert SalixAgent.ToolCallProvenance.current_source_ids(nil) == []
  end
end
