defmodule SalixAgent.LoopsAgentOutageTest do
  @moduledoc """
  A stranded Loop across an outage of its Agent's row, on a manual clock: the
  Reconciler's own minute timer drives every sweep, so each span below holds
  its sweeps.
  """
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixAgent", "Elixir.SalixStore"]

  alias SalixAgent.Loops
  alias SalixAgent.Loops.Reconciler
  alias SalixStore.Loops, as: Store
  alias SalixStore.Repo
  alias SalixStore.S3.Fake

  @minute 60_000

  defmodule OwnerProbe do
    @moduledoc "The Task owner port, forwarding each wake to the test."
    @behaviour SalixAgent.Loops.TaskOwner

    @impl true
    def loop_worker(_loop), do: {:error, :task_worker_missing}

    @impl true
    def loop_wake(loop, _payload, source) do
      test = SystemsRuntime.PersistentTerm.get({__MODULE__, :test})
      SystemsRuntime.Proc.send(test, {:loop_woke, loop["loop_id"], source})
      {:ok, :created}
    end

    @impl true
    def loop_ended(_loop, _fact), do: :ok
  end

  setup_all do
    SystemsRuntime.put_env(:salix_agent, :loops_sweep, true)
    SystemsRuntime.Proc.send(Reconciler, :sweep)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :loops_sweep, false) end)
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_owner = SystemsRuntime.get_env(:salix_agent, :loop_task_owner_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    SystemsRuntime.put_env(:salix_agent, :loop_task_owner_mod, OwnerProbe)
    SystemsRuntime.PersistentTerm.put({OwnerProbe, :test}, self())
    SalixAgent.TestSupport.configure_control_fixtures!()
    if SystemsRuntime.Proc.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)
    Repo.query!("TRUNCATE agent_loops, agent_loop_acks")

    on_exit(fn ->
      SystemsClock.take_over(keep_journal: true)
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store)
      SystemsRuntime.put_env(:salix_agent, :loop_task_owner_mod, previous_owner)
      Repo.query!("DROP TABLE IF EXISTS hidden_salix_agents")
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "worker"})
    {:ok, agent_id: agent_id, loop_id: stranded_loop!(agent_id)}
  end

  test "the two-hour staging outage of 2026-10-28 leaves the Loop active", tags do
    hide_agent!(tags.agent_id)

    run_minutes(125)

    assert_active(tags.loop_id)
    assert %{since: since, seen: seen} = missing(tags.agent_id)
    assert now() - since >= 124 * @minute
    assert now() - seen <= @minute
    refute_received {:loop_woke, _loop_id, _source}

    restore_agent!(tags.agent_id)
    run_minutes(1)

    refute missing(tags.agent_id)
    assert [{_server, _}] = Registry.lookup(SalixAgent.Registry, tags.agent_id)
    refute paused_undeliverable?(tags.loop_id)
  end

  test "the Loop pauses once its Agent has been missing for 24 hours and tells its Task", tags do
    hide_agent!(tags.agent_id)

    run_minutes(24 * 60 - 2)
    assert_active(tags.loop_id)

    run_minutes(3)

    assert paused_undeliverable?(tags.loop_id)
    refute missing(tags.agent_id)
    id = tags.loop_id
    assert_received {:loop_woke, ^id, "loop:" <> _ = source}
    assert source =~ "lifecycle:undeliverable"
    refute_received {:loop_woke, _loop_id, _source}

    restore_agent!(tags.agent_id)
    run_minutes(5)
    assert paused_undeliverable?(tags.loop_id)
  end

  test "a miss after a day without one starts a new grace", tags do
    hide_agent!(tags.agent_id)
    run_minutes(30)
    assert %{since: first_since} = missing(tags.agent_id)

    # Not stranded for a day: no sweep sees the Agent, so `seen` goes stale.
    set_status(tags.loop_id, "paused")
    run_minutes(25 * 60)
    set_status(tags.loop_id, "active")
    run_minutes(2)

    assert_active(tags.loop_id)
    assert %{since: since} = missing(tags.agent_id)
    assert since > first_since + 24 * 60 * @minute
  end

  # A Loop whose object is on no node, as after a Pod replacement.
  defp stranded_loop!(agent_id) do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    {:ok, %{"loop_id" => loop_id}} =
      Loops.request_task_loop(%{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "agent_id" => agent_id,
        "task_conversation_id" => "cnv_outage",
        "trigger" => %{"cron" => "0 9 * * *", "timezone" => "Asia/Shanghai"}
      })

    set_status(loop_id, "active")
    loop_id
  end

  defp set_status(loop_id, status) do
    {:ok, _} =
      Store.update(loop_id, fn row ->
        {:ok, Map.merge(row, %{"status" => status, "session_id" => "ses_outage"})}
      end)
  end

  # The Agent row absent from the online store, as before an import.
  defp hide_agent!(agent_id) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")
        Repo.query!("CREATE TABLE hidden_salix_agents (LIKE salix_agents)")

        Repo.query!(
          "INSERT INTO hidden_salix_agents SELECT * FROM salix_agents WHERE agent_id = $1",
          [agent_id]
        )

        Repo.query!("DELETE FROM salix_agents WHERE agent_id = $1", [agent_id])
      end)

    assert {:error, :not_found} = SalixAgent.Fleet.ensure_started(agent_id, create: false)
  end

  defp restore_agent!(agent_id) do
    Repo.query!(
      "INSERT INTO salix_agents SELECT * FROM hidden_salix_agents WHERE agent_id = $1",
      [agent_id]
    )
  end

  defp assert_active(loop_id),
    do: assert(%{"status" => "active", "paused_by" => nil} = elem(Store.get(loop_id), 1))

  defp paused_undeliverable?(loop_id),
    do:
      match?(%{"status" => "paused", "paused_by" => "undeliverable"}, elem(Store.get(loop_id), 1))

  defp missing(agent_id), do: :sys.get_state(Reconciler).missing_agents[agent_id]
  defp now, do: SystemsClock.system_time(:millisecond)

  # Each minute fires the Reconciler's own timer; the call waits for its sweep.
  defp run_minutes(count) do
    for _minute <- 1..count do
      SystemsClock.advance(@minute)
      :sys.get_state(Reconciler)
    end

    SystemsClock.settle(scope: ["Elixir.SalixAgent", "Elixir.SalixStore"])
  end
end
