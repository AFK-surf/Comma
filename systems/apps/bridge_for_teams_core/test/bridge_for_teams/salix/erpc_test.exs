defmodule BridgeForTeams.Salix.ErpcTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  alias BridgeForTeams.Salix.Erpc

  defmodule LocalTarget do
    @moduledoc false
    def called_by?(pid), do: pid in (Process.get(:"$callers") || [])
    def wait, do: SystemsRuntime.Proc.sleep(:infinity)
    def finish_after(milliseconds), do: SystemsClock.sleep(milliseconds)

    def wait_and_report(owner) do
      SystemsRuntime.Proc.send(owner, {:local_target_started, SystemsRuntime.Proc.self()})
      SystemsRuntime.Proc.sleep(:infinity)
    end

    def kill_self, do: SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)

    def current_context do
      {SystemsObservability.Context.current_surface(), Logger.metadata()[:correlation_id],
       OpenTelemetry.Span.hex_span_ctx(OpenTelemetry.Tracer.current_span_ctx())}
    end
  end

  defmodule GroupContext do
    @moduledoc false
    @behaviour SalixAgent.GroupContext

    @impl true
    def list(_tenant_id), do: []

    @impl true
    def get(group_id, tenant_id) do
      if SalixStore.Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
        {:ok, %{"tenant_id" => tenant_id, "group_id" => group_id}}
      else
        {:error, :not_found}
      end
    end
  end

  setup do
    on_exit(fn -> SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_nodes_override) end)
    :ok
  end

  test "unreachable node (noconnection) maps to :unavailable via the catch" do
    # Override with a bogus node so pick/1 succeeds but the :erpc.call raises
    # {:erpc, :noconnection}; the taxonomy must map it to :unavailable.
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_nodes_override, [:"nonode@nohost-zzz"])
    assert {:error, :unavailable} = Erpc.call(Salix.Control.Tenants, :get, ["t"])
  end

  test "a module a Salix node of the release before lacks is unavailable there, not refused" do
    module = Module.concat(__MODULE__, NotYetReleased)

    # What `:erpc.call` raises when the remote node has no such module.
    remote =
      {:error,
       {:error,
        {:exception, :undef, [{module, :put, [:place], []}, {:erpc, :execute_call, 4, []}]}}}

    assert Erpc.unknown_before_release(remote, module) == {:error, :unavailable}

    # Another module's error, or another refusal, stays what it was.
    assert Erpc.unknown_before_release(remote, LocalTarget) == remote
    assert Erpc.unknown_before_release({:error, :not_found}, module) == {:error, :not_found}
  end

  test "local ERPC entry restores the fixed serialized trace and surface context" do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])

    require OpenTelemetry.Tracer, as: Tracer

    Tracer.with_span "erpc_test.root" do
      root = OpenTelemetry.Span.hex_span_ctx(OpenTelemetry.Tracer.current_span_ctx())

      assert {"bft", correlation_id, remote} =
               SystemsObservability.Context.with_surface("bft", fn ->
                 Erpc.call(LocalTarget, :current_context, [])
               end)

      assert is_binary(correlation_id)
      assert remote.otel_trace_id == root.otel_trace_id
      refute remote.otel_span_id == root.otel_span_id
    end
  end

  test "local Salix target is cancelled when its caller exits" do
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])
    test_pid = SystemsRuntime.Proc.self()

    caller =
      SystemsRuntime.Proc.spawn(fn ->
        Erpc.call(LocalTarget, :wait_and_report, [test_pid], 60_000)
      end)

    assert_receive {:local_target_started, target}
    target_monitor = SystemsRuntime.Proc.monitor(target)

    SystemsRuntime.Proc.exit(caller, :kill)

    assert_receive {:DOWN, ^target_monitor, :process, ^target, :killed}
  end

  test "schedule CRUD and workspace reads go over erpc" do
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :group_context_mod, GroupContext)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :group_context_mod, prev_group_context)
    end)

    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    assert {:ok, _agent} =
             SalixAgent.Control.create_preallocated(
               %{"group_id" => group_id, "role" => "worker"},
               tenant_id,
               agent_id
             )

    # Workspace reads.
    assert {:ok, []} = Erpc.list_agent_files(agent_id, "/")
    assert {:error, :not_found} = Erpc.read_agent_file(agent_id, "/missing.md")

    # Schedule definitions (SalixCluster.Schedules validation applies).
    sched_id = SalixStore.Ids.new_schedule_id()

    assert {:ok, sched} =
             Erpc.create_schedule(%{
               "id" => sched_id,
               "agent_id" => agent_id,
               "prompt" => "p",
               "interval_minutes" => 5
             })

    assert sched["id"] == sched_id
    assert sched["interval_minutes"] == 5

    assert {:ok, updated} = Erpc.update_schedule(sched_id, %{"prompt" => "p2"})
    assert updated["prompt"] == "p2"

    assert {:ok, generated} =
             Erpc.create_schedule(%{
               "agent_id" => agent_id,
               "prompt" => "p",
               "interval_minutes" => 5
             })

    assert SalixStore.Ids.valid_schedule_id?(generated["id"])

    assert {:error, :invalid_schedule} =
             Erpc.create_schedule(%{"agent_id" => agent_id, "prompt" => "no recurrence"})

    assert {:error, :not_found} =
             Erpc.update_schedule(SalixStore.Ids.new_schedule_id(), %{"prompt" => "x"})
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
