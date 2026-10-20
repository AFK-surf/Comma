defmodule SalixWeb.CloudVMTest do
  require SystemsRuntime.Proc

  @moduledoc "Cloudflare Group VM lifecycle and recovery tests."
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias SalixEnv.Registry
  alias SalixWeb.CloudVM
  import Ecto.Query, only: [from: 2]
  alias SalixStore.Compute, as: GroupCompute
  alias SalixWeb.MockCloudflareGateway

  @config_missing "the Cloud VM requires tenant vm provider configuration: cloudflare"
  defmodule MeteringFake do
    def meter_vm_interval(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :cloud_vm_test_pid),
        {:vm_fact, fact}
      )

      :ok
    end
  end

  defmodule FailedMeteringFake do
    def meter_vm_interval(_fact), do: {:error, :unavailable}
  end

  defmodule UnattributedMeteringFake do
    def meter_vm_interval(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :cloud_vm_test_pid),
        {:vm_fact, fact}
      )

      {:unattributed, fact}
    end
  end

  defmodule TaskFake do
    @moduledoc "A Task as `SalixWeb.StationTasks` reads it: two Messages, and those a test adds."
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> ["build it", "and test it"] end, name: __MODULE__)

    def add(group, text) do
      Agent.update(__MODULE__, &(&1 ++ [text]))
      SalixWeb.StationTasks.appended(group, "cnv_task")
    end

    def messages_after(_group_id, _conversation_id, after_seq, limit) do
      messages =
        for {text, seq} <- Enum.with_index(Agent.get(__MODULE__, & &1), 1), seq > after_seq do
          %{
            "seq" => seq,
            "actor_type" => "user",
            "user_id" => "usr_ann",
            "content" => text,
            "created_at" => seq
          }
        end

      {:ok, Enum.take(messages, limit)}
    end
  end

  defmodule VMAuthorizationFake do
    @behaviour SalixWeb.ComputeProviders.Cloudflare.VMAuthorization

    @impl true
    def authorize_vm(attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :cloud_vm_test_pid),
        {:vm_authorize, attrs}
      )

      case SystemsRuntime.get_env(:salix_web, :cloud_vm_auth_result, :allow) do
        :allow ->
          :ok

        :block ->
          {:error,
           {:billing_unavailable,
            struct!(BillingCore.FeeControl.Decision,
              allowed?: false,
              reason: "insufficient_credits",
              decision_id: "decision_vm_test",
              balance_snapshot: 0
            )}}
      end
    end
  end

  setup do
    SalixStore.Repo.query!(
      "TRUNCATE compute_reconciler_claims, compute_reconciler_cursors, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    Salix.App.configure()
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_metering = SystemsRuntime.get_env(:salix_web, :vm_metering_mod)
    prev_vm_authorization = SystemsRuntime.get_env(:salix_web, :vm_authorization_mod)
    prev_vm_auth_result = SystemsRuntime.get_env(:salix_web, :cloud_vm_auth_result)
    prev_pid = SystemsRuntime.get_env(:salix_web, :cloud_vm_test_pid)
    prev_public_base_url = SystemsRuntime.get_env(:salix_web, :public_base_url)
    prev_platform_vm = SystemsRuntime.get_env(:salix_web, :platform_vm)
    prev_req_options = Req.default_options()
    req_adapter = Keyword.get(prev_req_options, :adapter, &Req.Steps.run_finch/1)

    # Exercise the Gateway's request parsing and control protocol in its Plug.
    # Station WebSockets and requests to other origins still use real sockets.
    on_exit(fn -> Req.default_options(prev_req_options) end)

    Req.default_options(
      Keyword.put(prev_req_options, :adapter, &gateway_request(&1, req_adapter))
    )

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_web, :cloud_vm_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.delete_env(:salix_web, :public_base_url)
    SystemsRuntime.delete_env(:salix_web, :platform_vm)
    SalixCluster.NodeLifecycle.reset()

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Default"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Cloud VM tests",
          "billing_owner" => %{
            "surface" => "bridge",
            "vm_profile_key" => "cf-standard-2"
          }
        },
        tenant_id()
      )

    Process.put(:test_group_id, group["group_id"])
    # A station exports its archive straight to R2.
    configure_archive_r2()

    on_exit(fn ->
      # An attachment whose Gateway stopped with the test waits out its
      # reconnect backoff on the clock before it can stop: drive the clock
      # from this callback so that wait ends.
      SystemsClock.take_over(keep_journal: true)
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      restore_salix_web_env(:vm_metering_mod, prev_metering)
      restore_salix_web_env(:vm_authorization_mod, prev_vm_authorization)
      restore_salix_web_env(:cloud_vm_auth_result, prev_vm_auth_result)
      restore_salix_web_env(:cloud_vm_test_pid, prev_pid)
      restore_salix_web_env(:public_base_url, prev_public_base_url)
      restore_salix_web_env(:platform_vm, prev_platform_vm)
      SalixCluster.NodeLifecycle.reset()
    end)

    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  # The VM's station loses its connection: its Container stops.
  defp drop_station(gateway, group_id) do
    {:ok, rec} = GroupCompute.group_workload(group_id)
    :ok = MockCloudflareGateway.stop_container(gateway, rec["provider_resource_name"])
  end

  defp group_id, do: Process.get(:test_group_id) || raise("test group is not configured")

  defp create_tenant!(attrs \\ %{}) do
    {:ok, tenant} = Salix.Control.Tenants.create(attrs)
    tenant["tenant_id"]
  end

  defp create_group!(tenant_id, name \\ "Cloud VM test group") do
    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => name,
          "billing_owner" => %{
            "surface" => "bridge",
            "vm_profile_key" => "cf-standard-2"
          }
        },
        tenant_id
      )

    group["group_id"]
  end

  defp create_agent!(tenant_id, attrs \\ %{}) do
    group_id = Map.get(attrs, "group_id") || create_group!(tenant_id)
    SalixAgent.Control.create(Map.put(attrs, "group_id", group_id), tenant_id)
  end

  defp restore_salix_web_env(key, nil), do: SystemsRuntime.delete_env(:salix_web, key)
  defp restore_salix_web_env(key, value), do: SystemsRuntime.put_env(:salix_web, key, value)

  defp gateway_request(%{url: %{scheme: scheme, host: host, port: port}} = request, fallback) do
    with gateway when is_pid(gateway) <- SystemsRuntime.Proc.whereis(MockCloudflareGateway),
         %URI{scheme: ^scheme, host: ^host, port: ^port} <-
           URI.parse(MockCloudflareGateway.base_url(gateway)) do
      request
      |> Req.Request.put_option(:plug, {MockCloudflareGateway.Plug, gateway})
      |> Req.Steps.run_plug()
    else
      # A stopped Gateway remains a real transport failure.
      _ -> fallback.(request)
    end
  end

  defp configure_tenant_cloudflare(tenant_id, gateway) do
    {:ok, _} =
      Salix.Control.Tenants.update(tenant_id, %{
        "config" =>
          Jason.encode!(%{
            "vm" => %{
              "default_provider" => "cloudflare",
              "providers" => %{
                "cloudflare" => %{
                  "enabled" => true,
                  "gateway_base_url" => MockCloudflareGateway.base_url(gateway),
                  "gateway_secret" => "test-secret"
                }
              }
            }
          })
      })
  end

  # Turns on the Group's Cloud VM switch, which needs the tenant's VM config.
  defp enable_cloud_vm!(group \\ group_id()) do
    {:ok, _group} = Salix.Control.Groups.update(group, %{"cloud_vm_enabled" => true})
    :ok
  end

  defp create_cloudflare_agent(attrs \\ %{}) do
    attrs = Map.merge(%{"group_id" => group_id()}, attrs)
    {:ok, agent} = SalixAgent.Control.create(attrs, tenant_id())
    enable_cloud_vm!(attrs["group_id"])
    _ = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)
    agent
  end

  defmodule StationClient do
    @moduledoc "A Workload's station, as far as its connection to Salix: it connects out and answers heartbeats."
    use WebSockex

    def start(ws_url, token, test_pid) do
      WebSockex.start(ws_url <> "/v1/connect?name=station", __MODULE__, test_pid,
        extra_headers: [
          {"authorization", "Bearer " <> token},
          {"x-salix-credential-kind", "workload"}
        ]
      )
    end

    @impl true
    def handle_frame({:text, raw}, test_pid) do
      case Jason.decode!(raw) do
        %{"type" => "connected", "connector_run_id" => run} ->
          SystemsRuntime.Proc.send(test_pid, {:station_connected, run})
          {:ok, test_pid}

        %{"type" => "heartbeat"} ->
          {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, test_pid}

        _ ->
          {:ok, test_pid}
      end
    end
  end

  test "a Cloud VM's station connects out as the VM's device with its Workload's credential" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :allow)
    create_cloudflare_agent()
    assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id())
    {:ok, rec} = GroupCompute.group_workload(group_id())
    ws = String.replace(SalixWeb.Application.base_url(), "http://", "ws://")

    {:ok, token} =
      GroupCompute.WorkloadCredential.issue_connect(rec["workload_id"], rec["generation"])

    {:ok, pid} = StationClient.start(ws, token, SystemsRuntime.Proc.self())

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    settle_receive({:station_connected, run})

    assert {:ok, %{"status" => "connected", "connector_run_id" => ^run} = device} =
             Registry.get_device(tenant_id(), group_id(), rec["device_id"])

    assert device["connector_id"] == rec["connector_id"]
    assert device["meta"]["managed_compute"] == true

    # A credential of another generation (a reset VM's) connects as nothing.
    {:ok, stale} =
      GroupCompute.WorkloadCredential.issue_connect(rec["workload_id"], rec["generation"] + 1)

    assert {:error, %WebSockex.RequestError{code: 401}} =
             StationClient.start(ws, stale, SystemsRuntime.Proc.self())
  end

  test "a Cloud VM's station is lent the workspace's accounts as profiles" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :allow)
    account = "acct-" <> SalixAgent.SubscriptionStore.id()

    {:ok, sealed} =
      SalixAgent.SubscriptionStore.seal(tenant_id(), account, %{"api_key" => "sk-vm"})

    {:ok, _} =
      SalixAgent.SubscriptionStore.create(tenant_id(), %{
        "id" => account,
        "name" => "Anthropic",
        "credential" => "api_key",
        "source" => "anthropic",
        "disabled" => false,
        "credentials" => sealed,
        "endpoint" => "https://api.anthropic.com",
        "protocol" => "anthropic",
        "auth" => "api_key"
      })

    create_cloudflare_agent()
    assert {:ok, :ready} = SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id())
    {:ok, rec} = GroupCompute.group_workload(group_id())
    sandbox = rec["provider_resource_name"]

    sent =
      settle_until(fn ->
        Enum.find(MockCloudflareGateway.calls(gateway), &(&1.op == :station_profiles))
      end)

    assert [%{"id" => "sh-" <> _ = share, "profile" => profile}] = sent.body["profiles"]

    # What the station may run on it: the catalog models its key serves.
    {models, rest} = Map.pop(profile, "models")
    assert "claude-opus-5-5" in models

    assert rest == %{
             "name" => "Anthropic",
             "runtime" => "claude",
             "credential" => "api_key",
             "source" => "anthropic",
             "endpoint" => "https://api.anthropic.com",
             "protocol" => "anthropic",
             "key" => "sk-vm"
           }

    assert {:ok, %{"profile" => ^profile, "allow" => nil}} =
             MockCloudflareGateway.station_asks(gateway, sandbox, "share.get", %{"id" => share})

    assert {:error, "only a subscription is lent"} =
             MockCloudflareGateway.station_asks(gateway, sandbox, "share.lend", %{"id" => share})

    assert {:error, "this station does not share that"} =
             MockCloudflareGateway.station_asks(gateway, sandbox, "share.lend", %{
               "id" => "sh-unknown0000"
             })
  end

  defmodule ControlPlaneFake do
    @behaviour SalixWeb.StationPlace

    @impl true
    def admit(tenant, group, station, previous, version) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :cloud_vm_test_pid),
        {:admit, tenant, group, station, previous, version}
      )

      {:ok, %{"provider" => "comma", "workspace" => group, "station" => station}}
    end
  end

  test "a Cloud VM's station is placed in its Group's workspace when it connects" do
    prior = SystemsRuntime.get_env(:salix_web, :station_control_plane)
    SystemsRuntime.put_env(:salix_web, :station_control_plane, ControlPlaneFake)
    on_exit(fn -> restore_salix_web_env(:station_control_plane, prior) end)

    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :allow)
    create_cloudflare_agent()
    assert {:ok, :ready} = SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id())
    {:ok, rec} = GroupCompute.group_workload(group_id())
    sandbox = rec["provider_resource_name"]
    station = MockCloudflareGateway.station_key(sandbox)
    group = group_id()

    settle_receive({:admit, _tenant, ^group, ^station, nil, "test"})

    placed =
      settle_until(fn ->
        Enum.find(MockCloudflareGateway.calls(gateway), &(&1.op == :station_place))
      end)

    assert placed.body["workspace"] == group
    assert placed.body["station"] == station

    settle_until(fn ->
      match?({:ok, %{"station_id" => ^station}}, GroupCompute.group_workload(group))
    end)

    # A VM that comes back with another key replaces the station it had.
    {:ok, _, _} =
      GroupCompute.update_group_workload(
        group,
        &Map.put(&1, "station_id", String.duplicate("a", 64))
      )

    :ok = MockCloudflareGateway.restart_station(gateway, sandbox)
    previous = String.duplicate("a", 64)
    settle_receive({:admit, _tenant, ^group, ^station, ^previous, "test"})

    settle_until(fn ->
      match?({:ok, %{"station_id" => ^station}}, GroupCompute.group_workload(group))
    end)

    {:ok, current} = GroupCompute.group_workload(group)
    assert current["connector_id"] == rec["connector_id"]
  end

  test "with the Group's Cloud VM switch on, its Router starts a new Group VM and an unbound Worker can place a Task there" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    enable_cloud_vm!()

    {:ok, router} =
      SalixAgent.Control.create(%{"group_id" => group_id(), "role" => "router"}, tenant_id())

    {:ok, worker} =
      SalixAgent.Control.create(%{"group_id" => group_id(), "role" => "worker"}, tenant_id())

    refute SalixAgent.StationBinding.bound?(worker)
    assert {:error, :not_found} = GroupCompute.group_workload(group_id())
    scope = %{tenant_id: tenant_id(), group_id: group_id(), agent_id: worker["agent_id"]}

    assert {:error, :cloud_vm_not_running} =
             Salix.Bindings.AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"})

    {:ok, other_group} = Salix.Control.Groups.create(%{"name" => "Other Group"}, tenant_id())
    enable_cloud_vm!(other_group["group_id"])

    {:ok, outsider} =
      SalixAgent.Control.create(%{"group_id" => other_group["group_id"]}, tenant_id())

    assert {:error, :worker_not_found, []} =
             CloudVM.Start.run(router["agent_id"], 300_000, outsider["agent_id"])

    assert {:error, :not_found} =
             Salix.Bindings.AgentConversations.runs_on(
               %{scope | agent_id: outsider["agent_id"]},
               %{"kind" => "cloud_vm"}
             )

    started = SystemsRuntime.Task.async(fn -> CloudVM.Start.run(router["agent_id"], 300_000) end)

    {:ok, result} =
      settle_until(fn ->
        SalixEnv.ComputeReconciler.sweep()
        SystemsRuntime.Task.yield(started, 0)
      end)

    assert {:ok, %{"status" => "connected", "steps" => steps}} = result
    assert hd(steps)["state"] == "none"
    assert List.last(steps)["state"] == "connected"
    assert {:ok, %{"status" => "ready"}} = GroupCompute.group_workload(group_id())

    assert {:ok, %{"kind" => "cloud_vm"}} =
             Salix.Bindings.AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"})
  end

  test "the Group's Cloud VM switch alone decides who starts the archived Cloud VM and places Tasks there" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :allow)
    _ = create_cloudflare_agent()
    assert {:ok, :ready} = SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id())

    assert {:ok, %{"status" => "archived"}} =
             SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id(), force: true)

    {:ok, agent} = SalixAgent.Control.create(%{"group_id" => group_id()}, tenant_id())

    {:ok, router} =
      SalixAgent.Control.create(%{"group_id" => group_id(), "role" => "router"}, tenant_id())

    worker = cloud_vm_worker!()
    scope = %{tenant_id: tenant_id(), group_id: group_id(), agent_id: worker["agent_id"]}
    unbound = %{tenant_id: tenant_id(), group_id: group_id(), agent_id: agent["agent_id"]}

    # Switch off: no Agent, bound to the Cloud VM or not, starts it or places a Task there.
    assert {:ok, _group} =
             Salix.Control.Groups.update(group_id(), %{"cloud_vm_enabled" => false})

    assert {:error, :cloud_vm_disabled, []} = CloudVM.Start.run(router["agent_id"], 300_000)

    assert {:error, :cloud_vm_disabled, []} =
             CloudVM.Start.run(router["agent_id"], 300_000, worker["agent_id"])

    assert Salix.Bindings.AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_disabled}

    assert Salix.Bindings.AgentConversations.runs_on(unbound, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_disabled}

    enable_cloud_vm!()

    # Archived, nothing is woken on the way: a Task cannot run on it.
    assert Salix.Bindings.AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"}) ==
             {:error, :cloud_vm_not_running}

    # The Router starts the Group's VM for the Worker.
    started =
      SystemsRuntime.Task.async(fn ->
        CloudVM.Start.run(router["agent_id"], 300_000, worker["agent_id"])
      end)

    # The Compute reconciler carries the wake out.
    {:ok, result} =
      settle_until(fn ->
        SalixEnv.ComputeReconciler.sweep()
        SystemsRuntime.Task.yield(started, 0)
      end)

    assert {:ok, %{"status" => "connected", "steps" => steps}} = result
    states = Enum.map(steps, & &1["state"])
    assert hd(states) == "archived"
    assert List.last(states) == "connected"
    assert Enum.map(steps, & &1["at_s"]) == Enum.sort(Enum.map(steps, & &1["at_s"]))

    # Bound to it or not, every Agent of the Group places its Tasks there now.
    assert {:ok, %{"kind" => "cloud_vm"}} =
             Salix.Bindings.AgentConversations.runs_on(scope, %{"kind" => "cloud_vm"})

    assert {:ok, %{"kind" => "cloud_vm"}} =
             Salix.Bindings.AgentConversations.runs_on(unbound, %{"kind" => "cloud_vm"})

    # Already connected: it answers at once, to the Worker itself as well.
    assert {:ok, %{"steps" => [%{"state" => "connected", "at_s" => 0}]}} =
             CloudVM.Start.run(worker["agent_id"], 300_000)

    # An archived Agent uses nothing.
    assert SalixAgent.CloudVM.allowed?(agent)
    refute SalixAgent.CloudVM.allowed?(Map.put(agent, "archived_at", 1))
  end

  # A Worker of `group` bound to the Group's Cloud VM.
  defp cloud_vm_worker!(group \\ group_id()) do
    {:ok, worker} =
      SalixAgent.Control.create(
        %{
          "group_id" => group,
          "role" => "worker",
          "name" => "On the Cloud VM",
          "station_binding" => %{
            "runs_on" => %{"kind" => "cloud_vm"},
            "model" => %{"kind" => "runtime", "provider" => "codex"}
          }
        },
        tenant_id()
      )

    worker
  end

  test "one async exec retains its call through first creation and archive wake" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    agent = create_cloudflare_agent(%{"role" => "worker"})
    target = cloud_target(agent["agent_id"], "cloud-vm")
    old_budget = SystemsRuntime.get_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 5_000)

    on_exit(fn ->
      if old_budget,
        do: SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, old_budget),
        else: SystemsRuntime.delete_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    end)

    for lifecycle <- [:create, :wake] do
      stale_run =
        if lifecycle == :wake do
          assert {:ok, record} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())

          assert {:ok, _} =
                   SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id(),
                     force: true,
                     now: record["runtime_selection_until"] + 1
                   )

          # The connection projection can outlive the archived owner. Admission
          # must still wake the Workload and retain this original tool call.
          run = force_connected("stale-before-wake", group_id())

          assert {:ok, %{"status" => "archived"}} =
                   SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())

          assert {:ok, %{"status" => "connected"}, _} =
                   SalixEnv.Control.get_command_environment(
                     target.device_id,
                     target.environment_id,
                     group_id(),
                     tenant_id()
                   )

          run
        end

      ctx =
        %{
          agent_id: agent["agent_id"],
          session_id: SalixStore.Ids.new_session_id(),
          tenant_id: tenant_id(),
          group_id: group_id(),
          role: "worker"
        }
        |> SalixAgent.TestSupport.with_plugin_projection()

      ctx =
        Map.put(
          ctx,
          :tool_disclosure,
          SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
        )

      command = "echo original-#{lifecycle}"

      call = %{
        name: "env.exec",
        id: "retained-#{lifecycle}",
        args: %{
          "device_id" => target.device_id,
          "environment" => target.environment_id,
          "command" => command,
          "description" => "Execute the original command"
        }
      }

      {[early], [pending]} = execute_with_async_window([call], ctx)
      assert early.status == "async_running"
      assert pending.tool_call_id == call.id
      group = group_id()

      eventually(fn ->
        case SalixWeb.ComputeProviders.Cloudflare.get_record(group) do
          {:ok, r} ->
            (r["runtime_selection_until"] || 0) > SystemsClock.system_time(:millisecond) and
              (lifecycle == :create or is_integer(r["wake_requested_at"]))

          _ ->
            false
        end
      end)

      assert SalixAgent.DependencyJob.yield(pending.dependency_job, 100) == nil

      if lifecycle == :create do
        assert {:ok, :ready} =
                 SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)
      else
        assert {:ok, _} = Registry.mark_disconnected(stale_run)
        assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group)
      end

      assert {:skipped, :runtime_selection} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      assert {:ok, result} = SalixAgent.DependencyJob.yield(pending.dependency_job, 3_000)
      assert result.status == "completed"
      assert Jason.decode!(result.content)["exit_code"] == 0
      assert :ok = SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(agent["agent_id"])

      frames =
        Enum.filter(
          MockCloudflareGateway.calls(gateway),
          &(&1.op == :frame and &1.body["method"] == "exec" and
              get_in(&1.body, ["params", "command"]) == command)
        )

      assert length(frames) == 1
    end
  end

  test "readiness timeout or cancelled async exec cannot dispatch later" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    # The VM's station connects after the readiness budget.
    :ok = MockCloudflareGateway.set_connect_delay(gateway, 1_000)
    agent = create_cloudflare_agent(%{"role" => "worker"})
    target = cloud_target(agent["agent_id"], "cloud-vm")
    old_budget = SystemsRuntime.get_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 100)

    on_exit(fn ->
      if old_budget,
        do: SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, old_budget),
        else: SystemsRuntime.delete_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    end)

    assert {:error, :timeout} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo expired", %{
               "wait_for_vm" => true
             })

    assert {:ok, r} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())
    assert r["runtime_selection_until"] <= SystemsClock.system_time(:millisecond)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 5_000)

    ctx =
      %{
        agent_id: agent["agent_id"],
        session_id: SalixStore.Ids.new_session_id(),
        tenant_id: tenant_id(),
        group_id: group_id(),
        role: "worker"
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
      )

    call = %{
      name: "env.exec",
      id: "cancelled-wake",
      args: %{
        "device_id" => target.device_id,
        "environment" => target.environment_id,
        "command" => "echo cancelled",
        "description" => "Execute the original command"
      }
    }

    {[_], [pending]} = execute_with_async_window([call], ctx)
    :ok = SalixAgent.DependencyJob.cancel(pending.dependency_job)

    assert {:ok, :ready} =
             SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id(), force: true)

    refute Enum.any?(
             MockCloudflareGateway.calls(gateway),
             &(&1.op == :frame and &1.body["method"] == "exec")
           )

    # A connected projection does not finish readiness while the owner wakes.
    update_vm_record(group_id(), &Map.put(&1, "status", "waking"))

    assert {:ok, %{"status" => "connected"}, _} =
             SalixEnv.Control.get_command_environment(
               target.device_id,
               target.environment_id,
               group_id(),
               tenant_id()
             )

    SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 100)

    assert {:error, :timeout} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo admission-expired", %{
               "wait_for_vm" => true
             })

    assert {:ok, record} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())
    assert record["runtime_selection_until"] <= SystemsClock.system_time(:millisecond)

    refute Enum.any?(
             MockCloudflareGateway.calls(gateway),
             &(&1.op == :frame and &1.body["method"] == "exec")
           )

    update_vm_record(group_id(), &Map.put(&1, "status", "ready"))

    # Keep reconnect slower than the readiness budget.
    :ok = MockCloudflareGateway.set_connect_delay(gateway, 1_000)
    drop_station(gateway, group_id())
    tenant = tenant_id()
    group = group_id()

    assert eventually(fn ->
             case Registry.get_device(tenant, group, target.device_id) do
               {:ok, device} -> device["status"] != "connected"
               _ -> true
             end
           end)

    SystemsRuntime.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 100)

    assert {:error, :timeout} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo offline", %{
               "wait_for_vm" => true
             })

    assert {:error, {:vm_waking, _}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo immediate", %{})
  end

  test "creating an agent with the Group's Cloud VM switch on does not create a Group VM" do
    SystemsRuntime.put_env(:salix_web, :platform_vm, %{
      "default_provider" => "cloudflare",
      "providers" => %{"cloudflare" => %{"enabled" => true}}
    })

    enable_cloud_vm!()
    {:ok, agent} = SalixAgent.Control.create(%{"group_id" => group_id()}, tenant_id())

    assert {:error, :not_found} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
  end

  test "the selected default VM environment creates one Group workload on first exec" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)

    {:ok, agent} = SalixAgent.Control.create(%{"group_id" => group_id()}, tenant_id())
    target = cloud_target(agent["agent_id"], "cloud-vm")

    # The Group's Cloud VM switch is off: no command creates its VM.
    assert {:error, :no_environment} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "true", %{})

    enable_cloud_vm!()
    assert {:error, :not_found} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())

    assert {:error, :no_environment} =
             SalixWeb.EnvDispatch.exec(
               agent["agent_id"],
               %{target | environment_id: "another-environment"},
               "true",
               %{}
             )

    assert {:error, :not_found} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())

    assert {:error, {:vm_waking, %{"env_id" => expected}}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "true", %{})

    assert expected == target.environment_id

    assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-2"}}} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())

    assert {:error, %{"error_class" => "vm_unavailable", "status" => "creating"}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "true", %{})

    assert {:ok, original} = SalixStore.Compute.group_workload(group_id())

    update_vm_record(group_id(), fn current ->
      current
      |> Map.put("status", "failed")
      |> Map.put("error", "gateway profile unavailable before release")
    end)

    SalixAgent.TestSupport.stop_all_agents()

    assert {:error, {:vm_waking, _}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "true", %{})

    assert {:ok, restarted} = SalixStore.Compute.group_workload(group_id())
    assert restarted["workload_id"] == original["workload_id"]
    assert restarted["status"] == "creating"
    assert restarted["provider_spec"]["profile_key"] == "cf-standard-2"
  end

  test "a rejected Android request on the absent default VM does not create a workload" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)

    enable_cloud_vm!()

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group_id(), "role" => "worker"}, tenant_id())

    policy = %{
      "version" => 2,
      "enabled" => true,
      "allowed_modes" => ["connected"],
      "allowed_profiles" => ["api30-phone"],
      "max_concurrent_leases" => 1,
      "max_lease_seconds" => 3600
    }

    assert {:ok, _} =
             Salix.Control.Tenants.update_config(tenant_id(), "android_control", policy)

    assert {:ok, _} =
             Salix.Control.Plugins.enable_group(tenant_id(), group_id(), "android-control")

    assert {:ok, admitted_policy} = Salix.Control.AndroidControl.authorize(tenant_id())

    assert {:error, :android_profile_not_allowed} =
             Salix.Control.AndroidControl.authorize_action(
               admitted_policy,
               %{
                 "protocol_version" => 2,
                 "profiles" => ["api30-phone", "api35-phone-google-apis"],
                 "profile_details" => [
                   %{"id" => "api30-phone", "status" => "installed"},
                   %{"id" => "api35-phone-google-apis", "status" => "installed"}
                 ],
                 "default_profile" => "api35-phone-google-apis"
               },
               %{"action" => "start", "profile" => "api35-phone-google-apis"}
             )

    assert {:error, :not_found} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())

    assert {:error, :no_environment} =
             SalixWeb.EnvDispatch.android(
               agent["agent_id"],
               cloud_target(agent["agent_id"], "cloud-vm"),
               %{"action" => "start", "profile" => "api35-phone-google-apis"}
             )

    assert {:error, :not_found} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())
  end

  test "an existing Cue Group starts and retries its first VM in standard-2" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)

    {:ok, group} =
      Salix.Control.Groups.create(
        %{"name" => "Existing Cue workspace", "billing_owner" => %{"surface" => "cue"}},
        tenant_id()
      )

    enable_cloud_vm!(group["group_id"])
    {:ok, agent} = SalixAgent.Control.create(%{"group_id" => group["group_id"]}, tenant_id())
    target = cloud_target(agent["agent_id"], "cloud-vm")

    assert {:error, {:vm_waking, _}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "true", %{})

    assert {:ok, original} = SalixStore.Compute.group_workload(group["group_id"])
    assert original["provider_spec"]["profile_key"] == "cf-standard-2"

    update_vm_record(group["group_id"], fn current ->
      current |> Map.put("status", "failed") |> Map.put("error", "transient failure")
    end)

    SalixAgent.TestSupport.stop_all_agents()

    assert {:error, {:vm_waking, _}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "true", %{})

    assert {:ok, restarted} = SalixStore.Compute.group_workload(group["group_id"])
    assert restarted["workload_id"] == original["workload_id"]
    assert restarted["provider_spec"]["profile_key"] == "cf-standard-2"
    assert restarted["status"] == "creating"
  end

  test "a Group's Cloud VM goes on the Agent VMM Host bound to it, and stays there" do
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)

    registration_id =
      "host-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Agent VMM Cloud VM",
          "billing_owner" => %{
            "surface" => "comma",
            "vm_profile_key" => "cf-standard-1",
            "billing_account_id" => "ba_agent_vmm"
          }
        },
        tenant_id()
      )

    group_id = group["group_id"]

    # No Host bound and no Cloudflare configured: no Cloud VM.
    assert {:error, {:bad_request, "the Cloud VM requires tenant vm provider configuration" <> _}} =
             Salix.Control.Groups.update(group_id, %{"cloud_vm_enabled" => true})

    # The Project's Runner is installed as the Group's Agent VMM Host.
    {:ok, _registration} =
      SalixStore.AgentVMM.create_registration(%{
        id: registration_id,
        tenant_id: tenant_id(),
        group_id: group_id,
        device_id: "host-device-" <> registration_id,
        enrollment_token: String.duplicate("h", 32)
      })

    connect_agent_vmm_host!(registration_id)
    enable_cloud_vm!(group_id)
    {:ok, agent} = SalixAgent.Control.create(%{"group_id" => group_id}, tenant_id())

    assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)
    assert rec["provider"] == "agent_vmm"
    assert rec["provider_resource_id"] == registration_id
    assert rec["device_id"] == SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group_id)
    assert rec["env_id"] == SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

    # A second Host bound later does not move the existing VM.
    {:ok, _second} =
      SalixStore.AgentVMM.create_registration(%{
        id: registration_id <> "-2",
        tenant_id: tenant_id(),
        group_id: group_id,
        device_id: "host-device-" <> registration_id <> "-2",
        enrollment_token: String.duplicate("i", 32)
      })

    assert {:ok, %{"workload_id" => same, "provider_resource_id" => ^registration_id}} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

    assert same == rec["workload_id"]

    # A Group with two Hosts and no VM yet gets none: nothing chooses between them.
    {:ok, other} =
      Salix.Control.Groups.create(%{"name" => "Two Hosts"}, tenant_id())

    for suffix <- ["-a", "-b"] do
      {:ok, _} =
        SalixStore.AgentVMM.create_registration(%{
          id: registration_id <> suffix,
          tenant_id: tenant_id(),
          group_id: other["group_id"],
          device_id: "host-device-" <> registration_id <> suffix,
          enrollment_token: String.duplicate("j", 32)
        })
    end

    assert {:error, {:conflict, "the Project has more than one Agent VMM Host"}} =
             Salix.Control.Groups.update(other["group_id"], %{"cloud_vm_enabled" => true})

    workload = SalixStore.Repo.get!(GroupCompute.Workload, rec["workload_id"])
    assert workload.template_key == "station.default"
    # The tenant's own Host is not a metered Cloudflare Container.
    refute_received {:vm_authorize, _}

    # An agent starting its sleeping VM asks for its container to start again.
    assert {:ok, _, _} =
             GroupCompute.update_group_workload(group_id, &Map.put(&1, "status", "archived"))

    worker = cloud_vm_worker!(group_id)

    assert {:error, :timeout, [%{"state" => "archived"} | _]} =
             SalixWeb.CloudVM.Start.run(agent["agent_id"], 50, worker["agent_id"])

    assert {:ok, %{"status" => "archived", "wake_requested_at" => requested}} =
             GroupCompute.group_workload(group_id)

    assert is_integer(requested)
    refute_received {:vm_authorize, _}
  end

  defmodule RunnerFake do
    @moduledoc false
    # The Runner's BFT heartbeat is fresh throughout: it says nothing of the
    # Host's connection to Salix.
    def runner_status(_tenant_id, "runner-office"),
      do: {:ok, %{"name" => "Office Mac", "status" => "online"}}

    def runner_status(_tenant_id, _runner_id), do: {:error, :not_found}
  end

  test "a Group's first Cloud VM is not created on its Project's Runner while the Runner's Host is not connected to Salix" do
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    previous_runners = SystemsRuntime.get_env(:salix_web, :agent_vmm_runner_mod)
    SystemsRuntime.put_env(:salix_web, :agent_vmm_runner_mod, RunnerFake)
    on_exit(fn -> restore_salix_web_env(:agent_vmm_runner_mod, previous_runners) end)

    registration_id =
      "host-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

    {:ok, _registration} =
      SalixStore.AgentVMM.create_registration(%{
        id: registration_id,
        tenant_id: tenant_id(),
        group_id: group_id(),
        device_id: "host-device-" <> registration_id,
        enrollment_token: String.duplicate("h", 32)
      })

    # The Host connected, then lost its connection. The Runner still reports to BFT.
    binding = connect_agent_vmm_host!(registration_id)
    installed_on_runner!(registration_id, "runner-office")
    assert SalixStore.AgentVMM.connected?(registration_id)

    assert {:ok, _lost} =
             SalixStore.AgentVMM.mark_connection_lost(registration_id, "gateway-test", "7")

    refute SalixStore.AgentVMM.connected?(registration_id)

    # The Group's Cloud VM switch may be on: where the VM goes is decided when it is created.
    enable_cloud_vm!()

    {:ok, router} =
      SalixAgent.Control.create(%{"group_id" => group_id(), "role" => "router"}, tenant_id())

    worker = cloud_vm_worker!()

    assert {:tool_failure, body, "runner_offline", "user_reportable", message, []} =
             SalixAgent.Tools.CloudVM.start(%{"agent_id" => worker["agent_id"]}, %{
               agent_id: router["agent_id"]
             })

    assert message =~ ~s(Agent VMM Host on this Project's Runner "Office Mac" is not connected)
    assert message =~ "or unbind the Runner"
    assert %{"code" => "runner_offline"} = Jason.decode!(body)

    assert {:error, {:runner_offline, %{"name" => "Office Mac", "status" => "host_disconnected"}}} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(router)

    # No VM was made, on the Runner or on Cloudflare.
    assert {:error, :not_found} = GroupCompute.group_workload(group_id())

    # The Host connects again: the VM is created on it.
    agent_vmm_host_connected!(binding)

    assert {:ok, %{"provider" => "agent_vmm", "provider_resource_id" => ^registration_id}} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(router)
  end

  # The Host was installed through BFT on the org Runner `runner_id`.
  defp installed_on_runner!(registration_id, runner_id) do
    SalixStore.Repo.query!(
      """
      INSERT INTO agent_vmm_install_operations (
        id, tenant_id, group_id, surface, scope_key, client_request_id, provider,
        delivery_target_type, delivery_target_id, registration_id,
        authorization_status, ticket_generation, ticket_secret_hash, ticket_status,
        ticket_expires_at, created_at, updated_at
      ) VALUES (
        $1, $2, $3, 'bft', 'project-' || $1, 'request-' || $1, 'agent-vmm',
        'bft_runner', $4, $1,
        'handed_off', 1, decode(repeat('11', 32), 'hex'), 'consumed',
        now(), now(), now()
      )
      """,
      [registration_id, tenant_id(), group_id(), runner_id]
    )
  end

  # The Host's current connection made its Project Environment's binding available.
  defp connect_agent_vmm_host!(registration_id) do
    {:ok, pool} =
      GroupCompute.create_pool(%{
        id: "host-pool-" <> registration_id,
        tenant_id: tenant_id(),
        name: "Host",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      GroupCompute.create_environment(%{
        id: "host-project-" <> registration_id,
        tenant_id: tenant_id(),
        owner_type: "project",
        owner_id: "project-" <> registration_id,
        pool_id: pool.id
      })

    {:ok, binding} =
      GroupCompute.create_provider_binding(%{
        id: "host-binding-" <> registration_id,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration_id
      })

    SalixStore.Repo.update_all(
      from(r in SalixStore.AgentVMM.Registration, where: r.id == ^registration_id),
      set: [status: "ready", desired_enabled: true]
    )

    agent_vmm_host_connected!(binding)
  end

  # What a Host's hello does to its binding: available, on that connection.
  defp agent_vmm_host_connected!(binding) do
    SalixStore.Repo.update_all(
      from(b in GroupCompute.ProviderBinding, where: b.id == ^binding.id),
      set: [
        status: "available",
        observation: %{"gateway_instance_id" => "gateway-test", "connection_epoch" => "7"}
      ]
    )

    binding
  end

  test "product profile selects the same SKU for start and interval metering" do
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    SystemsRuntime.put_env(:salix_web, :vm_metering_mod, MeteringFake)

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Comma standard-1",
          "billing_owner" => %{
            "surface" => "comma",
            "vm_profile_key" => "cf-standard-1",
            "billing_account_id" => "ba_standard_1"
          }
        },
        tenant_id()
      )

    agent = %{
      "agent_id" => "standard-1-agent",
      "tenant_id" => tenant_id(),
      "group_id" => group["group_id"]
    }

    assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-1"}}} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

    settle_receive({:vm_authorize, %{sku: "runtime-standard-1"}})
    assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group["group_id"])

    assert %{revived: []} =
             SalixWeb.ComputeProviders.Cloudflare.sweep_once(
               now: SystemsClock.system_time(:millisecond) + 60_000,
               bootstrap_mode: :dialback
             )

    settle_receive({:vm_fact, %{sku: "runtime-standard-1"}})
  end

  test "a legacy Comma standard-2 Workload keeps its saved location" do
    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Legacy Comma VM",
          "billing_owner" => %{"surface" => "comma", "vm_profile_key" => "cf-standard-1"}
        },
        tenant_id()
      )

    group_id = group["group_id"]

    assert {:ok, original, :created} =
             GroupCompute.ensure_group_workload(%{
               "tenant_id" => tenant_id(),
               "group_id" => group_id,
               "provider" => "cloudflare",
               "provider_resource_id" =>
                 SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group_id),
               "provider_spec" => %{"profile_key" => "cf-standard-2"},
               "status" => "archived",
               "created_at" => 1_000
             })

    assert {:ok, existing} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(%{
               "tenant_id" => tenant_id(),
               "group_id" => group_id
             })

    assert existing["workload_id"] == original["workload_id"]
    assert existing["provider_spec"]["profile_key"] == "cf-standard-2"
  end

  # Simulate the connector inside the VM dialing back to /v1/connect: a
  # connected registry record in the agent's group under the cloud-vm alias.
  defp attach_fake_connector_env(transport_id, group_id) do
    :ok = MockCloudflareGateway.detach_stations()

    {:ok, ^transport_id, device} =
      Registry.connect(
        to_string(node()),
        %{
          "alias" => "cloud-vm",
          "name" => "Cloud Workspace",
          "group_id" => group_id,
          "tenant_id" => tenant_id(),
          "device_id" => SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group_id),
          "connector_id" => SalixWeb.ComputeProviders.Cloudflare.cloudvm_connector_id(group_id)
        },
        transport_id: transport_id
      )

    device["connector_run_id"]
  end

  defp command_environment_id!(group_id) do
    settle_until(fn ->
      case SalixEnv.Control.get_environment(
             SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group_id),
             group_id,
             tenant_id()
           ) do
        {:ok, %{"environment_id" => id}} when is_binary(id) and id != "" -> id
        _ -> nil
      end
    end)
  end

  defp force_connected(transport_id, group_id) do
    connector_run_id = attach_fake_connector_env(transport_id, group_id)
    age_current_device(group_id)
    connector_run_id
  end

  defp age_current_device(group_id) do
    key =
      SalixStore.Keys.ctl_group_device(
        tenant_id(),
        group_id,
        SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group_id)
      )

    {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)

    device =
      Map.put(Jason.decode!(body), "updated_at", SystemsClock.system_time(:millisecond) - 120_000)

    {:ok, _} = SalixStore.S3.put(key, Jason.encode!(device), if_match: etag)
    :ok
  end

  defp cloud_device(group_id) do
    Registry.get_device(
      tenant_id(),
      group_id,
      SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group_id)
    )
  end

  # A test that writes a record as archived or waking by hand seals the
  # Gateway's control first, as the archive it stands for leaves it: the
  # Gateway opens a wake's permit only on a sealed control.
  defp seal_gateway_control(gateway, group_id) do
    {:ok, rec} = GroupCompute.group_workload(group_id)

    client =
      SalixEnv.VM.Providers.Cloudflare.Client.new(
        base_url: MockCloudflareGateway.base_url(gateway),
        secret: "test-secret",
        group_id: group_id
      )

    {:ok, _} =
      SalixEnv.VM.Providers.Cloudflare.Client.seal_control(client, rec["provider_resource_name"])

    :ok
  end

  defp update_vm_record(group_id, fun) do
    {:ok, updated, _previous} = GroupCompute.update_group_workload(group_id, fun)
    updated
  end

  defp configure_archive_r2 do
    previous = SystemsRuntime.get_env(:salix_web, :cloud_vm_archive_r2)

    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2, %{
      "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      "bucket" => "test-archive",
      "access_key_id" => "testaccess",
      "secret_access_key" => "testsecret"
    })

    # R2 itself is the store the Gateway mock's stations write their parts to.
    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2_req,
      plug: &SalixWeb.MockCloudflareGateway.r2/1
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :cloud_vm_archive_r2_req) end)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2, previous),
        else: SystemsRuntime.delete_env(:salix_web, :cloud_vm_archive_r2)
    end)
  end

  defp eventually(fun), do: settle_until(fun)

  # The async window polls its dependency job with a zero span: it takes only
  # a result already in the mailbox. A process that drives the clock settles
  # a zero span instead, and fails while a later timer is pending, so the test
  # settles first and polls without driving the clock.
  defp execute_with_async_window(calls, ctx) do
    settle()
    {_pid, ref} = spawn_monitor(fn -> SystemsClock.take_over(keep_journal: true) end)

    SystemsRuntime.Proc.receive do
      {:DOWN, ^ref, :process, _, :normal} -> :ok
    end

    try do
      SalixAgent.Tools.execute_with_async_window(calls, ctx)
    after
      SystemsClock.take_over(keep_journal: true)
    end
  end

  defp wait_for_call(gateway, op) do
    {:ok, settle_until(fn -> Enum.find(MockCloudflareGateway.calls(gateway), &(&1.op == op)) end)}
  end

  describe "the Group's Cloud VM switch" do
    test "does not turn on when the tenant has no default provider config" do
      tenant_id = create_tenant!()
      group_id = create_group!(tenant_id)

      assert {:error, {:bad_request, @config_missing}} =
               Salix.Control.Groups.update(group_id, %{"cloud_vm_enabled" => true})

      assert {:ok, %{"cloud_vm_enabled" => false}} = Salix.Control.Groups.get(group_id)
    end

    test "turns on under tenant VM config, and an Agent's vm is no setting" do
      tenant_id =
        create_tenant!(%{
          "config" =>
            Jason.encode!(%{
              "vm" => %{
                "default_provider" => "cloudflare",
                "providers" => %{"cloudflare" => %{"enabled" => true}}
              }
            })
        })

      # An older caller's `vm` neither turns the switch on nor is stored.
      {:ok, agent} = create_agent!(tenant_id, %{"vm" => %{"enabled" => true}})
      refute Map.has_key?(agent, "vm")
      refute SalixAgent.CloudVM.allowed?(agent)

      assert {:ok, %{"cloud_vm_enabled" => true}} =
               Salix.Control.Groups.update(agent["group_id"], %{"cloud_vm_enabled" => true})

      assert SalixAgent.CloudVM.allowed?(agent)

      assert {:error, :not_found} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])

      assert {:ok, %{"cloud_vm_enabled" => false}} =
               Salix.Control.Groups.update(agent["group_id"], %{"cloud_vm_enabled" => false})

      refute SalixAgent.CloudVM.allowed?(agent)
    end

    test "does not turn on in a router-only (guest) Tenant" do
      SystemsRuntime.put_env(:salix_web, :platform_vm, %{
        "default_provider" => "cloudflare",
        "providers" => %{"cloudflare" => %{"enabled" => true}}
      })

      tenant_id = create_tenant!()
      group_id = create_group!(tenant_id)
      {:ok, _profile} = SalixStore.TenantProfiles.put_router_only(tenant_id, 16)

      assert {:error, {:bad_request, "this tenant has no Cloud VM"}} =
               Salix.Control.Groups.update(group_id, %{"cloud_vm_enabled" => true})
    end

    test "turns on for tenants that follow platform VM config" do
      SystemsRuntime.put_env(:salix_web, :platform_vm, %{
        "default_provider" => "cloudflare",
        "providers" => %{"cloudflare" => %{"enabled" => true}}
      })

      tenant_id =
        create_tenant!(%{
          "config" => Jason.encode!(%{"vm" => %{"config_source" => "platform"}})
        })

      group_id = create_group!(tenant_id)

      assert {:ok, %{"cloud_vm_enabled" => true}} =
               Salix.Control.Groups.update(group_id, %{"cloud_vm_enabled" => true})

      assert {:error, :not_found} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "cloudflare auto-provision uses the Worker gateway" do
      gateway = start_supervised!(MockCloudflareGateway)

      tenant_id =
        create_tenant!(%{
          "config" =>
            Jason.encode!(%{
              "vm" => %{
                "default_provider" => "cloudflare",
                "providers" => %{
                  "cloudflare" => %{
                    "enabled" => true,
                    "gateway_base_url" => MockCloudflareGateway.base_url(gateway),
                    "gateway_secret" => "test-secret"
                  }
                }
              }
            })
        })

      {:ok, agent} = create_agent!(tenant_id)

      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)
      assert SalixEnv.ComputeReconciler.sweep() in [:more, :complete]

      # Allow the WebSocket attach and final record commit to finish.
      eventually(fn ->
        match?(
          {:ok, %{"provider" => "cloudflare", "status" => "ready"}},
          SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
        )
      end)

      assert {:ok,
              %{
                "provider_spec" => %{
                  "cloudflare_worker" => %{
                    "worker_version_id" => "version-1",
                    "worker_version_tag" => "tag-1",
                    "gateway_build_id" => "build-1",
                    "connector_image_version" => "connector-1"
                  }
                }
              }} = SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])

      assert {:ok, _} = wait_for_call(gateway, :ensure)
    end

    test "cloudflare provision restores the archive before the station starts and dispatches through it" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      archive = %{
        "type" => "connector_tar_zst_chunks",
        "storage" => "r2",
        "scope" => "full",
        "operation" => "archive-existing",
        "byte_size" => 3,
        "chunk_size" => 4 * 1024 * 1024,
        "chunk_count" => 1,
        "sessions" => 0
      }

      update_vm_record(group_id, &Map.put(&1, "archive", archive))

      assert {:ok, _} =
               SalixStore.S3.put(
                 SalixWeb.CloudVM.DurableArchive.chunk_key(group_id, "archive-existing", 0),
                 "old"
               )

      {ready, log} =
        ExUnit.CaptureLog.with_log(fn ->
          SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)
        end)

      assert {:ok, :ready} = ready

      # The VM is ready, and the log says what the restore put on the disk and
      # how long its steps took, as the station's receipt says.
      assert log =~
               "cloud-vm ready on its restored archive: group=#{group_id} operation=archive-existing"

      assert log =~
               ~s(restore=%{"bytes" => 3, "entries" => 2, "files" => 1, "timings" => %{"downloaded_ms" => 700, "first_byte_ms" => 90, "manifest_ms" => 40, "synced_ms" => 2600, "total_ms" => 2610, "written_ms" => 2500}})

      assert {:ok, %{"provider" => "cloudflare", "status" => "ready", "env_id" => env_id}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert env_id == SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)
      environment_id = command_environment_id!(group_id)

      # The start named the archive, the Container restored it, and only then
      # did its station start: it connected once, and was given no archive.
      ops = gateway |> MockCloudflareGateway.calls() |> Enum.map(& &1.op)
      assert [:ensure, :archive_restore, :connect | _] = ops
      assert Enum.count(ops, &(&1 == :connect)) == 1

      assert [%{body: %{"operation" => "archive-existing", "bytes" => 3, "parts" => 1}}] =
               Enum.filter(MockCloudflareGateway.calls(gateway), &(&1.op == :archive_restore))

      assert [%{body: %{"station" => %{"restore" => restore}}}] =
               Enum.filter(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))

      assert is_binary(restore)

      assert {:ok, %{"exit_code" => 0}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], environment_id),
                 "true",
                 %{}
               )
    end

    test "worker-only candidate keeps the last verified Sandbox image revision" do
      on_exit(fn -> SalixStore.S3.delete(SalixStore.Keys.ctl_vm_worker_release()) end)
      revision = String.duplicate("a", 40)
      digest = "sha256:" <> String.duplicate("b", 64)

      assert {:ok,
              %{
                "last_sandbox_image_revision" => ^revision,
                "last_sandbox_image_digest" => ^digest
              }} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "image-worker",
                 "worker_release_kind" => "sandbox_image",
                 "last_sandbox_image_revision" => revision,
                 "last_sandbox_image_digest" => digest
               })

      assert {:ok,
              %{
                "last_sandbox_image_revision" => ^revision,
                "last_sandbox_image_digest" => ^digest
              }} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "later-worker-candidate",
                 "worker_release_kind" => "gateway_only"
               })

      assert {:error, {:bad_request, "image revision and digest must be set together"}} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "incomplete-image",
                 "last_sandbox_image_revision" => String.duplicate("c", 40)
               })
    end

    test "gateway-only worker switch reconnects with desired override without destroying sandbox" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(agent["group_id"], force: true)

      assert {:ok, release} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "candidate-2",
                 "worker_release_id" => "rel-2",
                 "worker_release_kind" => "gateway_only"
               })

      assert release["worker_release_kind"] == "gateway_only"

      assert %{data: [outdated], next_cursor: nil} =
               SalixWeb.ComputeProviders.Cloudflare.list_outdated_cloudflare_vms()

      assert outdated["group_id"] == agent["group_id"]

      assert {:ok,
              %{
                "current_worker_version_id" => "candidate-2",
                "desired_worker_version_id" => "candidate-2",
                "rollout_state" => "ready",
                "operation_drain_summary" => %{"state" => "completed"}
              }} = SalixWeb.ComputeProviders.Cloudflare.force_worker_switch(agent["group_id"])

      calls = MockCloudflareGateway.calls(gateway)
      ensure_calls = Enum.filter(calls, &(&1.op == :ensure))

      assert length(ensure_calls) == 2

      assert List.last(ensure_calls).body["worker_version_overrides"] ==
               "salix-vm-verify=\"candidate-2\""

      refute Enum.any?(calls, &(&1.op == :destroy))
    end

    test "breaking worker switch archives destroys and restores with desired override" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(agent["group_id"], force: true)

      assert {:ok, _} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "candidate-3",
                 "worker_release_id" => "rel-3",
                 "worker_release_kind" => "breaking_connector"
               })

      assert {:ok,
              %{
                "current_worker_version_id" => "candidate-3",
                "worker_release_kind" => "breaking_connector",
                "rollout_state" => "ready"
              }} = SalixWeb.ComputeProviders.Cloudflare.force_worker_switch(agent["group_id"])

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      archive_index = Enum.find_index(ops, &(&1 == :archive_export))
      keepalive_index = Enum.find_index(ops, &(&1 == :keepalive))
      destroy_index = Enum.find_index(ops, &(&1 == :destroy))
      restore_index = Enum.find_index(ops, &(&1 == :archive_restore))

      assert is_integer(archive_index)
      assert is_integer(keepalive_index)
      assert is_integer(destroy_index)
      assert is_integer(restore_index)
      assert archive_index < keepalive_index
      assert keepalive_index < destroy_index
      assert destroy_index < restore_index

      ensure_calls = MockCloudflareGateway.calls(gateway) |> Enum.filter(&(&1.op == :ensure))

      assert List.last(ensure_calls).body["worker_version_overrides"] ==
               "salix-vm-verify=\"candidate-3\""
    end

    test "worker switch drains active operations and rejects mutating calls while draining" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec",
                 agent_id: agent["agent_id"]
               )

      assert {:ok, _} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "candidate-4",
                 "worker_release_id" => "rel-4"
               })

      assert {:error, {:active_operations, %{"active_operation_count" => 1}}} =
               SalixWeb.ComputeProviders.Cloudflare.force_worker_switch(group_id, grace_ms: 0)

      update_vm_record(group_id, &Map.put(&1, "rollout_state", "draining"))

      assert {:error, {:vm_rolling_update, %{"retry_after_ms" => 1_000, "rollout_id" => "rel-4"}}} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec")

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(
          group_id,
          operation_id,
          "completed",
          %{ok: true}
        )

      assert {:ok, %{"active_operation_count" => 0}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "idle archive only proceeds for the caller that owns archiving" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      update_vm_record(group_id, fn rec ->
        rec
        |> Map.put("last_operation_at", 1)
        |> Map.put("last_agent_settled_after_vm_at", 2)
      end)

      assert {:error, :active_or_not_ready} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id,
                 force: true,
                 before_archive_update: fn ->
                   update_vm_record(
                     group_id,
                     &Map.merge(&1, %{
                       "status" => "archiving",
                       "archive_operation_id" => "other-archive"
                     })
                   )
                 end
               )

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      refute :archive_export in ops
      refute :keepalive in ops
      refute :destroy in ops

      assert {:ok, %{"status" => "archiving", "archive_operation_id" => "other-archive"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "wake only proceeds for the caller that owns waking" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      update_vm_record(group_id, fn rec ->
        rec
        |> Map.put("status", "archived")
        |> Map.put("archive", %{
          "provider" => "cloudflare-sandbox-v1",
          "version" => 1,
          "files" => []
        })
      end)

      # This branch must not start a wake/provision attempt. The Cloudflare
      # attachment can still emit late websocket frame calls, so compare only
      # the gateway operations that would prove wake/provision actually ran.
      provision_ops_before =
        gateway
        |> MockCloudflareGateway.calls()
        |> Enum.filter(&(&1.op in [:ensure, :restore, :archive_restore, :readyz]))

      assert {:error, {:bad_state, "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id,
                 before_wake_update: fn ->
                   update_vm_record(group_id, &Map.put(&1, "status", "ready"))
                 end
               )

      provision_ops_after =
        gateway
        |> MockCloudflareGateway.calls()
        |> Enum.filter(&(&1.op in [:ensure, :restore, :archive_restore, :readyz]))

      assert provision_ops_after == provision_ops_before

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      :ok = seal_gateway_control(gateway, group_id)

      update_vm_record(group_id, fn rec ->
        rec
        |> Map.put("status", "archived")
        |> Map.put("archive", %{
          "provider" => "cloudflare-sandbox-v1",
          "version" => 1,
          "files" => []
        })
      end)

      assert {:error, :wake_operation_lost} =
               SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id,
                 before_cloudflare_ready: fn ->
                   update_vm_record(
                     group_id,
                     &Map.merge(&1, %{
                       "status" => "ready",
                       "wake_operation_id" => "newer-wake"
                     })
                   )
                 end
               )

      assert {:ok, %{"status" => "ready", "wake_operation_id" => "newer-wake"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    @tag :cloudvm_stale_device
    test "an old connected Device cannot finish a replacement before archive restoration" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:ok, %{"status" => "archived"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      assert_raise RuntimeError, "lost wake response", fn ->
        SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group,
          before_cloudflare_ready: fn -> raise "lost wake response" end
        )
      end

      {:ok, rec} = GroupCompute.group_workload(group)
      workload = SalixStore.Repo.get!(GroupCompute.Workload, rec["workload_id"])

      for stage <- ["recovery_rebuild", "recovery_restoring"] do
        assert {:ok, _, _} =
                 GroupCompute.update_group_workload(group, &Map.put(&1, "archive_reason", stage))

        assert :continue = SalixWeb.ComputeProviders.Cloudflare.confirm_completed_wake(workload)
        assert {:ok, %{"status" => "waking"}} = GroupCompute.group_workload(group)
      end
    end

    test "VM service maintenance pauses new mutating cloud-vm operations" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"operation_drain_summary" => %{"vm_count" => count}}} =
               SalixWeb.ComputeProviders.Cloudflare.begin_vm_maintenance(%{
                 "maintenance_id" => "maint-1",
                 "reason" => "breaking migration",
                 "retry_after_ms" => 2_000
               })

      assert count >= 1

      assert {:error,
              {:vm_service_upgrading,
               %{
                 "maintenance_id" => "maint-1",
                 "reason" => "breaking migration",
                 "retry_after_ms" => 2_000
               }}} = SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec")

      assert {:ok, status_operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "status")

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(
          group_id,
          status_operation_id,
          "completed",
          %{ok: true}
        )

      :ok = SalixWeb.ComputeProviders.Cloudflare.clear_vm_maintenance()

      assert {:ok, exec_operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec")

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(
          group_id,
          exec_operation_id,
          "completed",
          %{ok: true}
        )
    end

    test "cloudflare teardown archives before releasing keepalive and destroy" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      group_id = create_group!(tenant_id(), "Cloudflare Teardown")

      agent =
        create_cloudflare_agent(%{
          "group_id" => group_id
        })

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(agent["group_id"], force: true)

      assert {:ok, %{"provider" => "cloudflare", "status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])

      :ok = SalixWeb.ComputeProviders.Cloudflare.teardown(agent["group_id"])

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      archive_index = Enum.find_index(ops, &(&1 == :archive_export))
      keepalive_index = Enum.find_index(ops, &(&1 == :keepalive))
      destroy_index = Enum.find_index(ops, &(&1 == :destroy))

      assert is_integer(archive_index)
      assert is_integer(keepalive_index)
      assert is_integer(destroy_index)
      assert archive_index < keepalive_index
      assert keepalive_index < destroy_index
    end

    test "unused ready VM gets an idle grace period, archives, and wakes with its archive" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      refute rec["last_operation_at"]
      refute rec["last_agent_settled_after_vm_at"]

      assert {:skipped, :not_idle} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id,
                 now: rec["ready_at"] + 299_999
               )

      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))

      handler_id = "idle-archive-start-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      :ok =
        SystemsRuntime.Telemetry.attach(
          handler_id,
          [:salix, :vm, :idle_archive, :start],
          fn _event, measurements, metadata, pid ->
            SystemsRuntime.Proc.send(pid, {:idle_archive_start, measurements, metadata})
          end,
          SystemsRuntime.Proc.self()
        )

      on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)

      assert %{archived: [^group_id]} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(now: rec["ready_at"] + 300_000)

      settle_receive({:idle_archive_start, %{delay_seconds: delay}, %{profile: "cf-standard-2"}})
      assert delay >= 0

      assert {:ok,
              %{"status" => "archived", "archive" => %{"type" => "connector_tar_zst_chunks"}}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, %{"device_id" => device_id}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, %{devices: devices}} =
               SalixWeb.EnvDispatch.list_devices(agent["agent_id"], limit: 20)

      assert %{"status" => "archived"} =
               Enum.find(devices, &(&1["device_id"] == device_id))

      assert {:ok, %{"status" => "archived", "environments" => [environment]}} =
               SalixWeb.EnvDispatch.get_device(agent["agent_id"], device_id)

      assert environment["environment_id"] ==
               SalixStore.RuntimeIds.device_environment_id(device_id, "connector", "default")

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id)

      assert {:ok, %{"status" => "ready", "ready_at" => ready_at} = woke} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      refute Map.has_key?(woke, "wake_requested_at")
      refute Map.has_key?(woke, "wake_operation_id")

      update_vm_record(group_id, fn current ->
        current
        |> Map.put("last_operation_at", ready_at - 600_000)
        |> Map.put("last_agent_settled_after_vm_at", ready_at - 600_000)
      end)

      assert {:skipped, :not_idle} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id,
                 now: ready_at + 299_999
               )

      ops = Enum.map(MockCloudflareGateway.calls(gateway), & &1.op)

      assert Enum.find_index(ops, &(&1 == :archive_export)) <
               Enum.find_index(ops, &(&1 == :destroy))

      assert :archive_restore in ops
    end

    @tag :disposable_reset
    test "owner disposal stops the exact failed disk and wakes an empty next generation" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group = agent["group_id"]
      provider = SalixWeb.ComputeProviders.Cloudflare
      assert {:ok, :ready} = provider.provision_once(group, force: true)
      assert {:ok, before} = provider.get_record(group)
      source = %{"operation" => "unrestorable-source", "scope" => "full"}

      old_client =
        SalixEnv.VM.Providers.Cloudflare.Client.new(
          base_url: MockCloudflareGateway.base_url(gateway),
          secret: "test-secret",
          group_id: group,
          expected_owner: Map.take(before, ~w(workload_id generation))
        )

      target = "cf-standard-2:" <> before["provider_resource_name"]

      for n <- 1..64 do
        assert {:ok, _} =
                 SalixStore.Compute.begin_cloudflare_gateway_attempt(
                   group,
                   "lost-observation-#{n}",
                   :normal,
                   target,
                   %{"action" => "observe"}
                 )
      end

      update_vm_record(
        group,
        &Map.merge(&1, %{
          "status" => "waking",
          "archive" => source,
          "wake_operation_id" => "expired-wake",
          "last_wake_at" => 1
        })
      )

      assert {:ok, failed} = provider.get_record(group)
      old_workload = SalixStore.Repo.get!(SalixStore.Compute.Workload, failed["workload_id"])
      assert {:ok, discarded} = provider.discard_failed_vm(group, failed)
      assert discarded["generation"] == before["generation"] + 1
      assert discarded["workload_id"] == before["workload_id"]
      assert discarded["device_id"] == before["device_id"]
      assert discarded["archive"] == nil
      assert discarded["archive_previous"] == source
      assert discarded["active_operations"] == %{}

      assert {:error, :cloudflare_discard_target_changed} =
               provider.discard_failed_vm(group, failed)

      destroy = Enum.filter(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
      assert [%{body: %{"discard" => true}}] = destroy

      update_vm_record(
        group,
        &Map.put(&1, "wake_requested_at", SystemsClock.system_time(:millisecond))
      )

      # Count the Gateway calls only once the work the previous steps started
      # (the new generation's Connector) has run: the stale paths below must
      # add none of their own.
      settle()
      calls_before = length(MockCloudflareGateway.calls(gateway))
      assert {:error, :stale_generation} = provider.reconcile(nil, old_workload, [])
      assert length(MockCloudflareGateway.calls(gateway)) == calls_before
      assert {:ok, %{"status" => "ready"}} = provider.wake_archived_vm(group)

      settle()
      calls_before = length(MockCloudflareGateway.calls(gateway))

      assert {:error, :stale_generation} =
               SalixEnv.VM.Providers.Cloudflare.Client.destroy(
                 old_client,
                 before["provider_resource_name"]
               )

      assert length(MockCloudflareGateway.calls(gateway)) == calls_before

      refute Enum.any?(
               MockCloudflareGateway.calls(gateway),
               &(&1.op == :archive_restore)
             )
    end

    for transition <- [:provision, :wake] do
      test "late #{transition} readiness cannot overwrite a discarded carrier" do
        gateway = start_supervised!(MockCloudflareGateway)
        configure_tenant_cloudflare(tenant_id(), gateway)

        agent =
          create_cloudflare_agent()

        group = agent["group_id"]
        provider = SalixWeb.ComputeProviders.Cloudflare

        if unquote(transition) == :wake do
          assert {:ok, :ready} = provider.provision_once(group, force: true)
          assert {:ok, %{"status" => "archived"}} = provider.archive_idle_once(group, force: true)
        end

        hook = fn ->
          assert {:ok, old} = provider.get_record(group)

          if unquote(transition) == :wake do
            assert {:ok, _} = SalixStore.Compute.begin_cloudflare_discard(group, old)
          else
            assert {:ok, discarded} = provider.discard_failed_vm(group, old)
            assert discarded["generation"] == old["generation"] + 1
          end
        end

        result =
          if unquote(transition) == :wake,
            do: provider.wake_archived_vm(group, before_cloudflare_ready: hook),
            else: provider.provision_once(group, force: true, before_cloudflare_ready: hook)

        assert {:error, :wake_operation_lost} = result
        assert {:ok, after_disposal} = provider.get_record(group)

        assert after_disposal["status"] ==
                 if(unquote(transition) == :wake, do: "archiving", else: "archived")

        assert after_disposal["archive_reason"] ==
                 if(unquote(transition) == :wake, do: "disposable_reset", else: "discarded")
      end
    end

    @tag :disposable_reset
    test "image release discards a disk after a terminal archive export failure" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:archive_export_failed]})
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group = agent["group_id"]
      provider = SalixWeb.ComputeProviders.Cloudflare
      assert {:ok, :ready} = provider.provision_once(group, force: true)
      assert {:ok, before} = provider.get_record(group)

      assert {:error, :durable_archive_export_failed} =
               provider.archive_idle_once(group, force: true)

      assert {:ok, unchanged} = provider.get_record(group)
      assert unchanged["generation"] == before["generation"]
      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
      release = "failed-export-disposal"
      assert {:ok, %{"phase" => "prepared"}} = provider.prepare_image_release(release)
      on_exit(fn -> provider.cancel_image_release(release) end)

      assert {:ok, "started"} =
               provider.image_release_archive(
                 release,
                 group,
                 before["provider_resource_name"],
                 "cf-standard-2"
               )

      assert eventually(fn ->
               {:ok, current} = provider.get_record(group)

               current["status"] == "archived" and
                 current["generation"] == before["generation"] + 1
             end)

      assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :archive_export))

      assert [%{body: %{"discard" => true}}] =
               Enum.filter(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
    end

    test "idle archive keeps the workload fenced when quiesce outcome is unknown" do
      gateway =
        start_supervised!(
          {MockCloudflareGateway, fail_ops: [:runtime_quiesce_unconfirmed, :runtime_not_quiet]}
        )

      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:error, :runtime_quiesce_unconfirmed} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      assert rec["status"] == "archiving"
      assert rec["archive_operation_id"]
      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
    end

    test "orphan cleanup destroys without starting or checkpointing a container" do
      gateway =
        start_supervised!({MockCloudflareGateway, fail_ops: [:ensure, :archive_get, :checkpoint]})

      configure_tenant_cloudflare(tenant_id(), gateway)

      for status <- ["creating", "failed", "archiving"] do
        group_id = create_group!(tenant_id(), "Orphan #{status}")

        ghost = %{
          "group_id" => group_id,
          "tenant_id" => tenant_id()
        }

        assert {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(ghost)
        :ok = Salix.Control.Store.delete_record(SalixStore.Keys.ctl_group(group_id))
        update_vm_record(group_id, &Map.put(&1, "status", status))
        assert %{orphaned: [^group_id]} = SalixWeb.ComputeProviders.Cloudflare.sweep_once()
        assert {:error, :not_found} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      end

      assert Enum.map(MockCloudflareGateway.calls(gateway), & &1.op) == [
               :destroy,
               :destroy,
               :destroy
             ]
    end

    test "idle archive skips active operations" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, _operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec")

      assert {:skipped, :active_operations} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))

      assert {:ok, %{"status" => "ready", "active_operation_count" => 1}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "only the agent that used the VM can mark settled-after-vm" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      {:ok, sibling} =
        SalixAgent.Control.create(
          %{"group_id" => group_id},
          tenant_id()
        )

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec",
                 agent_id: agent["agent_id"]
               )

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(
          group_id,
          operation_id,
          "completed",
          %{ok: true}
        )

      :ok = SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(sibling["agent_id"])
      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      refute Map.has_key?(rec, "last_agent_settled_after_vm_at")

      :ok = SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(agent["agent_id"])

      assert {:ok, %{"last_agent_settled_after_vm_at" => settled_at}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert is_integer(settled_at)
    end

    test "shared reconciler parks an interrupted archive without provider deletion" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group = agent["group_id"]

      update_vm_record(
        group,
        &Map.merge(&1, %{
          "status" => "archiving",
          "archive_started_at" => SystemsClock.system_time(:millisecond) - 900_001
        })
      )

      assert {:ok, rec} = SalixStore.Compute.group_workload(group)
      assert SalixEnv.ComputeReconciler.sweep() in [:more, :complete]

      claim =
        SalixStore.Repo.get!(
          SalixStore.Compute.ReconcilerClaim,
          "cloudflare:" <> rec["workload_id"] <> ":1"
        )

      assert claim.last_error["kind"] == "action_required"
      assert claim.last_error["code"] == "group_transition_recovery_required"
      assert SalixEnv.ComputeReconciler.sweep() in [:more, :complete]
      assert {:ok, %{"status" => "archiving"}} = SalixStore.Compute.group_workload(group)

      refute Enum.any?(
               MockCloudflareGateway.calls(gateway),
               &(&1.op in [:destroy, :ensure, :restore])
             )
    end

    test "uncertain destroy keeps the saved archive fenced instead of reopening input" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:destroy]})
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:error, {:api_error, 500, "destroy failed"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      assert {:ok, rec} = SalixStore.Compute.group_workload(group)
      assert rec["status"] == "archiving"
      assert rec["archive_reason"] == "idle_committing"
      assert rec["archive"]["type"] == "connector_tar_zst_chunks"

      assert {:error, {:vm_archiving, _}} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group, "exec")
    end

    test "archiving VM rejects new mutating operations" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      update_vm_record(group_id, &Map.put(&1, "status", "archiving"))

      assert {:error, {:vm_archiving, %{"retry_after_ms" => 1_000}}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      refute Enum.any?(
               MockCloudflareGateway.calls(gateway),
               &(&1.op == :frame and &1.body["method"] == "exec")
             )
    end

    test "sweep archives idle cloudflare VM and archived record is not revived" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent()
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec",
                 agent_id: agent["agent_id"]
               )

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(
          group_id,
          operation_id,
          "completed",
          %{ok: true}
        )

      :ok = SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(agent["agent_id"])

      assert %{archived: [^group_id]} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(idle_archive_ms: 0)

      assert {:ok,
              %{
                "status" => "archived",
                "archive_reason" => "idle",
                "archive" => %{"type" => "connector_tar_zst_chunks"},
                "connector_archive" => %{"type" => "connector_tar_zst_chunks"}
              }} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      archive_index = Enum.find_index(ops, &(&1 == :archive_export))
      keepalive_index = Enum.find_index(ops, &(&1 == :keepalive))
      destroy_index = Enum.find_index(ops, &(&1 == :destroy))

      assert is_integer(archive_index)
      assert is_integer(keepalive_index)
      assert is_integer(destroy_index)
      assert archive_index < keepalive_index
      assert keepalive_index < destroy_index

      ensure_count = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))

      assert %{revived: [], archived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(force: true)

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure)) == ensure_count
    end

    test "real Cloud VM fixture drills metering, operation serialization, archive recovery through Compute" do
      SystemsRuntime.put_env(:salix_web, :vm_metering_mod, MeteringFake)
      SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Migration fixture",
            "billing_owner" => %{
              "billing_account_id" => "ba-migration-fixture",
              "surface" => "bridge",
              "vm_profile_key" => "cf-standard-2"
            }
          },
          tenant_id()
        )

      {:ok, agent} =
        create_agent!(tenant_id(), %{
          "group_id" => group["group_id"]
        })

      group_id = group["group_id"]

      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, operation_id} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec",
                 agent_id: agent["agent_id"]
               )

      assert {:skipped, :active_operations} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(
          group_id,
          operation_id,
          "completed",
          %{ok: true}
        )

      metered_at = SystemsClock.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: metered_at,
                 bootstrap_mode: :dialback,
                 idle_archive_ms: 86_400_000
               )

      settle_receive({:vm_fact, fact})
      assert fact.owner_snapshot["billing_account_id"] == "ba-migration-fixture"

      :ok = SalixWeb.ComputeProviders.Cloudflare.mark_agent_settled(agent["agent_id"])

      assert {:ok, %{"status" => "archived"} = archived} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert archived["last_metered_at"] == metered_at
      assert is_map(archived["archive"])

      # Restore the exact preserved archive through the serving Compute path.
      assert {:error, {:vm_waking, _}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      assert SalixEnv.ComputeReconciler.sweep() in [:more, :complete]

      eventually(fn ->
        match?(
          {:ok, %{"status" => "ready"}},
          SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
        )
      end)

      assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :archive_restore))
    end

    test "billing unavailable marks cloud VM record billing-suspended without starting VM" do
      SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
      SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :block)

      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Blocked VM",
            "billing_owner" => %{
              "billing_account_id" => "ba_vm_zero",
              "surface" => "bridge",
              "vm_profile_key" => "cf-standard-2"
            }
          },
          tenant_id()
        )

      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"group_id" => group["group_id"], "role" => "router"})
      assert SalixAgent.CloudVM.allowed?(agent)

      settle_receive(
        {:vm_authorize,
         %{
           billing_owner: %{"billing_account_id" => "ba_vm_zero"},
           entrypoint: "cloud_vm_enable",
           action: :resume
         }}
      )

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert rec["status"] == "billing_suspended"
      assert rec["billing_decision"]["reason"] == "insufficient_credits"

      assert {:error,
              %{
                "error_class" => "billing_unavailable",
                "reason" => "insufficient_credits",
                "retryable" => false
              }} =
               SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

      assert {:error, %{"reason" => "insufficient_credits"}} =
               CloudVM.RuntimeLifecycle.wake(group["group_id"])

      command =
        SystemsRuntime.Task.async(fn ->
          SalixWeb.EnvDispatch.exec(
            agent["agent_id"],
            cloud_target(agent["agent_id"], "cloud-vm"),
            "true",
            %{"wait_for_vm" => true}
          )
        end)

      assert {:error, %{"reason" => "insufficient_credits"}} = settled_await(command)
      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :archive_restore))
    end

    test "cloudflare VM authorization uses the VM record provider" do
      SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Cloudflare Billing VM",
            "billing_owner" => %{
              "billing_account_id" => "ba_vm_cloudflare",
              "surface" => "bridge",
              "vm_profile_key" => "cf-standard-2"
            }
          },
          tenant_id()
        )

      agent =
        create_cloudflare_agent(%{
          "group_id" => group["group_id"]
        })

      assert SalixAgent.CloudVM.allowed?(agent)

      settle_receive(
        {:vm_authorize,
         %{
           entrypoint: "cloud_vm_enable",
           provider: "cloudflare",
           provider_resource_name: provider_resource_name
         }}
      )

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert provider_resource_name == rec["provider_resource_name"]
    end
  end

  describe "sweep_once (recovery backstop)" do
    test "credits recovery makes a billing-suspended VM eligible and resumes it" do
      SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
      SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :block)

      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Recover VM",
            "billing_owner" => %{
              "billing_account_id" => "ba_vm_recovered",
              "surface" => "bridge",
              "vm_profile_key" => "cf-standard-2"
            }
          },
          tenant_id()
        )

      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"group_id" => group["group_id"]})
      assert SalixAgent.CloudVM.allowed?(agent)
      settle_receive({:vm_authorize, %{entrypoint: "cloud_vm_enable"}})

      SystemsRuntime.put_env(:salix_web, :cloud_vm_auth_result, :allow)

      summary = SalixWeb.ComputeProviders.Cloudflare.sweep_once([])
      assert summary.provisioned == [group["group_id"]]

      settle_receive(
        {:vm_authorize,
         %{
           billing_owner: %{"billing_account_id" => "ba_vm_recovered"},
           entrypoint: "cloud_vm_sweeper",
           action: :resume
         }}
      )

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert rec["status"] == "ready"
      assert rec["billing_decision"]["allowed"] == true

      assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))
    end

    test "cloudflare VM interval metering uses the VM record provider" do
      SystemsRuntime.put_env(:salix_web, :vm_metering_mod, MeteringFake)
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Metered Cloudflare VM",
            "billing_owner" => %{
              "billing_account_id" => "ba_vm_cloudflare_meter",
              "surface" => "bridge",
              "vm_profile_key" => "cf-standard-2"
            }
          },
          tenant_id()
        )

      agent = %{
        "agent_id" => "ghost-cloudflare-vm",
        "tenant_id" => tenant_id(),
        "group_id" => group["group_id"]
      }

      {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(agent)
      env_id = "cloudvm-cloudflare-meter"
      assert :ok = SalixEnv.Bridge.register_owner(env_id)

      assert {:ok, ^env_id, _} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "alias" => "cloud-vm",
                   "group_id" => group["group_id"],
                   "tenant_id" => tenant_id(),
                   "device_id" =>
                     SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group["group_id"]),
                   "connector_id" =>
                     SalixWeb.ComputeProviders.Cloudflare.cloudvm_connector_id(group["group_id"]),
                   "provider" => "cloudflare"
                 },
                 transport_id: env_id
               )

      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group["group_id"])

      now = SystemsClock.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now,
                 bootstrap_mode: :dialback
               )

      settle_receive({:vm_fact, fact})
      assert fact.provider == "cloudflare"
      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert fact.provider_resource_name == rec["provider_resource_name"]
      assert fact.source_key =~ "vm:cloudflare:#{group["group_id"]}:"

      # A later wake starts a new billable interval. The saved checkpoint still
      # belongs to the VM's previous ready period.
      next_ready_at = now + 60_000
      update_vm_record(group["group_id"], &Map.put(&1, "ready_at", next_ready_at))

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now + 120_000,
                 bootstrap_mode: :dialback
               )

      settle_receive({:vm_fact, next_fact})
      assert next_fact.interval_start_ms == next_ready_at
      assert next_fact.duration_seconds == 60
    end

    test "does not advance VM metering checkpoint when metering backend is disabled" do
      SystemsRuntime.delete_env(:salix_web, :vm_metering_mod)

      group_id = create_group!(tenant_id(), "Unmetered VM")

      agent = %{
        "agent_id" => "ghost-unmetered-vm",
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      }

      {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(agent)
      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group_id)

      now = SystemsClock.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now,
                 bootstrap_mode: :dialback
               )

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      refute Map.has_key?(rec, "last_metered_at")
    end

    test "advances VM metering checkpoint for unattributed typed rows" do
      SystemsRuntime.put_env(:salix_web, :vm_metering_mod, UnattributedMeteringFake)

      group_id = create_group!(tenant_id(), "Unattributed VM")

      agent = %{
        "agent_id" => "ghost-unattributed-vm",
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      }

      {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(agent)
      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group_id)

      now = SystemsClock.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now,
                 bootstrap_mode: :dialback
               )

      settle_receive({:vm_fact, fact})

      assert fact.owner_snapshot == %{
               "surface" => "bridge",
               "vm_profile_key" => "cf-standard-2"
             }

      assert {:ok, %{"last_metered_at" => ^now}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end
  end

  describe "Cloud VM station recovery" do
    test "sweep revives a VM whose station lost its connection" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert SalixEnv.Bridge.local?(env_id)

      drop_station(gateway, group_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      # Repair within the initial idle grace, rather than forcing idle shutdown.
      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      summary = SalixWeb.ComputeProviders.Cloudflare.sweep_once(now: rec["ready_at"])
      assert summary.archived == []
      assert summary.revived == [group_id]
      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)
    end

    test "ready management reconcile starts a stopped Container, whose station connects again" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      ensures_before = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))
      drop_station(gateway, group_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      workload = SalixStore.Repo.get!(SalixStore.Compute.Workload, rec["workload_id"])
      allocation = SalixStore.Repo.get!(SalixStore.Compute.Allocation, workload.allocation_id)

      assert {:ok, %{outcome: :group_reconciled}} =
               SalixWeb.ComputeProviders.Cloudflare.reconcile(allocation, workload, [])

      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure)) ==
               ensures_before + 1
    end

    test "dispatch-path repair starts a stopped Container, whose station connects again" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      ensures_before = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))
      connects_before = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :connect))
      drop_station(gateway, group_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      assert {:error, {:vm_waking, _}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)

      ensure =
        gateway
        |> MockCloudflareGateway.calls()
        |> Enum.filter(&(&1.op == :ensure))
        |> Enum.drop(ensures_before)
        |> List.first()

      assert ensure.body["worker_version_overrides"] =~ ~s(="version-1")

      eventually(fn ->
        Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :connect)) > connects_before
      end)

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, %{"exit_code" => 0}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )
    end

    # Archived once and woken: the VM's disk is its archive's, restored.
    defp archived_and_woken_vm(gateway) do
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      provider = SalixWeb.ComputeProviders.Cloudflare

      assert {:ok, :ready} = provider.provision_once(group_id, force: true)
      {:ok, ready} = provider.get_record(group_id)

      assert {:ok, %{"status" => "archived", "archive" => %{"operation" => archive}}} =
               provider.archive_idle_once(group_id, now: ready["ready_at"] + 300_000)

      assert {:ok, %{"status" => "ready"} = woke} = provider.wake_archived_vm(group_id)
      {agent, woke, archive}
    end

    defp gateway_ops(gateway, op),
      do: Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == op))

    test "a ready VM whose Container stopped is restored from its last archive, not started empty" do
      gateway = start_supervised!(MockCloudflareGateway)
      {agent, _woke, archive} = archived_and_woken_vm(gateway)
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)
      ensures = gateway_ops(gateway, :ensure)
      restored = gateway_ops(gateway, :archive_restore)

      # The Container stops: its disk, with the restored archive, is gone.
      drop_station(gateway, group_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      assert {:error, {:vm_waking, _}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      # No empty Container was started behind the ready record: it is archived
      # with its last archive, and a wake is requested.
      assert gateway_ops(gateway, :ensure) == ensures

      assert {:ok,
              %{
                "status" => "archived",
                "archive_reason" => "container_lost",
                "archive" => %{"operation" => ^archive},
                "container_loss" => %{"restored_from" => ^archive, "stop" => stop},
                "wake_requested_at" => requested
              }} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      # How it stopped was read from the Gateway in the step that found it
      # stopped, and is kept with the loss: the release that followed, and
      # every later archive, are commanded stops.
      assert %{
               "recorded" => true,
               "requested" => false,
               "exit_code" => 137,
               "error" => "Container exited with unexpected exit code: 137",
               "seen_by" => "monitor",
               "worker_version_id" => "version-1",
               "gateway_build_id" => "build-1",
               "connector_image_version" => "connector-1"
             } = stop

      assert is_integer(stop["at"]) and is_integer(stop["started_at"])

      assert is_integer(requested)

      # Its Gateway control was sealed and its Container released, as an
      # archive leaves them: the Gateway opens a wake's new permit only on a
      # sealed control.
      {:ok, lost} = GroupCompute.group_workload(group_id)

      assert %{
               "running" => false,
               "control" => %{
                 "sealed" => true,
                 "pending" => nil,
                 "last_terminal" => %{"action" => "destroy", "outcome" => "completed"}
               }
             } = MockCloudflareGateway.control(gateway, lost["provider_resource_name"])

      assert %{"sealed" => true} = lost["cloudflare_control"]

      assert {:ok,
              %{
                "status" => "ready",
                "archive" => %{"operation" => ^archive},
                "container_loss" => %{"stop" => ^stop}
              }} = SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id)

      assert gateway_ops(gateway, :control_refused) == 0

      # The next archive's destroy is the Gateway's last stop; the one nobody
      # commanded is still there to read.
      assert {:ok, %{"status" => "archived"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert %{
               "last_stop" => %{"requested" => true},
               "last_uncommanded_stop" => %{"requested" => false, "exit_code" => 137}
             } = MockCloudflareGateway.control(gateway, lost["provider_resource_name"])

      restores =
        gateway
        |> MockCloudflareGateway.calls()
        |> Enum.filter(&(&1.op == :archive_restore))
        |> Enum.drop(restored)

      assert [%{body: %{"operation" => ^archive}}] = restores
    end

    # A VM archived with its station taking part in the Task `cnv_task`, given
    # its two Messages: what the archive holds of it.
    defp archived_vm_in_a_task(gateway) do
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      provider = SalixWeb.ComputeProviders.Cloudflare
      start_supervised!(TaskFake)
      SystemsRuntime.put_env(:salix_web, :station_tasks, conversations: TaskFake)
      on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_tasks) end)

      assert {:ok, :ready} = provider.provision_once(group_id, force: true)
      {:ok, ready} = provider.get_record(group_id)
      sandbox = ready["provider_resource_name"]

      row = %{
        tenant_id: tenant_id(),
        group_id: group_id,
        conversation_id: "cnv_task",
        device_id: ready["device_id"],
        agent_id: agent["agent_id"],
        start: %{"requester" => "usr_ann", "runtime" => "codex", "model" => "gpt-5.4-mini"}
      }

      assert {:ok, session} = SalixWeb.StationTasks.invite(row)
      assert :ok = SalixWeb.StationTasks.joined(Map.put(row, :session, session))

      eventually(fn ->
        MockCloudflareGateway.tasks(gateway, sandbox) == %{"cnv_task" => 2}
      end)

      assert {:ok, %{"status" => "archived", "archive" => %{"operation" => archive}}} =
               provider.archive_idle_once(group_id, now: ready["ready_at"] + 300_000)

      # The Container is gone, and its disk with it.
      assert MockCloudflareGateway.tasks(gateway, sandbox) == %{}
      %{group_id: group_id, sandbox: sandbox, archive: archive}
    end

    test "a woken VM's station starts on its restored disk: it says hello with its Tasks' progress and is given only what it missed" do
      gateway = start_supervised!(MockCloudflareGateway)
      %{group_id: group_id, sandbox: sandbox} = archived_vm_in_a_task(gateway)
      # Said in the Task while the VM slept.
      TaskFake.add(group_id, "and ship it")
      seen = MockCloudflareGateway.calls(gateway)

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id)

      eventually(fn ->
        MockCloudflareGateway.tasks(gateway, sandbox) == %{"cnv_task" => 3}
      end)

      woke = calls_since(gateway, seen) |> Enum.reject(&(&1.op == :frame))
      # The archive first, then the station, once: it is the VM's own.
      assert [:ensure, :archive_restore, :connect | _] = Enum.map(woke, & &1.op)

      assert [%{body: %{"tasks" => [%{"task" => "cnv_task", "fetched" => 2}]}}] =
               Enum.filter(woke, &(&1.op == :connect))

      # It was not invited to the Task again, and was given the one Message after what it had.
      assert Enum.filter(woke, &(&1.op == :task_invite)) == []

      assert [%{body: %{"task" => "cnv_task", "through" => 3, "messages" => [%{"seq" => 3}]}}] =
               Enum.filter(woke, &(&1.op == :task_put))
    end

    test "a wake waits for the station that answers with the receipt: a device still shown connected from the Container before does not" do
      gateway = start_supervised!(MockCloudflareGateway)
      %{group_id: group_id, sandbox: sandbox} = archived_vm_in_a_task(gateway)
      provider = SalixWeb.ComputeProviders.Cloudflare

      # The archived Container's station is gone, but its device still shows
      # connected: its disconnect is not registered when the wake begins.
      _stale_run = attach_fake_connector_env(provider.cloudvm_env_id(group_id), group_id)
      assert {:ok, %{"status" => "connected"}} = cloud_device(group_id)
      # The woken Container's station connects a little after its start.
      :ok = MockCloudflareGateway.set_connect_delay(gateway, 3_000)

      # Nothing answers for the receipt there. The wake does not fail on
      # that: it waits, in its one wait, for the station that does.
      assert {:ok, %{"status" => "ready"}} = provider.wake_archived_vm(group_id)
      assert gateway_ops(gateway, :archive_restore) == 1
      assert MockCloudflareGateway.tasks(gateway, sandbox) == %{"cnv_task" => 2}
    end

    test "a wake whose Container stops after its station connected ends with that stop, not when its wait runs out" do
      gateway =
        start_supervised!({MockCloudflareGateway, fail_ops: [:container_stops_at_receipt]})

      %{group_id: group_id} = archived_vm_in_a_task(gateway)
      provider = SalixWeb.ComputeProviders.Cloudflare

      # Cloudflare stops the woken Container to roll out a new image, after
      # its station connected and before it answered.
      started = SystemsClock.monotonic_time(:millisecond)

      assert {:error, {:container_stopped, %{"exit_code" => 0}}} =
               provider.wake_archived_vm(group_id)

      assert SystemsClock.monotonic_time(:millisecond) - started < 60_000

      assert {:ok, %{"status" => "waking", "last_error" => last_error}} =
               provider.get_record(group_id)

      assert last_error =~ "container_stopped"

      # The next wake starts another Container, which restores and connects.
      assert {:ok, %{"status" => "ready"}} = provider.wake_archived_vm(group_id)
      assert gateway_ops(gateway, :archive_restore) == 2
    end

    test "a never-archived VM whose Container stopped starts empty with its disk loss marked" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, ready} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      refute ready["container_loss"]
      ensures = gateway_ops(gateway, :ensure)
      drop_station(gateway, group_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      assert {:error, {:vm_waking, _}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      assert {:ok,
              %{
                "status" => "ready",
                "container_loss" => %{
                  "restored_from" => nil,
                  "at" => at,
                  "stop" => %{"recorded" => true, "requested" => false, "exit_code" => 137}
                }
              }} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert is_integer(at)
      assert gateway_ops(gateway, :ensure) == ensures + 1
      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)
    end

    test "dispatch-path repair stays bounded while Cloudflare is unavailable" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      drop_station(gateway, group_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)
      :ok = stop_supervised(MockCloudflareGateway)

      task =
        SystemsRuntime.Task.async(fn ->
          SalixWeb.EnvDispatch.exec(
            agent["agent_id"],
            cloud_target(agent["agent_id"], "cloud-vm"),
            "true",
            %{}
          )
        end)

      result = SystemsClock.yield(task, 1_000) || SystemsRuntime.Task.shutdown(task, :brutal_kill)

      # The Container cannot be started: the VM is unavailable, and a later call may retry.
      assert {:ok,
              {:error,
               %{"error_class" => "vm_unavailable", "retryable" => true, "env_id" => ^env_id}}} =
               result

      # The unreachable Gateway ends this one repair attempt.
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)
    end
  end

  describe "Group switch off" do
    test "turning the Group's Cloud VM switch off preserves Group compute until explicit Group release" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent()
      group = agent["group_id"]

      assert {:ok, _} = Salix.Control.Groups.update(group, %{"cloud_vm_enabled" => false})
      assert {:ok, %{"desired_state" => "ready"}} = GroupCompute.group_workload(group)

      assert :ok = SalixWeb.ComputeProviders.Cloudflare.teardown_async(group)
      assert {:ok, %{"desired_state" => "stopped"}} = GroupCompute.group_workload(group)
    end
  end

  # A wake whose restore ran out of time. `phase` is the station's own import
  # receipt for the archive (nil: it never began).
  # The calls the gateway received after `seen` (an earlier calls/1 result),
  # oldest first.
  # The Gateway's calls after those in `seen`, oldest first.
  defp calls_since(gateway, seen),
    do: gateway |> MockCloudflareGateway.calls() |> Enum.drop(length(seen))

  defp cloud_target(agent_id, _environment_id) do
    device_id =
      SalixStore.RuntimeIds.cloud_vm_device_id(SalixStore.Ids.group_id_from_agent!(agent_id))

    %{
      device_id:
        SalixStore.RuntimeIds.cloud_vm_device_id(SalixStore.Ids.group_id_from_agent!(agent_id)),
      environment_id:
        SalixStore.RuntimeIds.device_environment_id(device_id, "connector", "default")
    }
  end
end
