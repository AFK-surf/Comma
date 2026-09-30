defmodule SalixWeb.ExternalRuntimeTest do
  use ExUnit.Case, async: false

  alias SalixAgent.ExternalAgentRuntime, as: ExternalRuntime
  alias SalixAgent.ExternalSessionStore
  alias SalixEnv.Registry
  alias SalixStore.{Compute, Repo, RuntimeIds, ULID}

  @session_id "ses1_1000000000000000001"

  defmodule FakeConnectorDispatch do
    def reset do
      :persistent_term.put({__MODULE__, :requests}, [])
      :persistent_term.put({__MODULE__, :stop_result}, {:ok, %{"stopped" => true}})
      :persistent_term.put({__MODULE__, :input_result}, :accepted)
    end

    def stop_result(result), do: :persistent_term.put({__MODULE__, :stop_result}, result)
    def input_result(result), do: :persistent_term.put({__MODULE__, :input_result}, result)

    def request(connector_run_id, "agent_runtime_stop", params, timeout: 6_000) do
      :persistent_term.put(
        {__MODULE__, :requests},
        requests() ++ [%{connector_run_id: connector_run_id, params: params}]
      )

      :persistent_term.get({__MODULE__, :stop_result})
    end

    def requests, do: :persistent_term.get({__MODULE__, :requests}, [])

    def request(connector_run_id, "agent_runtime_input", params) do
      :persistent_term.put(
        {__MODULE__, :requests},
        requests() ++ [%{connector_run_id: connector_run_id, params: params}]
      )

      case :persistent_term.get({__MODULE__, :input_result}) do
        :accepted ->
          {:ok,
           %{
             "accepted" => true,
             "dispatch_id" => params["dispatch_id"]
           }}

        result ->
          result
      end
    end
  end

  defmodule FakeComputeRuntimeDispatch do
    def reset, do: :persistent_term.put({__MODULE__, :result}, :accepted)
    def result(result), do: :persistent_term.put({__MODULE__, :result}, result)

    def request(_runtime_instance_id, _epoch, "agent_runtime_input", params) do
      case :persistent_term.get({__MODULE__, :result}, :accepted) do
        :accepted -> {:ok, %{"accepted" => true, "dispatch_id" => params["dispatch_id"]}}
        result -> result
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_store = Application.get_env(:salix_store, :s3_backend)

    previous_connector_dispatch =
      Application.get_env(:salix_web, :external_runtime_connector_dispatch)

    previous_compute_dispatch = Application.get_env(:salix_web, :compute_runtime_dispatch)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    FakeConnectorDispatch.reset()
    FakeComputeRuntimeDispatch.reset()

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      put_or_delete_env(:salix_store, :s3_backend, previous_store)

      put_or_delete_env(
        :salix_web,
        :external_runtime_connector_dispatch,
        previous_connector_dispatch
      )

      put_or_delete_env(:salix_web, :compute_runtime_dispatch, previous_compute_dispatch)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "External Runtime"})
    Process.put(:tenant_id, tenant["tenant_id"])

    {:ok, group} =
      Salix.Control.Groups.create(%{"name" => "External Runtime"}, tenant["tenant_id"])

    connector_run_id = connected_codex_device!(group["group_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    {:ok, group: group, connector_run_id: connector_run_id, worker: worker}
  end

  test "external runtime config is provider plus stable device runtime", context do
    assert {:ok, updated} =
             set_codex_runtime(context.worker["agent_id"], context.connector_run_id)

    assert updated["runtime_config"] == %{
             "kind" => "external",
             "provider" => "codex",
             "device_id" => device_id(context.connector_run_id),
             "runtime_id" => "runtime-codex",
             "device_runtime_id" => device_runtime_id(context.connector_run_id)
           }
  end

  test "begin creates a current dispatch capability for the exact binding", context do
    agent_id = context.worker["agent_id"]
    assert {:ok, worker} = set_codex_runtime(agent_id, context.connector_run_id)
    stage_external_input!(agent_id, @session_id, no_wake: true)

    assert {:ok, binding} =
             ExternalRuntime.begin_session(
               agent_id,
               @session_id,
               tenant_id(),
               worker["runtime_config"]
             )

    assert binding["connector_run_id"] == context.connector_run_id
    token = binding["runtime_capability"]["token"]
    assert is_binary(token)

    assert {:ok, state} = ExternalSessionStore.get_session_record(agent_id, @session_id)
    refute Map.has_key?(state["runtime"], "payload")
    assert state["runtime_capability_token"] == token

    assert state["runtime"]["binding"]["device_runtime_id"] ==
             device_runtime_id(context.connector_run_id)

    assert state["runtime_capability_token_hash"] == binding["runtime_capability"]["token_hash"]

    assert {:ok, public_session} = ExternalSessionStore.get_session(agent_id, @session_id)
    refute Map.has_key?(public_session, "runtime_capability_token")

    assert {:ok, public_sessions} = ExternalSessionStore.list_sessions(agent_id)
    refute Enum.any?(public_sessions, &Map.has_key?(&1, "runtime_capability_token"))
  end

  test "rollout sends only new Sessions to the new target while an active Session stays pinned",
       context do
    agent_id = context.worker["agent_id"]
    assert {:ok, worker} = set_codex_runtime(agent_id, context.connector_run_id)
    stage_external_input!(agent_id, @session_id, no_wake: true)

    assert {:ok, first} =
             ExternalRuntime.begin_session(
               agent_id,
               @session_id,
               tenant_id(),
               worker["runtime_config"]
             )

    replacement = connected_codex_device!(context.group["group_id"])
    assert {:ok, updated} = set_codex_runtime(agent_id, replacement)

    stage_external_input!(agent_id, @session_id, no_wake: true)

    assert {:ok, pinned} =
             ExternalRuntime.begin_session(
               agent_id,
               @session_id,
               tenant_id(),
               updated["runtime_config"]
             )

    assert pinned["stable_target_id"] == first["stable_target_id"]
    assert pinned["connector_run_id"] == context.connector_run_id
    assert pinned["runtime_capability"]["token"] == first["runtime_capability"]["token"]

    new_session_id = SalixStore.Ids.new_session_id()
    stage_external_input!(agent_id, new_session_id, no_wake: true)

    assert {:ok, new_binding} =
             ExternalRuntime.begin_session(
               agent_id,
               new_session_id,
               tenant_id(),
               updated["runtime_config"]
             )

    assert new_binding["connector_run_id"] == replacement
    refute new_binding["stable_target_id"] == first["stable_target_id"]
  end

  test "archive closes admission without waiting; stop pages each Session's original target",
       context do
    Application.put_env(:salix_web, :external_runtime_connector_dispatch, FakeConnectorDispatch)
    previous_driver = Application.get_env(:salix_agent, :external_runtime_driver)

    Application.put_env(
      :salix_agent,
      :external_runtime_driver,
      SalixWeb.ExternalRuntime.ExternalWorkerDriver
    )

    on_exit(fn -> put_or_delete_env(:salix_agent, :external_runtime_driver, previous_driver) end)
    id = context.worker["agent_id"]
    {:ok, worker} = set_codex_runtime(id, context.connector_run_id)

    sessions =
      for _ <- 1..5 do
        session_id = SalixStore.Ids.new_session_id()
        stage_external_input!(id, session_id, no_wake: true)

        assert {:ok, _} =
                 ExternalRuntime.begin_session(
                   id,
                   session_id,
                   tenant_id(),
                   worker["runtime_config"]
                 )

        session_id
      end

    replacement = connected_codex_device!(context.group["group_id"])
    assert {:ok, _} = set_codex_runtime(id, replacement)

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => context.group["group_id"], "name" => "Router", "role" => "router"},
        tenant_id()
      )

    ctx = %{
      agent_id: router["agent_id"],
      session_id: router["router_session_id"],
      tool_call_id: "archive"
    }

    archive = fn ->
      SalixAgent.AgentManagement.run(:archive, %{"agent_id" => id, "user_confirmed" => true}, ctx)
    end

    FakeConnectorDispatch.stop_result({:error, :disconnected})
    assert {:ok, _} = archive.()
    assert FakeConnectorDispatch.requests() == []

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.Control.ensure_not_stopped(id)

    assert {:error, :disconnected} = SalixAgent.Control.stop(id, tenant_id())
    FakeConnectorDispatch.stop_result({:ok, %{"stopped" => true}})

    final_cursor =
      Enum.reduce_while(1..10, nil, fn _, cursor ->
        before = length(FakeConnectorDispatch.requests())

        assert {:ok, %{next_cursor: next}} =
                 SalixAgent.Control.stop(id, tenant_id(), cursor: cursor)

        assert length(FakeConnectorDispatch.requests()) - before <= 2
        if is_nil(next), do: {:halt, nil}, else: {:cont, next}
      end)

    assert final_cursor == nil
    assert {:ok, archived} = SalixAgent.Control.get(id)
    assert SalixAgent.Control.permanently_archived?(archived)
    refute Map.has_key?(archived, "runtime_shutdown")
    requests = FakeConnectorDispatch.requests()
    assert Enum.all?(requests, &(&1.connector_run_id == context.connector_run_id))
    assert MapSet.new(Enum.map(requests, & &1.params["session_id"])) == MapSet.new(sessions)

    for session <- sessions do
      assert {:ok, _history} = ExternalSessionStore.get_session_record(id, session)
    end
  end

  test "server transport forwards one input batch and accepts the Connector commit", context do
    Application.put_env(
      :salix_web,
      :external_runtime_connector_dispatch,
      FakeConnectorDispatch
    )

    request = %{
      agent_id: context.worker["agent_id"],
      session_id: @session_id,
      dispatch_id: "dispatch-test",
      binding: %{
        "kind" => "connected_runtime",
        "provider" => "codex",
        "connector_run_id" => context.connector_run_id,
        "command" => "/usr/bin/codex",
        "runtime_capability" => %{"token" => "capability"}
      },
      system_prompt: "prompt",
      input_messages: [
        %{
          "id" => "pending",
          "role" => "user",
          "content" => "run",
          "trusted_origin" => %{"provider" => "internal"},
          "trusted_origin_source_message_ids" => ["source-message"]
        }
      ]
    }

    assert {:accepted, %{"dispatch_id" => "dispatch-test"}} =
             SalixWeb.ExternalRuntime.ConnectedRuntimeDriver.run(request)

    assert [%{connector_run_id: connector_run_id, params: params}] =
             FakeConnectorDispatch.requests()

    assert connector_run_id == context.connector_run_id
    assert params["kind"] == "external"
    assert params["provider"] == "codex"
    refute Map.has_key?(params, "runtime_payload")
    assert params["dispatch_id"] == request.dispatch_id

    assert params["input_messages"] == [
             %{"id" => "pending", "role" => "user", "content" => "run"}
           ]

    refute get_in(params, ["input_messages", Access.at(0), "trusted_origin"])

    refute get_in(params, [
             "input_messages",
             Access.at(0),
             "trusted_origin_source_message_ids"
           ])

    refute Map.has_key?(params, "message_tools")

    assert params["runtime_config"] == %{"command" => "/usr/bin/codex"}
  end

  test "connector events append SessionRecords", context do
    agent_id = context.worker["agent_id"]
    assert {:ok, worker} = set_codex_runtime(agent_id, context.connector_run_id)
    stage_external_input!(agent_id, @session_id, no_wake: true)

    assert {:ok, first} =
             ExternalRuntime.begin_session(
               agent_id,
               @session_id,
               tenant_id(),
               worker["runtime_config"]
             )

    event_id = ULID.generate()
    executed_at = System.system_time(:second) - 10

    params = %{
      "event_id" => event_id,
      "capability_token" => first["runtime_capability"]["token"],
      "event" => %{
        "type" => "status",
        "provider" => "codex",
        "name" => "turn/started",
        "state" => "running",
        "created_at" => executed_at,
        "native" => %{"method" => "turn/started"}
      }
    }

    assert {:error, {:bad_request, "event_id requires a valid ULID and integer event.created_at"}} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               context.connector_run_id,
               Map.delete(params, "event_id"),
               %{"tenant_id" => tenant_id(), "group_id" => context.group["group_id"]}
             )

    assert {:ok, %{"ok" => true}} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               context.connector_run_id,
               params,
               %{
                 "tenant_id" => tenant_id(),
                 "group_id" => context.group["group_id"]
               }
             )

    assert {:ok, %{"ok" => true}} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               context.connector_run_id,
               params,
               %{"tenant_id" => tenant_id(), "group_id" => context.group["group_id"]}
             )

    reconnected_run_id =
      connect_codex_device!(context.group["group_id"], device_id(context.connector_run_id))

    refute reconnected_run_id == context.connector_run_id

    assert {:error, :stale_connector_transport_generation} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               context.connector_run_id,
               Map.put(params, "event_id", ULID.generate()),
               %{"tenant_id" => tenant_id(), "group_id" => context.group["group_id"]}
             )

    assert {:ok, %{"ok" => true}} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               reconnected_run_id,
               params,
               %{"tenant_id" => tenant_id(), "group_id" => context.group["group_id"]}
             )

    assert {:error, :external_session_record_conflict} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               reconnected_run_id,
               put_in(params, ["event", "state"], "stopped"),
               %{"tenant_id" => tenant_id(), "group_id" => context.group["group_id"]}
             )

    assert {:ok,
            %{
              "records" => [
                %{
                  "id" => ^event_id,
                  "created_at" => ^executed_at,
                  "type" => "runtime.event",
                  "data" => data
                }
              ]
            }} =
             ExternalSessionStore.session_records(%{"agent_id" => agent_id}, @session_id,
               limit: 10
             )

    assert data["event"] == params["event"]

    assert {:ok, resumed} =
             ExternalRuntime.begin_session(
               agent_id,
               @session_id,
               tenant_id(),
               worker["runtime_config"]
             )

    assert resumed["connector_run_id"] == reconnected_run_id
    assert resumed["stable_target_id"] == first["stable_target_id"]
    assert resumed["runtime_capability"]["token"] == first["runtime_capability"]["token"]

    assert {:ok, _capability} =
             ExternalSessionStore.validate_runtime_capability(
               first["runtime_capability"]["token"]
             )
  end

  test "a caught-up Compute epoch rotates the session capability", context do
    runtime_config = compute_runtime!(context.group["group_id"])

    {:ok, worker} =
      SalixAgent.Control.create_preallocated(
        %{
          "group_id" => context.group["group_id"],
          "name" => "Compute worker",
          "role" => "worker",
          "runtime_config" => runtime_config
        },
        tenant_id(),
        SalixStore.Ids.new_agent_id(context.group["group_id"])
      )

    session_id = SalixStore.Ids.new_session_id()
    stage_external_input!(worker["agent_id"], session_id, no_wake: true)

    assert {:ok, first} =
             ExternalRuntime.begin_session(
               worker["agent_id"],
               session_id,
               tenant_id(),
               runtime_config
             )

    runtime = Repo.get_by!(Compute.RuntimeInstance, workload_id: runtime_config["workload_id"])

    assert {:ok, reconnecting} =
             Compute.observe_runtime(%{
               id: runtime.id,
               workload_id: runtime.workload_id,
               allocation_id: runtime.allocation_id,
               generation: runtime.generation,
               connection_epoch: "2"
             })

    assert {:ok, _runtime} =
             Compute.complete_runtime_catch_up(reconnecting.id, reconnecting.revision, "2")

    stage_external_input!(worker["agent_id"], session_id, no_wake: true)

    assert {:ok, resumed} =
             ExternalRuntime.begin_session(
               worker["agent_id"],
               session_id,
               tenant_id(),
               runtime_config
             )

    assert resumed["runtime_capability"]["connection_epoch"] == "2"
    refute resumed["runtime_capability"]["token"] == first["runtime_capability"]["token"]

    assert {:error, :unauthorized} =
             ExternalSessionStore.validate_runtime_capability(
               first["runtime_capability"]["token"]
             )
  end

  test "ComputeRuntimeDriver leaves execution ownership to the authenticated compute carrier",
       context do
    Application.put_env(:salix_web, :compute_runtime_dispatch, FakeComputeRuntimeDispatch)
    runtime_config = compute_runtime!(context.group["group_id"], "claude")

    {:ok, worker} =
      SalixAgent.Control.create_preallocated(
        %{
          "group_id" => context.group["group_id"],
          "name" => "Compute dispatcher worker",
          "role" => "worker",
          "runtime_config" => runtime_config
        },
        tenant_id(),
        SalixStore.Ids.new_agent_id(context.group["group_id"])
      )

    session_id = SalixStore.Ids.new_session_id()
    stage_external_input!(worker["agent_id"], session_id, no_wake: true)

    assert {:ok, binding} =
             ExternalRuntime.begin_session(
               worker["agent_id"],
               session_id,
               tenant_id(),
               runtime_config
             )

    request = %{
      agent_id: worker["agent_id"],
      session_id: session_id,
      dispatch_id: "compute-dispatch",
      binding: binding,
      system_prompt: "prompt",
      input_messages: [%{"id" => "message-1", "role" => "user", "content" => "run"}]
    }

    assert {:accepted, %{"dispatch_id" => "compute-dispatch"}} =
             SalixWeb.ExternalRuntime.ComputeRuntimeDriver.run(request)

    FakeComputeRuntimeDispatch.result({:error, :timeout})

    assert {:error, :timeout} = SalixWeb.ExternalRuntime.ComputeRuntimeDriver.run(request)

    assert {:ok, %{"ok" => true}} =
             SalixWeb.ExternalRuntime.handle_connector_event(
               nil,
               %{
                 "event_id" => ULID.generate(),
                 "capability_token" => binding["runtime_capability"]["token"],
                 "event" => %{
                   "type" => "status",
                   "provider" => "claude",
                   "name" => "result",
                   "state" => "completed",
                   "work_state" => "settled",
                   "dispatch_id" => "compute-dispatch",
                   "execution_id" => "execution-1",
                   "created_at" => System.system_time(:second)
                 }
               },
               %{"tenant_id" => tenant_id()}
             )
  end

  defp set_codex_runtime(agent_id, connector_run_id) do
    SalixAgent.Control.configure(agent_id, %{
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => device_id(connector_run_id),
        "runtime_id" => "runtime-codex",
        "device_runtime_id" => device_runtime_id(connector_run_id)
      }
    })
  end

  defp stage_external_input!(agent_id, session_id, opts) do
    assert {:ok, :external} =
             ExternalRuntime.stage_delivery(agent_id, %{
               source_message_id: "source-#{System.unique_integer([:positive])}",
               payload: %{
                 "session_id" => session_id,
                 "content" => "new input",
                 "role" => "user",
                 "no_wake" => Keyword.get(opts, :no_wake, false)
               }
             })
  end

  defp connected_codex_device!(group_id) do
    transport_id = "external-runtime-#{System.unique_integer([:positive])}"
    connect_codex_device!(group_id, "device-" <> transport_id)
  end

  defp connect_codex_device!(group_id, stable_device_id) do
    transport_id = "external-runtime-#{System.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => stable_device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Mac Studio"
        },
        transport_id: transport_id
      )

    connector_run_id = record["connector_run_id"]

    {:ok, _record} =
      Registry.update_meta(connector_run_id, fn meta ->
        Map.put(meta, "agent_runtimes", [
          %{
            "kind" => "external",
            "provider" => "codex",
            "runtime_id" => "runtime-codex",
            "device_runtime_id" =>
              RuntimeIds.device_runtime_id(stable_device_id, "codex", "runtime-codex"),
            "command" => "/usr/local/bin/codex",
            "version" => "codex-test",
            "version_detected" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "ready" => true,
            "readiness_checked_at" => System.system_time(:millisecond),
            "readiness_valid_until" => System.system_time(:millisecond) + 600_000
          }
        ])
      end)

    connector_run_id
  end

  defp compute_runtime!(group_id, provider \\ "codex") do
    suffix = System.unique_integer([:positive, :monotonic])
    prefix = "external-runtime-#{suffix}"

    {:ok, pool} =
      Compute.create_pool(%{
        id: prefix <> "-pool",
        tenant_id: tenant_id(),
        name: "External runtime",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: prefix <> "-environment",
        tenant_id: tenant_id(),
        owner_type: "project",
        owner_id: group_id,
        pool_id: pool.id
      })

    {:ok, provider_binding} =
      Compute.create_provider_binding(%{
        id: prefix <> "-binding",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: prefix <> "-private-ref"
      })

    {:ok, allocation} =
      Compute.allocate(%{
        id: prefix <> "-allocation",
        environment_id: environment.id,
        provider_binding_id: provider_binding.id,
        generation: 1
      })

    container_id =
      :crypto.hash(:sha256, prefix <> "-workload:1")
      |> Base.encode16(case: :lower)
      |> then(&("salix-" <> binary_part(&1, 0, 32)))

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded", %{
        "current_container" => %{"id" => container_id, "instance_id" => prefix <> "-instance"},
        "container_status" => "running"
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: prefix <> "-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: 1
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: prefix <> "-runtime",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {:ok, _runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")

    %{
      "kind" => "compute_workload",
      "workload_id" => workload.id,
      "runtime_spec" => %{"provider" => provider}
    }
  end

  defp device_id(connector_run_id) do
    {:ok, _transport_id, device} = Registry.get_by_connector_run_id(connector_run_id)
    device["device_id"]
  end

  defp device_runtime_id(connector_run_id),
    do: RuntimeIds.device_runtime_id(device_id(connector_run_id), "codex", "runtime-codex")

  defp tenant_id, do: Process.get(:tenant_id) || raise("test tenant is not configured")

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
