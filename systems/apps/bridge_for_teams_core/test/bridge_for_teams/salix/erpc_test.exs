defmodule BridgeForTeams.Salix.ErpcTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.Salix.Erpc
  alias SalixStore.RuntimeIds

  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

  @isolated_peer_runner_source ~S"""
  defmodule BridgeForTeams.Salix.ErpcTest.IsolatedPeerRunner do
    def run(scenario, target_node) do
      true = Node.connect(target_node)

      try do
        Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [target_node])

        try do
          execute(scenario, target_node)
        after
          Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
        end
      after
        Node.disconnect(target_node)
      end
    end

    defp execute(:legacy, target_node) do
      {BridgeForTeams.Salix.Erpc.call(:erlang, :node, []), target_node}
    end

    defp execute(:target_internal_undef, target_node) do
      target = BridgeForTeams.Salix.ErpcTest.UndefTarget
      result = BridgeForTeams.Salix.Erpc.call(target, :call, [self()])

      called_node =
        receive do
          {:undef_target_called, remote_pid} -> node(remote_pid)
        after
          1_000 -> :missing
        end

      replayed =
        receive do
          {:undef_target_called, _remote_pid} -> true
        after
          100 -> false
        end

      {result, target_node, called_node, replayed}
    end

    defp execute(:task_review, target_node) do
      result =
        BridgeForTeams.Salix.Erpc.accept_task_review(
          "group-old-salix",
          "conversation-old-salix",
          42
        )

      {result, target_node}
    end
  end
  """

  defmodule LocalTarget do
    @moduledoc false
    def called_by?(pid), do: pid in (Process.get(:"$callers") || [])
    def wait, do: Process.sleep(:infinity)
    def finish_after(milliseconds), do: Process.sleep(milliseconds)

    def wait_and_report(owner) do
      send(owner, {:local_target_started, self()})
      Process.sleep(:infinity)
    end

    def kill_self, do: Process.exit(self(), :kill)

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

  defmodule RuntimeEnv do
    @moduledoc false
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"] || "codex",
         "device_id" => config["device_id"] || "test-device",
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"] || "test-runtime",
         "device_runtime_id" => config["device_runtime_id"] || "test-device-runtime",
         "command" => config["command"] || "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id),
      do:
        {:ok,
         %{
           "status" => "unknown",
           "connector_run_id" => "test-connector-run",
           "device_id" => config["device_id"] || "test-device",
           "device_runtime_id" => config["device_runtime_id"]
         }}
  end

  setup do
    on_exit(fn -> Application.delete_env(:bridge_for_teams_core, :salix_nodes_override) end)
    :ok
  end

  test "triage readiness requires complete discovery and every current node" do
    ready_a = triage_ring(true, 2, 3, 4, 100)
    ready_b = triage_ring(true, 5, 6, 7, 200)
    not_ready = triage_ring(false, 0, 1, 0, 300)

    assert {:ok, ready} =
             Erpc.aggregate_triage_ring_status(2, [{:ok, ready_a}, {:ok, ready_b}],
               discovery_complete: true
             )

    assert ready.evaluation_readiness == :ready
    assert ready.runtime.evaluation_ready == true
    assert ready.runtime.active_evaluations == 7
    assert ready.runtime.open_buckets == 9
    assert ready.runtime.scheduled_buckets == 11
    assert ready.runtime.observed_at_ms == 200
    assert ready.diagnostics.observation_complete

    assert {:ok, unavailable} =
             Erpc.aggregate_triage_ring_status(2, [{:ok, ready_a}, {:ok, not_ready}],
               discovery_complete: true
             )

    assert unavailable.evaluation_readiness == :unavailable
    assert unavailable.runtime.evaluation_ready == false

    assert {:ok, undiscovered} =
             Erpc.aggregate_triage_ring_status(2, [{:ok, ready_a}, {:ok, ready_b}],
               discovery_complete: false
             )

    assert undiscovered.evaluation_readiness == :unknown
    assert undiscovered.runtime.evaluation_ready == nil
    refute undiscovered.diagnostics.discovery_complete

    old_shape = {:ok, %{running: true, runtime: %{evaluation_ready: true}, recovery: %{}}}

    assert {:ok, old} =
             Erpc.aggregate_triage_ring_status(2, [{:ok, ready_a}, old_shape],
               discovery_complete: true
             )

    assert old.evaluation_readiness == :unknown
    assert old.diagnostics.old_shape_node_count == 1

    assert {:ok, down} =
             Erpc.aggregate_triage_ring_status(2, [{:ok, ready_a}, {:error, :unavailable}],
               discovery_complete: true
             )

    assert down.evaluation_readiness == :unknown
    assert down.diagnostics.unavailable_node_count == 1

    assert {:ok, omitted} =
             Erpc.aggregate_triage_ring_status(2, [{:ok, ready_a}], discovery_complete: true)

    assert omitted.evaluation_readiness == :unknown
    refute omitted.diagnostics.observation_complete
  end

  test "triage readiness rejects over-limit candidates before any capability probe" do
    owner = self()
    candidates = ~w(a b c d e f g h i j k l m n o p q)a

    slow_probe = fn candidate ->
      send(owner, {:triage_capability_probe, candidate})
      Process.sleep(1_000)
      :salix
    end

    started_at = System.monotonic_time(:millisecond)

    assert {bounded_candidates, false} =
             Erpc.bounded_triage_status_nodes(candidates, true, slow_probe)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert length(bounded_candidates) == 17
    assert elapsed_ms < 500
    refute_receive {:triage_capability_probe, _candidate}

    assert {:ok, status} =
             Erpc.aggregate_triage_ring_status(length(bounded_candidates), [],
               discovery_complete: false
             )

    assert status.evaluation_readiness == :unknown
    assert status.diagnostics.candidate_limit_exceeded
    refute status.diagnostics.observation_complete
  end

  test "Kubernetes DNS is the complete bounded Triage readiness directory" do
    topologies = [
      salix: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [service: "comma-headless", application_name: "salix"]
      ]
    ]

    local = :"salix@10.0.0.1"
    peer = :"salix@10.0.0.2"

    resolver = fn ~c"comma-headless" ->
      {:ok,
       {:hostent, ~c"comma-headless.comma.svc.cluster.local", [], :inet, 4,
        [{10, 0, 0, 1}, {10, 0, 0, 2}]}}
    end

    assert {[^local, ^peer], true} =
             Erpc.kubernetes_dns_triage_status_directory(topologies, [local, peer], resolver)
  end

  test "Kubernetes DNS readiness discovery fails closed on lookup drift or overflow" do
    topologies = [
      salix: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [service: "comma-headless", application_name: "salix"]
      ]
    ]

    local = :"salix@10.0.0.1"
    extra_visible = :"salix@10.0.0.9"

    missing_visible = fn ~c"comma-headless" ->
      {:ok, {:hostent, ~c"comma-headless", [], :inet, 4, [{10, 0, 0, 1}]}}
    end

    assert {[^local, ^extra_visible], false} =
             Erpc.kubernetes_dns_triage_status_directory(
               topologies,
               [local, extra_visible],
               missing_visible
             )

    assert {[^local], false} =
             Erpc.kubernetes_dns_triage_status_directory(
               topologies,
               [local],
               fn ~c"comma-headless" -> {:error, :nxdomain} end
             )

    started_at = System.monotonic_time(:millisecond)

    assert {[^local], false} =
             Erpc.kubernetes_dns_triage_status_directory(
               topologies,
               [local],
               fn ~c"comma-headless" -> Process.sleep(2_000) end
             )

    assert System.monotonic_time(:millisecond) - started_at < 1_500

    too_many_addresses = for last <- 1..17, do: {10, 0, 1, last}

    assert {[^local], false} =
             Erpc.kubernetes_dns_triage_status_directory(
               topologies,
               [local],
               fn ~c"comma-headless" ->
                 {:ok, {:hostent, ~c"comma-headless", [], :inet, 4, too_many_addresses}}
               end
             )
  end

  test "Kubernetes DNS readiness fence rejects membership drift during collection" do
    topologies = [
      salix: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [service: "comma-headless", application_name: "salix"]
      ]
    ]

    local = :"salix@10.0.0.1"
    peer = :"salix@10.0.0.2"

    stable_resolver = fn ~c"comma-headless" ->
      {:ok, {:hostent, ~c"comma-headless", [], :inet, 4, [{10, 0, 0, 1}]}}
    end

    assert Erpc.kubernetes_dns_triage_status_stable?(
             topologies,
             [local],
             [local],
             fn -> [local] end,
             stable_resolver
           )

    refute Erpc.kubernetes_dns_triage_status_stable?(
             topologies,
             [local],
             [local],
             fn -> [local] end,
             fn ~c"comma-headless" -> {:error, :nxdomain} end
           )

    refute Erpc.kubernetes_dns_triage_status_stable?(
             topologies,
             [local],
             [local],
             fn -> [local, peer] end,
             stable_resolver
           )

    expanded_resolver = fn ~c"comma-headless" ->
      {:ok, {:hostent, ~c"comma-headless", [], :inet, 4, [{10, 0, 0, 1}, {10, 0, 0, 2}]}}
    end

    refute Erpc.kubernetes_dns_triage_status_stable?(
             topologies,
             [local],
             [local],
             fn -> [local, peer] end,
             expanded_resolver
           )

    {:ok, observed_calls} = Agent.start_link(fn -> 0 end)

    drifting_observed_provider = fn ->
      Agent.get_and_update(observed_calls, fn
        0 -> {[local], 1}
        count -> {[local, peer], count + 1}
      end)
    end

    refute Erpc.kubernetes_dns_triage_status_stable?(
             topologies,
             [local],
             [local],
             drifting_observed_provider,
             stable_resolver
           )
  end

  test "a complete readiness directory treats a non-Salix member as incomplete" do
    assert {[:a@h], false} =
             Erpc.bounded_triage_status_nodes([:a@h, :b@h], true, fn
               :a@h -> :salix
               :b@h -> :not_salix
             end)
  end

  test "no salix node -> all callbacks return :unavailable" do
    # Empty override list = no pickable node (the umbrella test node itself runs
    # salix_web, so deleting the override would now discover the local node).
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [])

    assert {:error, :unavailable} = Erpc.create_tenant(%{})
    assert {:error, :unavailable} = Erpc.update_tenant("t", %{})
    assert {:error, :unavailable} = Erpc.get_tenant("t")
    assert {:error, :unavailable} = Erpc.create_group_connector_token("g", "t", %{})
    assert {:error, :unavailable} = Erpc.create_group(%{})
    assert {:error, :unavailable} = Erpc.update_group("g", "t", %{})
    assert {:error, :unavailable} = Erpc.get_group("g")
    assert {:error, :unavailable} = Erpc.list_group_im_connects("g", nil)
    assert {:error, :unavailable} = Erpc.slack_manifest("Comma")
    assert {:error, :unavailable} = Erpc.create_slack_im_connect("t", "g", %{})
    assert {:error, :unavailable} = Erpc.update_slack_im_connect("t", "g", "c", %{})
    assert {:error, :unavailable} = Erpc.create_feishu_im_connect("t", "g", %{})
    assert {:error, :unavailable} = Erpc.update_feishu_im_connect("t", "g", "c", %{})
    assert {:error, :unavailable} = Erpc.feishu_bot_identity(%{"connect_id" => "c"})

    assert {:error, :unavailable} =
             Erpc.meeting_calendar_policy(%{"agent_id" => "a", "connect_id" => "c"})

    assert {:error, :unavailable} =
             Erpc.meeting_calendar_policy_status(%{"agent_id" => "a", "connect_id" => "c"})

    assert {:error, :unavailable} =
             Erpc.meeting_calendar_status(%{
               "agent_id" => "a",
               "connect_id" => "c",
               "limit" => 20
             })

    assert {:error, :unavailable} = Erpc.disable_im_connect("t", "g", "c")
    assert {:error, :unavailable} = Erpc.enable_im_connect("t", "g", "c")
    assert {:error, :unavailable} = Erpc.delete_im_connect("t", "g", "c")
    assert {:error, :unavailable} = Erpc.deliver("a", %{}, [])
    assert {:error, :unavailable} = Erpc.get_template("tmpl-test", SalixStore.Ids.new_tenant_id())
    assert {:error, :unavailable} = Erpc.list_sessions("a", [])
    assert {:error, :unavailable} = Erpc.get_session("a", "s", [])
    assert {:error, :unavailable} = Erpc.get_session_messages("a", "s")
    assert {:error, :unavailable} = Erpc.read_agent_file("a", "/x")
    assert {:error, :unavailable} = Erpc.list_agent_files("a", "/")

    assert {:error, :unavailable} =
             Erpc.create_schedule(%{"id" => SalixStore.Ids.new_schedule_id()})

    assert {:error, :unavailable} = Erpc.update_schedule("s", %{})
    assert {:error, :unavailable} = Erpc.get_env("tenant_e", "group_e", "device_e")

    assert {:ok, %{evaluation_readiness: :unknown}} =
             Erpc.triage_ring_status(%{runtime: nil, recovery: nil})
  end

  test "unreachable node (noconnection) maps to :unavailable via the catch" do
    # Override with a bogus node so pick/1 succeeds but the :erpc.call raises
    # {:erpc, :noconnection}; the taxonomy must map it to :unavailable.
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [:"nonode@nohost-zzz"])
    assert {:error, :unavailable} = Erpc.call(Salix.Control.Tenants, :get, ["t"])
  end

  test "new callers fall back to the legacy direct call on an old Salix peer" do
    origin = {Node.self(), Node.alive?()}

    {result, peer_node} =
      isolated_peer_call!(:legacy, """
      defmodule BridgeForTeams.Salix.Erpc do
        def legacy_release?, do: true
      end
      """)

    assert result == peer_node
    assert {Node.self(), Node.alive?()} == origin
  end

  test "review acceptance preserves a canonical owner conflict" do
    {result, peer_node} =
      isolated_peer_call!(:task_review, """
      defmodule SalixIM.ConversationServer do
        def accept_task_review(_group_id, _conversation_id, _review_version) do
          {:error, {:conflict, "Task review version changed"}}
        end
      end

      """)

    assert result ==
             {:error, {:conflict, "Task review version changed"}}

    refute peer_node == Node.self()
  end

  test "target-internal undef on a new Salix peer is not retried" do
    origin = {Node.self(), Node.alive?()}

    {result, peer_node, called_node, replayed} =
      isolated_peer_call!(:target_internal_undef, """
      defmodule BridgeForTeams.Salix.Erpc do
        def receive_call(_context, module, function, arguments) do
          apply(module, function, arguments)
        end
      end

      defmodule BridgeForTeams.Salix.ErpcTest.UndefTarget do
        def call(owner) do
          send(owner, {:undef_target_called, self()})
          apply(:bridge_for_teams_missing_target, :missing, [])
        end
      end
      """)

    assert {:error, _reason} = result
    assert called_node == peer_node
    refute replayed
    assert {Node.self(), Node.alive?()} == origin
  end

  test "call/4 returns :unavailable when no node is pickable" do
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [])
    assert {:error, :unavailable} = Erpc.call(Salix.Control.Tenants, :create, [%{}])
    assert {:error, :unavailable} = Erpc.call(Salix.Control.Tenants, :create, [%{}], 1_000)

    assert {:error, :unavailable} =
             Erpc.call(Salix.Control.Tenants, :create, [%{}], hint: "x")
  end

  test "call/4 invokes a local Salix target without erpc and preserves timeout isolation" do
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])
    assert Erpc.call(LocalTarget, :called_by?, [self()]) == true
    assert Erpc.call(LocalTarget, :wait, [], 1) == {:error, :timeout}
    assert Erpc.call(LocalTarget, :kill_self, []) == {:error, {:exit, :killed}}

    for _ <- 1..100 do
      assert Erpc.call(LocalTarget, :finish_after, [1], 1) in [:ok, {:error, :timeout}]
    end

    Process.sleep(10)

    refute Enum.any?(elem(Process.info(self(), :messages), 1), fn
             {ref, :ok} when is_reference(ref) -> true
             _other -> false
           end)
  end

  test "runtime-auth outer budget permits a valid response past the generic deadline" do
    inner_timeout = SalixEnv.Protocol.timeout("runtime_auth_login_start", %{})
    assert Erpc.runtime_auth_timeout() > inner_timeout

    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])

    task =
      Task.async(fn ->
        Erpc.call(
          LocalTarget,
          :finish_after,
          [15_100],
          Erpc.runtime_auth_timeout()
        )
      end)

    assert Task.await(task, 20_000) == :ok
  end

  test "local ERPC entry restores the fixed serialized trace and surface context" do
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])

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
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])
    test_pid = self()

    caller =
      spawn(fn ->
        Erpc.call(LocalTarget, :wait_and_report, [test_pid], 60_000)
      end)

    assert_receive {:local_target_started, target}, 1_000
    target_monitor = Process.monitor(target)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^target_monitor, :process, ^target, :killed}, 1_000
  end

  test "schedule CRUD and workspace reads go over erpc" do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :group_context_mod, GroupContext)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :group_context_mod, prev_group_context)
      restore(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
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

  defp isolated_peer_call!(scenario, target_source) do
    paths = :code.get_path()
    cookie = Atom.to_charlist(:salix_test_cookie)

    {:ok, caller, _caller_node} =
      :peer.start_link(%{
        name: :peer.random_name(:bft_erpc_caller),
        host: ~c"localhost",
        connection: 0,
        args: [~c"-setcookie", cookie, ~c"+S", ~c"1:1", ~c"+A", ~c"1"]
      })

    {:ok, target, target_node} =
      :peer.start_link(%{
        name: :peer.random_name(:bft_erpc_target),
        host: ~c"localhost",
        connection: 0,
        args: [~c"-setcookie", cookie, ~c"+S", ~c"1:1", ~c"+A", ~c"1"]
      })

    try do
      :ok = :peer.call(caller, :code, :add_pathsz, [paths])
      {:ok, _started} = :peer.call(caller, Application, :ensure_all_started, [:elixir])

      assert [_compiled | _rest] =
               :peer.call(caller, Code, :compile_string, [@isolated_peer_runner_source])

      :ok = :peer.call(target, :code, :add_pathsz, [paths])
      {:ok, _started} = :peer.call(target, Application, :ensure_all_started, [:elixir])
      assert [_compiled | _rest] = :peer.call(target, Code, :compile_string, [target_source])

      :peer.call(
        caller,
        BridgeForTeams.Salix.ErpcTest.IsolatedPeerRunner,
        :run,
        [scenario, target_node],
        30_000
      )
    after
      stop_peer(target)
      stop_peer(caller)
    end
  end

  defp stop_peer(peer) do
    try do
      :peer.stop(peer)
    catch
      :exit, _reason -> :ok
    end
  end

  defp triage_ring(ready?, active, open, scheduled, observed_at_ms) do
    %{
      running: true,
      runtime: %{
        running: true,
        mode: :review,
        namespace: "triage",
        evaluation_ready: ready?,
        active_evaluations: active,
        open_buckets: open,
        scheduled_buckets: scheduled,
        observed_at_ms: observed_at_ms
      },
      recovery: %{
        running: true,
        phase: :resolve,
        cursor: nil,
        holder: nil,
        lease_held: true,
        page_limit: 50,
        batch_limit: 50,
        backoff_ms: 250,
        pending_receipts: 1
      }
    }
  end

  test "runtime session reads use facade projections over erpc" do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :group_context_mod, GroupContext)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [node()])
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :group_context_mod, prev_group_context)
      restore(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
    end)

    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _agent} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "role" => "worker",
                 "runtime_config" => %{
                   "kind" => "external",
                   "provider" => "codex",
                   "device_id" => "test-device",
                   "runtime_id" => "test-runtime",
                   "device_runtime_id" => @device_runtime_id
                 }
               },
               tenant_id,
               agent_id
             )

    assert {:ok, :external} =
             SalixAgent.ExternalAgentRuntime.stage_delivery(agent_id, %{
               source_message_id: "bft-erpc-source",
               payload: %{
                 "session_id" => session_id,
                 "role" => "user",
                 "content" => "external bft erpc input"
               }
             })

    assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    assert {:ok, [listed]} = Erpc.list_sessions(agent_id, [])
    assert listed["session_id"] == session_id
    assert listed["runtime_kind"] == "external"
    refute Map.has_key?(listed, "messages")

    assert {:ok, session} = Erpc.get_session(agent_id, session_id, [])
    assert session["runtime_kind"] == "external"
    refute Map.has_key?(session, "messages")

    assert {:ok, messages} = Erpc.get_session_messages(agent_id, session_id)
    assert messages["messages"] == []

    assert {:ok, context} =
             SalixAgent.ExternalAgentRuntime.session_context(agent_id, session_id)

    assert [%{"content" => "external bft erpc input"}] = context["input_messages"]
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
