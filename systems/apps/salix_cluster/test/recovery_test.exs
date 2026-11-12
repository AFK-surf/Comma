defmodule SalixCluster.RecoveryTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Cluster recovery covers the singleton lease, committed PG due work,
  and connector cleanup. Providers and object storage use local doubles.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixCluster"]

  alias SalixStore.{
    Keys,
    S3
  }

  alias SalixCluster.{S3Lease, Recovery}

  alias SalixAgent.{
    Fleet,
    InternalSession,
    InternalSessionStore,
    SessionWorkRecovery
  }

  alias SalixAgent.LLM.Mock
  alias SalixStore.Ids

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    SalixStore.Repo.query!(
      "TRUNCATE local_file_refs, salix_agents, salix_capability_requests CASCADE"
    )

    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_placement = SystemsRuntime.get_env(:salix_agent, :placement)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      SystemsRuntime.put_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defmodule SlowSessionRecoveryServer do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:recover_session_work, targets}, _from, owner) do
      SystemsRuntime.Proc.send(owner, {:slow_session_recovery_started, targets})
      SystemsClock.sleep(300)
      {:reply, :ok, owner}
    end
  end

  defmodule SlowSessionRecoveryPlacement do
    @behaviour SalixAgent.Placement

    def configure(server, owner) do
      SystemsRuntime.PersistentTerm.put({__MODULE__, :server}, server)
      SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, owner)
    end

    def clear do
      SystemsRuntime.PersistentTerm.erase({__MODULE__, :server})
      SystemsRuntime.PersistentTerm.erase({__MODULE__, :owner})
    end

    @impl true
    def ensure_started(agent_id, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:slow_session_placement, agent_id, opts}
      )

      {:ok, SystemsRuntime.PersistentTerm.get({__MODULE__, :server})}
    end

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  describe "S3 singleton lease" do
    test "acquire is exclusive; stale leases are stealable; renew/release work" do
      t0 = 1_000_000
      assert {:ok, token_a} = S3Lease.acquire(:recovery, "node-a", now: t0, ttl_ms: 30_000)

      # another node can't take it while valid
      assert {:error, {:held_by, "node-a", _}} =
               S3Lease.acquire(:recovery, "node-b", now: t0 + 10_000, ttl_ms: 30_000)

      # holder can renew
      assert {:ok, token_a} = S3Lease.renew(token_a, now: t0 + 15_000, ttl_ms: 30_000)

      # after expiry (past the renewed lease), node-b steals
      assert {:ok, _token_b} =
               S3Lease.acquire(:recovery, "node-b", now: t0 + 50_000, ttl_ms: 30_000)

      # node-a's stale token can no longer renew (fail-closed)
      assert {:error, :lost} = S3Lease.renew(token_a, now: t0 + 51_000)
    end
  end

  # The "queue sweep re-homes stranded agents" describe retired with the
  # queue-marker lane and the staged protocol it recovered (A2 §3.4):
  # deliveries commit into session ledgers at deliver time, and lost wakes
  # are rediscovered through the committed PG due rows, which the
  # rest of this file covers exhaustively.

  describe "committed Session due work" do
    test "a slow session wake does not block the Recovery lease cadence", %{agent: a} do
      session_id = "ses1_1200000000000000024"

      create_owned_control!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "slow-session-recovery",
                   "created_at" => SystemsClock.system_time(:second),
                   "payload" => %{
                     "source_message_id" => "slow-session-recovery",
                     "role" => "user",
                     "content" => "continue after recovery"
                   }
                 }
               ])

      slow_server = start_supervised!({SlowSessionRecoveryServer, SystemsRuntime.Proc.self()})
      SlowSessionRecoveryPlacement.configure(slow_server, SystemsRuntime.Proc.self())
      SystemsRuntime.put_env(:salix_agent, :placement, SlowSessionRecoveryPlacement)
      on_exit(&SlowSessionRecoveryPlacement.clear/0)

      recovery_worker = :slow_session_work_recovery_test
      start_supervised!({SessionWorkRecovery, name: recovery_worker})

      S3.Fake.reset_put_log()

      start_supervised!(
        {Recovery,
         name: :recovery_slow_session_test,
         interval_ms: 25,
         session_work_recovery: recovery_worker}
      )

      settle_receive({:slow_session_recovery_started, [_target]})
      settle_receive({:slow_session_placement, ^a, [create: false]})
      lease_key = Keys.singleton(:recovery)

      # Each tick requests the wake before it takes the lease, so the wake can
      # start first.
      lease_writes_before =
        eventually(fn ->
          count = Enum.count(S3.Fake.put_log(), &(&1 == lease_key))
          count >= 1 && count
        end)

      # Recovery owns the singleton lease. A slow domain wake must not keep the
      # scheduler from renewing that lease and running the next correctness pass.
      # The wake stays blocked for 300 ms, far longer than this poll needs.
      assert eventually(fn ->
               Enum.count(S3.Fake.put_log(), &(&1 == lease_key)) > lease_writes_before
             end)
    end

    test "a missing session-work worker does not stop the Recovery cadence" do
      pid =
        start_supervised!(
          {Recovery,
           name: :recovery_missing_session_worker_test,
           interval_ms: 25,
           session_work_recovery: :missing_session_work_recovery_test}
        )

      assert eventually(fn -> :sys.get_state(pid, :infinity).tick_count >= 3 end)
      assert SystemsRuntime.Proc.alive?(pid)
    end

    test "a post-LISTEN catch-up requests the lease holder's worker immediately" do
      owner = SystemsRuntime.Proc.self()

      sweep_fn = fn opts ->
        SystemsRuntime.Proc.send(
          owner,
          {:notification_catch_up_sweep, SystemsRuntime.Proc.self(), opts}
        )

        SessionWorkRecovery.empty_summary()
      end

      recovery_worker = :notification_catch_up_session_work_test

      worker =
        start_supervised!({SessionWorkRecovery, name: recovery_worker, sweep_fn: sweep_fn})

      recovery =
        start_supervised!(
          {Recovery,
           name: :notification_catch_up_recovery_test,
           interval_ms: 60_000,
           session_work_recovery: recovery_worker}
        )

      # The initial lease tick owns the ordinary periodic request. Wait until
      # that task is fully retired so the listener-triggered request cannot be
      # mistaken for coalescing with startup work.
      settle_receive({:notification_catch_up_sweep, _task, _opts})
      assert eventually(fn -> :sys.get_state(worker, :infinity).task == nil end)

      assert :ok = Recovery.request_session_work_catchup(recovery)
      settle_receive({:notification_catch_up_sweep, _task, _opts})
    end

    test "non-stable session work resumes without an agent queue marker or later traffic", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000002"
      Mock.script([{:final, "continued without another user message"}])
      create_owned_control!(a)

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "passivated-session-work",
            "created_at" => SystemsClock.system_time(:second),
            "payload" => %{
              "source_message_id" => "passivated-session-work",
              "role" => "user",
              "content" => "continue this task"
            }
          }
        ])

      assert "unacked_queue_item" in InternalSession.work_reasons(session)
      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(fn -> session_has_content?(a, session_id, "continue this task") end, 1500)

      assert eventually(
               fn ->
                 session_has_content?(
                   a,
                   session_id,
                   "continued without another user message"
                 )
               end,
               1500
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 1500)
    end

    test "a dormant worker resumes the transcript after a committed tool result", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000017"
      Mock.script([{:final, "continued after the dormant tool result"}])
      create_owned_control!(a)

      {:ok, session} =
        InternalSessionStore.prepare_commit(
          a,
          session_id,
          [
            %{"type" => "session_created", "session_id" => session_id},
            %{
              "type" => "assistant",
              "session_id" => session_id,
              "message_id" => 1,
              "content" => "",
              "tool_calls" => [
                %{
                  "id" => "publish-result",
                  "name" => "call",
                  "args" => %{
                    "tool" => "preview.publish_html",
                    "params" => %{"site_name" => "snake"}
                  }
                }
              ]
            },
            %{
              "type" => "tool_result",
              "session_id" => session_id,
              "message_id" => 2,
              "tool_call_id" => "publish-result",
              "content" => "https://snake.salix.localhost"
            },
            %{"type" => "status", "session_id" => session_id, "status" => "idle"}
          ],
          hwm: 2
        )

      assert InternalSession.work_reasons(session) == [
               "transcript_continuation"
             ]

      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(
               fn ->
                 session_has_content?(a, session_id, "continued after the dormant tool result")
               end,
               1500
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 1500)

      {:ok, recovered} = InternalSessionStore.read(a, session_id)

      assert Enum.count(
               InternalSession.get(recovered, :messages),
               &(&1.content == "continued after the dormant tool result")
             ) == 1

      assert List.last(InternalSession.get(recovered, :messages)).content ==
               "continued after the dormant tool result"

      tool_result_index =
        Enum.find_index(
          InternalSession.get(recovered, :messages),
          &(&1.role == "tool" and &1.tool_call_id == "publish-result")
        )

      continuation_index =
        Enum.find_index(
          InternalSession.get(recovered, :messages),
          &(&1.role == "assistant" and
              &1.content == "continued after the dormant tool result")
        )

      assert is_integer(tool_result_index)
      assert is_integer(continuation_index)
      assert tool_result_index < continuation_index
    end

    test "recovery nudges a live parked AgentServer when the immediate session wake was lost", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000003"
      Mock.script([{:final, "parked owner recovered the session"}])
      create_owned_control!(a)

      {:ok, pid} = Fleet.ensure_started(a, create: false)
      assert {:parked, _owned} = SalixAgent.Server.info(pid)

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "parked-owner-session-work",
            "created_at" => SystemsClock.system_time(:second),
            "payload" => %{
              "source_message_id" => "parked-owner-session-work",
              "role" => "user",
              "content" => "wake the already-running owner"
            }
          }
        ])

      assert Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(
               fn -> session_has_content?(a, session_id, "wake the already-running owner") end,
               1500
             )

      assert eventually(
               fn ->
                 session_has_content?(a, session_id, "parked owner recovered the session")
               end,
               1500
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 1500)
    end

    test "a future wait keeps a deadline backstop without waking on every sweep", %{agent: a} do
      session_id = "ses1_1200000000000000004"
      wait_id = "future-wait"
      deadline_ms = SystemsClock.system_time(:millisecond) + 60_000
      create_owned_control!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "wait_set",
            "session_id" => session_id,
            "wait" => %{
              "wait_id" => wait_id,
              "reason" => "recovery must preserve the future deadline",
              "deadline_ms" => deadline_ms
            }
          }
        ])

      assert InternalSession.work_reasons(session) == ["wait_deadline"]

      assert %{rows: [[at]]} =
               SalixStore.Repo.query!(
                 "SELECT next_run_at FROM salix_sessions WHERE agent_id=$1 AND session_id=$2",
                 [a, session_id]
               )

      assert DateTime.to_unix(at, :millisecond) == deadline_ms
      refute Fleet.running?(a)
      assert %{rewoken: [], scanned: 0} = SessionWorkRecovery.sweep()
      refute Fleet.running?(a)
    end

    test "a malformed wait is rejected without creating a cold-recovery wake loop", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000012"
      create_owned_control!(a)

      assert {:error, :invalid_wait} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "wait_set",
                   "session_id" => session_id,
                   "wait" => %{
                     "wait_id" => "invalid-deadline",
                     "deadline_ms" => "later"
                   }
                 }
               ])

      assert {:error, :not_found} = InternalSessionStore.read(a, session_id)

      refute Fleet.running?(a)

      for _pass <- 1..2 do
        assert {:ok, %{session_work_rewoken: [], session_work_scanned: 0}} =
                 Recovery.sweep_once()

        refute Fleet.running?(a)
      end
    end

    test "an overdue wait without a timer resumes after full cold recovery", %{agent: a} do
      session_id = "ses1_1200000000000000009"
      Mock.script([{:final, "resumed after overdue wait"}])
      create_owned_control!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "wait_set",
            "session_id" => session_id,
            "wait" => %{
              "wait_id" => "overdue-wait",
              "reason" => "deadline elapsed while the runtime was asleep",
              "deadline_ms" => SystemsClock.system_time(:millisecond) - 600_000
            }
          }
        ])

      assert InternalSession.work_reasons(session) == ["wait_deadline"]

      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(
               fn -> session_has_content?(a, session_id, "resumed after overdue wait") end,
               1500
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 1500)

      {:ok, recovered} = InternalSessionStore.read(a, session_id)
      assert InternalSession.wait(recovered) == nil
      assert session_source_count(a, session_id, "wait-timeout:#{session_id}:overdue-wait") == 1
    end
  end

  # The recent-touch de-strand lane retired with the staged protocol (A2 §3.4).

  defmodule PausingRootMarkerListS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @root SalixStore.Keys.connector_runs_by_node_all_prefix()

    @impl true
    def list(prefix, opts) do
      result = SalixStore.S3.Fake.list(prefix, opts)

      if prefix == @root do
        owner = SystemsRuntime.fetch_env!(:salix_cluster, :recovery_pause_test_pid)
        SystemsRuntime.Proc.send(owner, {:root_snapshot_taken, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :resume -> :ok
        end
      end

      result
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake
    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake
    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake
    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  describe "connector env sweep (§5.5)" do
    test "marks connected envs on dead nodes disconnected; spares live ones" do
      live = "live-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      dead = "dead-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env_live = connect_device(live, "l")
      env_dead = connect_device(dead, "d")

      # Only `live` is a live peer; `dead` is not → its env is swept.
      disconnected = Recovery.sweep_envs(live_nodes: [live])

      assert env_dead.run_id in disconnected
      refute env_live.run_id in disconnected
      assert {:ok, %{"status" => "disconnected"}} = get_device(env_dead)
      assert {:ok, %{"status" => "connected"}} = get_device(env_live)
    end

    test "does not disconnect an env that reconnected away from a dead node" do
      dead = "dead-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      live = "live-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env = connect_device(dead, "laptop")
      transport_id = env.transport_id

      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(live, env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2

      disconnected = Recovery.sweep_envs(live_nodes: [live])

      refute reconnected["connector_run_id"] in disconnected
      assert {:ok, %{"status" => "connected", "node" => ^live}} = get_device(env)
    end

    test "flips aged connected records on a live node with no socket owner" do
      now = SystemsClock.system_time(:millisecond)
      me = to_string(node())

      # Crash-skipped-terminate leftover: connected, owned by THIS (live)
      # node, old, but nobody is registered in the local bridge registry.
      stale = connect_device(me, "s", now: now - 120_000)

      # Same shape but fresh: inside the registration grace window — kept.
      fresh = connect_device(me, "f", now: now)

      # Aged + ownerless but with a REAL local socket owner — kept.
      owned = connect_device(me, "o", now: now - 120_000)
      :ok = SalixEnv.Bridge.register_owner(owned.transport_id)

      disconnected = Recovery.sweep_envs(live_nodes: [me], now: now)

      assert stale.run_id in disconnected
      refute fresh.run_id in disconnected
      refute owned.run_id in disconnected
      assert {:ok, %{"status" => "disconnected"}} = get_device(stale)
      assert {:ok, %{"status" => "connected"}} = get_device(fresh)
      assert {:ok, %{"status" => "connected"}} = get_device(owned)
    end

    test "fast path (deep: false) sweeps dead-node markers without touching live records" do
      live = "live-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      dead = "dead-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env_live = connect_device(live, "l")
      env_dead = connect_device(dead, "d")

      disconnected = Recovery.sweep_envs(live_nodes: [live], deep: false)

      assert env_dead.run_id in disconnected
      refute env_live.run_id in disconnected
      assert {:ok, %{"status" => "disconnected"}} = get_device(env_dead)
      assert {:ok, %{"status" => "connected"}} = get_device(env_live)
    end

    test "the ownerless deep check runs only on the deep pass" do
      now = SystemsClock.system_time(:millisecond)
      me = to_string(node())

      # Aged, live-owner, no socket owner: only the authoritative-record scan
      # can see this shape — the fast path must skip it (that is what makes
      # 5 of 6 ticks cheap), the deep pass must flip it.
      stale = connect_device(me, "s", now: now - 120_000)

      assert [] == Recovery.sweep_envs(live_nodes: [me], now: now, deep: false)
      assert {:ok, %{"status" => "connected"}} = get_device(stale)

      deep = Recovery.sweep_envs(live_nodes: [me], now: now)
      assert stale.run_id in deep
      assert {:ok, %{"status" => "disconnected"}} = get_device(stale)
    end

    test "the deep pass prunes by-node markers whose run record is gone" do
      node_name = "gone-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env = connect_device(node_name, "g")

      # Deletion residue: the cleanup deleted the authoritative record but
      # lost the marker delete. Without reconciliation this leaks forever.
      :ok = SalixStore.S3.delete(SalixStore.Keys.connector_run(env.run_id))
      marker_key = SalixStore.Keys.connector_run_by_node(node_name, env.run_id)
      assert {:ok, _} = SalixStore.S3.head(marker_key)

      _ = Recovery.sweep_envs(live_nodes: [to_string(node())])

      assert {:error, :not_found} = SalixStore.S3.head(marker_key)
    end

    test "a run whose by-node marker never landed is still swept by the deep pass" do
      # The index may lie in the other direction too (connect wrote the record
      # but the marker PUT failed): the fast path cannot see this run, so the
      # deep pass is the correctness backstop.
      dead = "dead-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env = connect_device(dead, "m")
      :ok = SalixStore.S3.delete(SalixStore.Keys.connector_run_by_node(dead, env.run_id))

      assert [] == Recovery.sweep_envs(live_nodes: [to_string(node())], deep: false)
      assert {:ok, %{"status" => "connected"}} = get_device(env)

      deep = Recovery.sweep_envs(live_nodes: [to_string(node())])
      assert env.run_id in deep
      assert {:ok, %{"status" => "disconnected"}} = get_device(env)
    end

    test "a healthy reconnect born after the marker snapshot survives the fast sweep" do
      # Reviewer repro: the sweep snapshots the by-node index, the "dead" node
      # rejoins under the SAME name and the same stable device reconnects
      # (generation 2, old run retired), then the sweep resumes with its stale
      # dead-node decision. Destructive action must be confined to the
      # snapshotted run ids — the fresh generation stays connected.
      node_name = "rejoin-race-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env = connect_device(node_name, "r")
      transport_id = env.transport_id

      SystemsRuntime.put_env(:salix_cluster, :recovery_pause_test_pid, SystemsRuntime.Proc.self())
      SystemsRuntime.put_env(:salix_store, :s3_backend, PausingRootMarkerListS3)

      on_exit(fn ->
        SystemsRuntime.delete_env(:salix_cluster, :recovery_pause_test_pid)
      end)

      sweep =
        SystemsRuntime.Task.async(fn ->
          Recovery.sweep_envs(live_nodes: ["somewhere-else"], deep: false)
        end)

      settle_receive({:root_snapshot_taken, lister})
      # The node "rejoins": same node name, same device, new generation.
      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(node_name, env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2
      new_run_id = reconnected["connector_run_id"]

      SystemsRuntime.Proc.send(lister, :resume)
      disconnected = settled_await(sweep)

      # The stale snapshotted run resolves to nothing (retired) — no-op; the
      # post-snapshot healthy generation is untouched.
      refute new_run_id in disconnected
      assert {:ok, %{"status" => "connected", "connection_generation" => 2}} = get_device(env)
    end

    test "a post-snapshot same-name rejoin survives the DEEP pass (fresh-liveness gate)" do
      # Round-2 repro: the deep pass lists the authoritative records AFTER
      # the liveness snapshot, so a node that rejoined in between presents
      # its healthy generation 2 to the stale live-set — the owner/generation
      # fence alone would approve the teardown. The destructive-action gate
      # re-takes liveness immediately before each disconnect; the rejoined
      # node is alive there, so generation 2 must survive.
      node_name = "deep-rejoin-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env = connect_device(node_name, "dr")
      transport_id = env.transport_id

      # Liveness that CHANGES mid-sweep: dead at the snapshot, alive at the
      # gate (flipped by the test during the pause window below).
      liveness = :ets.new(:liveness, [:public])
      :ets.insert(liveness, {:live, ["somewhere-else"]})

      live_fun = fn ->
        [{:live, nodes}] = :ets.lookup(liveness, :live)
        nodes
      end

      SystemsRuntime.put_env(:salix_cluster, :recovery_pause_test_pid, SystemsRuntime.Proc.self())
      SystemsRuntime.put_env(:salix_store, :s3_backend, PausingRootMarkerListS3)

      on_exit(fn ->
        SystemsRuntime.delete_env(:salix_cluster, :recovery_pause_test_pid)
      end)

      sweep = SystemsRuntime.Task.async(fn -> Recovery.sweep_envs(live_nodes: live_fun) end)

      settle_receive({:root_snapshot_taken, lister})
      # The node rejoins: same name, same device, generation 2 — and the
      # cluster now sees it as live again.
      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(node_name, env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2
      new_run_id = reconnected["connector_run_id"]
      :ets.insert(liveness, {:live, ["somewhere-else", node_name]})

      SystemsRuntime.Proc.send(lister, :resume)
      disconnected = settled_await(sweep)

      refute new_run_id in disconnected
      assert {:ok, %{"status" => "connected", "connection_generation" => 2}} = get_device(env)
    end

    test "the first production tick (deep) leaves a mid-sweep reconnect onto a live node alone" do
      # The GenServer's first held tick runs deep semantics. A device whose
      # run migrates onto a live node during the pause window is observed by
      # the deep authoritative LIST with a live owner — nothing may touch it.
      dead = "first-tick-dead-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      env = connect_device(dead, "ft")
      transport_id = env.transport_id

      SystemsRuntime.put_env(:salix_cluster, :recovery_pause_test_pid, SystemsRuntime.Proc.self())
      SystemsRuntime.put_env(:salix_store, :s3_backend, PausingRootMarkerListS3)

      on_exit(fn ->
        SystemsRuntime.delete_env(:salix_cluster, :recovery_pause_test_pid)
      end)

      # Drive the exact production entry: sweep_once with deep defaults, as
      # the first held tick issues it.
      sweep =
        SystemsRuntime.Task.async(fn -> Recovery.sweep_once(live_nodes: [to_string(node())]) end)

      settle_receive({:root_snapshot_taken, lister})
      # Mid-sweep the device reconnects onto THIS (live) node.
      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(to_string(node()), env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2

      SystemsRuntime.Proc.send(lister, :resume)
      {:ok, %{env_disconnected: disconnected}} = settled_await(sweep)

      refute reconnected["connector_run_id"] in disconnected

      assert {:ok, %{"status" => "connected", "connection_generation" => 2}} =
               get_device(env)
    end

    test "sweep_once includes env_disconnected in its summary" do
      env = connect_device("ghost-node", "g")

      {:ok, summary} = Recovery.sweep_once(live_nodes: [to_string(node())])
      assert env.run_id in summary.env_disconnected
    end

    test "sweep_once purges expired OAuth auth states (willow PurgeExpiredOAuthAuthStates)" do
      alias SalixStore.OAuth.AuthState

      now = SystemsClock.system_time(:millisecond)

      base = %{
        "tenant" => "t1",
        "group_id" => "g1",
        "provider" => "github",
        "alias" => "work",
        "scopes" => [],
        "code_verifier" => "v",
        "redirect_uri" => "http://localhost/cb",
        "origin" => "agent",
        "status" => "pending",
        "created_at" => now
      }

      # The purge prefilters on LIST metadata (objects younger than one TTL
      # are deferred without a read), and these fixtures are written by the
      # test itself — so sweep from a vantage one TTL later, with the fresh
      # record's expiry pushed beyond that vantage.
      sweep_now = now + 11 * 60 * 1000

      # One long-expired pending state, one still-fresh one.
      :ok =
        AuthState.create(Map.merge(base, %{"state" => "stale-1", "expires_at" => now - 60_000}))

      :ok =
        AuthState.create(
          Map.merge(base, %{"state" => "fresh-1", "expires_at" => now + 2 * 60 * 60 * 1000})
        )

      assert {:ok, %{oauth_states_purged: 1}} = Recovery.sweep_once(now: sweep_now)

      assert {:error, :not_found} = AuthState.get("stale-1")
      assert {:ok, %{"state" => "fresh-1"}} = AuthState.get("fresh-1")

      # Idempotent: nothing left to purge on the next pass.
      assert {:ok, %{oauth_states_purged: 0}} = Recovery.sweep_once(now: sweep_now)
    end

    test "sweep_once performs bounded local-file ref expiry cleanup" do
      alias SalixStore.LocalFileRefs

      now = SystemsClock.system_time(:millisecond)
      ref = "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

      assert {:ok, _} =
               LocalFileRefs.insert_registration(%{
                 "version" => 1,
                 "local_file_ref" => ref,
                 "tenant_id" => "tnt1_recovery",
                 "group_id" => "grp1_recovery",
                 "owner_user_id" => "user_recovery",
                 "stable_device_id" => "dev_recovery",
                 "state" => "registered",
                 "created_at" => now - 2,
                 "expires_at" => now - 1
               })

      assert {:ok, %{local_file_refs_cleaned: 0}} =
               Recovery.sweep_once(now: now, local_file_ref_cleanup: false)

      assert {:ok, _} = LocalFileRefs.get(ref)

      assert {:ok, %{local_file_refs_cleaned: 1}} = Recovery.sweep_once(now: now)

      assert {:ok,
              %{
                "state" => "retired",
                "tenant_id" => "",
                "group_id" => "",
                "owner_user_id" => "",
                "stable_device_id" => ""
              }} = LocalFileRefs.get(ref)

      assert {:error, :local_file_ref_conflict} =
               LocalFileRefs.insert_registration(%{
                 "version" => 1,
                 "local_file_ref" => ref,
                 "tenant_id" => "tnt1_recovery",
                 "group_id" => "grp1_recovery",
                 "owner_user_id" => "user_recovery",
                 "stable_device_id" => "dev_recovery",
                 "state" => "registered",
                 "created_at" => now,
                 "expires_at" => now + 60_000
               })
    end
  end

  # The recent-touch prune cadence retired with the recent-touch store (A2 §3.4).

  describe "oauth auth-state purge cadence" do
    test "sweep_once gates the purge behind :oauth_purge" do
      now = SystemsClock.system_time(:millisecond)
      state_id = "recovery-cadence-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      :ok =
        SalixStore.OAuth.AuthState.create(%{
          "state" => state_id,
          "tenant" => "default",
          "group_id" => "group-1",
          "provider" => "github",
          "alias" => "work",
          "expires_at" => now - 1000
        })

      # One TTL in the future so the LIST-metadata prefilter ages the object
      # out of its deferral window and only the cadence gate is under test.
      future = now + 11 * 60 * 1000

      # Off-cadence tick: the purge must not run at all.
      assert {:ok, %{oauth_states_purged: 0}} =
               Recovery.sweep_once(now: future, oauth_purge: false)

      assert {:ok, _record} = SalixStore.OAuth.AuthState.get(state_id)

      # Default (direct callers / on-cadence tick): the purge runs.
      assert {:ok, %{oauth_states_purged: purged}} = Recovery.sweep_once(now: future)
      assert purged >= 1
      assert {:error, :not_found} = SalixStore.OAuth.AuthState.get(state_id)
    end
  end

  defp fetch_session(a, s) do
    case SalixAgent.InternalSessionStore.read(a, s) do
      {:ok, session} -> {:ok, %{messages: InternalSession.get(session, :messages)}}
      other -> other
    end
  end

  defp internal_sessions_settled?(agent_id) do
    case SalixAgent.InternalSessionStore.list(agent_id) do
      {:ok, [_ | _] = sessions} ->
        Enum.all?(sessions, &(InternalSession.status(&1) not in [:queued, :active]))

      _ ->
        false
    end
  end

  defp session_has_content?(agent_id, session_id, content) do
    case fetch_session(agent_id, session_id) do
      {:ok, %{messages: messages}} -> Enum.any?(messages, &(&1.content == content))
      _ -> false
    end
  end

  defp session_source_count(agent_id, session_id, source_id) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.count(InternalSession.get(session, :messages), fn message ->
          (message[:source_message_id] || message["source_message_id"] ||
             message[:runtime_message_id] || message["runtime_message_id"]) == source_id
        end)

      {:error, _reason} ->
        0
    end
  end

  defp connect_device(owner_node, name, opts \\ []) do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    device_id = Ids.new_device_id()
    transport_id = "transport-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    meta = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "device_id" => device_id,
      "connector_id" => "connector-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      "name" => name
    }

    {:ok, ^transport_id, device} =
      SalixEnv.Registry.connect(owner_node, meta, Keyword.put(opts, :transport_id, transport_id))

    %{
      tenant_id: tenant_id,
      group_id: group_id,
      device_id: device_id,
      transport_id: transport_id,
      run_id: device["connector_run_id"],
      meta: meta
    }
  end

  defp get_device(device) do
    SalixEnv.Registry.get_device(device.tenant_id, device.group_id, device.device_id)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp create_owned_control!(agent) do
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, owned} = SalixStore.Agent.claim(agent, to_string(node()), SalixAgent.State)
    :ok = SalixAgent.OwnershipCell.install(agent, owned.epoch)
    owned
  end

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
