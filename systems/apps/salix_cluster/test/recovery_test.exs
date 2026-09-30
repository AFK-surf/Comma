defmodule SalixCluster.RecoveryTest do
  @moduledoc """
  Cluster recovery covers the S3 singleton lease and the PG candidate
  projection sweeps that make wake hints losable. Run against the Fake.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{
    Codec,
    Keys,
    RuntimeIds,
    S3,
    SessionWorkCandidates,
    SessionWorkBackfillExpectedCandidates,
    Timers
  }

  alias SalixCluster.{S3Lease, Recovery}

  alias SalixAgent.{
    ExternalSessionActor,
    ExternalSessionStore,
    Fleet,
    InternalSession,
    InternalSessionStore,
    SessionWorkBackfill,
    SessionWorkRecovery,
    SessionWorkIndex
  }

  alias SalixAgent.LLM.Mock
  alias SalixStore.Ids

  @device_runtime_id RuntimeIds.device_runtime_id("recovery-device", "codex", "recovery-runtime")

  defmodule RuntimeEnv do
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"],
         "device_id" => "recovery-device",
         "connector_id" => "recovery-connector",
         "connector_run_id" => "recovery-connector-run",
         "runtime_id" => "recovery-runtime",
         "device_runtime_id" => config["device_runtime_id"],
         "command" => "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "status" => "ready",
         "connector_run_id" => "recovery-connector-run",
         "device_runtime_id" => config["device_runtime_id"]
       }}
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    SalixStore.Repo.query!(
      "TRUNCATE local_file_refs, session_work_candidates, session_work_backfill_expected_candidates"
    )

    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_placement = Application.get_env(:salix_agent, :placement)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    prev_external_runtime = Application.get_env(:salix_agent, :external_runtime_driver)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    Application.put_env(:salix_agent, :external_runtime_driver, SalixAgent.ExternalRuntime.None)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
      put_or_delete_env(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
      put_or_delete_env(:salix_agent, :external_runtime_driver, prev_external_runtime)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defmodule PlacementProbe do
    @behaviour SalixAgent.Placement

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def ensure_started(agent_id, opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:recovery_placement, agent_id, opts})
      {:ok, owner}
    end

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  defmodule PassivatingWakeServer do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    # A passivating owner swallows the sweep's re-home wake (Server.wake/1 is
    # a cast) without ever absorbing — the hint is lost, only durability can
    # save the delivery.
    @impl true
    def handle_cast(:wake, state), do: {:noreply, state}
  end

  defmodule PassivatingPlacement do
    @behaviour SalixAgent.Placement

    def set_server(pid), do: :persistent_term.put({__MODULE__, :server}, pid)
    def reset, do: :persistent_term.erase({__MODULE__, :server})

    @impl true
    def ensure_started(_agent_id, _opts),
      do: {:ok, :persistent_term.get({__MODULE__, :server})}

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  defmodule SlowSessionRecoveryServer do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:recover_session_work, targets}, _from, owner) do
      send(owner, {:slow_session_recovery_started, targets})
      Process.sleep(300)
      {:reply, :ok, owner}
    end
  end

  defmodule SlowSessionRecoveryPlacement do
    @behaviour SalixAgent.Placement

    def configure(server, owner) do
      :persistent_term.put({__MODULE__, :server}, server)
      :persistent_term.put({__MODULE__, :owner}, owner)
    end

    def clear do
      :persistent_term.erase({__MODULE__, :server})
      :persistent_term.erase({__MODULE__, :owner})
    end

    @impl true
    def ensure_started(agent_id, opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:slow_session_placement, agent_id, opts})
      {:ok, :persistent_term.get({__MODULE__, :server})}
    end

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  defmodule LegacySessionRecoveryServer do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:recover_session_work, targets}, _from, owner) do
      send(owner, {:legacy_exact_recovery_call, targets})

      # A pre-#698 Server has no exact-target call clause. Its serving/parked
      # catch-all keeps state without replying, so model that rolling-upgrade
      # boundary rather than returning an invented error.
      {:noreply, owner}
    end

    def handle_call(:wake, _from, owner) do
      send(owner, :legacy_generic_wake)
      {:reply, :ok, owner}
    end
  end

  defmodule ExactSessionRecoveryServer do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:recover_session_work, targets}, _from, owner) do
      send(owner, {:exact_session_recovery_call, targets})
      {:reply, :ok, owner}
    end

    def handle_call(:wake, _from, owner) do
      send(owner, :unexpected_generic_wake)
      {:reply, :ok, owner}
    end
  end

  defmodule DyingSessionRecoveryServer do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:recover_session_work, targets}, _from, owner) do
      send(owner, {:dying_exact_recovery_call, targets})
      {:stop, :normal, owner}
    end
  end

  defmodule LegacySessionRecoveryPlacement do
    @behaviour SalixAgent.Placement

    def configure(server) when is_pid(server),
      do: :persistent_term.put({__MODULE__, :servers}, %{:default => server})

    def configure(servers) when is_map(servers),
      do: :persistent_term.put({__MODULE__, :servers}, servers)

    def clear, do: :persistent_term.erase({__MODULE__, :servers})

    @impl true
    def ensure_started(agent_id, _opts) do
      servers = :persistent_term.get({__MODULE__, :servers})

      case Map.fetch(servers, agent_id) do
        {:ok, server} -> {:ok, server}
        :error -> {:ok, Map.fetch!(servers, :default)}
      end
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
  # are rediscovered through the PG candidate projection lanes, which the
  # rest of this file covers exhaustively.

  describe "session-work sweep re-homes passivated work" do
    test "a slow session wake does not block the Recovery lease cadence", %{agent: a} do
      session_id = "ses1_1200000000000000024"

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "slow-session-recovery",
                   "created_at" => System.system_time(:second),
                   "payload" => %{
                     "source_message_id" => "slow-session-recovery",
                     "role" => "user",
                     "content" => "continue after recovery"
                   }
                 }
               ])

      slow_server = start_supervised!({SlowSessionRecoveryServer, self()})
      SlowSessionRecoveryPlacement.configure(slow_server, self())
      Application.put_env(:salix_agent, :placement, SlowSessionRecoveryPlacement)
      on_exit(&SlowSessionRecoveryPlacement.clear/0)

      recovery_worker = :slow_session_work_recovery_test
      start_supervised!({SessionWorkRecovery, name: recovery_worker})

      test_pid = self()

      S3.Fake.reset_put_log()

      start_supervised!(
        {Recovery,
         name: :recovery_slow_session_test,
         interval_ms: 25,
         session_work_recovery: recovery_worker}
      )

      assert_receive {:slow_session_recovery_started, [_target]}, 1_000
      assert_receive {:slow_session_placement, ^a, [create: false]}, 1_000

      lease_key = Keys.singleton(:recovery)
      lease_writes_before = Enum.count(S3.Fake.put_log(), &(&1 == lease_key))
      assert lease_writes_before >= 1

      Process.sleep(150)

      # Recovery owns the singleton lease. A slow domain wake must not keep the
      # scheduler from renewing that lease and running the next correctness pass.
      assert Enum.count(S3.Fake.put_log(), &(&1 == lease_key)) > lease_writes_before
    end

    test "a missing session-work worker does not stop the Recovery cadence" do
      pid =
        start_supervised!(
          {Recovery,
           name: :recovery_missing_session_worker_test,
           interval_ms: 25,
           session_work_recovery: :missing_session_work_recovery_test}
        )

      assert eventually(fn -> :sys.get_state(pid).tick_count >= 3 end)
      assert Process.alive?(pid)
    end

    test "a post-LISTEN catch-up requests the lease holder's worker immediately" do
      owner = self()

      sweep_fn = fn opts ->
        send(owner, {:notification_catch_up_sweep, self(), opts})

        %{
          rewoken: [],
          scanned: 0,
          cleaned: 0,
          failed: 0,
          unproven_retained: 0,
          next: nil,
          deferred_next: nil,
          last_attempted_lane: nil
        }
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
      assert_receive {:notification_catch_up_sweep, _task, _opts}, 1_000
      assert eventually(fn -> :sys.get_state(worker).task == nil end)

      assert :ok = Recovery.request_session_work_catchup(recovery)
      assert_receive {:notification_catch_up_sweep, _task, _opts}, 200
    end

    test "a rolling-upgrade owner without exact recovery fails closed", %{agent: a} do
      session_id = "ses1_1200000000000000039"
      SalixAgent.TestSupport.create_control_agent!(a)

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "legacy-owner-fallback",
                   "created_at" => System.system_time(:second),
                   "payload" => %{
                     "source_message_id" => "legacy-owner-fallback",
                     "role" => "user",
                     "content" => "continue on a rolling-upgrade owner"
                   }
                 }
               ])

      assert {:ok, [%{"session_id" => ^session_id}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"session_id" => ^session_id}]}} =
               SessionWorkIndex.list_discovery()

      legacy_server = start_supervised!({LegacySessionRecoveryServer, self()})
      LegacySessionRecoveryPlacement.configure(legacy_server)
      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      started_at = System.monotonic_time(:millisecond)

      assert %{
               rewoken: [],
               scanned: 1,
               cleaned: 0,
               failed: 1
             } = SessionWorkRecovery.sweep(session_work_wake_timeout: 50)

      assert System.monotonic_time(:millisecond) - started_at < 500

      assert_receive {:legacy_exact_recovery_call,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     100

      refute_receive :legacy_generic_wake, 50

      # A compatibility wake is only a hint; it must not consume the durable
      # discovery authority before the old owner actually settles the work.
      assert {:ok, %{records: [%{"session_id" => ^session_id}]}} =
               SessionWorkIndex.list_discovery()
    end

    test "failure-first: an exact target timeout never falls back to generic local discovery", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000041"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "exact-target-no-fallback",
                   "payload" => %{
                     "source_message_id" => "exact-target-no-fallback",
                     "content" => "wake the verified session"
                   }
                 }
               ])

      server = start_supervised!({LegacySessionRecoveryServer, self()})
      LegacySessionRecoveryPlacement.configure(server)
      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      assert %{
               rewoken: [],
               failed: 1
             } =
               SessionWorkRecovery.sweep(
                 session_work_wake_timeout: 30,
                 session_work_page_wake_budget: 100
               )

      assert_receive {:legacy_exact_recovery_call,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     100

      refute_receive :legacy_generic_wake, 50
    end

    test "failure-first: contiguous-prefix continuation reaches an unattempted healthy owner", %{
      agent: a
    } do
      other = SalixAgent.TestSupport.new_agent_id()
      [stuck_agent, healthy_agent] = Enum.sort([a, other])

      sessions =
        for agent_id <- [stuck_agent, healthy_agent], into: %{} do
          session_id = Ids.new_session_id()
          SalixAgent.TestSupport.create_control_agent!(agent_id)

          assert {:ok, _session} =
                   InternalSessionStore.prepare_commit(agent_id, session_id, [
                     %{"type" => "session_created", "session_id" => session_id},
                     %{
                       "type" => "queue_append",
                       "session_id" => session_id,
                       "kind" => "user_message",
                       "dedupe_key" => "contiguous-prefix-#{agent_id}",
                       "payload" => %{
                         "source_message_id" => "contiguous-prefix-#{agent_id}",
                         "content" => "resume #{agent_id}"
                       }
                     }
                   ])

          {agent_id, session_id}
        end

      stuck_server =
        start_supervised!(%{
          id: {:stuck_recovery_owner, stuck_agent},
          start: {LegacySessionRecoveryServer, :start_link, [self()]}
        })

      healthy_server =
        start_supervised!(%{
          id: {:healthy_recovery_owner, healthy_agent},
          start: {ExactSessionRecoveryServer, :start_link, [self()]}
        })

      LegacySessionRecoveryPlacement.configure(%{
        stuck_agent => stuck_server,
        healthy_agent => healthy_server
      })

      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      first =
        SessionWorkRecovery.sweep(
          session_work_max_keys: 2,
          session_work_wake_timeout: 30,
          session_work_page_wake_budget: 30
        )

      refute healthy_agent in first.rewoken
      assert is_binary(first.next)

      second =
        SessionWorkRecovery.sweep(
          session_work_max_keys: 2,
          session_work_cursor: first.next,
          session_work_wake_timeout: 30,
          session_work_page_wake_budget: 30
        )

      assert healthy_agent in second.rewoken

      assert_receive {:exact_session_recovery_call,
                      [%{runtime: :internal, session_id: healthy_session_id}]},
                     100

      assert healthy_session_id == sessions[healthy_agent]
      refute_receive :unexpected_generic_wake, 50
    end

    test "a coalesced worker sweep rotates from a budget-consuming eager owner to overdue deferred work",
         %{agent: a} do
      now_ms = System.system_time(:millisecond)
      second_eager = SalixAgent.TestSupport.new_agent_id()
      healthy_deferred = SalixAgent.TestSupport.new_agent_id()
      [stuck_eager, trailing_eager] = Enum.sort([a, second_eager])

      eager_sessions =
        for agent_id <- [stuck_eager, trailing_eager], into: %{} do
          session_id = Ids.new_session_id()
          SalixAgent.TestSupport.create_control_agent!(agent_id)

          assert {:ok, _session} =
                   InternalSessionStore.prepare_commit(agent_id, session_id, [
                     %{"type" => "session_created", "session_id" => session_id},
                     %{
                       "type" => "queue_append",
                       "session_id" => session_id,
                       "kind" => "user_message",
                       "dedupe_key" => "worker-cross-lane-#{agent_id}",
                       "payload" => %{
                         "source_message_id" => "worker-cross-lane-#{agent_id}",
                         "content" => "resume #{agent_id}"
                       }
                     }
                   ])

          {agent_id, session_id}
        end

      deferred_session = Ids.new_session_id()
      SalixAgent.TestSupport.create_control_agent!(healthy_deferred)

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(healthy_deferred, deferred_session, [
                 %{"type" => "session_created", "session_id" => deferred_session},
                 %{
                   "type" => "wait_set",
                   "session_id" => deferred_session,
                   "wait" => %{
                     "wait_id" => "worker-cross-lane-deferred",
                     "reason" => "deadline elapsed while eager owner was stuck",
                     "deadline_ms" => now_ms - 1_000
                   }
                 }
               ])

      stuck_server =
        start_supervised!(%{
          id: {:worker_cross_lane_stuck_owner, stuck_eager},
          start: {LegacySessionRecoveryServer, :start_link, [self()]}
        })

      trailing_server =
        start_supervised!(%{
          id: {:worker_cross_lane_trailing_owner, trailing_eager},
          start: {LegacySessionRecoveryServer, :start_link, [self()]}
        })

      healthy_server =
        start_supervised!(%{
          id: {:worker_cross_lane_healthy_owner, healthy_deferred},
          start: {ExactSessionRecoveryServer, :start_link, [self()]}
        })

      LegacySessionRecoveryPlacement.configure(%{
        stuck_eager => stuck_server,
        trailing_eager => trailing_server,
        healthy_deferred => healthy_server
      })

      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      owner = self()

      sweep_fn = fn worker_opts ->
        send(owner, {:real_session_work_sweep_started, worker_opts})

        result =
          SessionWorkRecovery.sweep(
            Keyword.merge(worker_opts,
              now: now_ms,
              session_work_wake_timeout: 40,
              session_work_page_wake_budget: 40
            )
          )

        send(owner, {:real_session_work_sweep_finished, result})
        result
      end

      worker =
        start_supervised!(
          {SessionWorkRecovery,
           name: nil,
           task_supervisor: SalixAgent.TaskSup,
           sweep_fn: sweep_fn,
           session_work_max_keys: 1}
        )

      assert :ok = SessionWorkRecovery.request_sweep(worker)

      assert_receive {:real_session_work_sweep_started,
                      [
                        session_work_max_keys: 1,
                        session_work_cursor: nil,
                        deferred_session_work_cursor: nil,
                        session_work_start_lane: :eager
                      ]}

      assert :ok = SessionWorkRecovery.request_sweep(worker)

      assert_receive {:legacy_exact_recovery_call,
                      [%{runtime: :internal, session_id: stuck_session}]},
                     100

      assert stuck_session == eager_sessions[stuck_eager]

      assert_receive {:real_session_work_sweep_finished,
                      %{
                        rewoken: [],
                        failed: 1,
                        next: eager_cursor,
                        deferred_next: nil,
                        last_attempted_lane: :eager
                      }},
                     200

      assert is_binary(eager_cursor)

      assert_receive {:real_session_work_sweep_started, second_opts}, 200
      assert second_opts[:session_work_cursor] == eager_cursor
      assert second_opts[:deferred_session_work_cursor] == nil
      assert second_opts[:session_work_start_lane] == :deferred

      assert_receive {:exact_session_recovery_call,
                      [%{runtime: :internal, session_id: ^deferred_session}]},
                     100

      assert_receive {:real_session_work_sweep_finished, %{rewoken: rewoken}},
                     200

      assert healthy_deferred in rewoken
      refute_receive :legacy_generic_wake, 50
      refute_receive :unexpected_generic_wake, 50
      refute_receive {:real_session_work_sweep_started, _third_opts}, 50
    end

    test "a legacy generic wake does not claim recovery for due wait-only work", %{agent: a} do
      session_id = "ses1_1200000000000000042"
      now_ms = System.system_time(:millisecond)
      SalixAgent.TestSupport.create_control_agent!(a)

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "wait_set",
                   "session_id" => session_id,
                   "wait" => %{
                     "wait_id" => "legacy-owner-due-wait",
                     "reason" => "deadline elapsed during rolling upgrade",
                     "deadline_ms" => now_ms - 1_000
                   }
                 }
               ])

      assert {:ok, %{records: [%{"session_id" => ^session_id}], next: nil}} =
               SessionWorkIndex.list_due_discovery(now_ms)

      legacy_server = start_supervised!({LegacySessionRecoveryServer, self()})
      LegacySessionRecoveryPlacement.configure(legacy_server)
      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      assert %{
               rewoken: [],
               scanned: 1,
               cleaned: 0,
               failed: 1
             } =
               SessionWorkRecovery.sweep(
                 now: now_ms,
                 session_work_wake_timeout: 50
               )

      assert_receive {:legacy_exact_recovery_call,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     100

      refute_receive :legacy_generic_wake, 50

      assert {:ok, %{records: [%{"session_id" => ^session_id}], next: nil}} =
               SessionWorkIndex.list_due_discovery(now_ms)
    end

    test "old local-only work remains recoverable during a rolling upgrade", %{agent: a} do
      session_id = "ses1_1200000000000000040"
      Mock.script([{:final, "continued from the legacy local marker"}])
      SalixAgent.TestSupport.create_control_agent!(a)

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "legacy-local-only-work",
                   "created_at" => System.system_time(:second),
                   "payload" => %{
                     "source_message_id" => "legacy-local-only-work",
                     "role" => "user",
                     "content" => "continue from an old local marker"
                   }
                 }
               ])

      assert {:ok, %{records: [discovery]}} = SessionWorkIndex.list_discovery()
      assert :ok = SessionWorkIndex.delete_discovery(discovery)
      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      # Simulate a record written by a newer node and read by an older local
      # hydration path: unknown additive fields must not hide otherwise valid
      # local work.
      local_key = Keys.agent_session_work_index(a, "internal", session_id)
      assert {:ok, %{body: local_body}} = S3.get(local_key)

      local_record =
        local_body
        |> Jason.decode!()
        |> Map.put("future_write_generation", "generation-not-yet-understood")

      assert {:ok, _etag} = S3.put(local_key, Jason.encode!(local_record))

      assert {:ok, [%{"session_id" => ^session_id}]} = SessionWorkIndex.list(a)

      # The new global sweep cannot discover old local-only work and therefore
      # must neither delete nor mutate it.
      assert %{
               rewoken: [],
               scanned: 0,
               cleaned: 0,
               failed: 0
             } = SessionWorkRecovery.sweep()

      assert {:ok, [%{"session_id" => ^session_id}]} = SessionWorkIndex.list(a)
      refute Fleet.running?(a)

      # Existing AgentServer local hydration remains the compatibility path.
      assert {:ok, _pid} = Fleet.ensure_started(a, create: false)

      assert eventually(
               fn ->
                 session_has_content?(
                   a,
                   session_id,
                   "continued from the legacy local marker"
                 )
               end,
               200
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 200)
      assert eventually(fn -> SessionWorkIndex.list(a) == {:ok, []} end, 200)
    end

    test "a page of rolling-upgrade owners fails closed within one bounded wake budget", %{
      agent: a
    } do
      agents = [a, SalixAgent.TestSupport.new_agent_id()]

      placements =
        Map.new(agents, fn agent_id ->
          session_id = Ids.new_session_id()
          SalixAgent.TestSupport.create_control_agent!(agent_id)
          {:ok, _session} = InternalSessionStore.prepare_create(agent_id, session_id, %{})

          assert {:ok, _session} =
                   InternalSessionStore.prepare_commit(agent_id, session_id, [
                     %{
                       "type" => "queue_append",
                       "session_id" => session_id,
                       "kind" => "user_message",
                       "dedupe_key" => "legacy-page-#{agent_id}",
                       "created_at" => System.system_time(:second),
                       "payload" => %{
                         "source_message_id" => "legacy-page-#{agent_id}",
                         "role" => "user",
                         "content" => "continue on an old owner"
                       }
                     }
                   ])

          server =
            start_supervised!(%{
              id: {LegacySessionRecoveryServer, agent_id},
              start: {LegacySessionRecoveryServer, :start_link, [self()]}
            })

          {agent_id, server}
        end)

      LegacySessionRecoveryPlacement.configure(placements)
      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      started_at = System.monotonic_time(:millisecond)

      summary =
        SessionWorkRecovery.sweep(
          session_work_wake_timeout: 50,
          session_work_page_wake_budget: 250
        )

      assert summary.rewoken == []
      assert summary.scanned == 2
      assert summary.cleaned == 0
      assert summary.failed == 2
      assert System.monotonic_time(:millisecond) - started_at < 500

      for _agent_id <- agents do
        assert_receive {:legacy_exact_recovery_call, [_target]}, 100
      end

      refute_receive :legacy_generic_wake, 50
    end

    test "probe: a dead owner is not reported as a successful compatibility wake", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000041"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "dying-owner-fallback",
                   "created_at" => System.system_time(:second),
                   "payload" => %{
                     "source_message_id" => "dying-owner-fallback",
                     "role" => "user",
                     "content" => "keep the recovery marker after owner death"
                   }
                 }
               ])

      dying_server =
        start_supervised!(%{
          id: DyingSessionRecoveryServer,
          start: {DyingSessionRecoveryServer, :start_link, [self()]},
          restart: :temporary
        })

      LegacySessionRecoveryPlacement.configure(dying_server)
      Application.put_env(:salix_agent, :placement, LegacySessionRecoveryPlacement)
      on_exit(&LegacySessionRecoveryPlacement.clear/0)

      assert %{
               rewoken: [],
               scanned: 1,
               cleaned: 0,
               failed: 1
             } = SessionWorkRecovery.sweep(session_work_wake_timeout: 50)

      assert_receive {:dying_exact_recovery_call,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     100

      assert {:ok, %{records: [%{"session_id" => ^session_id}]}} =
               SessionWorkIndex.list_discovery()
    end

    test "non-stable session work resumes without an agent queue marker or later traffic", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000002"
      Mock.script([{:final, "continued without another user message"}])
      SalixAgent.TestSupport.create_control_agent!(a)

      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "passivated-session-work",
            "created_at" => System.system_time(:second),
            "payload" => %{
              "source_message_id" => "passivated-session-work",
              "role" => "user",
              "content" => "continue this task"
            }
          }
        ])

      assert "unacked_queue_item" in InternalSession.work_reasons(session)
      assert {:ok, [%{"session_id" => ^session_id}]} = SessionWorkIndex.list(a)
      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(fn -> session_has_content?(a, session_id, "continue this task") end, 200)

      assert eventually(
               fn ->
                 session_has_content?(
                   a,
                   session_id,
                   "continued without another user message"
                 )
               end,
               200
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 200)
    end

    test "candidate writes retain the agent-local marker and PG projection only", %{agent: a} do
      session_id = "ses1_1200000000000000040"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "local-marker-pg-projection",
                   "payload" => %{
                     "source_message_id" => "local-marker-pg-projection",
                     "content" => "survive rolling recovery ownership"
                   }
                 }
               ])

      local_key = Keys.agent_session_work_index(a, "internal", session_id)
      assert {:ok, %{body: body}} = S3.get(local_key)
      assert {:ok, local_record} = Jason.decode(body)
      assert local_record["token"] == InternalSession.work_index_token(session)

      assert {:ok, %{records: [%{"token" => token}]}} = SessionWorkIndex.list_discovery()
      assert token == InternalSession.work_index_token(session)
    end

    test "release backfill advances past a control agent with no local work markers", %{
      agent: a
    } do
      empty_agent =
        "agt1_0000000000000000000_0000000000000000000_0000000000000000000"

      SalixAgent.TestSupport.create_control_agent!(empty_agent)
      SalixAgent.TestSupport.create_control_agent!(a)

      session_id = "ses1_1200000000000000040"

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "backfill-after-empty-agent",
                   "payload" => %{
                     "source_message_id" => "backfill-after-empty-agent",
                     "content" => "project work after an empty roster entry"
                   }
                 }
               ])

      assert :ok = SessionWorkCandidates.delete_exact(InternalSession.work_index_token(session))
      reset_session_work_backfill!()

      task = Task.async(fn -> SessionWorkBackfill.run(page_size: 1) end)
      result = Task.yield(task, 1_000)

      if is_nil(result), do: Task.shutdown(task, :brutal_kill)

      assert {:ok, {:ok, %{status: :complete, processed: 1}}} = result

      assert {:ok, %{"session_id" => ^session_id}} =
               SessionWorkCandidates.fetch_exact(InternalSession.work_index_token(session))

      assert {:ok, true} = SalixStore.SessionWorkBackfillState.terminal?()
    end

    test "release backfill projects and recovery exact-wakes an eager local marker", %{agent: a} do
      session_id = "ses1_1200000000000000041"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "legacy-only-backfill",
                   "payload" => %{
                     "source_message_id" => "legacy-only-backfill",
                     "content" => "recover the legacy backlog"
                   }
                 }
               ])

      assert {:ok, [_record]} = SessionWorkIndex.list(a)
      assert :ok = SessionWorkCandidates.delete_exact(InternalSession.work_index_token(session))
      assert {:ok, []} = SessionWorkCandidates.list_all()

      reset_session_work_backfill!()
      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)

      server = start_supervised!({SlowSessionRecoveryServer, self()})
      SlowSessionRecoveryPlacement.configure(server, self())
      Application.put_env(:salix_agent, :placement, SlowSessionRecoveryPlacement)
      on_exit(&SlowSessionRecoveryPlacement.clear/0)

      assert %{rewoken: [^a], failed: 0} = SessionWorkRecovery.sweep()

      assert_receive {:slow_session_recovery_started,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     500

      assert {:ok, [%{"token" => token}]} = SessionWorkCandidates.list_all()
      assert token == InternalSession.work_index_token(session)
    end

    test "release backfill projects and recovery exact-wakes a due local marker", %{agent: a} do
      session_id = "ses1_1200000000000000042"
      now_ms = System.system_time(:millisecond)
      deadline_ms = now_ms - 1_000
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "wait_set",
                   "session_id" => session_id,
                   "wait" => %{
                     "wait_id" => "legacy-only-due-backfill",
                     "reason" => "recover the legacy deferred backlog",
                     "deadline_ms" => deadline_ms
                   }
                 }
               ])

      assert {:ok, [_record]} = SessionWorkIndex.list(a)
      assert :ok = SessionWorkCandidates.delete_exact(InternalSession.work_index_token(session))
      assert {:ok, []} = SessionWorkCandidates.list_all()

      reset_session_work_backfill!()
      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)

      server = start_supervised!({SlowSessionRecoveryServer, self()})
      SlowSessionRecoveryPlacement.configure(server, self())
      Application.put_env(:salix_agent, :placement, SlowSessionRecoveryPlacement)
      on_exit(&SlowSessionRecoveryPlacement.clear/0)

      assert %{rewoken: [^a], failed: 0} = SessionWorkRecovery.sweep(now: now_ms)

      assert_receive {:slow_session_recovery_started,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     500

      assert {:ok, [%{"token" => token}]} = SessionWorkCandidates.list_all()
      assert token == InternalSession.work_index_token(session)
    end

    test "capability recertification discovers old callback markers without changing session facts",
         %{agent: a} do
      session_id = "ses1_1200000000000000079"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => session_id,
                   "tool_call_id" => "legacy-capability",
                   "tool_name" => "location.request",
                   "status" => "running",
                   "completion_mode" => "external_callback"
                 }
               ])

      token = InternalSession.work_index_token(session)
      marker_key = Keys.agent_session_work_index(a, :internal, session_id)
      assert {:ok, %{body: marker_body}} = S3.get(marker_key)

      legacy_marker =
        Jason.decode!(marker_body) |> Map.put("reasons", ["external_callback_tool_call"])

      assert {:ok, _} = S3.put(marker_key, Jason.encode!(legacy_marker))
      assert :ok = SessionWorkCandidates.delete_exact(token)
      assert {:ok, []} = SessionWorkCandidates.list_all()
      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{body: original_session_body}} = S3.get(session_key)

      reset_session_work_backfill!()

      SalixStore.Repo.query!("""
      INSERT INTO session_work_backfill_state
        (name, phase, uncovered_authoritative_work, processed, projection_gaps,
         updated_at_ms, strategy_version)
      VALUES ('session_work_candidates_v1', 'verify', 0, 1, 0, 1, 4)
      """)

      SalixStore.Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('session_work_candidates_v1', now(), '{"strategy_version":4,"processed":1}'::jsonb)
      """)

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)

      assert {:ok, %{records: [candidate]}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      assert candidate["token"] == token
      assert "capability_deadline" in candidate["reasons"]
      assert {:ok, %{body: ^original_session_body}} = S3.get(session_key)
      assert {:ok, %{body: same_marker_body}} = S3.get(marker_key)
      assert Jason.decode!(same_marker_body) == legacy_marker
      assert {:ok, %{status: :already_complete}} = SessionWorkBackfill.run(page_size: 1)
    end

    test "release backfill resumes after the last attempted local marker and verifies zero", %{
      agent: a
    } do
      SalixAgent.TestSupport.create_control_agent!(a)

      sessions =
        for suffix <- ["0043", "0044"] do
          session_id = "ses1_120000000000000#{suffix}"

          assert {:ok, session} =
                   InternalSessionStore.prepare_commit(a, session_id, [
                     %{"type" => "session_created", "session_id" => session_id},
                     %{
                       "type" => "queue_append",
                       "session_id" => session_id,
                       "kind" => "user_message",
                       "dedupe_key" => "release-backfill-#{suffix}",
                       "payload" => %{
                         "source_message_id" => "release-backfill-#{suffix}",
                         "content" => "resume release backfill #{suffix}"
                       }
                     }
                   ])

          assert :ok =
                   SessionWorkCandidates.delete_exact(InternalSession.work_index_token(session))

          {session_id, InternalSession.work_index_token(session),
           InternalSession.storage_revision(session)}
        end

      {_first_session_id, first_token, _first_revision} = hd(sessions)

      assert :ok =
               SessionWorkCandidates.insert(%{
                 "token" => first_token,
                 "agent_id" => a,
                 "runtime_kind" => "internal",
                 "session_id" => "ses1_1200000000000000999",
                 "base_revision" => "pre-cutover-partial-revision",
                 "reasons" => ["queued_input"],
                 "updated_at" => 1
               })

      marker_keys =
        sessions
        |> Enum.map(fn {session_id, _token, _revision} ->
          Keys.agent_session_work_index(a, "internal", session_id)
        end)
        |> Enum.sort()

      [first_key, second_key] = marker_keys
      reset_session_work_backfill!()
      assert :ok = S3.Fake.set_fault({:fail, 503, :get, second_key})

      assert {:error, {:marker_backfill_failed, ^second_key, {:http, 503}}} =
               SessionWorkBackfill.run(page_size: 2)

      assert {:ok,
              %{
                phase: "backfill",
                marker_start_after: ^first_key,
                # Strategy v3 has already reconciled the seeded PG-only address,
                # then durably attempted the first local marker.
                processed: 2,
                uncovered_authoritative_work: 0
              }} = SalixStore.SessionWorkBackfillState.read()

      assert {:ok, false} = SalixStore.SessionWorkBackfillState.terminal?()
      S3.Fake.reset_read_log()

      assert {:ok, %{status: :complete, processed: 3}} =
               SessionWorkBackfill.run(page_size: 2)

      marker_prefix = Keys.agent_session_work_index_prefix(a)

      assert Enum.any?(S3.Fake.read_log(), fn
               {:list, ^marker_prefix, opts} -> opts[:start_after] == first_key
               _other -> false
             end)

      assert {:ok, true} = SalixStore.SessionWorkBackfillState.terminal?()
      assert {:ok, candidates} = SessionWorkCandidates.list_all()

      assert Enum.sort(Enum.map(candidates, & &1["token"])) ==
               Enum.sort(Enum.map(sessions, &elem(&1, 1)))

      assert Enum.sort(Enum.map(candidates, & &1["base_revision"])) ==
               Enum.sort(Enum.map(sessions, &elem(&1, 2)))
    end

    test "release backfill scopes a stable marker delete to its exact Session address", %{
      agent: a
    } do
      stable_session_id = "ses1_1200000000000000060"
      sibling_session_id = "ses1_1200000000000000061"
      sibling_agent_id = SalixAgent.TestSupport.new_agent_id()
      shared_token = "duplicate-legacy-token"
      SalixAgent.TestSupport.create_control_agent!(a)
      SalixAgent.TestSupport.create_control_agent!(sibling_agent_id)

      assert {:ok, _stable} =
               InternalSessionStore.prepare_commit(a, stable_session_id, [
                 %{"type" => "session_created", "session_id" => stable_session_id}
               ])

      stable_key = Keys.agent_session_work_index(a, "internal", stable_session_id)

      assert {:ok, _etag} =
               S3.put(
                 stable_key,
                 Jason.encode!(%{
                   "agent_id" => a,
                   "runtime_kind" => "internal",
                   "session_id" => stable_session_id,
                   "token" => shared_token
                 }),
                 []
               )

      sibling =
        sibling_agent_id
        |> InternalSession.new(sibling_session_id, %{})
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => sibling_session_id,
            "kind" => "user_message",
            "dedupe_key" => "duplicate-token-sibling-authority",
            "payload" => %{
              "source_message_id" => "duplicate-token-sibling-authority",
              "content" => "preserve the exact sibling authority"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(shared_token, ["unacked_queue_item"])

      assert {:ok, _etag} =
               S3.put(
                 Keys.agent_internal_runtime_session(sibling_agent_id, sibling_session_id),
                 Codec.compress_snapshot_etf(InternalSession.persist(sibling)),
                 if_none_match: "*"
               )

      assert :ok =
               SessionWorkCandidates.insert(%{
                 "token" => shared_token,
                 "agent_id" => sibling_agent_id,
                 "runtime_kind" => "internal",
                 "session_id" => sibling_session_id,
                 "base_revision" => "sibling-revision",
                 "reasons" => ["queued_input"],
                 "updated_at" => 1
               })

      reset_session_work_backfill!()
      _result = SessionWorkBackfill.run(page_size: 2)

      assert {:ok, %{"session_id" => ^sibling_session_id}} =
               SessionWorkCandidates.fetch_exact(shared_token)
    end

    test "release recertification resumes after the last attempted PG candidate address", %{
      agent: a
    } do
      SalixAgent.TestSupport.create_control_agent!(a)
      first_session_id = "ses1_1200000000000000071"
      second_session_id = "ses1_1200000000000000072"

      assert {:ok, first} = InternalSessionStore.prepare_create(a, first_session_id, %{})
      assert {:ok, second} = InternalSessionStore.prepare_create(a, second_session_id, %{})

      for {session_id, session, token} <- [
            {first_session_id, first, "pg-residue-first"},
            {second_session_id, second, "pg-residue-second"}
          ] do
        assert :ok =
                 SessionWorkCandidates.insert(%{
                   "token" => token,
                   "agent_id" => a,
                   "runtime_kind" => "internal",
                   "session_id" => session_id,
                   "base_revision" => InternalSession.storage_revision(session),
                   "reasons" => ["unacked_queue_item"],
                   "updated_at" => 1
                 })
      end

      reset_session_work_backfill!()
      second_key = Keys.agent_internal_runtime_session(a, second_session_id)
      assert :ok = S3.Fake.set_fault({:fail, 503, :get, second_key})

      second_address = %{agent_id: a, runtime_kind: "internal", session_id: second_session_id}

      assert {:error,
              {:candidate_backfill_failed, ^second_address,
               {:authoritative_session_read_failed, {:http, 503}}}} =
               SessionWorkBackfill.run(page_size: 1)

      assert {:ok,
              %{
                phase: "candidate_backfill",
                candidate_agent_start_after: ^a,
                candidate_runtime_kind_start_after: "internal",
                candidate_session_start_after: ^first_session_id,
                processed: 1
              }} = SalixStore.SessionWorkBackfillState.read()

      assert {:error, :not_found} = SessionWorkCandidates.fetch_exact("pg-residue-first")
      assert {:ok, _record} = SessionWorkCandidates.fetch_exact("pg-residue-second")

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)
      assert {:ok, []} = SessionWorkCandidates.list_all()
      assert {:ok, true} = SalixStore.SessionWorkBackfillState.terminal?()
    end

    test "release backfill removes every crashed same-base token for a stable Session", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000065"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: shared_base}} = S3.get(session_key)

      crashed_tokens =
        for _writer <- 1..3 do
          assert {:ok, %{"token" => token}} =
                   SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                     cas_base: shared_base
                   )

          token
        end

      reset_session_work_backfill!()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 2)
      assert {:ok, []} = SessionWorkCandidates.list_all()
      assert {:ok, true} = SalixStore.SessionWorkBackfillState.terminal?()

      assert Enum.all?(crashed_tokens, fn token ->
               SessionWorkCandidates.fetch_exact(token) == {:error, :not_found}
             end)

      assert {:ok, %{status: :already_complete}} = SessionWorkBackfill.run(page_size: 2)
    end

    test "release backfill repairs a PG-only candidate left after local marker cleanup", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000068"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      residue = %{
        "token" => "pg-only-cleanup-residue",
        "agent_id" => a,
        "runtime_kind" => "internal",
        "session_id" => session_id,
        "base_revision" => InternalSession.storage_revision(stable),
        "reasons" => ["unacked_queue_item"],
        "updated_at" => 1
      }

      # This is the durable crash state produced when stable cleanup deletes the
      # agent-local marker and the process dies before deleting its PG candidate.
      assert {:error, :not_found} =
               S3.get(Keys.agent_session_work_index(a, "internal", session_id))

      assert :ok = SessionWorkCandidates.insert(residue)
      reset_session_work_backfill!()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)
      assert {:error, :not_found} = SessionWorkCandidates.fetch_exact(residue["token"])
      assert {:ok, true} = SalixStore.SessionWorkBackfillState.terminal?()
    end

    test "stable cleanup retains the local marker when PG candidate deletion fails", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000070"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 base_revision: InternalSession.storage_revision(stable)
               )

      SalixStore.Repo.query!("""
      CREATE OR REPLACE FUNCTION fail_pr779_candidate_delete()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'injected candidate delete failure';
      END
      $$
      """)

      SalixStore.Repo.query!("""
      CREATE TRIGGER fail_pr779_candidate_delete
      BEFORE DELETE ON session_work_candidates
      FOR EACH ROW EXECUTE FUNCTION fail_pr779_candidate_delete()
      """)

      on_exit(fn ->
        SalixStore.Repo.query!(
          "DROP TRIGGER IF EXISTS fail_pr779_candidate_delete ON session_work_candidates"
        )

        SalixStore.Repo.query!("DROP FUNCTION IF EXISTS fail_pr779_candidate_delete()")
      end)

      assert {:error, :unavailable} =
               SessionWorkIndex.delete_if_token(a, :internal, session_id, token)

      marker_key = Keys.agent_session_work_index(a, "internal", session_id)
      assert {:ok, %{body: body}} = S3.get(marker_key)
      assert %{"token" => ^token} = Jason.decode!(body)
      assert {:ok, %{"token" => ^token}} = SessionWorkCandidates.fetch_exact(token)
    end

    test "stable cleanup cannot delete a same-token candidate at another Session address", %{
      agent: a
    } do
      cleanup_session_id = "ses1_1200000000000000073"
      sibling_session_id = "ses1_1200000000000000074"
      sibling_agent_id = SalixAgent.TestSupport.new_agent_id()
      shared_token = "corrupt-local-duplicate-token"

      marker_key = Keys.agent_session_work_index(a, "internal", cleanup_session_id)

      assert {:ok, _etag} =
               S3.put(
                 marker_key,
                 Jason.encode!(%{
                   "agent_id" => a,
                   "runtime_kind" => "internal",
                   "session_id" => cleanup_session_id,
                   "token" => shared_token
                 }),
                 []
               )

      assert :ok =
               SessionWorkCandidates.insert(%{
                 "token" => shared_token,
                 "agent_id" => sibling_agent_id,
                 "runtime_kind" => "internal",
                 "session_id" => sibling_session_id,
                 "base_revision" => "sibling-revision",
                 "reasons" => ["unacked_queue_item"],
                 "updated_at" => 1
               })

      assert {:ok, :deleted} =
               SessionWorkIndex.delete_if_token(a, :internal, cleanup_session_id, shared_token)

      assert {:error, :not_found} = S3.get(marker_key)

      assert {:ok, %{"agent_id" => ^sibling_agent_id, "session_id" => ^sibling_session_id}} =
               SessionWorkCandidates.fetch_exact(shared_token)
    end

    test "legacy terminal evidence cannot bypass the current release recertification", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000069"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      residue = %{
        "token" => "legacy-terminal-pg-residue",
        "agent_id" => a,
        "runtime_kind" => "internal",
        "session_id" => session_id,
        "base_revision" => InternalSession.storage_revision(stable),
        "reasons" => ["unacked_queue_item"],
        "updated_at" => 1
      }

      reset_session_work_backfill!()
      assert :ok = SessionWorkCandidates.insert(residue)

      SalixStore.Repo.query!("""
      INSERT INTO session_work_backfill_state
        (name, phase, uncovered_authoritative_work, processed, projection_gaps,
         updated_at_ms, strategy_version)
      VALUES
        ('session_work_candidates_v1', 'verify', 0, 1, 0, 1, 1)
      """)

      SalixStore.Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('session_work_candidates_v1', now(), '{"processed":1}'::jsonb)
      """)

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)
      assert {:error, :not_found} = SessionWorkCandidates.fetch_exact(residue["token"])

      assert %{rows: [[5]]} =
               SalixStore.Repo.query!("""
               SELECT (evidence->>'strategy_version')::integer
               FROM salix_cutover_markers
               WHERE name = 'session_work_candidates_v1'
               """)
    end

    test "release backfill keeps only the authoritative token at one Session address", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000066"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: shared_base}} = S3.get(session_key)

      stale_tokens =
        for _writer <- 1..2 do
          assert {:ok, %{"token" => token}} =
                   SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                     cas_base: shared_base
                   )

          token
        end

      assert {:ok, authoritative} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "authoritative-token-reconciliation",
                   "payload" => %{
                     "source_message_id" => "authoritative-token-reconciliation",
                     "content" => "keep only the committed unfinished-work token"
                   }
                 }
               ])

      reset_session_work_backfill!()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 2)

      assert {:ok, [candidate]} = SessionWorkCandidates.list_all()
      assert candidate["token"] == InternalSession.work_index_token(authoritative)
      assert candidate["session_id"] == session_id

      assert Enum.all?(stale_tokens, fn token ->
               SessionWorkCandidates.fetch_exact(token) == {:error, :not_found}
             end)
    end

    test "release backfill pages the roster in batches and verifies without a second S3 pass", %{
      agent: a
    } do
      agents = [a, SalixAgent.TestSupport.new_agent_id(), SalixAgent.TestSupport.new_agent_id()]
      Enum.each(agents, &SalixAgent.TestSupport.create_control_agent!/1)

      reset_session_work_backfill!()
      S3.Fake.reset_read_log()

      assert {:ok, %{objects: []}} =
               Task.async(fn -> S3.list("foreign/background/", max_keys: 1) end)
               |> Task.await()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 2)

      list_calls =
        Enum.filter(S3.Fake.read_log(self()), fn
          {:list, _prefix, _opts} -> true
          _other -> false
        end)

      assert length(list_calls) == 5

      roster_calls =
        Enum.filter(list_calls, fn {:list, prefix, _opts} ->
          prefix == Keys.ctl_agents_prefix()
        end)

      assert length(roster_calls) == 2
      assert Enum.all?(roster_calls, fn {:list, _prefix, opts} -> opts[:max_keys] == 2 end)
    end

    test "release verification is PG-only when expected coverage matches" do
      candidate = %{
        "token" => "expected-token",
        "agent_id" => "agt1_1200000000000000062",
        "runtime_kind" => "internal",
        "session_id" => "ses1_1200000000000000062",
        "base_revision" => "expected-revision",
        "reasons" => ["queued_input"],
        "updated_at" => 1
      }

      reset_session_work_backfill!()
      assert :ok = SessionWorkCandidates.insert(candidate)
      assert :ok = SessionWorkBackfillExpectedCandidates.replace_from_authority(candidate)
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.load()
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.put(%{phase: "verify"})
      S3.Fake.reset_read_log()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 2)
      assert S3.Fake.read_log(self()) == []
    end

    test "release verify retry is PG-only after address reconciliation is durable" do
      candidate = %{
        "token" => "authoritative-retry-token",
        "agent_id" => "agt1_1200000000000000067",
        "runtime_kind" => "internal",
        "session_id" => "ses1_1200000000000000067",
        "base_revision" => "authoritative-retry-revision",
        "reasons" => ["queued_input"],
        "updated_at" => 1
      }

      stale =
        candidate
        |> Map.put("token", "stale-retry-token")
        |> Map.put("base_revision", "stale-retry-revision")

      reset_session_work_backfill!()
      assert :ok = SessionWorkCandidates.insert(stale)
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.load()

      assert {:ok, _state} =
               SalixStore.SessionWorkBackfillState.persist_candidate(candidate, %{
                 phase: "verify",
                 processed: 1,
                 projection_gaps: 0,
                 uncovered_authoritative_work: 0
               })

      S3.Fake.reset_read_log()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 2)
      assert S3.Fake.read_log(self()) == []

      assert {:ok, [%{"token" => "authoritative-retry-token"}]} =
               SessionWorkCandidates.list_all()
    end

    test "release verification fails closed when an expected PG write is missing" do
      candidate = %{
        "token" => "lost-write-token",
        "agent_id" => "agt1_1200000000000000063",
        "runtime_kind" => "internal",
        "session_id" => "ses1_1200000000000000063",
        "base_revision" => "lost-write-revision",
        "reasons" => ["queued_input"],
        "updated_at" => 1
      }

      reset_session_work_backfill!()
      assert :ok = SessionWorkBackfillExpectedCandidates.replace_from_authority(candidate)
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.load()
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.put(%{phase: "verify"})

      assert {:error, {:uncovered_authoritative_work, 1}} =
               SessionWorkBackfill.run(page_size: 2)

      assert {:ok, false} = SalixStore.SessionWorkBackfillState.terminal?()
    end

    test "release verification fails closed when a workload locator differs" do
      candidate = %{
        "token" => "workload-locator-token",
        "agent_id" => "agt1_1200000000000000068",
        "runtime_kind" => "external",
        "session_id" => "ses1_1200000000000000068",
        "workload_id" => "workload_expected",
        "base_revision" => "workload-locator-revision",
        "reasons" => ["queued_input"],
        "updated_at" => 1
      }

      reset_session_work_backfill!()
      assert :ok = SessionWorkBackfillExpectedCandidates.replace_from_authority(candidate)
      assert :ok = SessionWorkCandidates.insert(%{candidate | "workload_id" => "workload_stale"})
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.load()
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.put(%{phase: "verify"})

      assert {:error, {:uncovered_authoritative_work, 1}} =
               SessionWorkBackfill.run(page_size: 2)

      assert {:ok, false} = SalixStore.SessionWorkBackfillState.terminal?()
      assert {:ok, %{projection_gaps: 1}} = SalixStore.SessionWorkBackfillState.read()
    end

    test "candidate written before cursor persistence is replayed idempotently", %{agent: a} do
      session_id = "ses1_1200000000000000064"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "candidate-before-cursor-crash",
                   "payload" => %{
                     "source_message_id" => "candidate-before-cursor-crash",
                     "content" => "resume the interrupted projection"
                   }
                 }
               ])

      assert {:ok, candidate} =
               SessionWorkCandidates.fetch_exact(InternalSession.work_index_token(session))

      assert :ok = SessionWorkBackfillExpectedCandidates.replace_from_authority(candidate)
      reset_session_work_backfill_state_only!()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 2)
      assert {:ok, [only]} = SessionWorkCandidates.list_all()
      assert only["token"] == InternalSession.work_index_token(session)
    end

    test "release verification fails closed when authoritative work is uncovered", %{agent: a} do
      session_id = "ses1_1200000000000000045"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "release-verification-gap",
                   "payload" => %{
                     "source_message_id" => "release-verification-gap",
                     "content" => "must remain covered"
                   }
                 }
               ])

      assert {:ok, expected} =
               SessionWorkCandidates.fetch_exact(InternalSession.work_index_token(session))

      reset_session_work_backfill!()
      assert :ok = SessionWorkBackfillExpectedCandidates.replace_from_authority(expected)
      assert :ok = SessionWorkCandidates.delete_exact(InternalSession.work_index_token(session))
      assert {:ok, _state} = SalixStore.SessionWorkBackfillState.load()

      assert {:ok, _state} =
               SalixStore.SessionWorkBackfillState.put(%{
                 phase: "verify",
                 agent_start_after: nil,
                 current_agent_key: nil,
                 marker_start_after: nil,
                 uncovered_authoritative_work: 0,
                 processed: 0
               })

      assert {:error, {:uncovered_authoritative_work, 1}} =
               SessionWorkBackfill.run(page_size: 1)

      assert {:ok, false} = SalixStore.SessionWorkBackfillState.terminal?()

      assert {:ok,
              %{
                phase: "verify",
                uncovered_authoritative_work: 0,
                projection_gaps: 1,
                processed: 0
              }} =
               SalixStore.SessionWorkBackfillState.read()
    end

    test "release backfill retains a missing authoritative Session marker without blocking terminal",
         %{agent: a} do
      missing_session_id = "ses1_1200000000000000046"
      healthy_session_id = "ses1_1200000000000000047"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, _marker} =
               SessionWorkIndex.mark(a, :internal, missing_session_id, ["unacked_queue_item"],
                 cas_base: "absent"
               )

      assert {:ok, healthy} =
               InternalSessionStore.prepare_commit(a, healthy_session_id, [
                 %{"type" => "session_created", "session_id" => healthy_session_id},
                 %{
                   "type" => "queue_append",
                   "session_id" => healthy_session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "release-backfill-after-missing",
                   "payload" => %{
                     "source_message_id" => "release-backfill-after-missing",
                     "content" => "project the healthy Session after the missing one"
                   }
                 }
               ])

      assert :ok = SessionWorkCandidates.delete_exact(InternalSession.work_index_token(healthy))
      reset_session_work_backfill!()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)

      assert {:ok, %{"session_id" => ^healthy_session_id}} =
               SessionWorkCandidates.fetch_exact(InternalSession.work_index_token(healthy))

      assert {:ok, retained_markers} = SessionWorkIndex.list(a)
      assert Enum.any?(retained_markers, &(&1["session_id"] == missing_session_id))
      assert {:ok, true} = SalixStore.SessionWorkBackfillState.terminal?()

      assert {:ok, %{status: :already_complete}} = SessionWorkBackfill.run(page_size: 1)
    end

    test "release backfill projects a legacy authoritative Session whose revision is nil", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000048"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: "absent"
               )

      legacy =
        a
        |> InternalSession.new(session_id, %{})
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "legacy-nil-revision",
            "payload" => %{
              "source_message_id" => "legacy-nil-revision",
              "content" => "project pre-revision work"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(token, ["unacked_queue_item"])

      assert InternalSession.storage_revision(legacy) == nil

      assert {:ok, _etag} =
               S3.put(
                 Keys.agent_internal_runtime_session(a, session_id),
                 Codec.compress_snapshot_etf(InternalSession.persist(legacy)),
                 if_none_match: "*"
               )

      assert :ok = SessionWorkCandidates.delete_exact(token)
      reset_session_work_backfill!()

      assert {:ok, %{status: :complete}} = SessionWorkBackfill.run(page_size: 1)

      assert {:ok, %{"base_revision" => nil, "session_id" => ^session_id}} =
               SessionWorkCandidates.fetch_exact(token)
    end

    test "release backfill bounds malformed roster and marker entries as uncovered", %{agent: a} do
      session_id = "ses1_1200000000000000049"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, _etag} =
               S3.put(Keys.ctl_agents_prefix() <> "invalid.json", Jason.encode!(%{}), [])

      assert {:ok, _etag} =
               S3.put(
                 Keys.agent_session_work_index(a, "internal", session_id),
                 "{not-json",
                 []
               )

      reset_session_work_backfill!()

      assert {:error, {:uncovered_authoritative_work, 2}} =
               SessionWorkBackfill.run(page_size: 1)

      assert {:ok, false} = SalixStore.SessionWorkBackfillState.terminal?()
    end

    for {label, token_field, malformed_session_id, blocked_session_id} <- [
          {"missing", %{}, "ses1_1200000000000000050", "ses1_1200000000000000051"},
          {"non-scalar", %{"token" => %{"malformed" => true}}, "ses1_1200000000000000052",
           "ses1_1200000000000000053"},
          {"empty", %{"token" => ""}, "ses1_1200000000000000054", "ses1_1200000000000000055"}
        ] do
      test "release backfill advances past a #{label} legacy marker token as uncovered", %{
        agent: a
      } do
        malformed_session_id = unquote(malformed_session_id)
        blocked_session_id = unquote(blocked_session_id)

        SalixAgent.TestSupport.create_control_agent!(a)

        for session_id <- [malformed_session_id, blocked_session_id] do
          assert {:ok, _stable} =
                   InternalSessionStore.prepare_commit(a, session_id, [
                     %{"type" => "session_created", "session_id" => session_id}
                   ])
        end

        malformed_key = Keys.agent_session_work_index(a, "internal", malformed_session_id)
        blocked_key = Keys.agent_session_work_index(a, "internal", blocked_session_id)

        malformed_marker =
          Map.merge(
            %{
              "agent_id" => a,
              "runtime_kind" => "internal",
              "session_id" => malformed_session_id
            },
            unquote(Macro.escape(token_field))
          )

        assert {:ok, _etag} = S3.put(malformed_key, Jason.encode!(malformed_marker), [])

        assert {:ok, _etag} =
                 S3.put(
                   blocked_key,
                   Jason.encode!(%{
                     "agent_id" => a,
                     "runtime_kind" => "internal",
                     "session_id" => blocked_session_id,
                     "token" => "valid-legacy-token"
                   }),
                   []
                 )

        reset_session_work_backfill!()
        assert :ok = S3.Fake.set_fault({:fail, 503, :get, blocked_key})

        assert {:error, {:marker_backfill_failed, ^blocked_key, {:http, 503}}} =
                 SessionWorkBackfill.run(page_size: 2)

        assert {:ok,
                %{
                  phase: "backfill",
                  marker_start_after: ^malformed_key,
                  processed: 1,
                  uncovered_authoritative_work: 1
                }} = SalixStore.SessionWorkBackfillState.read()

        assert {:error, {:uncovered_authoritative_work, 1}} =
                 SessionWorkBackfill.run(page_size: 2)

        assert {:ok, false} = SalixStore.SessionWorkBackfillState.terminal?()
      end
    end

    test "a dormant worker resumes the transcript after a committed tool result", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000017"
      Mock.script([{:final, "continued after the dormant tool result"}])
      SalixAgent.TestSupport.create_control_agent!(a)

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

      assert {:ok, [%{"reasons" => ["transcript_continuation"]}]} =
               SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"reasons" => ["transcript_continuation"]}], next: nil}} =
               SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(
               fn ->
                 session_has_content?(a, session_id, "continued after the dormant tool result")
               end,
               200
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 200)

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

      assert eventually(
               fn ->
                 SessionWorkIndex.list(a) == {:ok, []} and
                   match?({:ok, %{records: []}}, SessionWorkIndex.list_discovery()) and
                   match?(
                     {:ok, %{records: []}},
                     SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
                   )
               end,
               200
             )
    end

    test "recovery nudges a live parked AgentServer when the immediate session wake was lost", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000003"
      Mock.script([{:final, "parked owner recovered the session"}])
      SalixAgent.TestSupport.create_control_agent!(a)

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
            "created_at" => System.system_time(:second),
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
               200
             )

      assert eventually(
               fn ->
                 session_has_content?(a, session_id, "parked owner recovered the session")
               end,
               200
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 200)
    end

    test "a future wait keeps a deadline backstop without waking on every sweep", %{agent: a} do
      session_id = "ses1_1200000000000000004"
      wait_id = "future-wait"
      deadline_ms = System.system_time(:millisecond) + 60_000
      timer_key = Keys.timer(a, session_id, wait_id, Timers.minute_bucket(deadline_ms))
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "wait_set",
            "session_id" => session_id,
            "wait" => %{
              "wait_id" => wait_id,
              "reason" => "recovery must leave this to the timer",
              "deadline_ms" => deadline_ms
            }
          }
        ])

      assert InternalSession.get(session, :work_index_reasons) == ["wait_deadline"]
      assert {:ok, [_local_record]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [discovery], next: nil}} =
               SessionWorkIndex.list_due_discovery(deadline_ms)

      assert discovery["recover_after_ms"] == deadline_ms
      assert {:error, :not_found} = S3.get(timer_key)
      refute Fleet.running?(a)

      for _pass <- 1..2 do
        assert {:ok, %{session_work_rewoken: [], session_work_scanned: 0}} =
                 Recovery.sweep_once()

        refute Fleet.running?(a)
        assert {:error, :not_found} = S3.get(timer_key)

        assert {:ok, %{records: [_discovery], next: nil}} =
                 SessionWorkIndex.list_due_discovery(deadline_ms)
      end
    end

    test "a malformed wait is rejected without creating a cold-recovery wake loop", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000012"
      SalixAgent.TestSupport.create_control_agent!(a)

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
      assert {:ok, []} = SessionWorkIndex.list(a)
      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      refute Fleet.running?(a)

      for _pass <- 1..2 do
        assert {:ok, %{session_work_rewoken: [], session_work_scanned: 0}} =
                 Recovery.sweep_once()

        refute Fleet.running?(a)
      end
    end

    test "an eager input sharing a token with a future wait wakes immediately", %{agent: a} do
      session_id = "ses1_1200000000000000011"
      deadline_ms = System.system_time(:millisecond) + 60_000
      Mock.script([{:final, "future wait did not delay new work"}])
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "wait_set",
            "session_id" => session_id,
            "wait" => %{
              "wait_id" => "mixed-reason-wait",
              "reason" => "wait unless new work arrives",
              "deadline_ms" => deadline_ms
            }
          },
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "mixed-reason-input",
            "created_at" => System.system_time(:second),
            "payload" => %{
              "source_message_id" => "mixed-reason-input",
              "role" => "user",
              "content" => "handle this before the wait deadline"
            }
          }
        ])

      assert InternalSession.get(session, :work_index_reasons) == [
               "unacked_queue_item",
               "wait_deadline"
             ]

      assert {:ok, %{records: [_eager], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(
               fn ->
                 session_has_content?(a, session_id, "handle this before the wait deadline")
               end,
               200
             )

      assert eventually(
               fn ->
                 session_has_content?(a, session_id, "future wait did not delay new work")
               end,
               200
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 200)
    end

    test "an overdue wait without a timer resumes after full cold recovery", %{agent: a} do
      session_id = "ses1_1200000000000000009"
      Mock.script([{:final, "resumed after overdue wait"}])
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "wait_set",
            "session_id" => session_id,
            "wait" => %{
              "wait_id" => "overdue-wait",
              "reason" => "deadline elapsed while the runtime was asleep",
              "deadline_ms" => System.system_time(:millisecond) - 600_000
            }
          }
        ])

      assert InternalSession.get(session, :work_index_reasons) == ["wait_deadline"]

      assert {:ok, %{records: [_discovery], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      assert eventually(
               fn -> session_has_content?(a, session_id, "resumed after overdue wait") end,
               200
             )

      assert eventually(fn -> internal_sessions_settled?(a) end, 200)

      # Session state settles before the durable discovery candidate deletion
      # can become visible. Wait for both projections instead of racing that
      # asynchronous cleanup on a loaded scheduler.
      assert eventually(
               fn ->
                 match?({:ok, %{records: [], next: nil}}, SessionWorkIndex.list_discovery()) and
                   match?(
                     {:ok, %{records: [], next: nil}},
                     SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
                   )
               end,
               200
             )
    end

    test "an overdue external wait wakes its exact session after full cold recovery", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000010"
      wait_id = "overdue-external-wait"
      deadline_ms = System.system_time(:millisecond) - 600_000

      SalixAgent.TestSupport.create_control_agent!(a, %{
        "role" => "worker",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "recovery-device",
          "runtime_id" => "recovery-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

      {:ok, pid} =
        ExternalSessionActor.start_link(
          agent_id: a,
          session_id: session_id,
          process_on_init: false
        )

      assert {:ok, :committed} =
               ExternalSessionActor.stage_delivery(pid, %{
                 "source_message_id" => "external-recovery-seed",
                 "payload" => %{
                   "session_id" => session_id,
                   "role" => "user",
                   "content" => "seed external recovery state",
                   "no_wake" => true
                 }
               })

      assert {:ok, wait_state} =
               ExternalSessionActor.commit_session_events(pid, [
                 %{
                   "type" => "wait_set",
                   "session_id" => session_id,
                   "wait" => %{
                     "wait_id" => wait_id,
                     "reason" => "deadline elapsed while every owner was asleep",
                     "deadline_ms" => deadline_ms
                   }
                 }
               ])

      due_candidate_token = wait_state["work_index_token"]
      assert is_binary(due_candidate_token)

      timer_key = Keys.timer(a, session_id, wait_id, Timers.minute_bucket(deadline_ms))
      assert :ok = S3.delete(timer_key)
      assert :ok = GenServer.stop(pid, :normal)

      # GenServer.stop/3 waits for the actor to exit, but Registry removes the
      # monitored registration asynchronously. Fence that exact projection
      # before asserting the fully cold state; a loaded scheduler can otherwise
      # expose the already-dead actor until Registry consumes its DOWN message.
      assert eventually(
               fn ->
                 Registry.lookup(
                   SalixAgent.Registry,
                   ExternalSessionActor.key(a, session_id)
                 ) == []
               end,
               200
             )

      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      source_id = "wait-timeout:#{session_id}:#{wait_id}"

      assert eventually(
               fn ->
                 case ExternalSessionStore.get_session_record(a, session_id) do
                   {:ok, state} ->
                     state["wait"] == nil and
                       Enum.count(
                         state["input_message_queue"],
                         &(&1["source_message_id"] == source_id)
                       ) == 1

                   {:error, _reason} ->
                     false
                 end
               end,
               200
             )

      assert [{recovered_pid, _value}] =
               Registry.lookup(
                 SalixAgent.Registry,
                 ExternalSessionActor.key(a, session_id)
               )

      # The session-state CAS becomes visible before the same actor finishes
      # retiring its old deferred candidate. Synchronize with that exact owner
      # instead of racing the callback or asserting that the global lane is empty.
      _actor_state = :sys.get_state(recovered_pid)

      assert {:error, :not_found} =
               SessionWorkCandidates.fetch_exact(due_candidate_token)
    end

    test "an overdue external wait progresses when its SessionActor is already alive", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000043"
      wait_id = "live-external-overdue-wait"
      deadline_ms = System.system_time(:millisecond) - 1_000

      SalixAgent.TestSupport.create_control_agent!(a, %{
        "role" => "worker",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "recovery-device",
          "runtime_id" => "recovery-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

      {:ok, pid} =
        ExternalSessionActor.start_link(
          agent_id: a,
          session_id: session_id,
          process_on_init: false
        )

      assert {:ok, :committed} =
               ExternalSessionActor.stage_delivery(pid, %{
                 "source_message_id" => "live-external-recovery-seed",
                 "payload" => %{
                   "session_id" => session_id,
                   "role" => "user",
                   "content" => "seed live external recovery state",
                   "no_wake" => true
                 }
               })

      assert {:ok, _state} =
               ExternalSessionActor.commit_session_events(pid, [
                 %{
                   "type" => "wait_set",
                   "session_id" => session_id,
                   "wait" => %{
                     "wait_id" => wait_id,
                     "reason" => "deadline elapsed while the session actor stayed alive",
                     "deadline_ms" => deadline_ms
                   }
                 }
               ])

      timer_key = Keys.timer(a, session_id, wait_id, Timers.minute_bucket(deadline_ms))
      assert :ok = S3.delete(timer_key)
      assert Process.alive?(pid)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} = Recovery.sweep_once()
      assert a in session_work_rewoken

      source_id = "wait-timeout:#{session_id}:#{wait_id}"

      assert eventually(
               fn ->
                 case ExternalSessionStore.get_session_record(a, session_id) do
                   {:ok, state} ->
                     state["wait"] == nil and
                       Enum.count(
                         state["input_message_queue"],
                         &(&1["source_message_id"] == source_id)
                       ) == 1

                   {:error, _reason} ->
                     false
                 end
               end,
               100
             )

      assert eventually(
               fn ->
                 match?(
                   {:ok, %{records: [], next: nil}},
                   SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
                 )
               end,
               200
             )
    end

    test "a transient deferred authoritative read cannot erase an overdue wait", %{agent: a} do
      session_id = "ses1_1200000000000000041"
      wait_id = "transient-deferred-discovery-read"
      now_ms = System.system_time(:millisecond)
      source_id = "wait-timeout:#{session_id}:#{wait_id}"

      Mock.script([{:final, "recovered after transient discovery read"}])
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "wait_set",
                   "session_id" => session_id,
                   "wait" => %{
                     "wait_id" => wait_id,
                     "reason" => "deferred discovery read failed once",
                     "deadline_ms" => now_ms - 1_000
                   }
                 }
               ])

      assert {:ok, %{records: [%{"token" => token}], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert :ok = S3.Fake.set_fault({:fail, 503, :get, session_key})

      assert %{
               rewoken: [],
               scanned: 1,
               cleaned: 0,
               failed: 1
             } = SessionWorkRecovery.sweep(now: now_ms)

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      assert %{rewoken: [^a], failed: 0} = SessionWorkRecovery.sweep(now: now_ms)

      assert eventually(
               fn ->
                 session_has_content?(
                   a,
                   session_id,
                   "recovered after transient discovery read"
                 )
               end,
               200
             )

      assert eventually(fn -> session_source_count(a, session_id, source_id) == 1 end, 200)
    end

    test "a transient eager authoritative read cannot hide immediate work", %{agent: a} do
      session_id = "ses1_1200000000000000042"
      source_id = "transient-eager-discovery-read"

      Mock.script([{:final, "recovered after transient eager discovery read"}])
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => source_id,
                   "payload" => %{
                     "source_message_id" => source_id,
                     "content" => "recover this immediate work"
                   }
                 }
               ])

      assert {:ok, %{records: [%{"token" => token}], next: nil}} =
               SessionWorkIndex.list_discovery()

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert :ok = S3.Fake.set_fault({:fail, 503, :get, session_key})

      assert %{
               rewoken: [],
               scanned: 1,
               cleaned: 0,
               failed: 1
             } = SessionWorkRecovery.sweep()

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()

      assert %{rewoken: [^a], failed: 0} = SessionWorkRecovery.sweep()

      assert eventually(
               fn ->
                 session_has_content?(
                   a,
                   session_id,
                   "recovered after transient eager discovery read"
                 )
               end,
               200
             )

      assert eventually(fn -> session_source_count(a, session_id, source_id) == 1 end, 200)
    end

    test "a wait missed by the timer lookback still resumes exactly once", %{agent: a} do
      session_id = "ses1_1200000000000000012"
      wait_id = "missed-timer-window"
      now_ms = System.system_time(:millisecond)
      deadline_ms = now_ms - 10 * 60_000
      source_id = "wait-timeout:#{session_id}:#{wait_id}"

      wait = %{
        "wait_id" => wait_id,
        "reason" => "timer singleton was asleep beyond its lookback",
        "timeout_seconds" => 60,
        "deadline_ms" => deadline_ms,
        "source" => "wait_for"
      }

      Mock.script([{:final, "recovered beyond timer lookback"}])
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, _session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "wait_set", "session_id" => session_id, "wait" => wait}
               ])

      assert :ok = SalixAgent.Waits.register_timer_for_wait(a, session_id, wait)

      timer_key = Keys.timer(a, session_id, wait_id, Timers.minute_bucket(deadline_ms))
      assert {:ok, _timer} = S3.get(timer_key)

      # The timer singleton intentionally scans only the recent five-minute
      # window, so this old marker is invisible to its normal pass.
      assert {:ok, []} =
               SalixCluster.Timers.fire_due(now: now_ms, lookback_minutes: 5)

      assert {:ok, _timer} = S3.get(timer_key)
      refute Fleet.running?(a)

      assert {:ok, %{session_work_rewoken: session_work_rewoken}} =
               Recovery.sweep_once(now: now_ms)

      assert a in session_work_rewoken

      assert eventually(
               fn -> session_has_content?(a, session_id, "recovered beyond timer lookback") end,
               200
             )

      assert eventually(fn -> session_source_count(a, session_id, source_id) == 1 end, 200)

      # If the old timer marker is later swept with a wider operator window,
      # the same deterministic source id reaches the session dedupe boundary
      # and cannot create a second timeout fact or second LLM round.
      assert {:ok, [%{source_message_id: ^source_id}]} =
               SalixCluster.Timers.fire_due(now: now_ms, lookback_minutes: 15)

      assert session_source_count(a, session_id, source_id) == 1
      assert {:error, :not_found} = S3.get(timer_key)
    end

    test "pre-CAS work for an existing session survives until its matching CAS can land", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000005"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})
      assert InternalSession.work_index_token(stable) == nil

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: cas_base}} = S3.get(session_key)

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: cas_base
               )

      assert {:ok, [%{"session_id" => ^session_id}]} = SessionWorkIndex.list(a)
      assert {:ok, %{records: [_record], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_scanned: 1,
                session_work_cleaned: 0
              }} = Recovery.sweep_once()

      assert {:ok, [%{"token" => ^token}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()

      next =
        stable
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "pre-cas-existing",
            "payload" => %{
              "source_message_id" => "pre-cas-existing",
              "content" => "resume after the CAS"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(token, ["unacked_queue_item"])

      assert {:ok, _etag} =
               S3.put(
                 session_key,
                 Codec.compress_snapshot_etf(InternalSession.persist(next)),
                 if_match: cas_base
               )

      assert {:ok, %{session_work_rewoken: rewoken}} = Recovery.sweep_once()
      assert a in rewoken
    end

    test "failure-first: every persisted Session write mints a non-reusable revision", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000042"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, created} = InternalSessionStore.prepare_create(a, session_id, %{})
      created_revision = InternalSession.storage_revision(created)
      assert is_binary(created_revision)

      assert :ok = InternalSessionStore.prepare_seed(a, created, force: true)
      assert {:ok, forced} = InternalSessionStore.read(a, session_id)
      forced_revision = InternalSession.storage_revision(forced)
      assert is_binary(forced_revision)
      refute forced_revision == created_revision

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert :ok = S3.delete(session_key)
      assert {:ok, recreated} = InternalSessionStore.prepare_create(a, session_id, %{})
      recreated_revision = InternalSession.storage_revision(recreated)
      assert is_binary(recreated_revision)
      refute recreated_revision in [created_revision, forced_revision]
    end

    test "failure-first: a superseded pre-CAS candidate is retired exactly", %{agent: a} do
      session_id = "ses1_1200000000000000043"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok, %{"token" => stale_token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 base_revision: InternalSession.storage_revision(stable)
               )

      assert {:ok, current} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "queue_append",
                   "session_id" => session_id,
                   "kind" => "user_message",
                   "dedupe_key" => "supersede-pre-cas",
                   "payload" => %{
                     "source_message_id" => "supersede-pre-cas",
                     "content" => "advance the authoritative session"
                   }
                 }
               ])

      refute InternalSession.work_index_token(current) == stale_token

      assert %{
               cleaned: 1,
               failed: 0
             } = SessionWorkRecovery.sweep()

      assert {:ok, %{records: discovery}} = SessionWorkIndex.list_discovery()
      refute Enum.any?(discovery, &(&1["token"] == stale_token))
    end

    test "pre-create work survives until its create CAS can land", %{agent: a} do
      session_id = "ses1_1200000000000000027"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: "absent"
               )

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_scanned: 1,
                session_work_cleaned: 0
              }} = Recovery.sweep_once()

      assert {:ok, [%{"token" => ^token}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()

      next =
        a
        |> InternalSession.new(session_id, %{})
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "pre-cas-create",
            "payload" => %{
              "source_message_id" => "pre-cas-create",
              "content" => "resume after the create CAS"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(token, ["unacked_queue_item"])

      assert {:ok, _etag} =
               S3.put(
                 Keys.agent_internal_runtime_session(a, session_id),
                 Codec.compress_snapshot_etf(InternalSession.persist(next)),
                 if_none_match: "*"
               )

      assert {:ok, %{session_work_rewoken: rewoken}} = Recovery.sweep_once()
      assert a in rewoken
    end

    test "probe: a create generation remains discoverable if an intervening session is deleted",
         %{
           agent: a
         } do
      session_id = "ses1_1200000000000000032"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: "absent"
               )

      assert {:ok, _intervening} = InternalSessionStore.prepare_create(a, session_id, %{})

      assert {:ok,
              %{
                session_work_cleaned: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert :ok = S3.delete(session_key)

      resumed =
        a
        |> InternalSession.new(session_id, %{})
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "resumed-create-after-delete",
            "payload" => %{
              "source_message_id" => "resumed-create-after-delete",
              "content" => "resumed create"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(token, ["unacked_queue_item"])

      assert {:ok, _etag} =
               S3.put(
                 session_key,
                 Codec.compress_snapshot_etf(InternalSession.persist(resumed)),
                 if_none_match: "*"
               )

      assert {:ok, [%{"token" => ^token}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()
    end

    test "a non-reusable storage revision prevents ETag ABA from reviving a stale writer", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000033"
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{body: original_body, etag: original_etag}} = S3.get(session_key)
      {:ok, original} = InternalSession.load(Codec.snapshot_etf(original_body))

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: original_etag,
                 base_revision: InternalSession.storage_revision(original)
               )

      modified =
        original
        |> InternalSession.export()
        |> then(&Map.put(&1, :last_activity_at, (&1.last_activity_at || 0) + 1))
        |> InternalSession.open()

      assert :ok = InternalSessionStore.prepare_seed(a, modified, force: true)
      assert {:ok, %{etag: modified_etag}} = S3.get(session_key)
      refute modified_etag == original_etag

      assert {:ok,
              %{
                session_work_cleaned: 1,
                session_work_unproven_retained: 0
              }} = Recovery.sweep_once()

      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert :ok = InternalSessionStore.prepare_seed(a, original, force: true)
      assert {:ok, %{etag: restored_etag}} = S3.get(session_key)
      refute restored_etag == original_etag

      resumed =
        original
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "resumed-after-etag-aba",
            "payload" => %{
              "source_message_id" => "resumed-after-etag-aba",
              "content" => "resumed after ABA"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(token, ["unacked_queue_item"])

      assert {:error, :precondition_failed} =
               S3.put(
                 session_key,
                 Codec.compress_snapshot_etf(InternalSession.persist(resumed)),
                 if_match: original_etag
               )

      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()
    end

    test "probe: token-addressed intents preserve the winner of two same-base writers", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000034"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: shared_base}} = S3.get(session_key)

      assert {:ok, %{"token" => winner_token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: shared_base
               )

      assert {:ok, %{"token" => loser_token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: shared_base
               )

      refute winner_token == loser_token

      winner =
        stable
        |> InternalSession.apply_events([
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "same-base-winner",
            "payload" => %{
              "source_message_id" => "same-base-winner",
              "content" => "the first writer won"
            }
          }
        ])
        |> InternalSession.normalize()
        |> InternalSession.put_work_index(winner_token, ["unacked_queue_item"])

      assert {:ok, _winner_etag} =
               S3.put(
                 session_key,
                 Codec.compress_snapshot_etf(InternalSession.persist(winner)),
                 if_match: shared_base
               )

      server = start_supervised!({SlowSessionRecoveryServer, self()})
      SlowSessionRecoveryPlacement.configure(server, self())
      Application.put_env(:salix_agent, :placement, SlowSessionRecoveryPlacement)

      on_exit(fn -> SlowSessionRecoveryPlacement.clear() end)

      assert {:ok,
              %{
                session_work_rewoken: [^a],
                session_work_scanned: 2,
                session_work_cleaned: 0,
                session_work_failed: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert_receive {:slow_session_recovery_started,
                      [%{runtime: :internal, session_id: ^session_id}]},
                     500

      assert {:ok, %{records: discovery, next: nil}} = SessionWorkIndex.list_discovery()

      assert Enum.sort(Enum.map(discovery, & &1["token"])) ==
               Enum.sort([winner_token, loser_token])
    end

    test "probe: same-base intents all remain when every writer crashes before CAS", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000037"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})

      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: shared_base}} = S3.get(session_key)

      tokens =
        for _writer <- 1..3 do
          assert {:ok, %{"token" => token}} =
                   SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                     cas_base: shared_base
                   )

          token
        end

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_scanned: 3,
                session_work_cleaned: 0,
                session_work_failed: 0
              }} = Recovery.sweep_once()

      assert {:ok, %{records: discovery, next: nil}} = SessionWorkIndex.list_discovery()
      assert Enum.sort(Enum.map(discovery, & &1["token"])) == Enum.sort(tokens)
    end

    test "probe: external create work remains discoverable after intervening delete", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000035"
      session_key = Keys.agent_external_runtime_session(a, session_id)

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :external, session_id, ["unacked_queue_item"],
                 cas_base: "absent"
               )

      intervening = external_session_state(a, session_id)

      assert {:ok, _etag} =
               S3.put(session_key, Jason.encode!(intervening), if_none_match: "*")

      assert {:ok,
              %{
                session_work_cleaned: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert :ok = S3.delete(session_key)

      resumed =
        intervening
        |> Map.put("input_message_queue", [external_user_input("external-resumed-create")])
        |> Map.put("work_index_token", token)

      assert {:ok, _etag} =
               S3.put(session_key, Jason.encode!(resumed), if_none_match: "*")

      assert {:ok, [%{"token" => ^token}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()
    end

    test "probe: external content-hash ABA cannot strand a resumed writer", %{agent: a} do
      session_id = "ses1_1200000000000000036"
      session_key = Keys.agent_external_runtime_session(a, session_id)
      original = external_session_state(a, session_id)
      original_body = Jason.encode!(original)

      assert {:ok, _created} =
               S3.put(session_key, original_body, if_none_match: "*")

      assert {:ok, %{etag: original_etag}} = S3.get(session_key)

      assert {:ok, %{"token" => token}} =
               SessionWorkIndex.mark(a, :external, session_id, ["unacked_queue_item"],
                 cas_base: original_etag
               )

      modified = Map.update!(original, "updated_at", &(&1 + 1))

      assert {:ok, _modified} =
               S3.put(session_key, Jason.encode!(modified), if_match: original_etag)

      assert {:ok, %{etag: modified_etag}} = S3.get(session_key)

      refute modified_etag == original_etag

      assert {:ok,
              %{
                session_work_cleaned: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert {:ok, %{etag: ^original_etag}} =
               S3.put(session_key, original_body, if_match: modified_etag)

      resumed =
        original
        |> Map.put("input_message_queue", [external_user_input("external-resumed-aba")])
        |> Map.put("work_index_token", token)

      assert {:ok, _etag} =
               S3.put(session_key, Jason.encode!(resumed), if_match: original_etag)

      assert {:ok, [%{"token" => ^token}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()
    end

    test "probe: external same-base intents preserve the winning writer", %{agent: a} do
      session_id = "ses1_1200000000000000038"
      session_key = Keys.agent_external_runtime_session(a, session_id)
      stable = external_session_state(a, session_id)

      assert {:ok, _created} =
               S3.put(session_key, Jason.encode!(stable), if_none_match: "*")

      assert {:ok, %{etag: shared_base}} = S3.get(session_key)

      assert {:ok, %{"token" => winner_token}} =
               SessionWorkIndex.mark(a, :external, session_id, ["unacked_queue_item"],
                 cas_base: shared_base
               )

      assert {:ok, %{"token" => loser_token}} =
               SessionWorkIndex.mark(a, :external, session_id, ["unacked_queue_item"],
                 cas_base: shared_base
               )

      winner =
        stable
        |> Map.put("input_message_queue", [external_user_input("external-same-base-winner")])
        |> Map.put("work_index_token", winner_token)

      assert {:ok, _winner} =
               S3.put(session_key, Jason.encode!(winner), if_match: shared_base)

      server = start_supervised!({SlowSessionRecoveryServer, self()})
      SlowSessionRecoveryPlacement.configure(server, self())
      Application.put_env(:salix_agent, :placement, SlowSessionRecoveryPlacement)

      on_exit(fn -> SlowSessionRecoveryPlacement.clear() end)

      assert {:ok,
              %{
                session_work_rewoken: [^a],
                session_work_scanned: 2,
                session_work_cleaned: 0,
                session_work_failed: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert_receive {:slow_session_recovery_started,
                      [%{runtime: :external, session_id: ^session_id}]},
                     500

      assert {:ok, %{records: discovery, next: nil}} = SessionWorkIndex.list_discovery()

      assert Enum.sort(Enum.map(discovery, & &1["token"])) ==
               Enum.sort([winner_token, loser_token])
    end

    test "a superseded CAS generation is retained without disturbing the live generation", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000028"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})
      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: first_base}} = S3.get(session_key)

      assert {:ok, %{"token" => abandoned_token}} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: first_base
               )

      assert {:ok, live} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => session_id,
                   "tool_call_id" => "live-callback-generation",
                   "tool_name" => "permission.request",
                   "status" => "running",
                   "completion_mode" => "external_callback",
                   "capability_deadline_ms" => System.system_time(:millisecond) + 60_000
                 }
               ])

      live_token = InternalSession.work_index_token(live)
      refute live_token == abandoned_token

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_cleaned: 0,
                session_work_failed: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"token" => ^abandoned_token}], next: nil}} =
               SessionWorkIndex.list_discovery()
    end

    test "a missing session cannot prove its update generation dead", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000029"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})
      session_key = Keys.agent_internal_runtime_session(a, session_id)
      assert {:ok, %{etag: cas_base}} = S3.get(session_key)

      assert {:ok, _record} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: cas_base
               )

      assert :ok = S3.delete(session_key)

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_cleaned: 0,
                session_work_failed: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert {:ok, [%{"session_id" => ^session_id}]} = SessionWorkIndex.list(a)

      assert {:ok, %{records: [%{"session_id" => ^session_id}], next: nil}} =
               SessionWorkIndex.list_discovery()
    end

    test "probe: old-format records fail safe even when aged and missing", %{
      agent: a
    } do
      existing_session_id = "ses1_1200000000000000030"
      missing_session_id = "ses1_1200000000000000031"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, _stable} = InternalSessionStore.prepare_create(a, existing_session_id, %{})

      assert {:ok, %{"token" => kept_token}} =
               SessionWorkIndex.mark(
                 a,
                 :internal,
                 existing_session_id,
                 ["unacked_queue_item"]
               )

      assert {:ok, _aged_missing} =
               SessionWorkIndex.mark(a, :internal, missing_session_id, ["unacked_queue_item"],
                 updated_at: System.system_time(:second) - 600
               )

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_scanned: 2,
                session_work_cleaned: 0,
                session_work_failed: 0,
                session_work_unproven_retained: 2
              }} = Recovery.sweep_once()

      assert {:ok, records} = SessionWorkIndex.list(a)

      assert Enum.sort(Enum.map(records, & &1["session_id"])) ==
               Enum.sort([existing_session_id, missing_session_id])

      assert Enum.find(records, &(&1["session_id"] == existing_session_id))["token"] == kept_token

      assert {:ok, %{records: discovery}} = SessionWorkIndex.list_discovery()

      assert Enum.sort(Enum.map(discovery, & &1["session_id"])) ==
               Enum.sort([existing_session_id, missing_session_id])
    end

    test "an unproven generation never attempts discovery deletion", %{agent: a} do
      session_id = "ses1_1200000000000000025"
      SalixAgent.TestSupport.create_control_agent!(a)
      {:ok, stable} = InternalSessionStore.prepare_create(a, session_id, %{})
      assert InternalSession.work_index_token(stable) == nil
      cas_base = superseded_internal_session_base!(a, session_id)

      assert {:ok, record} =
               SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"],
                 cas_base: cas_base
               )

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_cleaned: 0,
                session_work_failed: 0,
                session_work_unproven_retained: 1
              }} = Recovery.sweep_once()

      assert {:ok, [%{"token" => token}]} = SessionWorkIndex.list(a)
      assert token == record["token"]

      assert {:ok, %{records: [%{"token" => ^token}], next: nil}} =
               SessionWorkIndex.list_discovery()

      refute Fleet.running?(a)
    end

    test "callback-only work is discoverable at its deadline without early wake", %{
      agent: a
    } do
      session_id = "ses1_1200000000000000026"
      SalixAgent.TestSupport.create_control_agent!(a)

      assert {:ok, session} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => session_id,
                   "tool_call_id" => "live-callback",
                   "tool_name" => "permission.request",
                   "status" => "running",
                   "completion_mode" => "external_callback",
                   "capability_deadline_ms" => System.system_time(:millisecond) + 60_000
                 }
               ])

      live_token = InternalSession.work_index_token(session)
      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      assert {:ok,
              %{
                session_work_rewoken: [],
                session_work_cleaned: 0,
                session_work_failed: 0
              }} = Recovery.sweep_once()

      assert {:ok, [%{"token" => ^live_token}]} = SessionWorkIndex.list(a)
      assert {:ok, %{records: [], next: nil}} = SessionWorkIndex.list_discovery()

      assert {:ok, %{records: [], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))

      assert {:ok, %{records: [%{"token" => ^live_token}], next: nil}} =
               SessionWorkIndex.list_due_discovery(System.system_time(:millisecond) + 60_000)

      refute Fleet.running?(a)
    end

    test "failed capability settlement survives owner loss and unrelated eager pages", %{agent: a} do
      SalixAgent.TestSupport.create_control_agent!(a)
      Mock.script(List.duplicate({:final, "Recovery finished."}, 4))

      for suffix <- 1..3 do
        sid = "ses1_120000000000000004#{suffix}"

        {:ok, _} =
          InternalSessionStore.prepare_commit(a, sid, [
            %{"type" => "session_created", "session_id" => sid},
            %{"type" => "status", "session_id" => sid, "status" => "active"}
          ])
      end

      target = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(target)
      sid = "ses1_1200000000000000049"
      call_id = "cold-expiry"

      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => target,
          "source_session_id" => sid,
          "tool_call_id" => call_id,
          "request_type" => "host_access",
          "request_payload" => %{},
          "expires_at" => System.system_time(:second) - 1
        })

      {:ok, _} =
        InternalSessionStore.prepare_commit(target, sid, [
          %{"type" => "session_created", "session_id" => sid},
          %{"type" => "status", "session_id" => sid, "status" => "active"},
          Map.merge(SalixAgent.CapabilityRequestStore.execution_fields(request), %{
            "type" => "async_tool_call_started",
            "session_id" => sid,
            "tool_call_id" => call_id,
            "tool_name" => "permission.request",
            "status" => "running",
            "completion_mode" => "external_callback"
          })
        ])

      # The request can reach its terminal result while the Session write fails.
      # Keep that failure active until the owner exits, so no in-memory retry
      # can make the recovery assertion pass.
      key = Keys.agent_internal_runtime_session(target, sid)
      S3.Fake.reset_put_log()
      S3.Fake.blackhole({:fail, 503, :put, key})
      on_exit(fn -> if Process.whereis(S3.Fake), do: S3.Fake.clear_blackhole() end)
      {:ok, owner} = SalixAgent.InternalSessionFleet.ensure_started(target, sid)
      assert eventually(fn -> key in S3.Fake.put_log() end)
      assert :ok = Fleet.terminate_child(owner)
      refute Process.alive?(owner)

      assert {:ok, unfinished} = InternalSessionStore.read(target, sid)

      assert {:ok, %{"status" => "running"}} =
               InternalSession.lookup_async_call(unfinished, call_id)

      assert {:ok, [_ | _]} = SessionWorkIndex.list(target)

      assert {:ok, %{"status" => "expired"}} =
               SalixAgent.CapabilityRequests.get(
                 request["group_id"],
                 request["request_id"],
                 request["tenant_id"]
               )

      S3.Fake.clear_blackhole()

      # A new recovery worker has no cursors or notifications from the failed
      # owner. Its normal eager-first sweep must also reach the overdue work.
      worker = start_supervised!({SessionWorkRecovery, name: nil, session_work_max_keys: 1})
      assert :ok = SessionWorkRecovery.request_sweep(worker)

      assert eventually(fn ->
               with {:ok, session} <- InternalSessionStore.read(target, sid),
                    {:ok, record} <- InternalSession.lookup_async_call(session, call_id) do
                 record["status"] == "failed" and
                   record["error_class"] == "capability_request_expired" and
                   InternalSession.pending_obligation_count(session) == 0
               else
                 _ -> false
               end
             end)

      assert eventually(fn -> session_has_content?(target, sid, "Recovery finished.") end)
    end

    test "global discovery scan is paginated with opaque cursors", %{agent: a} do
      SalixAgent.TestSupport.create_control_agent!(a)

      for suffix <- 6..8 do
        session_id = "ses1_120000000000000000#{suffix}"
        {:ok, _session} = InternalSessionStore.prepare_create(a, session_id, %{})

        assert {:ok, _record} =
                 SessionWorkIndex.mark(a, :internal, session_id, ["unacked_queue_item"])
      end

      assert {:ok, %{records: first_page, next: cursor}} =
               SessionWorkIndex.list_discovery(max_keys: 2)

      assert length(first_page) == 2
      assert is_binary(cursor)

      assert {:ok, %{records: second_page, next: nil}} =
               SessionWorkIndex.list_discovery(max_keys: 2, continuation_token: cursor)

      assert length(second_page) == 1
    end

    test "deferred recovery rotates across due pages and stops before future waits", %{agent: a} do
      now_ms = System.system_time(:millisecond)

      due_sessions =
        for suffix <- 13..15 do
          session_id = "ses1_12000000000000000#{suffix}"
          {:ok, _stable} = InternalSessionStore.prepare_create(a, session_id, %{})
          cas_base = superseded_internal_session_base!(a, session_id)

          assert {:ok, _record} =
                   SessionWorkIndex.mark(a, :internal, session_id, ["wait_deadline"],
                     cas_base: cas_base,
                     recover_after_ms: now_ms - (16 - suffix) * 1_000
                   )

          session_id
        end

      future_session = "ses1_1200000000000000016"
      {:ok, _stable} = InternalSessionStore.prepare_create(a, future_session, %{})
      future_cas_base = superseded_internal_session_base!(a, future_session)

      assert {:ok, future_record} =
               SessionWorkIndex.mark(a, :internal, future_session, ["wait_deadline"],
                 cas_base: future_cas_base,
                 recover_after_ms: now_ms + 60_000
               )

      assert length(due_sessions) == 3

      assert {:ok,
              %{
                session_work_scanned: 2,
                session_work_cleaned: 0,
                session_work_unproven_retained: 2,
                session_work_deferred_cursor: cursor
              }} = Recovery.sweep_once(now: now_ms, session_work_max_keys: 2)

      assert is_binary(cursor)

      assert {:ok,
              %{
                session_work_scanned: 1,
                session_work_cleaned: 0,
                session_work_unproven_retained: 1,
                session_work_deferred_cursor: nil
              }} =
               Recovery.sweep_once(
                 now: now_ms,
                 session_work_max_keys: 2,
                 deferred_session_work_cursor: cursor
               )

      assert {:ok, remaining_records} = SessionWorkIndex.list(a)

      assert Enum.sort(Enum.map(remaining_records, & &1["session_id"])) ==
               Enum.sort(due_sessions ++ [future_session])

      # A fresh pass starts at the oldest retained unproven records. It advances
      # an opaque cursor past them without hydrating the later future deadline.
      S3.Fake.reset_read_log()

      assert {:ok,
              %{
                session_work_scanned: 2,
                session_work_cleaned: 0,
                session_work_unproven_retained: 2,
                session_work_deferred_cursor: restart_cursor
              }} = Recovery.sweep_once(now: now_ms, session_work_max_keys: 2)

      assert is_binary(restart_cursor)

      future_key = Keys.agent_internal_runtime_session(a, future_session)

      refute Enum.any?(S3.Fake.read_log(), fn
               {:get, ^future_key} -> true
               _other -> false
             end)

      assert {:ok, %{records: deferred_records, next: nil}} =
               SessionWorkIndex.list_due_discovery(now_ms + 60_000)

      assert Enum.sort(Enum.map(deferred_records, & &1["session_id"])) ==
               Enum.sort(due_sessions ++ [future_session])

      assert Enum.any?(deferred_records, &(&1["token"] == future_record["token"]))
      refute Fleet.running?(a)
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
        owner = Application.fetch_env!(:salix_cluster, :recovery_pause_test_pid)
        send(owner, {:root_snapshot_taken, self()})

        receive do
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
      live = "live-#{System.unique_integer([:positive])}"
      dead = "dead-#{System.unique_integer([:positive])}"
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
      dead = "dead-#{System.unique_integer([:positive])}"
      live = "live-#{System.unique_integer([:positive])}"
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
      now = System.system_time(:millisecond)
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
      live = "live-#{System.unique_integer([:positive])}"
      dead = "dead-#{System.unique_integer([:positive])}"
      env_live = connect_device(live, "l")
      env_dead = connect_device(dead, "d")

      disconnected = Recovery.sweep_envs(live_nodes: [live], deep: false)

      assert env_dead.run_id in disconnected
      refute env_live.run_id in disconnected
      assert {:ok, %{"status" => "disconnected"}} = get_device(env_dead)
      assert {:ok, %{"status" => "connected"}} = get_device(env_live)
    end

    test "the ownerless deep check runs only on the deep pass" do
      now = System.system_time(:millisecond)
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
      node_name = "gone-#{System.unique_integer([:positive])}"
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
      dead = "dead-#{System.unique_integer([:positive])}"
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
      node_name = "rejoin-race-#{System.unique_integer([:positive])}"
      env = connect_device(node_name, "r")
      transport_id = env.transport_id

      Application.put_env(:salix_cluster, :recovery_pause_test_pid, self())
      Application.put_env(:salix_store, :s3_backend, PausingRootMarkerListS3)

      on_exit(fn ->
        Application.delete_env(:salix_cluster, :recovery_pause_test_pid)
      end)

      sweep =
        Task.async(fn ->
          Recovery.sweep_envs(live_nodes: ["somewhere-else"], deep: false)
        end)

      assert_receive {:root_snapshot_taken, lister}

      # The node "rejoins": same node name, same device, new generation.
      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(node_name, env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2
      new_run_id = reconnected["connector_run_id"]

      send(lister, :resume)
      disconnected = Task.await(sweep, 10_000)

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
      node_name = "deep-rejoin-#{System.unique_integer([:positive])}"
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

      Application.put_env(:salix_cluster, :recovery_pause_test_pid, self())
      Application.put_env(:salix_store, :s3_backend, PausingRootMarkerListS3)

      on_exit(fn ->
        Application.delete_env(:salix_cluster, :recovery_pause_test_pid)
      end)

      sweep = Task.async(fn -> Recovery.sweep_envs(live_nodes: live_fun) end)

      assert_receive {:root_snapshot_taken, lister}

      # The node rejoins: same name, same device, generation 2 — and the
      # cluster now sees it as live again.
      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(node_name, env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2
      new_run_id = reconnected["connector_run_id"]
      :ets.insert(liveness, {:live, ["somewhere-else", node_name]})

      send(lister, :resume)
      disconnected = Task.await(sweep, 10_000)

      refute new_run_id in disconnected
      assert {:ok, %{"status" => "connected", "connection_generation" => 2}} = get_device(env)
    end

    test "the first production tick (deep) leaves a mid-sweep reconnect onto a live node alone" do
      # The GenServer's first held tick runs deep semantics. A device whose
      # run migrates onto a live node during the pause window is observed by
      # the deep authoritative LIST with a live owner — nothing may touch it.
      dead = "first-tick-dead-#{System.unique_integer([:positive])}"
      env = connect_device(dead, "ft")
      transport_id = env.transport_id

      Application.put_env(:salix_cluster, :recovery_pause_test_pid, self())
      Application.put_env(:salix_store, :s3_backend, PausingRootMarkerListS3)

      on_exit(fn ->
        Application.delete_env(:salix_cluster, :recovery_pause_test_pid)
      end)

      # Drive the exact production entry: sweep_once with deep defaults, as
      # the first held tick issues it.
      sweep = Task.async(fn -> Recovery.sweep_once(live_nodes: [to_string(node())]) end)

      assert_receive {:root_snapshot_taken, lister}

      # Mid-sweep the device reconnects onto THIS (live) node.
      {:ok, ^transport_id, reconnected} =
        SalixEnv.Registry.connect(to_string(node()), env.meta, transport_id: transport_id)

      assert reconnected["connection_generation"] == 2

      send(lister, :resume)
      {:ok, %{env_disconnected: disconnected}} = Task.await(sweep, 10_000)

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

      now = System.system_time(:millisecond)

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

      now = System.system_time(:millisecond)
      ref = "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

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
      now = System.system_time(:millisecond)
      state_id = "recovery-cadence-#{System.unique_integer([:positive])}"

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

  defp reset_session_work_backfill! do
    SalixStore.Repo.query!(
      "TRUNCATE session_work_backfill_state, session_work_backfill_expected_candidates"
    )

    reset_session_work_terminal!()
  end

  defp reset_session_work_backfill_state_only! do
    SalixStore.Repo.query!("TRUNCATE session_work_backfill_state")
    reset_session_work_terminal!()
  end

  defp reset_session_work_terminal! do
    SalixStore.Repo.query!(
      "DELETE FROM salix_cutover_markers WHERE name = 'session_work_candidates_v1'"
    )

    :ok
  end

  # Return a session version that a paused mark-first writer can no longer
  # commit against. Rewriting the same stable body advances the Fake S3 CAS
  # generation without introducing work into the authoritative session state.
  defp superseded_internal_session_base!(agent_id, session_id) do
    key = Keys.agent_internal_runtime_session(agent_id, session_id)
    assert {:ok, %{body: body, etag: old_etag}} = S3.get(key)
    {:ok, state} = InternalSession.load(Codec.snapshot_etf(body))

    next =
      state
      |> InternalSession.export()
      |> then(&Map.put(&1, :last_activity_at, (&1.last_activity_at || 0) + 1))
      |> InternalSession.open()

    assert {:ok, new_etag} =
             S3.put(
               key,
               Codec.compress_snapshot_etf(InternalSession.persist(next)),
               if_match: old_etag
             )

    refute new_etag == old_etag
    old_etag
  end

  defp external_session_state(agent_id, session_id) do
    timestamp = System.system_time(:second)

    %{
      "agent_id" => agent_id,
      "session_id" => session_id,
      "runtime" => %{"binding" => %{"kind" => "external", "provider" => "codex"}},
      "input_message_queue" => [],
      "async_tool_calls" => %{},
      "wait" => nil,
      "work_index_token" => nil,
      "created_at" => timestamp,
      "updated_at" => timestamp
    }
  end

  defp external_user_input(source_message_id) do
    %{
      "role" => "user",
      "content" => "resume external work",
      "source_message_id" => source_message_id,
      "no_wake" => false,
      "created_at" => System.system_time(:second)
    }
  end

  defp internal_sessions_settled?(agent_id) do
    case SalixAgent.InternalSessionStore.list(agent_id) do
      {:ok, [_ | _] = sessions} ->
        Enum.all?(sessions, &(InternalSession.status(&1) not in [:queued, :active]))

      _ ->
        false
    end
  end

  defp session_has_content?(agent_id, content) do
    session_has_content?(agent_id, "ses1_1200000000000000001", content)
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
    transport_id = "transport-#{System.unique_integer([:positive])}"

    meta = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "device_id" => device_id,
      "connector_id" => "connector-#{System.unique_integer([:positive])}",
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
