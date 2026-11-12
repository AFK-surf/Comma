defmodule SalixAgent.InternalSessionFlushSettlementTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSession, InternalSessionActor, InternalSessionStore, OwnershipCell}
  alias SalixAgent.InternalSessionStore.PGCodec
  alias SalixStore.Repo

  @session "ses1_0000000000000000700"

  setup do
    agent = SalixAgent.TestSupport.new_agent_id()

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

    Repo.query!(
      """
      INSERT INTO salix_agents
        (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,root_revision)
      VALUES ($1,'tenant','group','worker',1,$2,'owner',1,1)
      """,
      [agent, PGCodec.encode(%{})]
    )

    :ok = OwnershipCell.install(agent, 1)
    on_exit(fn -> OwnershipCell.clear(agent) end)

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, @session), %{
        runtime_epoch: 1
      })

    assert {:ok, _} = InternalSessionStore.create(agent, @session)
    {:ok, agent: agent}
  end

  test "source progress and input become visible together at the durable fence", %{
    agent: agent_id
  } do
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)

    entry = %{
      source_message_id: "conversation-input",
      payload: %{content: "accepted work"},
      conversation_source: %{
        "conversation_id" => "conversation",
        "participant_id" => "participant",
        "generation" => @session,
        "seq" => 1
      }
    }

    assert {{:awaiting_fence, _}, _uncommitted, nil} =
             InternalSession.Command.prepare(agent_id, @session, base, :input, {entry, false})

    assert {:ok, before} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(before) == %{}
    assert InternalSession.export(before).input_queue == []

    assert {{:ok, :committed}, committed, nil} =
             InternalSession.Command.run(agent_id, @session, base, :input, {entry, false})

    assert {:ok, after_crash} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(after_crash)["participant"]["seq"] == 1
    assert length(InternalSession.export(after_crash).input_queue) == 1

    assert {{:ok, :duplicate}, _, nil} =
             InternalSession.Command.run(agent_id, @session, committed, :input, {entry, false})

    assert {:ok, after_retry} = InternalSessionStore.read(agent_id, @session)
    assert length(InternalSession.export(after_retry).input_queue) == 1

    other = %{
      entry
      | source_message_id: "another-conversation-input",
        conversation_source: %{
          entry.conversation_source
          | "participant_id" => "other-participant",
            "conversation_id" => "other-conversation"
        }
    }

    assert {{:ok, :committed}, _, nil} =
             InternalSession.Command.run(agent_id, @session, committed, :input, {other, false})

    assert {:ok, fan_in} = InternalSessionStore.read(agent_id, @session)
    assert map_size(InternalSession.conversation_sources(fan_in)) == 2
    assert length(InternalSession.export(fan_in).input_queue) == 2
  end

  test "source gaps and retired binding generations cannot admit inputs", %{agent: agent_id} do
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)

    for {seq, generation} <- [{2, @session}, {1, "retired-session"}] do
      entry = %{
        source_message_id: "rejected-source",
        payload: %{content: "must not enter"},
        conversation_source: %{
          "conversation_id" => "conversation",
          "participant_id" => "participant",
          "generation" => generation,
          "seq" => seq
        }
      }

      assert {{:error, :conversation_source_gap}, _, nil} =
               InternalSession.Command.run(agent_id, @session, base, :input, {entry, false})
    end

    assert {:ok, stored} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.conversation_sources(stored) == %{}
    assert InternalSession.export(stored).input_queue == []
  end

  test "a duplicate of staged input must cross its durable fence before acknowledgment", %{
    agent: agent_id
  } do
    assert {:ok, base} = InternalSessionStore.read_revision(agent_id, @session)
    input = %{source_message_id: "staged-duplicate", payload: %{content: "retain this input"}}

    assert {{:awaiting_fence, _}, staged, nil} =
             SalixAgent.InternalSession.Command.prepare(
               agent_id,
               @session,
               base,
               :input,
               {input, false}
             )

    assert {:ok, before} = InternalSessionStore.read(agent_id, @session)
    assert InternalSession.get(before, :input_queue) == []

    assert {{:ok, :duplicate}, committed, nil} =
             SalixAgent.InternalSession.Command.run(
               agent_id,
               @session,
               staged,
               :input,
               {input, false}
             )

    assert {:ok, after_write} = InternalSessionStore.read(agent_id, @session)

    assert [%{"dedupe_key" => "staged-duplicate"}] =
             InternalSession.get(after_write, :input_queue)

    assert committed.pending == nil
  end
end
