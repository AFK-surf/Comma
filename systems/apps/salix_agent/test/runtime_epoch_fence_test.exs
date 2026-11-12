defmodule SalixAgent.RuntimeEpochFenceTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSession, InternalSessionActor, InternalSessionStore, OwnershipCell}
  alias SalixAgent.InternalSessionStore.PGCodec
  alias SalixStore.Repo

  @session "ses1_0000000000000000001"

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

    on_exit(fn -> OwnershipCell.clear(agent) end)
    {:ok, agent: agent}
  end

  defp event(status),
    do: %{"type" => "status", "session_id" => @session, "status" => status}

  defp own(agent) do
    :ok = OwnershipCell.install(agent, 1)

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, @session), nil)

    assert {:ok, state} = InternalSessionStore.create(agent, @session)
    assert InternalSession.get(state, :runtime_epoch) == 1
  end

  test "an absent or fenced claim cannot create Session facts", %{agent: agent} do
    assert {:error, :fenced} = InternalSessionStore.prepare_create(agent, @session)
    :ok = OwnershipCell.fence(agent, 1)
    assert {:error, :fenced} = InternalSessionStore.prepare_create(agent, @session)
    assert {:error, :not_found} = InternalSessionStore.read(agent, @session)
  end

  test "a claim changed after the builder read fences the frozen commit", %{agent: agent} do
    own(agent)

    builder = fn _state ->
      Repo.query!("UPDATE salix_agents SET owner_epoch=2 WHERE agent_id=$1", [agent])
      {:ok, [event("active")]}
    end

    assert {:error, {:fenced, 2}} = InternalSessionStore.commit_dynamic(agent, @session, builder)
    assert {:ok, stored} = InternalSessionStore.read(agent, @session)
    assert InternalSession.status(stored) == :idle
    assert InternalSession.get(stored, :runtime_epoch) == 1
  end

  test "same-node reclaim does not replace an old actor's captured epoch", %{agent: agent} do
    own(agent)
    assert {:ok, version} = InternalSessionStore.read_revision(agent, @session)
    assert {:ok, staged} = InternalSessionStore.write_revision(version, [event("active")])

    Repo.query!("UPDATE salix_agents SET owner_epoch=3 WHERE agent_id=$1", [agent])
    :ok = OwnershipCell.clear(agent)
    :ok = OwnershipCell.install(agent, 3)

    assert {:ok, task} = InternalSessionStore.start_durable_fence(agent, @session, staged)
    assert {:error, {:fenced, 3}} = InternalSessionStore.await_durable_fence(task)
    assert {:ok, stored} = InternalSessionStore.read(agent, @session)
    assert InternalSession.status(stored) == :idle
    assert InternalSession.get(stored, :runtime_epoch) == 1

    # A new actor can use the new claim after the old actor exits.
    Registry.unregister(SalixAgent.Registry, InternalSessionActor.key(agent, @session))

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, @session), %{
        runtime_epoch: 3
      })

    assert {:ok, committed} = InternalSessionStore.commit(agent, @session, [event("active")])
    assert InternalSession.get(committed, :runtime_epoch) == 3
    assert InternalSession.status(committed) == :active
  end
end
