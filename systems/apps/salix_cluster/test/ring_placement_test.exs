defmodule SalixCluster.RingPlacementTest do
  @moduledoc """
  Placement ring: consistent-hash ownership properties, the Ring
  GenServer on a single node, and local placement routing.
  """
  use ExUnit.Case, async: false

  alias SalixCluster.{Ring, Placement, ConversationPlacement}

  describe "consistent-hash ring properties" do
    test "ownership is deterministic and stable for a fixed node set" do
      ring = build([:a, :b, :c, :d])
      keys = for i <- 1..200, do: "agent-#{i}"

      owners = Map.new(keys, &{&1, HashRing.key_to_node(ring, &1)})
      # deterministic
      assert Enum.all?(keys, fn k -> HashRing.key_to_node(ring, k) == owners[k] end)
      # all four nodes get a meaningful share (consistent hashing balances)
      counts = owners |> Map.values() |> Enum.frequencies()
      assert map_size(counts) == 4
      assert Enum.all?(Map.values(counts), &(&1 > 10))
    end

    test "removing a node only remaps keys that lived on it" do
      ring = build([:a, :b, :c, :d])
      keys = for i <- 1..300, do: "k-#{i}"
      before = Map.new(keys, &{&1, HashRing.key_to_node(ring, &1)})

      ring2 = HashRing.remove_node(ring, :d)

      moved =
        Enum.count(keys, fn k -> HashRing.key_to_node(ring2, k) != before[k] end)

      # keys that were on :a/:b/:c are undisturbed; only ~25% (the :d keys) move
      on_d = Enum.count(before, fn {_k, n} -> n == :d end)
      assert moved == on_d
    end
  end

  describe "Ring GenServer (single node)" do
    test "owner is stable and nodes includes self" do
      assert Node.self() in Ring.nodes()
      o1 = Ring.owner("agent-x")
      o2 = Ring.owner("agent-x")
      assert o1 == o2
      # single-node cluster: this node owns everything
      assert o1 == Node.self()
    end
  end

  describe "placement routing (local)" do
    setup do
      SalixAgent.TestSupport.stop_all_agents()
      prev = Application.get_env(:salix_store, :s3_backend)
      prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      start_supervised!(SalixStore.S3.Fake)

      on_exit(fn ->
        SalixAgent.TestSupport.stop_all_agents()
        Application.put_env(:salix_store, :s3_backend, prev)
        put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      end)

      :ok
    end

    test "owner == self routes to local Fleet and starts a Server" do
      a = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, pid} = Placement.ensure_started(a, create: false)
      assert is_pid(pid)
      assert node(pid) == Node.self()
      assert SalixAgent.Fleet.running?(a)
    end

    test "unreachable remote owner returns an explicit error instead of starting locally" do
      remote = :"salix-owner-down@127.0.0.1"
      ring = Process.whereis(Ring)
      send(ring, {:nodeup, remote, %{}})

      on_exit(fn ->
        send(ring, {:nodedown, remote, %{}})
      end)

      agent_id = agent_owned_by(remote)
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      assert {:error, {:owner_unreachable, ^remote, _reason}} =
               Placement.ensure_started(agent_id, create: false)

      refute SalixAgent.Fleet.running?(agent_id)
    end

    test "session fleets refuse to start session actors on a non-owner node" do
      remote = :"salix-session-owner-down@127.0.0.1"
      ring = Process.whereis(Ring)
      send(ring, {:nodeup, remote, %{}})

      on_exit(fn ->
        send(ring, {:nodedown, remote, %{}})
      end)

      agent_id = agent_owned_by(remote)
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      assert {:error, {:owner_unreachable, ^remote, _reason}} =
               SalixAgent.InternalSessionFleet.ensure_started(
                 agent_id,
                 "ses1_1200000000000000001"
               )

      assert {:error, {:owner_unreachable, ^remote, _reason}} =
               SalixAgent.ExternalSessionFleet.ensure_started(
                 agent_id,
                 "ses1_1200000000000000001"
               )

      assert Registry.lookup(
               SalixAgent.Registry,
               SalixAgent.InternalSessionActor.key(agent_id, "ses1_1200000000000000001")
             ) == []

      assert Registry.lookup(
               SalixAgent.Registry,
               SalixAgent.ExternalSessionActor.key(agent_id, "ses1_1200000000000000001")
             ) == []
    end

    test "a live lease holder wins after the ring remaps the agent" do
      remote = :"salix-replacement@127.0.0.1"
      ring = Process.whereis(Ring)
      send(ring, {:nodeup, remote, %{}})
      on_exit(fn -> send(ring, {:nodedown, remote, %{}}) end)

      agent_id = agent_owned_by(remote)
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      assert {:ok, _owned} =
               SalixStore.Agent.claim(agent_id, to_string(node()), SalixAgent.State)

      assert Ring.owner(agent_id) == remote
      assert {:ok, pid} = Placement.ensure_started(agent_id, create: false)
      assert node(pid) == node()
      # Stop must resolve the same owner; otherwise a ring move strands the
      # running holder even when a caller explicitly requests a stop.
      assert :ok = Placement.stop_existing(agent_id, [])
    end

    test "a disconnected live holder is not replaced before lease expiry" do
      agent_id = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(agent_id)
      holder = "disconnected-holder@127.0.0.1"
      assert {:ok, _owned} = SalixStore.Agent.claim(agent_id, holder, SalixAgent.State)

      assert {:error, {:owner_unreachable, ^holder, :not_connected}} =
               Placement.ensure_started(agent_id, create: false)

      refute SalixAgent.Fleet.running?(agent_id)
      assert {:ok, head} = SalixStore.Agent.peek(agent_id)
      assert head.owner_node == holder
    end

    test "an expired disconnected lease falls back to ring placement" do
      agent_id = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      assert {:ok, _owned} =
               SalixStore.Agent.claim(agent_id, "expired-holder@127.0.0.1", SalixAgent.State,
                 now: System.system_time(:millisecond) - 120_000,
                 ttl_ms: 1_000
               )

      assert {:ok, pid} = Placement.ensure_started(agent_id, create: false)
      assert node(pid) == node()
    end

    test "conversation placement starts the local owner for a conversation key" do
      tenant_id = SalixStore.Ids.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)
      conversation_id = SalixStore.Ids.new_conversation_id()

      assert {:ok, pid} = ConversationPlacement.ensure_started(group_id, conversation_id, [])
      assert is_pid(pid)
      assert node(pid) == Node.self()
      assert SalixIM.ConversationFleet.running?(group_id, conversation_id)

      :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    end

    test "conversation placement starts the local group collection owner" do
      tenant_id = SalixStore.Ids.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)

      assert {:ok, pid} = ConversationPlacement.ensure_group_started(group_id, [])
      assert is_pid(pid)
      assert node(pid) == Node.self()

      assert [{^pid, _value}] =
               Registry.lookup(
                 SalixIM.ConversationRegistry,
                 SalixIM.ConversationGroupActor.key(group_id)
               )

      :ok = DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid)
    end

    test "conversation placement returns an explicit error for unreachable remote owner" do
      remote = :"salix-conversation-owner-down@127.0.0.1"
      ring = Process.whereis(Ring)
      send(ring, {:nodeup, remote, %{}})

      on_exit(fn ->
        send(ring, {:nodedown, remote, %{}})
      end)

      {group_id, conversation_id} = conversation_owned_by(remote)

      assert {:error, {:owner_unreachable, _owner_key, _reason}} =
               ConversationPlacement.ensure_started(group_id, conversation_id, [])

      refute SalixIM.ConversationFleet.running?(group_id, conversation_id)
    end

    test "group collection placement routes to its remote owner and reports it unreachable" do
      remote = :"salix-conversation-group-owner-down@127.0.0.1"
      ring = Process.whereis(Ring)
      send(ring, {:nodeup, remote, %{}})

      on_exit(fn ->
        send(ring, {:nodedown, remote, %{}})
      end)

      group_id = conversation_group_owned_by(remote)
      owner_key = "conversation-group:" <> group_id

      assert {:error, {:owner_unreachable, ^owner_key, _reason}} =
               ConversationPlacement.ensure_group_started(group_id, [])

      assert Registry.lookup(
               SalixIM.ConversationRegistry,
               SalixIM.ConversationGroupActor.key(group_id)
             ) == []
    end
  end

  defp build(nodes), do: Enum.reduce(nodes, HashRing.new(), &HashRing.add_node(&2, &1))

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)

  defp agent_owned_by(owner) do
    Enum.find_value(1..10_000, fn _idx ->
      agent_id = SalixAgent.TestSupport.new_agent_id()
      if Ring.owner(agent_id) == owner, do: agent_id
    end) || flunk("no agent id mapped to #{inspect(owner)}")
  end

  defp conversation_owned_by(owner) do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    Enum.find_value(1..10_000, fn _idx ->
      conversation_id = SalixStore.Ids.new_conversation_id()
      if Ring.owner(group_id <> ":" <> conversation_id) == owner, do: {group_id, conversation_id}
    end) || flunk("no conversation id mapped to #{inspect(owner)}")
  end

  defp conversation_group_owned_by(owner) do
    Enum.find_value(1..10_000, fn _idx ->
      tenant_id = SalixStore.Ids.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)

      if Ring.owner("conversation-group:" <> group_id) == owner, do: group_id
    end) || flunk("no conversation group id mapped to #{inspect(owner)}")
  end
end
