defmodule SalixWeb.ParticipantDeviceDiagnosisE2ETest do
  @moduledoc """
  Agent-facing product-path coverage for participant activity and device
  runtime diagnosis through the Router's tools.
  """

  use SystemsClock.Case, async: false

  alias SalixAgent.{SessionToolDispatch, ToolDisclosure}

  alias Salix.Control.{Groups, Plugins, Tenants}
  alias SalixEnv.Registry
  alias SalixIM.{ConversationInput, Conversations}
  alias SalixStore.{Ids, Keys, RuntimeIds, S3}

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      im_provider: SystemsRuntime.get_env(:salix_agent, :im_provider_mod),
      plugin_store: SystemsRuntime.get_env(:salix_agent, :plugin_store_mod),
      session_activity: SystemsRuntime.get_env(:salix_im, :session_activity_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    SystemsRuntime.put_env(:salix_agent, :plugin_store_mod, Salix.Bindings.AgentPluginStore)
    SystemsRuntime.put_env(:salix_im, :session_activity_mod, Salix.Bindings.IMSessionActivity)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_agent, :im_provider_mod, previous.im_provider)
      restore(:salix_agent, :plugin_store_mod, previous.plugin_store)
      restore(:salix_im, :session_activity_mod, previous.session_activity)
    end)

    {:ok, tenant} = Tenants.create(%{"name" => "Participant runtime E2E"})
    {:ok, group} = Groups.create(%{"name" => "Participant runtime E2E"}, tenant["tenant_id"])

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, group} =
      Groups.update(
        group["group_id"],
        %{"router_agent_id" => router["agent_id"]},
        tenant["tenant_id"]
      )

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    {:ok, tenant: tenant, group: group, router: router, worker: worker}
  end

  test "Router reads participant status and diagnoses a disconnected device through device.get",
       %{tenant: tenant, group: group, router: router, worker: worker} do
    tenant_id = tenant["tenant_id"]
    group_id = group["group_id"]
    {connector_run_id, fixed_binding} = connect_ready_runtime!(tenant_id, group_id)

    {conversation_id, participant_id, session_id} =
      create_agent_task_conversation!(group_id, router["agent_id"], worker["agent_id"])

    assert {:ok, _session} =
             SalixAgent.InternalSessionStore.prepare_create(worker["agent_id"], session_id)

    assert {:ok, disconnected} = Registry.mark_disconnected(connector_run_id)
    assert disconnected["status"] == "disconnected"

    ctx = router_tool_context(tenant_id, group_id, router["agent_id"])

    listed =
      call_tool!(ctx, "im_api.internal.list_conversation_participants", %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id
      })

    assert Enum.any?(
             listed["participants"],
             &(&1["participant_id"] == participant_id and &1["type"] == "agent")
           )

    participant_prefix =
      Keys.ctl_group_conversation_participants_prefix(group_id, conversation_id)

    SalixStore.S3.Fake.reset_read_log()

    participant_status =
      call_tool!(ctx, "im_api.internal.get_conversation_participant_status", %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id,
        "participant_id" => participant_id
      })

    tools = ctx.tool_disclosure["tools"]

    assert %{
             "env_get_disclosed" => true,
             "old_combined_operation_disclosed" => false
           } == %{
             "env_get_disclosed" => Enum.any?(tools, &(&1["name"] == "device.get")),
             "old_combined_operation_disclosed" =>
               Enum.any?(
                 tools,
                 &(&1["name"] ==
                     "im_api.internal.get_conversation_participant_runtime_status")
               )
           }

    assert participant_status["activity"]["state"] in ["active", "stopped", "error"]

    env_get = Enum.find(tools, &(&1["name"] == "device.get"))
    assert env_get["callable"] == true
    assert env_get["helpable"] == true

    help = call_tool!(ctx, "help", %{"tool" => "device.get"})
    assert help["input_schema"]["required"] == ["device_id"]

    device = call_tool!(ctx, "device.get", %{"device_id" => fixed_binding["device_id"]})

    assert device["device_id"] == fixed_binding["device_id"]
    assert device["name"] == "Fixed worker device"
    assert device["status"] == "disconnected"
    assert device["updated_at"] == disconnected["updated_at"] |> div(1_000)

    runtime =
      Enum.find(
        device["device_runtimes"],
        &(&1["device_runtime_id"] == fixed_binding["device_runtime_id"])
      )

    assert runtime["provider"] == "codex"
    assert runtime["runtime_id"] == fixed_binding["runtime_id"]
    assert runtime["status"] == "disconnected"
    assert runtime["issue"] == "connector_disconnected"

    refute_sensitive_projection!(device, [session_id, "/usr/local/bin/codex"])

    device_prefix = Keys.ctl_group_devices_prefix(tenant_id, group_id)
    internal_session_prefix = Keys.agent_internal_runtime_sessions_prefix(worker["agent_id"])
    group_agents_prefix = Keys.ctl_agents_prefix_for_group(group_id)

    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {:list, ^participant_prefix, _opts} -> true
             {:list, ^device_prefix, _opts} -> true
             {:list, ^internal_session_prefix, _opts} -> true
             {:list, ^group_agents_prefix, _opts} -> true
             _other -> false
           end)

    participant_key =
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        participant_id
      )

    assert {:ok, %{body: participant_body, etag: participant_etag}} = S3.get(participant_key)

    mismatched_participant =
      participant_body
      |> Jason.decode!()
      |> Map.put("participant_id", Ids.new_participant_id())

    assert {:ok, _result} =
             S3.put(participant_key, Jason.encode!(mismatched_participant),
               if_match: participant_etag
             )

    mismatched_read =
      call_tool(ctx, "im_api.internal.get_conversation_participant_status", %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id,
        "participant_id" => participant_id
      })

    assert mismatched_read.error
    assert mismatched_read.content =~ "participant not found"
  end

  test "Router device.get returns specific workspace and authentication observations",
       %{tenant: tenant, group: group, router: router} do
    tenant_id = tenant["tenant_id"]
    group_id = group["group_id"]
    {connector_run_id, binding} = connect_ready_runtime!(tenant_id, group_id)
    ctx = router_tool_context(tenant_id, group_id, router["agent_id"])

    update_runtime_readiness!(connector_run_id, %{
      "ready" => false,
      "readiness_issue" => "workspace_unavailable",
      "readiness_message" => "HOME is not set; the runtime workspace root cannot be resolved."
    })

    workspace = call_tool!(ctx, "device.get", %{"device_id" => binding["device_id"]})
    workspace_runtime = runtime!(workspace, binding)
    assert workspace_runtime["status"] == "unavailable"
    assert workspace_runtime["issue"] == "workspace_unavailable"

    assert workspace_runtime["message"] ==
             "HOME is not set; the runtime workspace root cannot be resolved."

    update_runtime_readiness!(connector_run_id, %{
      "auth_ready" => false,
      "native_server_startable" => false,
      "ready" => false,
      "readiness_issue" => "authentication_required",
      "readiness_message" => "Codex reports no authenticated account."
    })

    authentication =
      call_tool!(ctx, "device.get", %{"device_id" => binding["device_id"]})

    authentication_runtime = runtime!(authentication, binding)
    assert authentication_runtime["status"] == "unavailable"
    assert authentication_runtime["issue"] == "authentication_required"
    assert authentication_runtime["message"] == "Codex reports no authenticated account."
    refute inspect(authentication) =~ "last_error"
  end

  test "Router device.get drops an invalid public readiness message but keeps status and issue",
       %{tenant: tenant, group: group, router: router} do
    tenant_id = tenant["tenant_id"]
    group_id = group["group_id"]
    {connector_run_id, binding} = connect_ready_runtime!(tenant_id, group_id)
    marker = "invalid-public-readiness-marker-"

    update_runtime_readiness!(connector_run_id, %{
      "ready" => false,
      "readiness_issue" => "workspace_unavailable",
      "readiness_message" => marker <> String.duplicate("x", 301)
    })

    ctx = router_tool_context(tenant_id, group_id, router["agent_id"])
    device = call_tool!(ctx, "device.get", %{"device_id" => binding["device_id"]})
    runtime = runtime!(device, binding)

    assert runtime["status"] == "unavailable"
    assert runtime["issue"] == "workspace_unavailable"
    refute Map.has_key?(runtime, "message")
    refute Jason.encode!(device) =~ marker
  end

  defp connect_ready_runtime!(tenant_id, group_id) do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    transport_id = "participant-runtime-#{suffix}"
    device_id = "participant-device-#{suffix}"
    runtime_id = "codex-#{suffix}"
    binding = runtime_ref(device_id, runtime_id)
    now = SystemsClock.system_time(:millisecond)

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "participant-connector-#{suffix}",
          "name" => "Fixed worker device"
        },
        transport_id: transport_id,
        now: now
      )

    connector_run_id = record["connector_run_id"]

    {:ok, _record} =
      Registry.update_meta(
        connector_run_id,
        fn meta ->
          runtime =
            %{
              "kind" => "external",
              "provider" => "codex",
              "runtime_id" => runtime_id,
              "device_runtime_id" => binding["device_runtime_id"],
              "command" => "/usr/local/bin/codex",
              "version_detected" => true,
              "auth_ready" => true,
              "native_server_startable" => true,
              "ready" => true,
              "readiness_checked_at" => now,
              "readiness_valid_until" => now + 600_000
            }

          Map.put(meta, "agent_runtimes", [runtime])
        end,
        now: now
      )

    {connector_run_id, binding}
  end

  defp runtime_ref(device_id, runtime_id) do
    %{
      "provider" => "codex",
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" => RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
    }
  end

  defp update_runtime_readiness!(connector_run_id, overrides) do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, _record} =
             Registry.update_meta(
               connector_run_id,
               fn meta ->
                 [runtime] = meta["agent_runtimes"]

                 Map.put(
                   meta,
                   "agent_runtimes",
                   [
                     runtime
                     |> Map.merge(overrides)
                     |> Map.put("readiness_checked_at", now)
                     |> Map.put("readiness_valid_until", now + 600_000)
                   ]
                 )
               end,
               now: now
             )
  end

  defp runtime!(device, binding) do
    Enum.find(
      device["device_runtimes"],
      &(&1["device_runtime_id"] == binding["device_runtime_id"])
    )
  end

  defp create_agent_task_conversation!(group_id, router_agent_id, worker_agent_id) do
    now = SystemsClock.system_time(:millisecond)

    {:ok, conversation} =
      ConversationInput.create_group_conversation(group_id, %{
        "kind" => "agent_task",
        "title" => "Runtime diagnosis",
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router_agent_id,
            "role_label" => "delegator",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => worker_agent_id,
            "role_label" => "worker",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          }
        ],
        "created_at" => now,
        "updated_at" => now
      })

    conversation_id = conversation["conversation_id"]

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    worker = Enum.find(participants, &(&1["agent_id"] == worker_agent_id))
    participant_id = worker["participant_id"]
    session_id = get_in(worker, ["payload", "session_id"])
    assert Ids.valid_session_id?(session_id)

    {conversation_id, participant_id, session_id}
  end

  defp router_tool_context(tenant_id, group_id, agent_id) do
    assert {:ok, projection} =
             Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id})

    ctx = %{
      agent_id: agent_id,
      session_id: Ids.new_session_id(),
      tenant_id: tenant_id,
      group_id: group_id,
      role: "router",
      runtime_kind: :internal,
      plugin_projection: projection,
      llm_tool_envelope: true,
      # A round configuration context always carries the activation's admitted
      # source ids as data; this synthetic call has none.
      source_message_ids: []
    }

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("router", :internal, ctx))
  end

  defp call_tool!(ctx, tool, params) do
    result = call_tool(ctx, tool, params)
    refute result.error, result.content
    Jason.decode!(result.content)
  end

  defp call_tool(ctx, tool, params) do
    [result] =
      SessionToolDispatch.execute(
        [
          %{
            "id" => "call-#{SystemsRuntime.Proc.unique_integer([:positive])}",
            "name" => "call",
            "args" => %{"tool" => tool, "params" => params}
          }
        ],
        ctx
      )

    result
  end

  defp refute_sensitive_projection!(value, forbidden_values) do
    forbidden_keys = ~w(
      agent_runtimes command connector_id connector_run_id credential group_id identity_material
      last_error last_exec memory_path native_execution_id native_session_id node_id path
      process_instance_id process_name provision_request_id provisioner_id raw_error session_id
      session_ids session_snapshot skills system_info tenant_id unknown_private
    )

    walk = fn
      walk, map when is_map(map) ->
        Enum.each(map, fn {key, nested} ->
          refute key in forbidden_keys
          walk.(walk, nested)
        end)

      walk, list when is_list(list) ->
        Enum.each(list, &walk.(walk, &1))

      _walk, scalar ->
        refute scalar in forbidden_values
    end

    walk.(walk, value)
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
