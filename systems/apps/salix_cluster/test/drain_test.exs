defmodule SalixCluster.DrainTest do
  @moduledoc """
  Graceful node drain: every local Server
  stops, its lease is explicitly released (head CAS clears owner; the
  `ctl/leases/` index entry is deleted), and a post-drain delivery re-claims
  the agent from the released state. Run against the Fake backend.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Agent, Keys, S3}
  alias SalixCluster.Drain
  alias SalixAgent.{Fleet, Server}
  alias SalixAgent.LLM.Mock

  defmodule LocalRing do
    @moduledoc false
    def owner(_agent_id), do: Node.self()
    def nodes, do: [Node.self()]
  end

  defmodule FakeAttachments do
    @moduledoc false
    def stop_all, do: %{completed: 2, timeout: 0, error: 0, errors: []}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixCluster.NodeLifecycle.reset()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SalixCluster.NodeLifecycle.reset()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
    end)

    :ok
  end

  test "drain stops every local agent, clears each head's lease, and frees the lease index" do
    agents = for _ <- 1..3, do: SalixAgent.TestSupport.new_agent_id()
    Mock.script(for _ <- agents, do: {:final, "parked reply"})

    for a <- agents do
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "hi", session_id: "ses1_1200000000000000001"},
                 source_message_id: "drain-hi-#{a}"
               )
    end

    # The root Server parks after routing work; the per-session actor owns the
    # actual round. Drain only after the session itself has left active work so
    # the test does not intentionally kill an in-flight session actor.
    assert eventually(fn ->
             Enum.all?(agents, fn agent ->
               parked?(agent) and session_has_content?(agent, "parked reply") and
                 internal_sessions_settled?(agent)
             end)
           end)

    assert {:ok, %{drained: drained, handed_off: 0, failed: []}} = Drain.drain(ring: LocalRing)
    assert Enum.sort(drained) == Enum.sort(agents)

    # The Server's default node_id is to_string(node()) — the lease index entry
    # was written under that node string.
    node_id = to_string(node())

    for a <- agents do
      assert eventually(fn -> not Fleet.running?(a) end)

      # Root CAS cleared the owner: the agent is pure S3 objects now.
      assert {:ok, head} = Agent.peek(a)
      assert head.owner_node == nil
      assert head.lease_until == nil

      # ctl/leases/{node}/{agent} entry deleted.
      assert {:error, :not_found} = S3.head(Keys.lease(node_id, a))
    end
  end

  test "a post-drain delivery re-claims the released agent end-to-end" do
    a = SalixAgent.TestSupport.new_agent_id()
    Mock.script([{:final, "first reply"}])

    SalixAgent.TestSupport.create_control_agent!(a)

    assert {:ok, :created} =
             SalixAgent.deliver(a, %{content: "hello", session_id: "ses1_1200000000000000001"},
               source_message_id: "drain-hello-#{a}"
             )

    assert eventually(fn ->
             parked?(a) and session_has_content?(a, "first reply") and
               internal_sessions_settled?(a)
           end)

    assert {:ok, %{drained: [^a], handed_off: 0, failed: []}} = Drain.drain(ring: LocalRing)
    assert eventually(fn -> not Fleet.running?(a) end)

    # The released head is claimable again: a fresh delivery starts a new
    # Server, which steals/claims and runs a round to completion.
    Mock.script([{:final, "after drain"}])

    assert {:ok, :created} =
             SalixAgent.deliver(a, %{content: "again", session_id: "ses1_1200000000000000001"},
               source_message_id: "drain-again-#{a}"
             )

    assert eventually(
             fn ->
               case SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001") do
                 {:ok, %{messages: [_ | _] = msgs}} -> List.last(msgs).content == "after drain"
                 _ -> false
               end
             end,
             200
           )

    {:ok, session} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
    assert Enum.any?(session.messages, &(&1.content == "again"))
  end

  test "drain with no local agents returns zeros" do
    # Earlier tests' agents may re-spawn from late wake casts racing the first
    # drain — drain until convergence, then the steady state must be zeros.
    assert eventually(fn ->
             {:ok, %{drained: drained}} = Drain.drain(ring: LocalRing)
             drained == []
           end)

    assert {:ok, %{drained: [], handed_off: 0, failed: []}} = Drain.drain(ring: LocalRing)
  end

  test "drain marks node draining and includes VM cleanup summaries" do
    refute SalixCluster.NodeLifecycle.draining?()

    assert {:ok,
            %{
              drained: [],
              handed_off: 0,
              failed: [],
              agents: %{completed: 0, timeout: 0, error: 0},
              sessions: %{completed: 0, timeout: 0, error: 0},
              attachments: %{completed: 2, timeout: 0, error: 0}
            }} =
             Drain.drain(
               ring: LocalRing,
               attachments_mod: FakeAttachments
             )

    assert SalixCluster.NodeLifecycle.draining?()
    assert {:error, :draining} = SalixCluster.NodeLifecycle.readiness()
  end

  test "handoff: false drains without consulting the ring" do
    a = SalixAgent.TestSupport.new_agent_id()
    Mock.script([{:final, "ok"}])

    SalixAgent.TestSupport.create_control_agent!(a)

    assert {:ok, :created} =
             SalixAgent.deliver(a, %{content: "hi", session_id: "ses1_1200000000000000001"},
               source_message_id: "drain-hi-#{a}"
             )

    assert eventually(fn ->
             parked?(a) and session_has_content?(a, "ok") and internal_sessions_settled?(a)
           end)

    # No ring module needed at all when handoff is disabled.
    assert {:ok, %{drained: [^a], handed_off: 0, failed: []}} =
             Drain.drain(handoff: false, ring: :no_ring_module)

    assert eventually(fn -> not Fleet.running?(a) end)
  end

  # ---- helpers ----

  defp parked?(agent_id) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] ->
        try do
          match?({:parked, _owned}, Server.info(pid))
        catch
          :exit, _ -> false
        end

      [] ->
        false
    end
  end

  defp internal_sessions_settled?(agent_id) do
    case SalixAgent.InternalSessionStore.list(agent_id) do
      {:ok, [_ | _] = sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.get(&1, :status) not in [:queued, :active])
        )

      _ ->
        false
    end
  end

  defp session_has_content?(agent_id, content) do
    case SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_1200000000000000001") do
      {:ok, %{messages: messages}} -> Enum.any?(messages, &(&1.content == content))
      _ -> false
    end
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
