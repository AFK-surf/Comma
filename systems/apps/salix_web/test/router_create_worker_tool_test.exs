defmodule SalixWeb.RouterCreateWorkerToolTest do
  @moduledoc """
  Actual disclosed Router management calls across environment target discovery,
  command ownership and persisted Control records.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools.Peers
  alias SalixEnv.Registry
  alias SalixStore.RuntimeIds

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_management = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, Salix.Bindings.AgentManagement)
    prev_env_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :group_context_mod, Salix.Bindings.AgentGroupContext)

    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Salix.Bindings.AgentEnvDispatch)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      put_or_delete_env(:salix_store, :s3_backend, prev_store)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :env_dispatch, prev_env_dispatch)
      put_or_delete_env(:salix_agent, :agent_management_ports, prev_management)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Router Create Worker"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    {:ok, group} =
      Salix.Control.Groups.create(
        %{"name" => "Router Create Worker"},
        tenant_id()
      )

    group_id = group["group_id"]

    SalixAgent.TestSupport.configure_platform_models!()

    {:ok, router} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "name" => "Router",
          "role" => "router"
        },
        tenant_id()
      )

    device = connected_codex_device!(group_id)

    %{
      group_id: group_id,
      router: router,
      connector_run_id: device.connector_run_id,
      environment_id: device.environment_id,
      runtime_id: device.runtime_id,
      device_runtime_id: device.device_runtime_id
    }
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "router adds an ordinary worker through the internal IM provider",
       %{router: router, group_id: group_id} do
    {:ok, worker} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
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

  test "a Worker bound to a station flows through create, get, update and rebind; External Runtime targets are refused",
       fixture do
    ctx = tool_context(fixture.router)

    refused =
      tool_result(
        "agent.create_worker",
        %{
          "name" => "Reviewer",
          "purpose" => "Backend",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "connected", "device_runtime_id" => fixture.device_runtime_id}
        },
        ctx,
        "create-connected"
      )

    assert refused.error
    assert refused.content =~ "external_runtime_retired"

    input = %{
      "name" => "Reviewer",
      "purpose" => "Backend",
      "creation_reason" => "This test needs an independent Worker",
      "runtime" => %{"kind" => "station", "device_id" => "dev-router-create-worker"},
      "model" => %{"kind" => "runtime", "provider" => "codex"}
    }

    created = tool!("agent.create_worker", input, ctx, "create")
    id = created["agent"]["agent_id"]
    assert created["result"] == "applied"

    assert created["agent"]["runtime"] == %{
             "kind" => "station",
             "runs_on" => %{"kind" => "station", "device_id" => "dev-router-create-worker"},
             "provider" => "codex"
           }

    assert created["agent"]["model"]["source"] == "runtime_default"
    audit = created["agent"]["creation_audit"]
    assert audit["tool_call_id"] == "create"
    assert audit["router_agent_id"] == fixture.router["agent_id"]

    replay = tool!("agent.create_worker", input, ctx, "create")
    assert replay["agent"]["agent_id"] == id
    assert replay["replayed"]

    detail = tool!("agent.get", %{"agent_id" => id}, ctx, "get")
    assert detail["agent"]["binding_revision"] == 1

    moved =
      tool!(
        "agent.rebind_runtime",
        %{
          "agent_id" => id,
          "target" => %{"kind" => "cloud_vm"},
          "expected_binding_revision" => 1
        },
        ctx,
        "rebind"
      )

    assert moved["result"] == "applied"
    assert moved["agent"]["runtime"]["runs_on"] == %{"kind" => "cloud_vm"}

    failed =
      tool_result(
        "agent.rebind_runtime",
        %{
          "agent_id" => id,
          "target" => %{"kind" => "station", "device_id" => "dev-other"},
          "expected_binding_revision" => 1
        },
        ctx,
        "rebind-stale"
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
    assert updated["agent"]["runtime"]["kind"] == "station"
    assert tool!("agent.list", %{}, ctx, "list")["items"] |> Enum.any?(&(&1["agent_id"] == id))
  end

  test "internal worker outside BridgeForTeams follows the platform model and rejects a Router-chosen model",
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

    assert created["agent"]["model"]["source"] == "platform_default"

    # A Group outside BridgeForTeams has no org to allow a model: a
    # Router-chosen model is rejected and creates nothing.
    chosen =
      tool_result(
        "agent.create_worker",
        %{
          "name" => "Chosen model",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"},
          "model" => %{"kind" => "catalog", "model" => "gpt-5.5"}
        },
        ctx,
        "chosen-model"
      )

    assert chosen.content =~ "model_selection_unsupported"
    assert {:ok, page} = SalixAgent.Control.page_workers(tenant_id(), fixture.group_id)
    assert length(page.items) == 1
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
    env_id = "env-router-create-worker-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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
            "readiness_checked_at" => SystemsClock.system_time(:millisecond),
            "readiness_valid_until" => SystemsClock.system_time(:millisecond) + 600_000,
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

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
