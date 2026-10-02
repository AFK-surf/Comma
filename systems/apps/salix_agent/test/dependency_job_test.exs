defmodule SalixAgent.DependencyJobTest do
  use ExUnit.Case, async: false

  alias SalixAgent.DependencyJob

  setup do
    previous_global = Application.get_env(:salix_agent, :dependency_max_children)
    previous_tenant = Application.get_env(:salix_agent, :dependency_max_children_per_tenant)
    previous_timeout = Application.get_env(:salix_agent, :dependency_job_timeout_ms)

    Application.put_env(:salix_agent, :dependency_max_children, 1)
    Application.put_env(:salix_agent, :dependency_max_children_per_tenant, 1)
    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{llm: 5_000})

    on_exit(fn ->
      restore_env(:dependency_max_children, previous_global)
      restore_env(:dependency_max_children_per_tenant, previous_tenant)
      restore_env(:dependency_job_timeout_ms, previous_timeout)
    end)

    :ok
  end

  test "a Tenant profile override replaces the per-Tenant admission limit" do
    Application.put_env(:salix_agent, :dependency_max_children, 3)
    send(SalixAgent.DependencyAdmission, {:tenant_limits, %{"guest-tenant" => 2}})
    on_exit(fn -> send(SalixAgent.DependencyAdmission, {:tenant_limits, %{}}) end)

    blocker = fn -> Process.sleep(:infinity) end
    assert {:ok, first} = DependencyJob.start(:llm, "guest-tenant", blocker)
    assert {:ok, second} = DependencyJob.start(:llm, "guest-tenant", blocker)
    assert {:error, :dependency_saturated} = DependencyJob.start(:llm, "guest-tenant", blocker)

    assert {:ok, other} = DependencyJob.start(:llm, "other-tenant", blocker)
    assert {:error, :dependency_saturated} = DependencyJob.start(:llm, "other-tenant", blocker)

    Enum.each([first, second, other], &DependencyJob.cancel/1)
  end

  test "owner death cancels its task and releases global and tenant admission" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, job} =
          DependencyJob.start(:llm, "owner-death-tenant", fn ->
            send(test_pid, {:dependency_started, self()})
            Process.sleep(:infinity)
          end)

        send(test_pid, {:owner_job, job})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_job, _job}, 1_000
    assert_receive {:dependency_started, dependency_pid}, 1_000

    assert {:error, :dependency_saturated} =
             DependencyJob.start(:llm, "owner-death-tenant", fn -> :unreachable end)

    Process.exit(owner, :kill)
    assert eventually(fn -> not Process.alive?(dependency_pid) end)

    assert {:ok, replacement} = eventually_start("owner-death-tenant")
    :ok = DependencyJob.cancel(replacement)
  end

  test "admission restart terminates untracked tasks before admitting bounded replacements" do
    attach_telemetry([[:salix, :dependency_job, :active]])

    {:ok, abandoned} =
      DependencyJob.start(
        :llm,
        "admission-restart-tenant",
        fn -> Process.sleep(:infinity) end,
        timeout_ms: 100
      )

    abandoned_monitor = Process.monitor(abandoned.pid)

    assert_receive {:telemetry, [:salix, :dependency_job, :active], %{value: 1}, %{kind: :llm}}

    assert {:error, :dependency_saturated} =
             DependencyJob.start(:llm, "admission-restart-other-tenant", fn -> :unreachable end)

    admission = Process.whereis(SalixAgent.DependencyAdmission)
    admission_monitor = Process.monitor(admission)
    Process.exit(admission, :kill)

    assert_receive {:DOWN, ^admission_monitor, :process, ^admission, :killed}, 1_000
    assert_receive {:DOWN, ^abandoned_monitor, :process, _pid, _reason}, 1_000

    assert_receive {:telemetry, [:salix, :dependency_job, :active], %{value: 0}, %{kind: :llm}}

    assert eventually(fn ->
             replacement_admission = Process.whereis(SalixAgent.DependencyAdmission)
             is_pid(replacement_admission) and replacement_admission != admission
           end)

    assert Task.Supervisor.children(SalixAgent.DependencyTaskSup) == []
    assert {:ok, replacement} = eventually_start("admission-restart-tenant")

    assert_receive {:dependency_job_timeout, abandoned_token}, 500
    assert abandoned_token == abandoned.token
    :ok = DependencyJob.cancel(abandoned, :timeout)

    assert Process.alive?(replacement.pid)
    assert Task.Supervisor.children(SalixAgent.DependencyTaskSup) == [replacement.pid]

    assert {:error, :dependency_saturated} =
             DependencyJob.start(:llm, "admission-restart-other-tenant", fn -> :unreachable end)

    :ok = DependencyJob.cancel(replacement)
  end

  test "task crash notifies the exact owner and releases admission" do
    {:ok, crashed} =
      DependencyJob.start(:llm, "task-death-tenant", fn -> exit(:dependency_boom) end)

    assert_receive {:dependency_job_down, token, :dependency_boom}, 1_000
    assert token == crashed.token
    :ok = DependencyJob.complete(crashed)

    assert {:ok, replacement} = eventually_start("task-death-tenant")
    :ok = DependencyJob.cancel(replacement)
  end

  test "admission emits active pressure and one terminal outcome per accepted job" do
    attach_telemetry([[:salix, :dependency_job, :active], [:salix, :dependency_job, :stop]])

    {:ok, job} =
      DependencyJob.start(:llm, "telemetry-tenant", fn -> Process.sleep(:infinity) end)

    assert_receive {:telemetry, [:salix, :dependency_job, :active], %{value: 1}, %{kind: :llm}}

    assert {:error, :dependency_saturated} =
             DependencyJob.start(:llm, "other-telemetry-tenant", fn -> :unreachable end)

    assert_receive {:telemetry, [:salix, :dependency_job, :stop], %{},
                    %{kind: :llm, outcome: :saturated}}

    :ok = DependencyJob.cancel(job)

    assert_receive {:telemetry, [:salix, :dependency_job, :stop], %{},
                    %{kind: :llm, outcome: :cancelled}}

    assert_receive {:telemetry, [:salix, :dependency_job, :active], %{value: 0}, %{kind: :llm}}

    refute_receive {:telemetry, [:salix, :dependency_job, :stop], %{}, %{kind: :llm}}, 50
  end

  test "the owner deadline emits timeout deterministically across repeated timer races" do
    attach_telemetry([[:salix, :dependency_job, :stop]])

    Enum.each(1..10, fn attempt ->
      {:ok, job} =
        DependencyJob.start(
          :llm,
          "telemetry-timeout-tenant-#{attempt}",
          fn -> Process.sleep(:infinity) end,
          timeout_ms: 2
        )

      assert_receive {:dependency_job_timeout, token}, 200
      assert token == job.token
      :ok = DependencyJob.cancel(job, :timeout)

      assert_receive {:telemetry, [:salix, :dependency_job, :stop], %{},
                      %{kind: :llm, outcome: :timeout}}
    end)

    refute_receive {:telemetry, [:salix, :dependency_job, :stop], %{},
                    %{kind: :llm, outcome: :cancelled}},
                   50
  end

  defp eventually_start(tenant_id, attempts \\ 100)

  defp eventually_start(_tenant_id, 0), do: {:error, :admission_not_released}

  defp eventually_start(tenant_id, attempts) do
    case DependencyJob.start(:llm, tenant_id, fn -> Process.sleep(:infinity) end) do
      {:ok, _job} = result ->
        result

      {:error, :dependency_saturated} ->
        Process.sleep(10)
        eventually_start(tenant_id, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
end
