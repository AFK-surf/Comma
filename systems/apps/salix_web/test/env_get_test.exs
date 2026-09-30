defmodule SalixWeb.EnvGetTest do
  use ExUnit.Case, async: false

  alias Salix.Control.{Groups, Tenants}
  alias SalixEnv.{Control, Registry}
  alias SalixStore.{Ids, Keys, RuntimeIds, S3}
  alias SalixWeb.EnvDispatch

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous)
    end)

    {:ok, tenant} = Tenants.create(%{"name" => "device.get test"})
    {:ok, group} = Groups.create(%{"name" => "device.get test"}, tenant["tenant_id"])

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Router", "role" => "router"},
        tenant["tenant_id"]
      )

    {:ok, tenant_id: tenant["tenant_id"], group_id: group["group_id"], agent: agent}
  end

  test "exact public device read projects canonical runtime availability without listing", ctx do
    now = System.system_time(:millisecond)
    {connector_run_id, binding} = connect_runtime!(ctx.tenant_id, ctx.group_id, now)
    device_key = Keys.ctl_group_device(ctx.tenant_id, ctx.group_id, binding["device_id"])

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, ready} = EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])
    assert ready["status"] == "connected"
    assert runtime!(ready, binding)["status"] == "ready"

    assert ready["capabilities"] == %{
             "component_releases" => %{
               "salix-connect" => %{"release_id" => "salix-connect-test"}
             },
             "component_versions" => %{"salix-connect" => "salix-connect-test"},
             "execution_boundary" => "connector-direct",
             "host_access_required" => true,
             "runtime_probe" => true
           }

    configured_environment =
      Enum.find(ready["environments"], &(&1["environment_provider"] == "sandbox"))

    assert configured_environment == %{
             "capabilities" => %{"persistent_processes" => true},
             "description" => "Public workspace",
             "device_id" => binding["device_id"],
             "environment_id" => configured_environment["environment_id"],
             "environment_provider" => "sandbox",
             "environment_runtime_id" => "workspace",
             "name" => "Workspace",
             "path_semantics" => "sandbox workspace",
             "requires_permission" => true,
             "risk" => "sandbox",
             "shares_user_files" => false
           }

    assert ready["connector_health"] == %{
             "request_capacity" => 8,
             "request_inflight" => 0,
             "schema_version" => 1
           }

    assert Enum.any?(SalixStore.S3.Fake.read_log(self()), &(&1 == {:get, device_key}))
    refute Enum.any?(SalixStore.S3.Fake.read_log(self()), &match?({:list, _, _}, &1))
    refute_private_fields(ready)

    update_runtime!(connector_run_id, binding, now + 1, %{"auth_ready" => false})

    assert {:ok, unavailable} =
             EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])

    assert runtime!(unavailable, binding)["status"] == "unavailable"
    assert runtime!(unavailable, binding)["issue"] == "authentication_required"

    update_runtime!(connector_run_id, binding, now + 2, %{"readiness_valid_until" => now - 1})
    assert {:ok, stale} = EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])
    assert runtime!(stale, binding)["status"] == "stale"
    assert runtime!(stale, binding)["issue"] == "readiness_expired"

    assert {:ok, _device} =
             Registry.update_meta(
               connector_run_id,
               &Map.put(&1, "agent_runtimes", []),
               now: now + 3
             )

    assert {:ok, current_only} =
             EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])

    refute Enum.any?(
             current_only["device_runtimes"],
             &(&1["device_runtime_id"] == binding["device_runtime_id"])
           )

    refute Enum.any?(current_only["device_runtimes"], fn runtime ->
             runtime["status"] == "missing" or runtime["issue"] == "runtime_not_found"
           end)

    update_runtime!(connector_run_id, binding, now + 4, %{})
    assert {:ok, _device} = Registry.mark_disconnected(connector_run_id)

    assert {:ok, disconnected} =
             EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])

    assert disconnected["status"] == "disconnected"
    assert runtime!(disconnected, binding)["status"] == "disconnected"
    assert runtime!(disconnected, binding)["issue"] == "connector_disconnected"
  end

  test "a disconnected Cloudflare device does not expose private Workload data",
       ctx do
    {run, binding} =
      connect_runtime!(ctx.tenant_id, ctx.group_id, System.system_time(:millisecond))

    {:ok, _} = Registry.mark_disconnected(run)

    record = %{
      "tenant_id" => ctx.tenant_id,
      "group_id" => ctx.group_id,
      "device_id" => binding["device_id"],
      "env_id" => "idle-vm-test",
      "connector_id" => "idle-vm-connector",
      "provider_resource_name" => "idle-vm-test",
      "provider" => "cloudflare",
      "runtime_connector" => true,
      "status" => "ready",
      "runtime_idle" => true,
      "private_token" => "must-not-leak"
    }

    assert {:ok, _, :created} = SalixStore.Compute.ensure_group_workload(record)
    assert {:ok, idle} = EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])
    assert idle["status"] == "disconnected"
    refute Map.has_key?(idle, "cloud_vm")
    refute inspect(idle) =~ "must-not-leak"
    refute_private_fields(idle)

    assert {:error, :identity_mismatch} =
             SalixStore.Compute.update_group_workload(ctx.group_id, fn current ->
               Map.put(current, "tenant_id", Ids.new_tenant_id())
             end)

    for identity <- [%{"device_id" => Ids.new_device_id()}, %{"provider" => "agent_vmm"}] do
      assert {:error, :identity_mismatch} =
               SalixStore.Compute.update_group_workload(ctx.group_id, &Map.merge(&1, identity))
    end

    for mismatch <- [
          %{"runtime_connector" => false},
          %{"status" => "failed"},
          %{"runtime_idle" => false}
        ] do
      assert {:ok, _, _} =
               SalixStore.Compute.update_group_workload(ctx.group_id, fn _ ->
                 Map.merge(record, mismatch)
               end)

      assert {:ok, disconnected} =
               EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])

      assert disconnected["status"] == "disconnected"
      refute Map.has_key?(disconnected, "cloud_vm")
    end
  end

  test "SalixEnv owns one recursively typed public device DTO for exact, list, HTTP, and device.get",
       ctx do
    now = System.system_time(:millisecond)
    binding = connect_public_dto_boundary_fixture!(ctx.tenant_id, ctx.group_id, now)

    assert {:ok, exact} =
             Control.get_environment(binding.device_id, ctx.group_id, ctx.tenant_id)

    assert {:ok, listed} = Control.list_group_environments(ctx.group_id, ctx.tenant_id)
    assert Enum.find(listed, &(&1["device_id"] == binding.device_id)) == exact

    assert exact["capabilities"] == %{
             "component_releases" => %{
               "salix-connect" => %{"release_id" => "public-release"}
             },
             "component_versions" => %{"salix-connect" => "1.2.3"},
             "runtime_probe" => true
           }

    assert exact["connector_health"] == %{
             "request_inflight" => 2,
             "schema_version" => 1
           }

    refute Map.has_key?(exact, "alias")
    refute Map.has_key?(exact, "arch")
    refute Map.has_key?(exact, "agent_runtimes")

    configured_environment =
      Enum.find(
        exact["environments"],
        &(&1["environment_provider"] == "sandbox" and
            &1["environment_runtime_id"] == "workspace")
      )

    assert configured_environment["capabilities"] == %{"persistent_processes" => true}
    refute Map.has_key?(configured_environment, "name")
    refute Map.has_key?(configured_environment, "description")
    refute Map.has_key?(configured_environment, "path_semantics")
    refute Map.has_key?(configured_environment, "risk")
    refute Map.has_key?(configured_environment, "shares_user_files")
    refute Map.has_key?(configured_environment, "requires_permission")

    runtime =
      Enum.find(
        exact["device_runtimes"],
        &(&1["device_runtime_id"] == binding.device_runtime_id)
      )

    assert runtime["status"] == "ready"
    assert runtime["version"] == "1.2.3"
    refute Map.has_key?(runtime, "model")
    refute Map.has_key?(runtime, "model_provider")
    refute Map.has_key?(runtime, "reasoning_effort")

    assert {:ok, env_get} = EnvDispatch.get_device(ctx.agent["agent_id"], binding.device_id)
    assert Map.take(exact, Map.keys(env_get)) == env_get

    {:ok, api_key} = Tenants.create_api_key(ctx.tenant_id, %{"name" => "public DTO test"})

    http =
      Plug.Test.conn(
        :get,
        "/v1/runtime/groups/#{ctx.group_id}/environments/#{binding.device_id}"
      )
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> api_key["key"])
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert http.status == 200
    assert Jason.decode!(http.resp_body) == exact

    refute_private_dto_values(exact)
    refute_private_dto_values(env_get)
  end

  test "a reserved device has canonical metadata and is readable before connecting", ctx do
    device_id = Ids.new_device_id()

    assert {:ok, _generation, reserved, _reservation} =
             Registry.reserve_connector_credential(
               ctx.tenant_id,
               ctx.group_id,
               device_id,
               "pending-connector",
               nil,
               %{"name" => "Pending laptop", "device_id" => Ids.new_device_id()}
             )

    assert reserved["meta"]["tenant_id"] == ctx.tenant_id
    assert reserved["meta"]["group_id"] == ctx.group_id
    assert reserved["meta"]["device_id"] == device_id
    assert {:ok, device} = EnvDispatch.get_device(ctx.agent["agent_id"], device_id)
    assert device["name"] == "Pending laptop"
    assert device["status"] == "disconnected"
    assert device["environments"] == []
  end

  test "missing, cross-scope, mismatched, and failed exact device reads do not fall back", ctx do
    now = System.system_time(:millisecond)
    {_connector_run_id, binding} = connect_runtime!(ctx.tenant_id, ctx.group_id, now)
    missing_device_id = Ids.new_device_id()

    assert {:error, :not_found} = EnvDispatch.get_device(ctx.agent["agent_id"], missing_device_id)

    {:ok, other_group} = Groups.create(%{"name" => "Other"}, ctx.tenant_id)

    {:ok, other_agent} =
      SalixAgent.Control.create(
        %{"group_id" => other_group["group_id"], "name" => "Other", "role" => "router"},
        ctx.tenant_id
      )

    SalixStore.S3.Fake.reset_read_log()

    assert {:error, :not_found} =
             EnvDispatch.get_device(other_agent["agent_id"], binding["device_id"])

    refute Enum.any?(SalixStore.S3.Fake.read_log(self()), &match?({:list, _, _}, &1))

    device_key = Keys.ctl_group_device(ctx.tenant_id, ctx.group_id, binding["device_id"])
    assert {:ok, %{body: body, etag: etag}} = S3.get(device_key)
    device = Jason.decode!(body)
    corrupt = put_in(device, ["meta", "device_id"], Ids.new_device_id())
    assert {:ok, _} = S3.put(device_key, Jason.encode!(corrupt), if_match: etag)

    assert {:error, :not_found} =
             EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])

    assert {:ok, %{etag: corrupt_etag}} = S3.get(device_key)
    assert {:ok, _} = S3.put(device_key, Jason.encode!(device), if_match: corrupt_etag)
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :get, device_key})

    assert {:error, {:http, 503}} =
             EnvDispatch.get_device(ctx.agent["agent_id"], binding["device_id"])
  end

  defp connect_runtime!(tenant_id, group_id, now) do
    device_id = Ids.new_device_id()
    runtime_id = "codex-default"

    binding = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" => RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
    }

    {:ok, _transport_id, device} =
      Registry.connect(
        "private-node",
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "private-connector",
          "name" => "Developer laptop",
          "os" => "darwin",
          "arch" => "arm64",
          "description" => "Public device",
          "skills" => [%{"name" => "private-skill"}],
          "system_info" => %{"hostname" => "private-hostname"},
          "provision_request_id" => "private-provision-request",
          "provisioner_id" => "private-provisioner",
          "unknown_private" => "private-top-level",
          "capabilities" => %{
            "component_releases" => %{
              "private-component" => %{
                "credential" => "private-component-credential",
                "release_id" => "private-component-release"
              },
              "salix-connect" => %{
                "commit" => %{"credential" => "private-commit-credential"},
                "credential" => "private-release-credential",
                "release_id" => "salix-connect-test"
              }
            },
            "component_versions" => %{
              "private-component" => "private-component-version",
              "salix-connect" => "salix-connect-test"
            },
            "execution_boundary" => "connector-direct",
            "meeting_runtime" => %{"credential" => "private-meeting-credential"},
            "persistent_processes" => ["private-process-capability"],
            "runtime_probe" => true,
            "host_access_required" => true,
            "unknown_private" => "private-capability",
            "agent_runtimes" => [%{"command" => "private-capability-command"}],
            "environments" => [
              %{
                "environment_provider" => "sandbox",
                "environment_runtime_id" => "workspace",
                "name" => "Workspace",
                "description" => "Public workspace",
                "path_semantics" => "sandbox workspace",
                "capabilities" => %{
                  "computer_use_tool" => %{"credential" => "private-tool-credential"},
                  "persistent_processes" => true,
                  "unknown_private" => "private-nested-capability",
                  "agent_runtimes" => [%{"command" => "private-nested-runtime-command"}]
                },
                "risk" => "sandbox",
                "shares_user_files" => false,
                "requires_permission" => true,
                "command" => "private-environment-command",
                "path" => "/private/environment/path",
                "memory_path" => "/private/environment/memory",
                "process" => %{"pid" => 123},
                "connector_id" => "private-environment-connector",
                "unknown_private" => "private-environment"
              }
            ]
          },
          "connector_health" => %{
            "schema_version" => 1,
            "request_inflight" => 0,
            "request_capacity" => 8,
            "unknown_private" => "private-health",
            "process" => %{"pid" => 456},
            "last_error" => "private-health-error"
          }
        },
        transport_id: "env-get-#{System.unique_integer([:positive])}",
        process_instance_id: "private-process-instance",
        now: now
      )

    update_runtime!(
      device["connector_run_id"],
      binding,
      now,
      %{},
      device["connection_generation"]
    )

    {device["connector_run_id"], binding}
  end

  defp connect_public_dto_boundary_fixture!(tenant_id, group_id, now) do
    device_id = Ids.new_device_id()
    runtime_id = "codex-public-dto"
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)

    {:ok, _transport_id, _device} =
      Registry.connect(
        "private-dto-node",
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "private-dto-connector",
          "name" => "Typed device",
          "description" => "Public description",
          "alias" => %{"credential" => "private-device-alias"},
          "os" => "darwin",
          "arch" => ["private-device-arch"],
          "capabilities" => %{
            "component_releases" => %{
              "private-component" => %{"credential" => "private-component-release"},
              "salix-connect" => %{
                "release_id" => "public-release",
                "commit" => %{"credential" => "private-release-commit"}
              }
            },
            "component_versions" => %{
              "private-component" => %{"credential" => "private-component-version"},
              "salix-connect" => "1.2.3"
            },
            "runtime_probe" => true,
            "meeting_runtime" => %{"credential" => "private-meeting-runtime"},
            "persistent_processes" => ["private-process-capability"],
            "environments" => [
              %{
                "environment_provider" => "sandbox",
                "environment_runtime_id" => "workspace",
                "alias" => "workspace",
                "name" => %{"credential" => "private-environment-name"},
                "description" => ["private-environment-description"],
                "path_semantics" => %{"credential" => "private-environment-path"},
                "risk" => ["private-environment-risk"],
                "shares_user_files" => %{"credential" => "private-environment-sharing"},
                "requires_permission" => ["private-environment-permission"],
                "capabilities" => %{
                  "persistent_processes" => true,
                  "computer_use_tool" => %{"credential" => "private-environment-tool"}
                }
              }
            ]
          },
          "connector_health" => %{
            "schema_version" => 1,
            "request_inflight" => 2,
            "request_capacity" => %{"credential" => "private-health-capacity"},
            "observed_at" => ["private-health-observation"],
            "unknown_private" => %{"credential" => "private-health-unknown"}
          },
          "agent_runtimes" => [
            %{
              "kind" => "external",
              "provider" => "codex",
              "runtime_id" => runtime_id,
              "device_runtime_id" => device_runtime_id,
              "identity_material" => "/private/bin/codex",
              "command" => "/private/bin/codex",
              "version" => "1.2.3",
              "model" => %{"credential" => "private-runtime-model"},
              "model_provider" => ["private-runtime-model-provider"],
              "reasoning_effort" => %{"credential" => "private-runtime-reasoning"},
              "unknown_private" => %{"credential" => "private-runtime-unknown"},
              "version_detected" => true,
              "auth_ready" => true,
              "native_server_startable" => true,
              "ready" => true,
              "readiness_checked_at" => now,
              "readiness_valid_until" => now + 600_000
            }
          ]
        },
        transport_id: "public-dto-#{System.unique_integer([:positive])}",
        process_instance_id: "private-dto-process",
        now: now
      )

    %{device_id: device_id, device_runtime_id: device_runtime_id}
  end

  defp update_runtime!(connector_run_id, binding, now, overrides, generation \\ nil) do
    runtime =
      Map.merge(
        %{
          "kind" => "external",
          "provider" => binding["provider"],
          "runtime_id" => binding["runtime_id"],
          "device_runtime_id" => binding["device_runtime_id"],
          "command" => "/private/bin/codex",
          "identity_material" => "private-native-id",
          "last_error" => "private raw provider error",
          "session_snapshot" => %{"session_ids" => ["private-session"]},
          "native_session_id" => "private-native-session",
          "native_execution_id" => "private-native-execution",
          "unknown_private" => %{"credential" => "private-runtime-credential"},
          "version_detected" => true,
          "auth_ready" => true,
          "native_server_startable" => true,
          "ready" => true,
          "readiness_checked_at" => now,
          "readiness_valid_until" => now + 600_000
        },
        overrides
      )

    assert {:ok, _device} =
             Registry.update_meta(
               connector_run_id,
               fn meta ->
                 meta = Map.put(meta, "agent_runtimes", [runtime])

                 if generation do
                   Map.put(meta, "runtime_session_snapshot_generation", generation)
                 else
                   meta
                 end
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

  defp refute_private_fields(device) do
    forbidden_keys = ~w(
      agent_runtimes command connector_id connector_run_id credential group_id identity_material
      last_error last_exec memory_path native_execution_id native_session_id node_id path process
      process_instance_id provision_request_id provisioner_id raw_error session_ids
      session_snapshot skills system_info tenant_id unknown_private
    )

    forbidden_values = [
      "private-node",
      "private-connector",
      "private-process-instance",
      "private-top-level",
      "private-capability",
      "private-capability-command",
      "private-nested-capability",
      "private-nested-runtime-command",
      "private-environment-command",
      "/private/environment/path",
      "/private/environment/memory",
      "private-environment-connector",
      "private-environment",
      "private-component-credential",
      "private-component-release",
      "private-component-version",
      "private-commit-credential",
      "private-health",
      "private-health-error",
      "/private/bin/codex",
      "private-native-id",
      "private-native-session",
      "private-native-execution",
      "private-runtime-credential",
      "private raw provider error",
      "private-meeting-credential",
      "private-process-capability",
      "private-release-credential",
      "private-tool-credential",
      "private-session",
      "private-provision-request",
      "private-provisioner",
      "private-hostname",
      "private-skill"
    ]

    walk = fn
      walk, map when is_map(map) ->
        Enum.each(map, fn {key, value} ->
          refute key in forbidden_keys
          walk.(walk, value)
        end)

      walk, list when is_list(list) ->
        Enum.each(list, &walk.(walk, &1))

      _walk, scalar ->
        refute scalar in forbidden_values
    end

    walk.(walk, device)
  end

  defp refute_private_dto_values(value) do
    forbidden_values = ~w(
      private-component-release private-component-version private-device-alias
      private-device-arch private-environment-description private-environment-name
      private-environment-path private-environment-permission private-environment-risk
      private-environment-sharing private-environment-tool private-health-capacity
      private-health-observation private-health-unknown private-meeting-runtime
      private-process-capability private-release-commit private-runtime-model
      private-runtime-model-provider private-runtime-reasoning private-runtime-unknown
    )

    walk = fn
      walk, map when is_map(map) ->
        Enum.each(map, fn {key, nested} ->
          refute key in ["credential", "unknown_private"]
          walk.(walk, nested)
        end)

      walk, list when is_list(list) ->
        Enum.each(list, &walk.(walk, &1))

      _walk, scalar ->
        refute scalar in forbidden_values
    end

    walk.(walk, value)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
