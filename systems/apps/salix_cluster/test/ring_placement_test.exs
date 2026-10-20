defmodule SalixCluster.RingPlacementTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Placement ring: consistent-hash ownership properties, the Ring
  GenServer on a single node, and local placement routing.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
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
  end

  describe "placement routing (local)" do
    setup do
      SalixAgent.TestSupport.stop_all_agents()
      prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
      prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
      SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      start_supervised!(SalixStore.S3.Fake)

      on_exit(fn ->
        SalixAgent.TestSupport.stop_all_agents()
        SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
        put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      end)

      :ok
    end

    test "owner == self routes to local Fleet and starts a Server" do
      a = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, pid} = Placement.ensure_started(a, create: false)
      assert SystemsRuntime.Proc.is_process(pid)
      assert node(pid) == Node.self()
      assert SalixAgent.Fleet.running?(a)
    end

    test "unreachable remote owner returns an explicit error instead of starting locally" do
      remote = :"salix-owner-down@127.0.0.1"
      ring = SystemsRuntime.Proc.whereis(Ring)
      SystemsRuntime.Proc.send(ring, {:nodeup, remote, %{}})

      on_exit(fn ->
        SystemsRuntime.Proc.send(ring, {:nodedown, remote, %{}})
      end)

      agent_id = agent_owned_by(remote)
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      assert {:error, {:owner_unreachable, ^remote, _reason}} =
               Placement.ensure_started(agent_id, create: false)

      refute SalixAgent.Fleet.running?(agent_id)
    end

    test "the session fleet refuses to start session actors on a non-owner node" do
      remote = :"salix-session-owner-down@127.0.0.1"
      ring = SystemsRuntime.Proc.whereis(Ring)
      SystemsRuntime.Proc.send(ring, {:nodeup, remote, %{}})

      on_exit(fn ->
        SystemsRuntime.Proc.send(ring, {:nodedown, remote, %{}})
      end)

      agent_id = agent_owned_by(remote)
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      assert {:error, {:owner_unreachable, ^remote, _reason}} =
               SalixAgent.InternalSessionFleet.ensure_started(
                 agent_id,
                 "ses1_1200000000000000001"
               )

      assert Registry.lookup(
               SalixAgent.Registry,
               SalixAgent.InternalSessionActor.key(agent_id, "ses1_1200000000000000001")
             ) == []
    end

    test "a live lease holder wins after the ring remaps the agent" do
      remote = :"salix-replacement@127.0.0.1"
      ring = SystemsRuntime.Proc.whereis(Ring)
      SystemsRuntime.Proc.send(ring, {:nodeup, remote, %{}})
      on_exit(fn -> SystemsRuntime.Proc.send(ring, {:nodedown, remote, %{}}) end)

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

    test "conversation placement starts the local owner for a conversation key" do
      tenant_id = SalixStore.Ids.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)
      conversation_id = SalixStore.Ids.new_conversation_id()

      assert {:ok, pid} = ConversationPlacement.ensure_started(group_id, conversation_id, [])
      assert SystemsRuntime.Proc.is_process(pid)
      assert node(pid) == Node.self()
      assert SalixIM.ConversationFleet.running?(group_id, conversation_id)

      :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)
    end

    # Rolling-release regression: owners and subscribers attached while this
    # node owned a key must not stay here after the ring moves the key.
    test "a ring change releases local owners the ring moved and their subscribers" do
      remote = :"salix-conversation-owner-moved@127.0.0.1"
      ring = SystemsRuntime.Proc.whereis(Ring)
      nodes = [Node.self(), remote]
      moved_group_id = conversation_group_placed_by(nodes, remote)
      kept_group_id = conversation_group_placed_by(nodes, Node.self())
      {group_id, conversation_id} = conversation_placed_by(nodes, remote)
      participant_id = SalixStore.Ids.new_participant_id()

      assert {:ok, %{"owner_pid" => group_pid, "resync_required" => true}} =
               SalixIM.ConversationServer.subscribe_group_conversation_list(
                 moved_group_id,
                 "agent_task",
                 SystemsRuntime.Proc.self()
               )

      assert {:ok, kept_pid} = ConversationPlacement.ensure_group_started(kept_group_id, [])

      assert {:ok, conversation_pid} =
               ConversationPlacement.ensure_started(group_id, conversation_id, [])

      assert {:ok, participant_pid} =
               SalixIM.ConversationFleet.ensure_participant_started(
                 group_id,
                 conversation_id,
                 participant_id
               )

      moved = [group_pid, conversation_pid, participant_pid]
      refs = Map.new(moved, &{SystemsRuntime.Proc.monitor(&1), &1})

      on_exit(fn ->
        SystemsRuntime.Proc.send(ring, {:nodedown, remote, %{}})
        SalixIM.ConversationFleet.release(kept_pid)
      end)

      # monitor/1 can return before its signal reaches the owner. Each reply
      # confirms that monitor was installed before the Keeper can release it.
      Enum.each(moved, &SystemsRuntime.Server.get_state(&1, :infinity))
      SystemsRuntime.Proc.send(ring, {:nodeup, remote, %{}})

      for _pid <- moved do
        settle_receive({:DOWN, ref, :process, pid, :normal})
        assert refs[ref] == pid
      end

      # Registry unregisters asynchronously; a restarted owner would stay.
      assert eventually(fn -> Enum.all?(moved, &(not registered?(&1))) end)
      assert SystemsRuntime.Proc.alive?(kept_pid)
    end
  end

  defp build(nodes), do: Enum.reduce(nodes, HashRing.new(), &HashRing.add_node(&2, &1))

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp agent_owned_by(owner) do
    Enum.find_value(1..10_000, fn _idx ->
      agent_id = SalixAgent.TestSupport.new_agent_id()
      if Ring.owner(agent_id) == owner, do: agent_id
    end) || flunk("no agent id mapped to #{inspect(owner)}")
  end

  defp registered?(pid), do: Registry.keys(SalixIM.ConversationRegistry, pid) != []

  defp conversation_placed_by(nodes, owner) do
    ring = build(nodes)
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    Enum.find_value(1..10_000, fn _idx ->
      conversation_id = SalixStore.Ids.new_conversation_id()

      if HashRing.key_to_node(ring, group_id <> ":" <> conversation_id) == owner,
        do: {group_id, conversation_id}
    end) || flunk("no conversation id placed on #{inspect(owner)}")
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp conversation_group_placed_by(nodes, owner) do
    ring = build(nodes)

    Enum.find_value(1..10_000, fn _idx ->
      tenant_id = SalixStore.Ids.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)

      if HashRing.key_to_node(ring, "conversation-group:" <> group_id) == owner,
        do: group_id
    end) || flunk("no conversation group id placed on #{inspect(owner)}")
  end
end
