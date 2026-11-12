defmodule SalixAgent.SessionWorkRecoveryTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixAgent.SessionWorkRecovery

  test "coalesces concurrent requests and rotates after the last attempted lane" do
    owner = SystemsRuntime.Proc.self()

    sweep_fn = fn opts ->
      SystemsRuntime.Proc.send(owner, {:session_work_sweep, SystemsRuntime.Proc.self(), opts})

      SystemsRuntime.Proc.receive do
        {:finish_session_work_sweep, result} -> result
      end
    end

    worker =
      start_supervised!(
        {SessionWorkRecovery,
         name: nil,
         task_supervisor: SalixAgent.TaskSup,
         sweep_fn: sweep_fn,
         session_work_max_keys: 7}
      )

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    settle_receive({:session_work_sweep, first_task, first_opts})
    assert first_opts[:session_work_max_keys] == 7
    assert first_opts[:cursors] == %{}
    assert first_opts[:start_lane] == :sessions

    assert :ok = SessionWorkRecovery.request_sweep(worker)
    assert :ok = SessionWorkRecovery.request_sweep(worker)

    SystemsRuntime.Proc.send(
      first_task,
      {:finish_session_work_sweep,
       summary(
         cursors: %{sessions: {1, "a", "s"}},
         last_attempted_lane: :sessions
       )}
    )

    settle_receive({:session_work_sweep, second_task, second_opts})
    assert second_opts[:cursors] == %{sessions: {1, "a", "s"}}
    assert second_opts[:start_lane] == :capability_expiry

    SystemsRuntime.Proc.send(second_task, {:finish_session_work_sweep, summary()})
    assert eventually(fn -> :sys.get_state(worker, :infinity).task == nil end)
    settle_refute_receive({:session_work_sweep, _third_task, _third_opts}, 50)
  end

  defmodule UnavailablePlacement do
    @behaviour SalixAgent.Placement
    def ensure_started(agent_id, _opts) do
      send(SystemsRuntime.get_env(:salix_agent, :recovery_test_owner), {:attempted, agent_id})
      {:error, :owner_unreachable}
    end

    def stop_existing(_, _), do: :ok
  end

  test "committed inputs survive lost hints and failed wakes without candidate repair" do
    alias SalixAgent.InternalSessionStore.{PG, PGCodec}
    alias SalixStore.Repo
    previous = SystemsRuntime.get_env(:salix_agent, :placement)
    SystemsRuntime.put_env(:salix_agent, :placement, UnavailablePlacement)
    SystemsRuntime.put_env(:salix_agent, :recovery_test_owner, self())

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_agent, :placement, previous)
      SystemsRuntime.delete_env(:salix_agent, :recovery_test_owner)
    end)

    SalixStore.RepoTestSetup.exclusively(fn ->
      Repo.query!("TRUNCATE salix_agents CASCADE")
      Repo.query!("TRUNCATE salix_capability_requests")
      agent = "recovery-agent"
      session = "ses1_0000000000000000091"

      SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

      Repo.query!(
        """
        INSERT INTO salix_agents (agent_id,tenant_id,group_id,role,config_revision,
          config_payload,owner_epoch,root_revision)
        VALUES ($1,'tenant','group','worker',1,$2,1,1)
        """,
        [agent, PGCodec.encode(%{})]
      )

      assert {:ok, initial} = PG.create(agent, session, 1)

      assert {{:ok, :committed}, accepted} =
               PG.input_revision(initial, 1, %{
                 source_message_id: "accepted-before-crash",
                 payload: %{content: "continue"}
               })

      assert {:ok, active} =
               PG.commit_revision(accepted, 1, [
                 %{"type" => "status", "session_id" => session, "status" => "active"}
               ])

      assert SalixAgent.InternalSession.status(active.state) == :active

      assert %{scanned: 1, failed: 1} = SessionWorkRecovery.sweep()
      assert_received {:attempted, ^agent}
      assert %{scanned: 0} = SessionWorkRecovery.sweep()
      assert {:ok, current} = PG.read(agent, session)
      assert current.revision == active.revision
      assert length(SalixAgent.InternalSession.get(current.state, :input_queue)) == 1

      Repo.query!(
        "UPDATE salix_sessions SET dispatch_after=clock_timestamp()-interval '1 second' WHERE agent_id=$1",
        [agent]
      )

      assert %{scanned: 1, failed: 1} = SessionWorkRecovery.sweep()
      assert_received {:attempted, ^agent}

      assert {:ok, [%{session_id: ^session}], nil} =
               SessionWorkRecovery.local_work_page(agent, nil, 100)
    end)
  end

  defp summary(overrides \\ []) do
    Map.merge(
      SessionWorkRecovery.empty_summary(),
      Map.new(overrides)
    )
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
