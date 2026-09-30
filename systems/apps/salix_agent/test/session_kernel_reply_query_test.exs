defmodule SalixAgent.SessionKernelReplyQueryTest do
  @moduledoc """
  Coverage for the reply-shaped Session queries in the Lean kernel.

  The visible reply scope derives on the clean trusted path and survives
  compaction, and `provider_states` answers what `ContextProviders` reads
  from a plain state map.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State

  alias SalixAgent.ContextProviders

  @group_id "grp1_0000000000000000001_0000000000000000002"
  @conversation_id "cnv1_0000000000000000001"
  @participant_id "ptp1_0000000000000000001"
  @message_id "msg1_0000000000000000001"
  @source_id "groupconv:cnv1_0000000000000000001:msg1_0000000000000000001:ptp1_0000000000000000001"

  # -- driver ---------------------------------------------------------------

  defp outcome(fun) do
    {:returned, fun.()}
  catch
    kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  defp same(state, name, args, fun) do
    expected = outcome(fn -> fun.(state) end)
    actual = outcome(fn -> SalixVerifiedKernel.Session.query(open(state), name, args) end)

    assert actual === expected, """
    query #{inspect(name)} with #{inspect(args)} disagreed
    elixir: #{inspect(expected, limit: :infinity)}
    kernel: #{inspect(actual, limit: :infinity)}
    state:  #{inspect(state, limit: :infinity)}
    """

    expected
  end

  defp open(state), do: SalixVerifiedKernel.Session.open(state)

  defp derive(state, ids),
    do: SalixVerifiedKernel.Session.query(open(state), :derive_visible_reply_scope, ids)

  # -- fixtures -------------------------------------------------------------

  defp trusted_origin(overrides \\ %{}) do
    Map.merge(
      %{
        "provider" => "internal",
        "agent_group_id" => @group_id,
        "conversation_id" => @conversation_id,
        "conversation_kind" => "user_chat",
        "message_id" => @message_id,
        "participant_id" => @participant_id,
        "source_actor_type" => "user"
      },
      overrides
    )
  end

  defp trusted_user_message(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        role: "user",
        content: "hello",
        source_message_id: @source_id,
        trusted_origin: trusted_origin()
      },
      overrides
    )
  end

  defp session(messages, overrides \\ %{}) do
    struct!(
      %State{
        agent_id: "agt1_0000000000000000001_0000000000000000002_0000000000000000003",
        session_id: "ses1_0000000000000000001",
        messages: messages
      },
      overrides
    )
  end

  defp activation_scope do
    {:ok, scope} = derive(session([trusted_user_message()]), [@source_id])
    {:ok, scope} = SalixAgent.TestSupport.PresentationScope.with_identity(scope)
    scope
  end

  # -- derive_visible_reply_scope -------------------------------------------

  test "derive_visible_reply_scope derives on the clean trusted path" do
    assert {:ok, _} = derive(session([trusted_user_message()]), [@source_id])
  end

  test "derive_visible_reply_scope extends and preserves a compacted scope" do
    scope = activation_scope()

    pending = %{id: 3, role: "assistant", content: "draft", tool_calls: []}
    no_wake = %{id: 4, role: "user", content: "internal context", no_wake: true}

    compacted =
      session([pending, no_wake], %{
        last_ack_message_id: 1,
        compacted_through: 2,
        visible_reply_activation_scope: scope
      })

    assert {:ok, ^scope} = derive(compacted, [@source_id])

    new_message_id = "msg1_0000000000000000002"
    new_source = "groupconv:#{@conversation_id}:#{new_message_id}:#{@participant_id}"

    same_conversation =
      trusted_user_message(%{
        id: 5,
        source_message_id: new_source,
        trusted_origin: trusted_origin(%{"message_id" => new_message_id})
      })

    extended = %{compacted | messages: [pending, no_wake, same_conversation]}
    assert {:ok, _} = derive(extended, [@source_id, new_source])
  end

  # -- provider_states ------------------------------------------------------

  test "provider_states matches ContextProviders.provider_states/1" do
    candidates = [
      %{},
      nil,
      %{"migration_notice" => %{"version" => 3}},
      %{"runtime_context" => %{"version" => 3}},
      %{"runtime_context" => %{"version" => "7"}},
      %{"runtime_context" => %{"version" => " 7 "}},
      %{"runtime_context" => %{"version" => -2}},
      %{"runtime_context" => %{"version" => nil}},
      %{"runtime_context" => %{"version" => 3}, "migration_notice" => %{"version" => 1}},
      %{runtime_context: %{version: 4}},
      %{"runtime_context" => %{"other" => 1}},
      %{"runtime_context" => "not a map"},
      %{"mcp" => %{"servers" => ["a"]}, "runtime_context" => %{"version" => 2}},
      %{"empty" => %{}, "kept" => %{"a" => 1}},
      %{"nil_state" => nil, "kept" => %{"a" => 1}},
      %{"list_state" => [1, 2], "kept" => %{"a" => 1}},
      %{:atom_key => %{:inner => [%{:deep => 1}]}},
      "not a map",
      [1, 2]
    ]

    for states <- candidates do
      state = session([], %{context_provider_states: states})
      same(state, :provider_states, nil, &ContextProviders.provider_states/1)
    end
  end
end
