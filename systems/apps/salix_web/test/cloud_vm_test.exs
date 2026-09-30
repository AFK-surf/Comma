defmodule SalixWeb.CloudVMTest do
  @moduledoc "Cloudflare Group VM lifecycle and recovery tests."
  use ExUnit.Case, async: false

  alias SalixEnv.Registry
  alias SalixEnv.VM.Providers.Cloudflare.Attachments, as: CloudflareAttachments
  alias SalixWeb.CloudVM
  alias SalixStore.Compute, as: GroupCompute
  alias SalixWeb.MockCloudflareGateway

  @config_missing "vm.enabled requires tenant vm provider configuration: cloudflare"

  defmodule MeteringFake do
    def meter_vm_interval(fact) do
      send(Application.fetch_env!(:salix_web, :cloud_vm_test_pid), {:vm_fact, fact})
      :ok
    end
  end

  defmodule FailedMeteringFake do
    def meter_vm_interval(_fact), do: {:error, :unavailable}
  end

  defmodule UnattributedMeteringFake do
    def meter_vm_interval(fact) do
      send(Application.fetch_env!(:salix_web, :cloud_vm_test_pid), {:vm_fact, fact})
      {:unattributed, fact}
    end
  end

  defmodule VMAuthorizationFake do
    @behaviour SalixWeb.ComputeProviders.Cloudflare.VMAuthorization

    @impl true
    def authorize_vm(attrs) do
      send(Application.fetch_env!(:salix_web, :cloud_vm_test_pid), {:vm_authorize, attrs})

      case Application.get_env(:salix_web, :cloud_vm_auth_result, :allow) do
        :allow ->
          :ok

        :block ->
          {:error,
           {:billing_unavailable,
            %{
              allowed?: false,
              reason: "insufficient_credits",
              decision_id: "decision_vm_test",
              balance_snapshot: 0
            }}}
      end
    end
  end

  setup do
    SalixStore.Repo.query!(
      "TRUNCATE compute_reconciler_claims, compute_reconciler_cursors, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    Salix.App.configure()
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_metering = Application.get_env(:salix_web, :vm_metering_mod)
    prev_vm_authorization = Application.get_env(:salix_web, :vm_authorization_mod)
    prev_vm_auth_result = Application.get_env(:salix_web, :cloud_vm_auth_result)
    prev_pid = Application.get_env(:salix_web, :cloud_vm_test_pid)
    prev_public_base_url = Application.get_env(:salix_web, :public_base_url)
    prev_platform_vm = Application.get_env(:salix_web, :platform_vm)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :cloud_vm_test_pid, self())
    Application.delete_env(:salix_web, :public_base_url)
    Application.delete_env(:salix_web, :platform_vm)
    SalixCluster.NodeLifecycle.reset()

    if Process.whereis(SalixStore.S3.Fake) do
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

    on_exit(fn ->
      CloudflareAttachments.stop_all()
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
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

  defp restore_salix_web_env(key, nil), do: Application.delete_env(:salix_web, key)
  defp restore_salix_web_env(key, value), do: Application.put_env(:salix_web, key, value)

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

  defp create_cloudflare_agent(attrs \\ %{}) do
    attrs = Map.merge(%{"group_id" => group_id(), "vm" => %{"enabled" => true}}, attrs)
    {:ok, agent} = SalixAgent.Control.create(attrs, tenant_id())
    _ = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)
    agent
  end

  test "one async exec retains its call through first creation and archive wake" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    agent = create_cloudflare_agent(%{"role" => "worker"})
    target = cloud_target(agent["agent_id"], "cloud-vm")
    old_budget = Application.get_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 5_000)

    on_exit(fn ->
      if old_budget,
        do: Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, old_budget),
        else: Application.delete_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
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

      {[early], [pending]} = SalixAgent.Tools.execute_with_async_window([call], ctx)
      assert early.status == "async_running"
      assert pending.tool_call_id == call.id
      group = group_id()

      eventually(fn ->
        case SalixWeb.ComputeProviders.Cloudflare.get_record(group) do
          {:ok, r} ->
            (r["runtime_selection_until"] || 0) > System.system_time(:millisecond) and
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
    agent = create_cloudflare_agent(%{"role" => "worker"})
    target = cloud_target(agent["agent_id"], "cloud-vm")
    old_budget = Application.get_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 100)

    on_exit(fn ->
      if old_budget,
        do: Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, old_budget),
        else: Application.delete_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms)
    end)

    assert {:error, :timeout} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo expired", %{
               "wait_for_vm" => true
             })

    assert {:ok, r} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())
    assert r["runtime_selection_until"] <= System.system_time(:millisecond)
    Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 5_000)

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

    {[_], [pending]} = SalixAgent.Tools.execute_with_async_window([call], ctx)
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

    Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 100)

    assert {:error, :timeout} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo admission-expired", %{
               "wait_for_vm" => true
             })

    assert {:ok, record} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id())
    assert record["runtime_selection_until"] <= System.system_time(:millisecond)

    refute Enum.any?(
             MockCloudflareGateway.calls(gateway),
             &(&1.op == :frame and &1.body["method"] == "exec")
           )

    update_vm_record(group_id(), &Map.put(&1, "status", "ready"))

    # Keep reconnect slower than the readiness budget.
    :ok = MockCloudflareGateway.set_connect_delay(gateway, 1_000)
    CloudflareAttachments.stop_all()
    tenant = tenant_id()
    group = group_id()

    assert eventually(fn ->
             case Registry.get_device(tenant, group, target.device_id) do
               {:ok, device} -> device["status"] != "connected"
               _ -> true
             end
           end)

    Application.put_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 100)

    assert {:error, :timeout} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo offline", %{
               "wait_for_vm" => true
             })

    assert {:error, {:vm_waking, _}} =
             SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo immediate", %{})
  end

  test "maintenance admitted during readiness wait prevents the retained command" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    agent = create_cloudflare_agent(%{"role" => "worker"})
    target = cloud_target(agent["agent_id"], "cloud-vm")
    group = group_id()

    call =
      Task.async(fn ->
        SalixWeb.EnvDispatch.exec(agent["agent_id"], target, "echo fenced", %{
          "wait_for_vm" => true
        })
      end)

    assert eventually(fn ->
             {:ok, record} = SalixWeb.ComputeProviders.Cloudflare.get_record(group)
             (record["runtime_selection_until"] || 0) > System.system_time(:millisecond)
           end)

    # Connect first, then publish maintenance before the next readiness poll.
    assert {:ok, :ready} = SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

    assert {:ok, _} =
             SalixWeb.ComputeProviders.Cloudflare.begin_vm_maintenance(%{
               "maintenance_id" => "during-readiness",
               "reason" => "release",
               "retry_after_ms" => 1_000
             })

    on_exit(fn -> SalixWeb.ComputeProviders.Cloudflare.clear_vm_maintenance() end)
    assert {:error, {:vm_service_upgrading, _}} = Task.await(call, 3_000)

    refute Enum.any?(
             MockCloudflareGateway.calls(gateway),
             &(&1.op == :frame and &1.body["method"] == "exec")
           )
  end

  test "creating an enabled agent does not create a Group VM" do
    Application.put_env(:salix_web, :platform_vm, %{
      "default_provider" => "cloudflare",
      "providers" => %{"cloudflare" => %{"enabled" => true}}
    })

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group_id(), "vm" => %{"enabled" => true}},
        tenant_id()
      )

    assert {:error, :not_found} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
  end

  test "the selected default VM environment creates one Group workload on first exec" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group_id(), "vm" => %{"enabled" => true}},
        tenant_id()
      )

    target = cloud_target(agent["agent_id"], "cloud-vm")
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

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group_id(), "role" => "worker", "vm" => %{"enabled" => true}},
        tenant_id()
      )

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

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "vm" => %{"enabled" => true}},
        tenant_id()
      )

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

  test "an Agent cannot request a profile above its Group product policy" do
    Application.put_env(:salix_web, :platform_vm, %{
      "default_provider" => "cloudflare",
      "providers" => %{"cloudflare" => %{"enabled" => true}}
    })

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id(),
          "vm" => %{
            "enabled" => true,
            "provider" => "cloudflare",
            "profile" => "cf-standard-1"
          }
        },
        tenant_id()
      )

    assert {:error, :vm_profile_not_authorized} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

    assert {:error, :not_found} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
  end

  test "product profile selects the same SKU for start and interval metering" do
    Application.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
    Application.put_env(:salix_web, :vm_metering_mod, MeteringFake)

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
      "group_id" => group["group_id"],
      "vm" => %{"enabled" => true, "provider" => "cloudflare"}
    }

    assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-1"}}} =
             SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

    assert_receive {:vm_authorize, %{sku: "runtime-standard-1"}}
    assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group["group_id"])

    assert %{revived: []} =
             SalixWeb.ComputeProviders.Cloudflare.sweep_once(
               now: System.system_time(:millisecond) + 60_000,
               bootstrap_mode: :dialback
             )

    assert_receive {:vm_fact, %{sku: "runtime-standard-1"}}
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
               "group_id" => group_id,
               "vm" => %{"enabled" => true, "provider" => "cloudflare"}
             })

    assert existing["workload_id"] == original["workload_id"]
    assert existing["provider_spec"]["profile_key"] == "cf-standard-2"
  end

  # Simulate the connector inside the VM dialing back to /v1/connect: a
  # connected registry record in the agent's group under the cloud-vm alias.
  defp attach_fake_connector(group_id) do
    transport_id = "cloudvm-#{System.unique_integer([:positive])}"
    attach_fake_connector_env(transport_id, group_id)
  end

  defp attach_fake_connector_env(transport_id, group_id) do
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

  defp command_environment_id!(group_id, attempts \\ 100) do
    case SalixEnv.Control.get_environment(
           SalixWeb.ComputeProviders.Cloudflare.cloudvm_device_id(group_id),
           group_id,
           tenant_id()
         ) do
      {:ok, %{"environment_id" => id}} when is_binary(id) and id != "" -> id
      _ -> retry_command_environment_id(group_id, attempts)
    end
  end

  defp retry_command_environment_id(group_id, attempts) when attempts > 0 do
    Process.sleep(10)
    command_environment_id!(group_id, attempts - 1)
  end

  defp retry_command_environment_id(group_id, _attempts) do
    flunk("cloud VM for #{group_id} did not project a command environment")
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
      Map.put(Jason.decode!(body), "updated_at", System.system_time(:millisecond) - 120_000)

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

  defp update_vm_record(group_id, fun) do
    {:ok, updated, _previous} = GroupCompute.update_group_workload(group_id, fun)
    updated
  end

  defp configure_archive_r2 do
    previous = Application.get_env(:salix_web, :cloud_vm_archive_r2)

    Application.put_env(:salix_web, :cloud_vm_archive_r2, %{
      "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      "bucket" => "test-archive",
      "access_key_id" => "testaccess",
      "secret_access_key" => "testsecret"
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_web, :cloud_vm_archive_r2, previous),
        else: Application.delete_env(:salix_web, :cloud_vm_archive_r2)
    end)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp req_as(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]
    Req.request!([method: method, url: base() <> path, headers: headers, retry: false] ++ opts)
  end

  defp tenant_api_key(tenant_id \\ tenant_id()) do
    {:ok, %{"key" => key}} =
      Salix.Control.Tenants.create_api_key(tenant_id, %{"name" => "runtime test"})

    key
  end

  defp base, do: SalixWeb.Application.base_url()

  describe "agent creation with vm.enabled" do
    test "rejects when the tenant has no default provider config" do
      tenant_id = create_tenant!()

      assert {:error, {:bad_request, @config_missing}} =
               create_agent!(tenant_id, %{"vm" => %{"enabled" => true}})
    end

    test "rejects retired provider without leaving a workload" do
      assert {:error, {:bad_request, reason}} =
               SalixAgent.Control.create(
                 %{"group_id" => group_id(), "vm" => %{"enabled" => true}},
                 tenant_id()
               )

      assert reason =~ "cloudflare"
      assert {:error, :not_found} = SalixStore.Compute.group_workload(group_id())

      assert {:error, :unsupported_provider} =
               SalixWeb.ComputeProviders.Cloudflare.ensure_record(%{
                 "group_id" => group_id(),
                 "vm" => %{"provider" => "sprites"}
               })
    end

    test "uses tenant default provider and accepts explicit cloudflare provider" do
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

      {:ok, defaulted} =
        create_agent!(tenant_id, %{"vm" => %{"enabled" => true}})

      assert defaulted["vm"]["provider"] == "cloudflare"

      assert {:error, :not_found} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(defaulted["group_id"])

      explicit_group_id = create_group!(tenant_id, "CF Explicit")

      {:ok, explicit} =
        SalixAgent.Control.create(
          %{
            "group_id" => explicit_group_id,
            "vm" => %{"enabled" => true, "provider" => "cloudflare"}
          },
          tenant_id
        )

      assert explicit["vm"]["provider"] == "cloudflare"

      assert {:error, :not_found} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(explicit["group_id"])
    end

    test "uses platform default provider for tenants that follow platform config" do
      Application.put_env(:salix_web, :platform_vm, %{
        "default_provider" => "cloudflare",
        "providers" => %{"cloudflare" => %{"enabled" => true}}
      })

      tenant_id =
        create_tenant!(%{
          "config" => Jason.encode!(%{"vm" => %{"config_source" => "platform"}})
        })

      {:ok, agent} =
        create_agent!(tenant_id, %{"vm" => %{"enabled" => true}})

      assert agent["vm"]["provider"] == "cloudflare"

      assert {:error, :not_found} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
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

      {:ok, agent} =
        create_agent!(tenant_id, %{"vm" => %{"enabled" => true}})

      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)
      assert SalixEnv.ComputeReconciler.sweep() in [:more, :complete]

      # Allow the WebSocket attach and final record commit to finish.
      eventually(
        fn ->
          match?(
            {:ok, %{"provider" => "cloudflare", "status" => "ready"}},
            SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
          )
        end,
        500
      )

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

      assert {:ok, _} = MockCloudflareGateway.wait_for_call(gateway, :ensure)
    end

    test "cloudflare provision restores archived workspace and dispatches through attachment" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      update_vm_record(group_id, &Map.put(&1, "archive", %{"id" => "archive-existing"}))

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"provider" => "cloudflare", "status" => "ready", "env_id" => env_id}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert env_id == SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)
      environment_id = command_environment_id!(group_id)

      assert {:ok, _} = MockCloudflareGateway.wait_for_call(gateway, :ensure)

      assert {:ok, %{body: %{"archive" => %{"id" => "archive-existing"}}}} =
               MockCloudflareGateway.wait_for_call(gateway, :restore)

      assert {:ok, %{"exit_code" => 0}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], environment_id),
                 "true",
                 %{}
               )

      eventually(fn ->
        Enum.any?(
          MockCloudflareGateway.calls(gateway),
          &(&1.op == :frame and &1.body["method"] == "exec")
        )
      end)
    end

    test "a pre-profile Gateway fails a standard-1 VM closed until its release lands" do
      gateway = start_supervised!({MockCloudflareGateway, profiles: false})
      configure_tenant_cloudflare(tenant_id(), gateway)

      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Comma workspace",
            "billing_owner" => %{"surface" => "comma", "vm_profile_key" => "cf-standard-1"}
          },
          tenant_id()
        )

      agent =
        create_cloudflare_agent(%{
          "group_id" => group["group_id"],
          "vm" => %{"enabled" => true, "provider" => "cloudflare"}
        })

      group_id = agent["group_id"]

      assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-1"}}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      # One Gateway request settles the attempt; no retry inside the provisioning budget.
      assert {:ok, :failed} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"status" => "failed", "error" => error}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert error =~ "cf-standard-1"
      assert error =~ "Gateway"

      assert [%{op: :unsupported_profile}] =
               Enum.filter(MockCloudflareGateway.calls(gateway), &(&1.op != :healthz))

      # After the dual-profile Gateway release, the next use restarts and succeeds.
      :ok = MockCloudflareGateway.set_profiles(gateway, true)
      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent)

      assert {:ok, %{"status" => "creating"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"status" => "ready", "provider_spec" => %{"profile_key" => "cf-standard-1"}}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, %{body: %{"worker_version_key" => "salix-" <> _}}} =
               MockCloudflareGateway.wait_for_call(gateway, :ensure)
    end

    test "cloudflare new VM uses desired worker release override" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      assert {:ok, %{"desired_worker_version_id" => "candidate-1"}} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "candidate-1",
                 "worker_release_id" => "rel-1"
               })

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(agent["group_id"], force: true)

      assert {:ok,
              %{
                "current_worker_version_id" => "candidate-1",
                "desired_worker_version_id" => "candidate-1",
                "worker_release_id" => "rel-1",
                "rollout_state" => "ready"
              }} = SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])

      assert {:ok,
              %{
                body: %{
                  "worker_version_key" => sandbox_id,
                  "worker_version_overrides" => "salix-vm-verify=\"candidate-1\""
                }
              }} = MockCloudflareGateway.wait_for_call(gateway, :ensure)

      assert sandbox_id ==
               SalixStore.RuntimeIds.cloud_vm_provider_resource_name(agent["group_id"])
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

    test "worker release rejects unknown release kind" do
      assert {:error, {:bad_request, "unknown worker_release_kind: sandbx_image"}} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "candidate-bad",
                 "worker_release_kind" => "sandbx_image"
               })
    end

    test "gateway-only worker switch reconnects with desired override without destroying sandbox" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})

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

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})

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
      archive_index = Enum.find_index(ops, &(&1 == :archive))
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

    test "breaking worker switch does not release sandbox when archive record write fails" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, _} =
               CloudVM.put_worker_release(%{
                 "desired_worker_version_id" => "candidate-durable",
                 "worker_release_kind" => "breaking_connector"
               })

      {:ok, projection} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      workload_id = projection["workload_id"]
      # The fixture rejects the actual archive write in the dedicated Docker DB.
      # Provider deletion must stay unreachable when that transaction fails.
      constraint = "rfc36_archive_write_fault"

      on_exit(fn ->
        SalixStore.Repo.query!(
          "ALTER TABLE compute_workloads DROP CONSTRAINT IF EXISTS " <> constraint
        )
      end)

      assert {:error, :compute_storage_unavailable} =
               SalixWeb.ComputeProviders.Cloudflare.force_worker_switch(group_id,
                 before_archive_persist: fn ->
                   escaped_id = String.replace(workload_id, "'", "''")

                   SalixStore.Repo.query!(
                     "ALTER TABLE compute_workloads ADD CONSTRAINT " <>
                       constraint <>
                       " CHECK (id <> '" <>
                       escaped_id <> "' OR spec->'archive'->'archive' IS NULL) NOT VALID"
                   )

                   :ok
                 end
               )

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      assert :archive in ops
      refute :keepalive in ops
      refute :destroy in ops
    end

    test "worker switch drains active operations and rejects mutating calls while draining" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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
      refute :archive in ops
      refute :keepalive in ops
      refute :destroy in ops

      assert {:ok, %{"status" => "archiving", "archive_operation_id" => "other-archive"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "wake only proceeds for the caller that owns waking" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

    test "interrupted wake resumes the same operation and clears its request" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"status" => "archived"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert_raise RuntimeError, "lost wake response", fn ->
        SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id,
          before_cloudflare_ready: fn -> raise "lost wake response" end
        )
      end

      assert {:ok, %{"status" => "waking", "wake_operation_id" => operation}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, %{"status" => "ready"} = ready} =
               SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id)

      refute ready["wake_operation_id"]
      refute ready["wake_requested_at"]
      assert is_binary(operation)
    end

    test "waking record resumes before the archive import has a restored receipt" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"status" => "archived"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      update_vm_record(group_id, fn rec ->
        rec
        |> Map.put("status", "waking")
        |> Map.put("wake_operation_id", "wake-existing")
        |> Map.put("last_wake_at", System.system_time(:millisecond))
      end)

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_archived_vm(group_id)

      assert {:ok, ready} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      refute ready["wake_operation_id"]
    end

    test "VM service maintenance pauses new mutating cloud-vm operations" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

    test "rollout drain rejects environment mutating operation" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      environment_id = command_environment_id!(group_id)

      update_vm_record(
        group_id,
        &Map.merge(&1, %{
          "rollout_state" => "draining",
          "worker_release_id" => "rel-connector-id"
        })
      )

      assert {:error,
              {:vm_rolling_update,
               %{"retry_after_ms" => 1_000, "rollout_id" => "rel-connector-id"}}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], environment_id),
                 "true",
                 %{}
               )
    end

    test "missing connector resolution does not leak active operation count" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)
      {:ok, current_device} = cloud_device(group_id)
      SalixEnv.Registry.mark_disconnected(current_device["connector_run_id"])

      assert {:error, {:vm_waking, %{"env_id" => ^env_id}}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      assert {:ok, %{"active_operations" => active_operations}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert Enum.all?(active_operations, fn {_id, operation} ->
               operation["kind"] == "cloudflare_gateway_attempt"
             end)
    end

    test "cloudflare teardown archives before releasing keepalive and destroy" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      group_id = create_group!(tenant_id(), "Cloudflare Teardown")

      agent =
        create_cloudflare_agent(%{
          "group_id" => group_id,
          "vm" => %{"enabled" => true, "provider" => "cloudflare"}
        })

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(agent["group_id"], force: true)

      assert {:ok, %{"provider" => "cloudflare", "status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])

      :ok = SalixWeb.ComputeProviders.Cloudflare.teardown(agent["group_id"])

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      archive_index = Enum.find_index(ops, &(&1 == :archive))
      keepalive_index = Enum.find_index(ops, &(&1 == :keepalive))
      destroy_index = Enum.find_index(ops, &(&1 == :destroy))

      assert is_integer(archive_index)
      assert is_integer(keepalive_index)
      assert is_integer(destroy_index)
      assert archive_index < keepalive_index
      assert keepalive_index < destroy_index
    end

    test "cloudflare teardown blocks release and destroy when checkpoint fails" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:archive_get, :checkpoint]})
      configure_tenant_cloudflare(tenant_id(), gateway)

      group_id = create_group!(tenant_id(), "Cloudflare Teardown Checkpoint")

      agent =
        create_cloudflare_agent(%{
          "group_id" => group_id,
          "vm" => %{"enabled" => true, "provider" => "cloudflare"}
        })

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(agent["group_id"], force: true)

      assert {:error, {:api_error, 500, "archive unavailable"}} =
               SalixWeb.ComputeProviders.Cloudflare.teardown(agent["group_id"])

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      assert :archive in ops
      refute :checkpoint in ops
      refute :keepalive in ops
      refute :destroy in ops

      assert {:ok, %{"provider" => "cloudflare"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
    end

    test "unused ready VM gets an idle grace period, archives, and wakes with its archive" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

      handler_id = "idle-archive-start-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:salix, :vm, :idle_archive, :start],
          fn _event, measurements, metadata, pid ->
            send(pid, {:idle_archive_start, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert %{archived: [^group_id]} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(now: rec["ready_at"] + 300_000)

      assert_receive {:idle_archive_start, %{delay_seconds: delay}, %{profile: "cf-standard-2"}}
      assert delay >= 0

      assert {:ok, %{"status" => "archived", "archive" => %{"type" => "connector_tar_gz"}}} =
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
      assert Enum.find_index(ops, &(&1 == :archive)) < Enum.find_index(ops, &(&1 == :destroy))
      assert :archive_restore in ops
    end

    test "missing Registry VM appears once without exceeding device page limit" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"status" => "archived", "device_id" => device_id}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert {:ok, _} = SalixEnv.Registry.delete_device(tenant_id(), group_id, device_id)

      assert {:ok, %{devices: [%{"device_id" => ^device_id}], next_cursor: cursor}} =
               SalixWeb.EnvDispatch.list_devices(agent["agent_id"], limit: 1)

      assert is_binary(cursor)

      assert {:ok, %{devices: next_page}} =
               SalixWeb.EnvDispatch.list_devices(agent["agent_id"], limit: 1, cursor: cursor)

      refute Enum.any?(next_page, &(&1["device_id"] == device_id))
    end

    test "image release stops an archived Container that is still running" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"status" => "archived"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert {:ok, %{"status" => "archived", "provider_resource_name" => resource} = rec} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert rec["archive"]["type"] == "connector_tar_gz"
      saved_archive = rec["archive"]
      destroy_count = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
      keepalive_count = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :keepalive))

      assert {:ok, %{"phase" => "prepared"}} =
               SalixWeb.ComputeProviders.Cloudflare.prepare_image_release("archived-running")

      on_exit(fn ->
        SalixWeb.ComputeProviders.Cloudflare.cancel_image_release("archived-running")
      end)

      assert {:ok, "archived"} =
               SalixWeb.ComputeProviders.Cloudflare.image_release_archive(
                 "archived-running",
                 group_id,
                 resource,
                 "cf-standard-2"
               )

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy)) ==
               destroy_count + 1

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :keepalive)) ==
               keepalive_count + 1

      assert {:ok, %{"status" => "archived", "archive" => ^saved_archive}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "image release reconnects a disconnected Device before archiving its running VM" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"provider_resource_name" => resource}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      assert {:ok, %{"phase" => "prepared"}} =
               SalixWeb.ComputeProviders.Cloudflare.prepare_image_release("disconnected-ready")

      on_exit(fn ->
        SalixWeb.ComputeProviders.Cloudflare.cancel_image_release("disconnected-ready")
      end)

      assert {:ok, "started"} =
               SalixWeb.ComputeProviders.Cloudflare.image_release_archive(
                 "disconnected-ready",
                 group_id,
                 resource,
                 "cf-standard-2"
               )

      eventually(
        fn ->
          {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
          rec["status"] == "archived"
        end,
        300
      )

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :connect)) >= 2

      assert {:ok, %{"status" => "archived", "last_error" => nil}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "image release archives a connected pre-profile standard-2 attachment" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"provider_resource_name" => resource, "device_id" => device_id}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      key = SalixStore.Keys.ctl_group_device(tenant_id(), group_id, device_id)
      {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)
      device = Jason.decode!(body)
      assert device["meta"]["profile_key"] == "cf-standard-2"

      legacy_device = update_in(device, ["meta"], &Map.delete(&1, "profile_key"))
      assert {:ok, _} = SalixStore.S3.put(key, Jason.encode!(legacy_device), if_match: etag)

      assert {:ok, %{"phase" => "prepared"}} =
               SalixWeb.ComputeProviders.Cloudflare.prepare_image_release("legacy-attachment")

      on_exit(fn ->
        SalixWeb.ComputeProviders.Cloudflare.cancel_image_release("legacy-attachment")
      end)

      assert {:ok, "started"} =
               SalixWeb.ComputeProviders.Cloudflare.image_release_archive(
                 "legacy-attachment",
                 group_id,
                 resource,
                 "cf-standard-2"
               )

      eventually(fn ->
        {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
        rec["status"] == "archived"
      end)

      assert {:ok, %{"status" => "archived", "last_error" => nil}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "archive timeout retains its Gateway claim until the start outcome is known" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, %{"provider_resource_name" => resource}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)
      :ok = MockCloudflareGateway.set_connect_delay(gateway, 12_000)

      assert {:ok, %{"phase" => "prepared"}} =
               SalixWeb.ComputeProviders.Cloudflare.prepare_image_release("late-attachment")

      on_exit(fn ->
        SalixWeb.ComputeProviders.Cloudflare.cancel_image_release("late-attachment")
      end)

      assert {:ok, "started"} =
               SalixWeb.ComputeProviders.Cloudflare.image_release_archive(
                 "late-attachment",
                 group_id,
                 resource,
                 "cf-standard-2"
               )

      eventually(
        fn ->
          {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

          rec["status"] == "archiving" and
            rec["last_error"] ==
              "{:archive_resume_pending, :archive_attachment_unavailable}" and
            rec["active_operation_count"] == 1
        end,
        1_500
      )

      assert CloudflareAttachments.whereis(env_id) == nil
      Process.sleep(2_500)
      assert CloudflareAttachments.whereis(env_id) == nil
      refute SalixEnv.Bridge.local?(env_id)

      assert {:ok, %{"active_operation_count" => 1, "active_operations" => operations}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert [{_, %{"kind" => "cloudflare_gateway_attempt"}}] = Map.to_list(operations)
    end

    test "a VM used by an unsettled agent does not use the initial idle fallback" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, operation} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec",
                 agent_id: agent["agent_id"]
               )

      :ok =
        SalixWeb.ComputeProviders.Cloudflare.finish_operation(group_id, operation, "completed", %{
          ok: true
        })

      assert {:skipped, :not_settled_after_vm} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
    end

    test "idle archive returns to ready when active native work refuses quiesce" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:runtime_not_quiet]})
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:error, :runtime_not_quiet} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      assert rec["status"] == "ready"
      refute rec["archive_operation_id"]
      refute rec["archive"]
      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
    end

    test "idle archive keeps the workload fenced when quiesce outcome is unknown" do
      gateway =
        start_supervised!(
          {MockCloudflareGateway, fail_ops: [:runtime_quiesce_unconfirmed, :runtime_not_quiet]}
        )

      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

    test "initial idle archive rechecks use at the record mutation boundary" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:error, :active_or_not_ready} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id,
                 idle_archive_ms: 0,
                 before_archive_update: fn ^group_id ->
                   {:ok, operation} =
                     SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "exec",
                       agent_id: agent["agent_id"]
                     )

                   :ok =
                     SalixWeb.ComputeProviders.Cloudflare.finish_operation(
                       group_id,
                       operation,
                       "completed",
                       %{ok: true}
                     )
                 end
               )

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op in [:archive, :destroy]))
    end

    test "orphan cleanup destroys without starting or checkpointing a container" do
      gateway =
        start_supervised!({MockCloudflareGateway, fail_ops: [:ensure, :archive_get, :checkpoint]})

      configure_tenant_cloudflare(tenant_id(), gateway)

      for status <- ["creating", "failed", "archiving"] do
        group_id = create_group!(tenant_id(), "Orphan #{status}")

        ghost = %{
          "group_id" => group_id,
          "tenant_id" => tenant_id(),
          "vm" => %{"provider" => "cloudflare"}
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

    test "failed orphan destruction keeps its record for retry and is not reported as cleaned" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:destroy]})
      configure_tenant_cloudflare(tenant_id(), gateway)
      group_id = create_group!(tenant_id(), "Failed orphan")

      ghost = %{
        "group_id" => group_id,
        "tenant_id" => tenant_id(),
        "vm" => %{"provider" => "cloudflare"}
      }

      assert {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(ghost)
      :ok = Salix.Control.Store.delete_record(SalixStore.Keys.ctl_group(group_id))

      assert {:error, {:api_error, 500, "destroy failed"}} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert %{orphaned: []} = SalixWeb.ComputeProviders.Cloudflare.sweep_once()
      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      assert rec["last_error"] =~ "orphan_teardown"
      assert rec["last_error"] =~ "destroy failed"
      assert Enum.all?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
    end

    test "idle archive skips active operations" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      {:ok, sibling} =
        SalixAgent.Control.create(
          %{"group_id" => group_id, "vm" => %{"enabled" => true, "provider" => "cloudflare"}},
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

    test "idle archive failure keeps sandbox alive" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:archive_get]})
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

      assert {:error, {:api_error, 500, "archive unavailable"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      assert :archive in ops
      refute :keepalive in ops
      refute :destroy in ops

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end

    test "shared reconciler parks an interrupted archive without provider deletion" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group = agent["group_id"]

      update_vm_record(
        group,
        &Map.merge(&1, %{
          "status" => "archiving",
          "archive_started_at" => System.system_time(:millisecond) - 900_001
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

    test "Group release survives its caller and retains the archive in the stopped Workload" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:ok, rec} = SalixStore.Compute.group_workload(group)

      assert :ok =
               Task.async(fn -> SalixWeb.ComputeProviders.Cloudflare.teardown_async(group) end)
               |> Task.await()

      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))

      assert {:error, :workload_stopped} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group, "exec")

      for _ <- 1..2, do: assert(SalixEnv.ComputeReconciler.sweep() in [:more, :complete])
      assert {:error, :not_found} = SalixStore.Compute.group_workload(group)
      stopped = SalixStore.Repo.get!(SalixStore.Compute.Workload, rec["workload_id"])
      assert stopped.observed_state == "stopped"
      assert get_in(stopped.spec, ["archive", "archive", "type"]) == "connector_tar_gz"
      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy)) == 1
    end

    test "uncertain destroy keeps the saved archive fenced instead of reopening input" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:destroy]})
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:error, {:api_error, 500, "destroy failed"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      assert {:ok, rec} = SalixStore.Compute.group_workload(group)
      assert rec["status"] == "archiving"
      assert rec["archive_reason"] == "idle_committing"
      assert rec["archive"]["type"] == "connector_tar_gz"

      assert {:error, {:vm_archiving, _}} =
               SalixWeb.ComputeProviders.Cloudflare.begin_operation(group, "exec")
    end

    test "Cloudflare recovery expires and an exact operator retry opens one new episode" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:ensure]})
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      assert {:ok, rec} = SalixStore.Compute.group_workload(agent["group_id"])
      for _ <- 1..2, do: assert(SalixEnv.ComputeReconciler.sweep() in [:more, :complete])
      id = "cloudflare:" <> rec["workload_id"] <> ":1"
      claim = SalixStore.Repo.get!(SalixStore.Compute.ReconcilerClaim, id)
      assert is_binary(claim.last_error["provider_recovery_deadline"])
      {:ok, deadline, 0} = DateTime.from_iso8601(claim.last_error["provider_recovery_deadline"])
      remaining = DateTime.diff(deadline, DateTime.utc_now(), :second)
      assert remaining > 3_000
      assert remaining <= 3_300
      expired = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()

      claim
      |> Ecto.Changeset.change(
        last_error: Map.put(claim.last_error, "provider_recovery_deadline", expired),
        next_retry_at: DateTime.utc_now()
      )
      |> SalixStore.Repo.update!()

      before = length(MockCloudflareGateway.calls(gateway))

      for _ <- 1..2, do: assert(SalixEnv.ComputeReconciler.sweep() in [:more, :complete])

      assert SalixStore.Repo.get!(SalixStore.Compute.ReconcilerClaim, id).last_error["code"] ==
               "group_provider_recovery_expired"

      assert length(MockCloudflareGateway.calls(gateway)) == before

      assert {:error, :recovery_changed} =
               SalixEnv.ComputeReconciler.retry_runtime_recovery(rec["workload_id"], 1, "stale")

      update_vm_record(agent["group_id"], &Map.put(&1, "attempt_at", nil))

      assert {:ok, %{retry: "scheduled"}} =
               SalixEnv.ComputeReconciler.retry_runtime_recovery(rec["workload_id"], 1, expired)

      for _ <- 1..2, do: assert(SalixEnv.ComputeReconciler.sweep() in [:more, :complete])
      renewed = SalixStore.Repo.get!(SalixStore.Compute.ReconcilerClaim, id)
      assert renewed.last_error["provider_recovery_deadline"] != expired
      assert length(MockCloudflareGateway.calls(gateway)) > before
    end

    test "a new wake reopens a recovery superseded by a completed archive" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:ok, %{"status" => "archived"} = archived} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      expired = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.to_iso8601()
      old_time = DateTime.add(DateTime.utc_now(), -60, :second)

      SalixStore.Repo.insert!(%SalixStore.Compute.ReconcilerClaim{
        id: "cloudflare:" <> archived["workload_id"] <> ":1",
        provider: "cloudflare",
        workload_id: archived["workload_id"],
        generation: 1,
        claim_token: Ecto.UUID.generate(),
        attempt_count: 1,
        last_error: %{
          "kind" => "action_required",
          "code" => "group_provider_recovery_expired",
          "provider_recovery_deadline" => expired
        },
        created_at: old_time,
        updated_at: old_time
      })

      assert {:error, {:vm_waking, _}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_if_archived(group)

      assert {:ok, requested} = SalixStore.Compute.group_workload(group)
      assert requested["wake_requested_at"] >= archived["archived_at"]

      claim =
        SalixStore.Repo.get!(
          SalixStore.Compute.ReconcilerClaim,
          "cloudflare:" <> archived["workload_id"] <> ":1"
        )

      assert claim.last_error == %{}

      assert SalixEnv.ComputeReconciler.sweep() in [:more, :complete]

      eventually(fn ->
        match?({:ok, %{"status" => "ready"}}, SalixStore.Compute.group_workload(group))
      end)
    end

    test "a later completed archive supersedes an old transition fault" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:ok, %{"status" => "archived"} = archived} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      claim_id = "cloudflare:" <> archived["workload_id"] <> ":1"
      fault = %{"kind" => "action_required", "code" => "group_transition_recovery_required"}
      now = DateTime.from_unix!(archived["archived_at"] * 1_000 + 1_000_000, :microsecond)

      SalixStore.Repo.insert!(%SalixStore.Compute.ReconcilerClaim{
        id: claim_id,
        provider: "cloudflare",
        workload_id: archived["workload_id"],
        generation: 1,
        claim_token: Ecto.UUID.generate(),
        attempt_count: 1,
        last_error: fault,
        created_at: now,
        updated_at: now
      })

      assert {:error, %{"error_class" => "vm_recovery_action_required"}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_if_archived(group)

      assert {:ok, %{"status" => "archived"}} = SalixStore.Compute.group_workload(group)

      claim_id
      |> then(&SalixStore.Repo.get!(SalixStore.Compute.ReconcilerClaim, &1))
      |> Ecto.Changeset.change(updated_at: DateTime.add(now, -120, :second))
      |> SalixStore.Repo.update!()

      assert {:error, {:vm_waking, _}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_if_archived(group)

      assert {:ok, %{"wake_requested_at" => requested_at}} =
               SalixStore.Compute.group_workload(group)

      assert requested_at >= archived["archived_at"]
      assert SalixStore.Repo.get!(SalixStore.Compute.ReconcilerClaim, claim_id).last_error == %{}
    end

    test "a current recovery fault is reported instead of a false waking receipt" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group, force: true)

      assert {:ok, %{"status" => "archived"} = archived} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group, force: true)

      now = DateTime.utc_now()

      SalixStore.Repo.insert!(%SalixStore.Compute.ReconcilerClaim{
        id: "cloudflare:" <> archived["workload_id"] <> ":1",
        provider: "cloudflare",
        workload_id: archived["workload_id"],
        generation: 1,
        claim_token: Ecto.UUID.generate(),
        attempt_count: 1,
        last_error: %{
          "kind" => "action_required",
          "code" => "group_provider_recovery_expired",
          "provider_recovery_deadline" => DateTime.to_iso8601(now)
        },
        created_at: now,
        updated_at: now
      })

      assert {:error, %{"error_class" => "vm_recovery_action_required", "retryable" => false}} =
               SalixWeb.ComputeProviders.Cloudflare.wake_if_archived(group)

      assert {:ok, current} = SalixStore.Compute.group_workload(group)
      assert current["status"] == "archived"
      assert current["wake_requested_at"] == archived["wake_requested_at"]
    end

    test "archiving VM rejects new mutating operations" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

    test "cancelled idle archive keeps the prior disk archive and resumes the Device" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      operation = "archive-cancel-owned"
      old_archive = %{"type" => "connector_tar_gz_chunks", "operation" => "archive-prior"}

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      {:ok, before} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      resource = before["provider_resource_name"]
      assert :ok = MockCloudflareGateway.set_export(gateway, resource, operation, "user data")

      update_vm_record(group_id, fn current ->
        current
        |> Map.put("status", "archiving")
        |> Map.put("archive_reason", "idle")
        |> Map.put("archive_operation_id", operation)
        |> Map.put("archive", old_archive)
      end)

      assert {:ok, "cancelled"} =
               SalixWeb.ComputeProviders.Cloudflare.cancel_archive_operation(group_id, operation)

      assert {:ok, after_cancel} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      assert after_cancel["status"] == "ready"
      assert after_cancel["archive"] == old_archive
      assert after_cancel["archive_operation_id"] == nil
      assert operation in after_cancel["archive_gc_operations"]
      assert after_cancel["archive_last_operation"]["result"] == "cancelled"

      assert {:ok, %{"status" => "connected"}} =
               SalixEnv.Registry.get_device(
                 after_cancel["tenant_id"],
                 group_id,
                 after_cancel["device_id"]
               )

      calls = MockCloudflareGateway.calls(gateway)
      assert Enum.any?(calls, &(&1.op == :archive_export && &1.body["method"] == "DELETE"))

      assert Enum.any?(calls, fn call ->
               call.op == :frame && call.body["method"] == "cloud_runtime_resume" &&
                 call.body["params"]["token"] == operation
             end)
    end

    test "admin cancellation wins against an exporting archive worker before pointer commit" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      old_archive = %{"type" => "connector_tar_gz", "operation" => "archive-prior"}

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      update_vm_record(group_id, &Map.put(&1, "archive", old_archive))
      parent = self()

      task =
        Task.async(fn ->
          SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id,
            force: true,
            before_archive_persist: fn ->
              send(parent, {:archive_ready_to_commit, self()})

              receive do
                :continue_archive -> :ok
              end
            end
          )
        end)

      assert_receive {:archive_ready_to_commit, worker}, 10_000

      {:ok, %{"archive_operation_id" => operation}} =
        SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert {:ok, "cancelled"} =
               SalixWeb.ComputeProviders.Cloudflare.cancel_archive_operation(group_id, operation)

      send(worker, :continue_archive)
      assert {:error, :archive_operation_lost} = Task.await(task, 10_000)

      assert {:ok, after_cancel} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      assert after_cancel["status"] == "ready"
      assert after_cancel["archive"] == old_archive
      refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))
    end

    test "sweep archives idle cloudflare VM and archived record is not revived" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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
                "archive" => %{"type" => "connector_tar_gz"},
                "connector_archive" => %{"type" => "connector_tar_gz"}
              }} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)
      archive_index = Enum.find_index(ops, &(&1 == :archive))
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
      Application.put_env(:salix_web, :vm_metering_mod, MeteringFake)
      Application.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
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
          "group_id" => group["group_id"],
          "vm" => %{"enabled" => true, "provider" => "cloudflare"}
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

      metered_at = System.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: metered_at,
                 bootstrap_mode: :dialback,
                 idle_archive_ms: 86_400_000
               )

      assert_receive {:vm_fact, fact}
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

    test "env dispatch wakes and restores archived cloudflare VM from connector archive" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)

      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
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

      assert {:ok, %{"status" => "archived"}} =
               SalixWeb.ComputeProviders.Cloudflare.archive_idle_once(group_id, force: true)

      assert {:error, {:vm_waking, %{"retry_after_ms" => 1_000}}} =
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

      assert {:ok, %{"status" => "ready"}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)

      assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :archive_restore))

      assert {:ok, %{"exit_code" => 0}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )
    end

    test "billing unavailable marks cloud VM record billing-suspended without starting VM" do
      Application.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
      Application.put_env(:salix_web, :cloud_vm_auth_result, :block)

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
      agent = create_cloudflare_agent(%{"group_id" => group["group_id"]})
      assert agent["vm"]["provider"] == "cloudflare"

      assert_receive {:vm_authorize,
                      %{
                        billing_owner: %{"billing_account_id" => "ba_vm_zero"},
                        entrypoint: "cloud_vm_enable",
                        action: :resume
                      }}

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert rec["status"] == "billing_suspended"
      assert rec["billing_decision"]["reason"] == "insufficient_credits"
    end

    test "cloudflare VM authorization uses the VM record provider" do
      Application.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
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
          "group_id" => group["group_id"],
          "vm" => %{"enabled" => true, "provider" => "cloudflare"}
        })

      assert agent["vm"]["provider"] == "cloudflare"

      assert_receive {:vm_authorize,
                      %{
                        entrypoint: "cloud_vm_enable",
                        provider: "cloudflare",
                        provider_resource_name: provider_resource_name
                      }}

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert provider_resource_name == rec["provider_resource_name"]
    end
  end

  describe "sweep_once (recovery backstop)" do
    test "credits recovery makes a billing-suspended VM eligible and resumes it" do
      Application.put_env(:salix_web, :vm_authorization_mod, VMAuthorizationFake)
      Application.put_env(:salix_web, :cloud_vm_auth_result, :block)

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
      assert agent["vm"]["provider"] == "cloudflare"
      assert_receive {:vm_authorize, %{entrypoint: "cloud_vm_enable"}}

      Application.put_env(:salix_web, :cloud_vm_auth_result, :allow)

      summary = SalixWeb.ComputeProviders.Cloudflare.sweep_once([])
      assert summary.provisioned == [group["group_id"]]

      assert_receive {:vm_authorize,
                      %{
                        billing_owner: %{"billing_account_id" => "ba_vm_recovered"},
                        entrypoint: "cloud_vm_sweeper",
                        action: :resume
                      }}

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group["group_id"])
      assert rec["status"] == "ready"
      assert rec["billing_decision"]["allowed"] == true

      assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))
    end

    test "cloudflare VM interval metering uses the VM record provider" do
      Application.put_env(:salix_web, :vm_metering_mod, MeteringFake)
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
        "group_id" => group["group_id"],
        "vm" => %{"enabled" => true, "provider" => "cloudflare"}
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

      now = System.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now,
                 bootstrap_mode: :dialback
               )

      assert_receive {:vm_fact, fact}
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

      assert_receive {:vm_fact, next_fact}
      assert next_fact.interval_start_ms == next_ready_at
      assert next_fact.duration_seconds == 60
    end

    test "does not advance VM metering checkpoint when metering backend is disabled" do
      Application.delete_env(:salix_web, :vm_metering_mod)

      group_id = create_group!(tenant_id(), "Unmetered VM")

      agent = %{
        "agent_id" => "ghost-unmetered-vm",
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      }

      {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(agent)
      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group_id)

      now = System.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now,
                 bootstrap_mode: :dialback
               )

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      refute Map.has_key?(rec, "last_metered_at")
      refute_received {:vm_fact, _}
    end

    test "advances VM metering checkpoint for unattributed typed rows" do
      Application.put_env(:salix_web, :vm_metering_mod, UnattributedMeteringFake)

      group_id = create_group!(tenant_id(), "Unattributed VM")

      agent = %{
        "agent_id" => "ghost-unattributed-vm",
        "tenant_id" => tenant_id(),
        "group_id" => group_id
      }

      {:ok, _, :created} = SalixWeb.ComputeProviders.Cloudflare.ensure_record(agent)
      assert {:ok, _} = SalixWeb.ComputeProviders.Cloudflare.mark_ready(group_id)

      now = System.system_time(:millisecond) + 60_000

      assert %{revived: []} =
               SalixWeb.ComputeProviders.Cloudflare.sweep_once(
                 now: now,
                 bootstrap_mode: :dialback
               )

      assert_receive {:vm_fact, fact}

      assert fact.owner_snapshot == %{
               "surface" => "bridge",
               "vm_profile_key" => "cf-standard-2"
             }

      assert {:ok, %{"last_metered_at" => ^now}} =
               SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
    end
  end

  test "cloud runtime requests are idempotent and keep installation ownership in the VM" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    agent = create_cloudflare_agent()
    args = %{"provider" => "codex", "request_id" => "worker-one"}

    assert {:ok, %{"state" => "pending", "target" => nil}} =
             SalixWeb.CloudVM.Runtimes.request(agent, args)

    assert {:ok, _} = SalixWeb.CloudVM.Runtimes.request(agent, args)
    assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
    assert map_size(rec["runtime_targets"]) == 1

    assert {:error, :runtime_request_conflict} =
             SalixWeb.CloudVM.Runtimes.request(agent, %{args | "provider" => "claude"})

    assert {:error, :cloud_vm_runtime_invalid_request} =
             SalixWeb.CloudVM.Runtimes.request(agent, %{args | "request_id" => "../../elsewhere"})

    update_vm_record(agent["group_id"], fn current ->
      put_in(
        current,
        ["runtime_targets", "worker-one", "requested_at"],
        System.system_time(:millisecond) - 300_001
      )
    end)

    assert {:ok, %{"state" => "failed", "issue" => "runtime_install_timeout"}} =
             SalixWeb.CloudVM.Runtimes.get(tenant_id(), agent["group_id"], "worker-one")

    assert {:ok, %{"state" => "pending"}} =
             SalixWeb.CloudVM.Runtimes.request(agent, Map.put(args, "retry", true))

    assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(agent["group_id"])
    assert map_size(rec["runtime_targets"]) == 1
  end

  test "cloud runtime API scopes preparation and status to the authenticated tenant" do
    gateway = start_supervised!(MockCloudflareGateway)
    configure_tenant_cloudflare(tenant_id(), gateway)
    agent = create_cloudflare_agent()
    group = agent["group_id"]
    token = tenant_api_key()
    prepare = "/v1/runtime/agent-groups/#{group}/agents/#{agent["agent_id"]}/cloud-vm/runtimes"
    status = "/v1/runtime/groups/#{group}/cloud-vm/runtimes/worker-api"

    response =
      req_as(token, :post, prepare, json: %{"provider" => "claude", "request_id" => "worker-api"})

    assert response.status == 202
    assert response.body["state"] == "pending"
    response = req_as(token, :get, status, [])
    assert response.status == 200
    assert response.headers["cache-control"] == ["no-store"]
    {:ok, foreign_tenant} = Salix.Control.Tenants.create(%{"name" => "Runtime isolation"})
    foreign = tenant_api_key(foreign_tenant["tenant_id"])
    assert req_as(foreign, :get, status, []).status == 404

    assert req_as(foreign, :post, prepare,
             json: %{"provider" => "claude", "request_id" => "other"}
           ).status == 409

    assert req_as(foreign, :put, status <> "/managed-auth", json: %{"account_id" => "foreign"}).status ==
             409

    assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group)
    assert map_size(rec["runtime_targets"]) == 1
  end

  describe "Cloudflare attachment recovery" do
    test "sweep revives a lost cloudflare attachment" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert SalixEnv.Bridge.local?(env_id)

      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      # Repair within the initial idle grace, rather than forcing idle shutdown.
      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      summary = SalixWeb.ComputeProviders.Cloudflare.sweep_once(now: rec["ready_at"])
      assert summary.archived == []
      assert summary.revived == [group_id]
      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)
    end

    test "ready management reconcile reattaches without provisioning the running Cloudflare sandbox" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      ensures_before = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))
      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      workload = SalixStore.Repo.get!(SalixStore.Compute.Workload, rec["workload_id"])
      allocation = SalixStore.Repo.get!(SalixStore.Compute.Allocation, workload.allocation_id)

      assert {:ok, %{outcome: :group_reconciled}} =
               SalixWeb.ComputeProviders.Cloudflare.reconcile(allocation, workload, [])

      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure)) ==
               ensures_before
    end

    test "reconcile keeps a live attachment on another transport" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      assert {:ok, rec} = SalixWeb.ComputeProviders.Cloudflare.get_record(group_id)
      assert {:ok, device} = cloud_device(group_id)
      env_id = rec["env_id"]
      alternate_env = env_id <> "-remote-like"
      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      client =
        SalixEnv.VM.Providers.Cloudflare.Client.new(
          base_url: MockCloudflareGateway.base_url(gateway),
          secret: "test-secret",
          group_id: group_id
        )

      assert {:ok, _} =
               CloudflareAttachments.ensure(
                 env_id: alternate_env,
                 sandbox_id: rec["provider_resource_name"],
                 client: client,
                 meta:
                   device["meta"]
                   |> Map.put("provider_resource_name", rec["provider_resource_name"])
                   |> Map.put("managed_compute", true)
               )

      on_exit(fn -> CloudflareAttachments.stop(alternate_env) end)

      eventually(fn ->
        match?(
          {:ok, %{"status" => "connected", "transport_id" => ^alternate_env}},
          cloud_device(group_id)
        )
      end)

      assert {:ok, _, _} =
               GroupCompute.update_group_workload(group_id, fn current ->
                 Map.put(current, "provider_migration", %{
                   "phase" => "committed",
                   "archive_hold" => "awaiting_durable_archive"
                 })
               end)

      workload = SalixStore.Repo.get!(SalixStore.Compute.Workload, rec["workload_id"])
      allocation = SalixStore.Repo.get!(SalixStore.Compute.Allocation, workload.allocation_id)

      assert {:ok, %{outcome: :group_reconciled}} =
               SalixWeb.ComputeProviders.Cloudflare.reconcile(allocation, workload, [])

      Process.sleep(500)
      assert CloudflareAttachments.whereis(env_id) == nil

      assert {:ok, %{"status" => "connected", "transport_id" => ^alternate_env}} =
               cloud_device(group_id)
    end

    test "dispatch-path repair reattaches Cloudflare without ensuring the sandbox" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      ensures_before = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))
      connects_before = Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :connect))
      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)

      assert {:error, {:vm_waking, _}} =
               SalixWeb.EnvDispatch.exec(
                 agent["agent_id"],
                 cloud_target(agent["agent_id"], "cloud-vm"),
                 "true",
                 %{}
               )

      eventually(fn -> SalixEnv.Bridge.local?(env_id) end)

      assert Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure)) ==
               ensures_before

      eventually(fn ->
        Enum.count(MockCloudflareGateway.calls(gateway), &(&1.op == :connect)) > connects_before
      end)

      reconnect =
        gateway
        |> MockCloudflareGateway.calls()
        |> Enum.filter(&(&1.op == :connect))
        |> List.last()

      assert reconnect.body["worker_version_overrides"] =~ ~s(="version-1")

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

    test "dispatch-path repair stays bounded while Cloudflare is unavailable" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      agent = create_cloudflare_agent(%{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})
      group_id = agent["group_id"]
      env_id = SalixWeb.ComputeProviders.Cloudflare.cloudvm_env_id(group_id)

      assert {:ok, :ready} =
               SalixWeb.ComputeProviders.Cloudflare.provision_once(group_id, force: true)

      CloudflareAttachments.stop(env_id)
      eventually(fn -> not SalixEnv.Bridge.local?(env_id) end)
      :ok = stop_supervised(MockCloudflareGateway)
      attachments = Process.monitor(Process.whereis(CloudflareAttachments))

      task =
        Task.async(fn ->
          SalixWeb.EnvDispatch.exec(
            agent["agent_id"],
            cloud_target(agent["agent_id"], "cloud-vm"),
            "true",
            %{}
          )
        end)

      result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)

      assert {:ok, {:error, {:vm_waking, %{"env_id" => ^env_id}}}} = result

      # The unreachable Gateway ends this one repair attempt. It must not
      # restart in a loop and take down the node's other attachments.
      eventually(fn -> CloudflareAttachments.whereis(env_id) == nil end)
      refute_receive {:DOWN, ^attachments, :process, _, _}, 500
    end
  end

  describe "agent PATCH / DELETE" do
    test "disabling every Agent preserves Group compute until explicit Group release" do
      gateway = start_supervised!(MockCloudflareGateway)
      configure_tenant_cloudflare(tenant_id(), gateway)
      first = create_cloudflare_agent()
      second = create_cloudflare_agent()
      group = first["group_id"]

      for agent <- [first, second] do
        assert {:ok, _} =
                 SalixAgent.Control.configure(agent["agent_id"], %{"vm" => %{"enabled" => false}})

        assert {:ok, %{"desired_state" => "ready"}} = GroupCompute.group_workload(group)
      end

      assert :ok = SalixWeb.ComputeProviders.Cloudflare.teardown_async(group)
      assert {:ok, %{"desired_state" => "stopped"}} = GroupCompute.group_workload(group)
    end

    test "enabling retired Sprites via PATCH leaves the agent and workload unchanged" do
      {:ok, plain} = create_agent!(tenant_id(), %{"group_id" => group_id()})

      assert {:error, {:bad_request, reason}} =
               SalixAgent.Control.configure(plain["agent_id"], %{
                 "vm" => %{"enabled" => true, "provider" => "sprites"}
               })

      assert reason =~ "cloudflare"
      {:ok, unchanged} = SalixAgent.Control.get(plain["agent_id"], tenant_id())
      refute unchanged["vm"]["enabled"]
      assert {:error, :not_found} = SalixStore.Compute.group_workload(plain["group_id"])
    end

    test "enabling via PATCH without tenant config is rejected" do
      tenant_id = create_tenant!()
      {:ok, agent} = create_agent!(tenant_id)

      assert {:error, {:bad_request, @config_missing}} =
               SalixAgent.Control.configure(agent["agent_id"], %{"vm" => %{"enabled" => true}})
    end
  end

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
