defmodule SalixWeb.RouterCreateWorkerToolTest do
  @moduledoc """
  Actual disclosed Router management calls across environment target discovery,
  command ownership and persisted Control records. Retained legacy obligations
  are tested separately from the replacement tool's no-provisioning contract.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  alias SalixStore.{Compute, Repo}
  alias SalixAgent.Tools.Peers
  alias SalixEnv.Registry
  alias SalixStore.RuntimeIds

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    prev_management = Application.get_env(:salix_agent, :agent_management_ports)
    Application.put_env(:salix_agent, :agent_management_ports, Salix.Bindings.AgentManagement)
    prev_env_dispatch = Application.get_env(:salix_agent, :env_dispatch)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :group_context_mod, Salix.Bindings.AgentGroupContext)

    Application.put_env(
      :salix_agent,
      :runtime_environment_mod,
      Salix.Bindings.AgentRuntimeEnvironment
    )

    Application.put_env(:salix_agent, :env_dispatch, Salix.Bindings.AgentEnvDispatch)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      put_or_delete_env(:salix_store, :s3_backend, prev_store)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
      put_or_delete_env(:salix_agent, :env_dispatch, prev_env_dispatch)
      put_or_delete_env(:salix_agent, :agent_management_ports, prev_management)
    end)

    template_id = "tmpl-router-create-worker-#{System.unique_integer([:positive])}"
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Router Create Worker"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} =
      Salix.Control.Groups.create(
        %{"name" => "Router Create Worker"},
        tenant_id()
      )

    group_id = group["group_id"]

    {:ok, _template} =
      SalixAgent.Templates.create(%{
        "template_id" => template_id,
        "name" => "Router Create Worker Template",
        "model" => "mock",
        "provider" => "mock"
      })

    {:ok, router} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "template_id" => template_id,
          "name" => "Router",
          "role" => "router"
        },
        tenant_id()
      )

    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant_id(), "agent_defaults", %{
        "worker_template_id" => template_id
      })

    device = connected_codex_device!(group_id)

    %{
      group_id: group_id,
      template_id: template_id,
      router: router,
      connector_run_id: device.connector_run_id,
      environment_id: device.environment_id,
      runtime_id: device.runtime_id,
      device_runtime_id: device.device_runtime_id
    }
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "retired provisioning obligations honor claims and finish once without the retired tool",
       %{
         router: router,
         group_id: group_id
       } do
    reconciler = Process.whereis(SalixAgent.ExternalWorkerOperationReconciler)
    :sys.suspend(reconciler)
    on_exit(fn -> if Process.alive?(reconciler), do: :sys.resume(reconciler) end)

    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "router-claimed-pool-#{suffix}",
        tenant_id: tenant_id(),
        name: "Router claimed pool",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]},
        capabilities: ["runtime_exec", "runtime_process"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "router-claimed-environment-#{suffix}",
        tenant_id: tenant_id(),
        owner_type: "project",
        owner_id: group_id,
        pool_id: pool.id
      })

    {:ok, _binding} =
      Compute.create_provider_binding(%{
        id: "router-claimed-binding-#{suffix}",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: "router-claimed-provider-#{suffix}"
      })

    tool_call_id = "tool-compute-claimed-#{suffix}"

    operation_hash =
      :sha256
      |> :crypto.hash(
        Enum.join(
          ["agent.create_worker", "external", router["agent_id"], "main", tool_call_id],
          ":"
        )
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    workload_id = "workload_" <> operation_hash

    {:ok, placement} =
      Compute.ensure_external_worker_placement(%{
        tenant_id: tenant_id(),
        group_id: group_id,
        operation_hash: operation_hash,
        tool_call_id: tool_call_id,
        environment_id: environment.id,
        provider: "pi",
        template_key: "external.pi",
        allocation_id: "allocation_" <> operation_hash,
        workload_id: workload_id
      })

    {1, _} =
      Repo.update_all(
        from(o in Compute.ExternalWorkerOperation, where: o.id == ^placement.operation.id),
        set: [
          claim_token: "competing-reconciler",
          lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        ]
      )

    agent_ids_before =
      tenant_id()
      |> SalixAgent.Control.list(group_id: group_id)
      |> MapSet.new(& &1["agent_id"])

    _ = SalixAgent.ExternalWorkerOperationReconciler.sweep()

    assert agent_ids_before ==
             tenant_id()
             |> SalixAgent.Control.list(group_id: group_id)
             |> MapSet.new(& &1["agent_id"])

    operation = Repo.get!(Compute.ExternalWorkerOperation, placement.operation.id)
    assert operation.state == "placement_ready"
    assert operation.worker_id == nil

    {1, _} =
      Repo.update_all(
        from(o in Compute.ExternalWorkerOperation, where: o.id == ^operation.id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    # A legacy reservation may point at an unrelated identity. Rotate the
    # reservation without changing that Agent, then finish the accepted Workload.
    {:ok, unrelated} =
      SalixAgent.Control.create(
        %{"group_id" => group_id, "role" => "worker", "name" => "Unrelated"},
        tenant_id()
      )

    key = SalixStore.Keys.ctl_agent_worker_tool_idempotency(group_id, operation_hash)

    {:ok, _} =
      SalixStore.S3.put(
        key,
        Jason.encode!(%{
          "agent_id" => unrelated["agent_id"],
          "group_id" => group_id,
          "worker_type" => "external",
          "idempotency_hash" => operation_hash
        }),
        if_none_match: "*"
      )

    _ = SalixAgent.ExternalWorkerOperationReconciler.sweep()
    operation = Repo.get!(Compute.ExternalWorkerOperation, operation.id)
    assert operation.state == "worker_ready"
    assert operation.worker_id != unrelated["agent_id"]
    assert {:ok, ^unrelated} = SalixAgent.Control.get(unrelated["agent_id"], tenant_id())
    assert is_binary(operation.worker_id)
    first_id = operation.worker_id
    _ = SalixAgent.ExternalWorkerOperationReconciler.sweep()
    assert Repo.get!(Compute.ExternalWorkerOperation, operation.id).worker_id == first_id
    assert {:ok, worker} = SalixAgent.Control.get(first_id, tenant_id())
    assert worker["runtime_config"]["workload_id"] == workload_id
    assert worker["configuration_authority"] == "salix"
  end

  test "device.get exposes external Codex device runtimes for router selection", %{
    router: router,
    environment_id: environment_id
  } do
    ctx = %{agent_id: router["agent_id"], session_id: "main"}
    %{"devices" => [summary]} = Jason.decode!(Peers.list_devices(%{}, ctx))
    device = Jason.decode!(Peers.get_device(%{"device_id" => summary["device_id"]}, ctx))

    assert Enum.any?(device["environments"], &(&1["environment_id"] == environment_id))
    refute Map.has_key?(device, "connector_run_id")
    runtime = Enum.find(device["device_runtimes"], &(&1["provider"] == "codex"))
    assert runtime["runtime_id"]
    assert runtime["device_runtime_id"]
    assert runtime["device_id"] == device["device_id"]
    assert runtime["status"] == "ready"
  end

  test "router adds an ordinary worker through the internal IM provider",
       %{router: router, group_id: group_id, template_id: template_id} do
    {:ok, worker} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "template_id" => template_id,
          "name" => "Researcher",
          "role" => "worker"
        },
        tenant_id()
      )

    {:ok, conversation} =
      SalixIM.ConversationServer.create_group_conversation(group_id, %{
        "title" => "Meeting preparation",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    params = %{
      "conversation_id" => conversation["conversation_id"],
      "agent_id" => worker["agent_id"],
      "role_label" => "researcher",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"}
    }

    assert {:ok, result} =
             Salix.Bindings.AgentIMProvider.call_api(
               router["agent_id"],
               "internal",
               "internal.add_agent_participant",
               %{
                 "connect_id" => "internal",
                 "tool_call_id" => "tool-add-researcher",
                 "params" => params,
                 "tool_context" => %{
                   "runtime_kind" => "internal",
                   "session_id" => "main"
                 }
               }
             )

    assert result["conversation_id"] == conversation["conversation_id"]
    assert result["agent_id"] == worker["agent_id"]

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               conversation["conversation_id"]
             )

    assert Enum.any?(
             participants,
             &(&1["agent_id"] == worker["agent_id"] and &1["role_label"] == "researcher")
           )

    assert {:ok, retried} =
             Salix.Bindings.AgentIMProvider.call_api(
               router["agent_id"],
               "internal",
               "internal.add_agent_participant",
               %{
                 "connect_id" => "internal",
                 "tool_call_id" => "tool-add-researcher-retry",
                 "params" => params,
                 "tool_context" => %{
                   "runtime_kind" => "internal",
                   "session_id" => "main"
                 }
               }
             )

    assert retried["participant_id"] == result["participant_id"]
    assert retried["notification_filter"] == result["notification_filter"]
  end

  test "disclosed environment target flows unchanged through create, get, update and rebind",
       fixture do
    ctx = tool_context(fixture.router)
    page = tool!("env.runtime_targets", %{"kind" => "connected"}, ctx, "discover")
    assert [item] = page["items"]
    target = item["target"]
    assert target["device_runtime_id"] == fixture.device_runtime_id
    assert target["kind"] == "connected"

    created =
      tool!(
        "agent.create_worker",
        %{
          "name" => "Reviewer",
          "purpose" => "Backend",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => target
        },
        ctx,
        "create"
      )

    id = created["agent"]["agent_id"]
    assert created["result"] == "applied"
    assert created["agent"]["runtime"]["kind"] == "connected"
    audit = created["agent"]["creation_audit"]
    assert audit["tool_call_id"] == "create"
    assert audit["router_agent_id"] == fixture.router["agent_id"]
    assert audit["reason"] == "This test needs an independent Worker"

    replay =
      tool!(
        "agent.create_worker",
        %{
          "name" => "Reviewer",
          "purpose" => "Backend",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => target
        },
        ctx,
        "create"
      )

    assert replay["agent"]["agent_id"] == id
    assert replay["replayed"]

    detail = tool!("agent.get", %{"agent_id" => id}, ctx, "get")
    revision = detail["agent"]["binding_revision"]

    rebound =
      tool!(
        "agent.rebind_runtime",
        %{"agent_id" => id, "target" => target, "expected_binding_revision" => revision},
        ctx,
        "rebind"
      )

    assert rebound["result"] == "unchanged"
    assert rebound["agent"]["runtime"] == detail["agent"]["runtime"]

    {:ok, _} =
      Registry.update_meta(fixture.connector_run_id, fn meta ->
        [runtime] = meta["agent_runtimes"]
        runtime_id = RuntimeIds.runtime_id("/usr/local/bin/pi")
        id = RuntimeIds.device_runtime_id(runtime["device_id"], "pi", runtime_id)

        next_runtime =
          Map.merge(runtime, %{
            "id" => id,
            "device_runtime_id" => id,
            "runtime_id" => runtime_id,
            "provider" => "pi",
            "command" => "/usr/local/bin/pi"
          })

        Map.put(meta, "agent_runtimes", [runtime, next_runtime])
      end)

    [next] =
      tool!(
        "env.runtime_targets",
        %{"kind" => "connected", "provider" => "pi"},
        ctx,
        "discover-next"
      )["items"]

    changed =
      tool!(
        "agent.rebind_runtime",
        %{"agent_id" => id, "target" => next["target"], "expected_binding_revision" => revision},
        ctx,
        "rebind-next"
      )

    assert changed["result"] == "applied"

    failed =
      tool_result(
        "agent.rebind_runtime",
        %{"agent_id" => id, "target" => target, "expected_binding_revision" => revision},
        ctx,
        "rebind"
      )

    assert failed.error
    assert failed.content =~ "binding_conflict"

    updated =
      tool!(
        "agent.update",
        %{"agent_id" => id, "name" => "Code Reviewer", "purpose" => "Review backend changes"},
        ctx,
        "update"
      )

    assert updated["agent"]["creation_audit"] == audit

    rejected =
      tool_result("agent.update", %{"agent_id" => id, "purpose" => "  "}, ctx, "clear-purpose")

    assert rejected.error

    assert tool!("agent.get", %{"agent_id" => id}, ctx, "after-rejection")["agent"]["purpose"] ==
             "Review backend changes"

    assert updated["agent"]["name"] == "Code Reviewer"
    assert updated["agent"]["purpose"] == "Review backend changes"
    assert tool!("agent.list", %{}, ctx, "list")["items"] |> Enum.any?(&(&1["agent_id"] == id))
  end

  test "internal worker uses configured default and rejects legacy provisioning parameters",
       fixture do
    ctx = tool_context(fixture.router)

    created =
      tool!(
        "agent.create_worker",
        %{
          "name" => "Internal reviewer",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx,
        "internal"
      )

    assert created["agent"]["model"]["template_id"] == fixture.template_id

    result =
      tool_result(
        "agent.create_worker",
        %{
          "worker_type" => "external",
          "runtime_source" => "compute",
          "environment" => "new-environment",
          "provider" => "codex"
        },
        ctx,
        "legacy"
      )

    assert result.content =~ "agent.create_worker"
    assert {:ok, page} = SalixAgent.Control.page_workers(tenant_id(), fixture.group_id)
    assert length(page.items) == 1
  end

  test "missing locator is repaired by bounded discovery and current readiness is authoritative",
       fixture do
    SalixStore.Repo.delete_all(SalixEnv.RuntimeTargets.Locator)
    ctx = tool_context(fixture.router)
    target = %{"kind" => "connected", "device_runtime_id" => fixture.device_runtime_id}

    result =
      tool_result(
        "agent.create_worker",
        %{
          "name" => "Known ID",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => target
        },
        ctx,
        "before-discovery"
      )

    assert result.error
    assert result.content =~ "target_discovery_required"

    assert [_] =
             tool!("env.runtime_targets", %{"kind" => "connected", "limit" => 1}, ctx, "discover")[
               "items"
             ]

    assert tool!(
             "agent.create_worker",
             %{
               "name" => "Known ID",
               "purpose" => "Execute the test responsibility",
               "creation_reason" => "This test needs an independent Worker",
               "runtime" => target
             },
             ctx,
             "after-discovery"
           )["result"] == "applied"

    {:ok, _} =
      Registry.update_meta(fixture.connector_run_id, fn meta ->
        Map.update!(meta, "agent_runtimes", fn runtimes ->
          Enum.map(runtimes, &Map.put(&1, "ready", false))
        end)
      end)

    result =
      tool_result(
        "agent.create_worker",
        %{
          "name" => "Unavailable",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => target
        },
        ctx,
        "unavailable"
      )

    assert result.error
  end

  defp tool_context(router) do
    ctx =
      %{
        agent_id: router["agent_id"],
        session_id: router["router_session_id"],
        role: "router",
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
    )
  end

  defp tool_result(name, args, ctx, id) do
    [result] = SalixAgent.Tools.execute([%{"id" => id, "name" => name, "args" => args}], ctx)
    result
  end

  defp tool!(name, args, ctx, id) do
    result = tool_result(name, args, ctx, id)
    refute result.error, inspect(result)
    Jason.decode!(result.content)
  end

  defp connected_codex_device!(group_id) do
    env_id = "env-router-create-worker-#{System.unique_integer([:positive])}"
    device_id = "dev-router-create-worker"
    environment_id = RuntimeIds.device_environment_id(device_id, "connector", "default")
    runtime_id = RuntimeIds.runtime_id("/usr/local/bin/codex")
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)

    {:ok, ^env_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "connector-router-create-worker",
          "name" => "Mac Studio",
          "alias" => "mac",
          "os" => "darwin",
          "arch" => "arm64"
        },
        transport_id: env_id
      )

    connector_run_id = record["connector_run_id"]

    {:ok, _record} =
      Registry.update_meta(connector_run_id, fn meta ->
        Map.put(meta, "agent_runtimes", [
          %{
            "id" => device_runtime_id,
            "kind" => "external",
            "provider" => "codex",
            "device_id" => device_id,
            "runtime_id" => runtime_id,
            "device_runtime_id" => device_runtime_id,
            "status" => "available",
            "version_detected" => true,
            "ready" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "readiness_checked_at" => System.system_time(:millisecond),
            "readiness_valid_until" => System.system_time(:millisecond) + 600_000,
            "command" => "/usr/local/bin/codex",
            "version" => "codex-test"
          }
        ])
      end)

    %{
      connector_run_id: connector_run_id,
      environment_id: environment_id,
      runtime_id: runtime_id,
      device_runtime_id: device_runtime_id
    }
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
