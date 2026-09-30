defmodule SalixStore.AgentVMMHostClientTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias SalixStore.{AgentVMM, AgentVMMHostClient, Compute, Repo}

  defmodule HTTP do
    def post(url, body) do
      send(Application.fetch_env!(:salix_store, :agent_vmm_host_client_test_pid), {
        :host_request,
        url,
        body
      })

      case Application.get_env(:salix_store, :agent_vmm_host_client_test_result) do
        {:error, _} = error ->
          error

        _ ->
          successful_post(url, body)
      end
    end

    defp successful_post(url, body) do
      case String.ends_with?(url, "/compute.exec") do
        true ->
          {:ok, %{"outcome" => "succeeded", "exit_code" => 0}}

        false ->
          if is_binary(body["path"]) do
            {:ok, %{"path" => body["path"], "kind" => "WORKSPACE_ENTRY_KIND_FILE"}}
          else
            {:ok, %{"outcome" => "succeeded"}}
          end
      end
    end

    def post_import(url, headers) do
      send(Application.fetch_env!(:salix_store, :agent_vmm_host_client_test_pid), {
        :host_import_request,
        url,
        headers
      })

      case Application.get_env(:salix_store, :agent_vmm_host_client_test_result) do
        :stream_stale -> {:error, :stale_session}
        _ -> {:ok, %{"reference" => elem(List.keyfind(headers, "x-comma-image-reference", 0), 1)}}
      end
    end
  end

  defmodule GatewayErrorHTTP do
    import Plug.Conn

    def init(options), do: options

    def call(conn, _options) do
      body =
        Application.get_env(:salix_store, :agent_vmm_gateway_error_body, %{
          "code" => "resource_capacity_exhausted",
          "stage" => "import_admission",
          "resource" => "storage_headroom",
          "message" => "Guest storage headroom is unavailable.",
          "available_bytes" => 1_073_741_824,
          "required_bytes" => 2_147_483_648,
          "ignored" => "not part of the contract"
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(body))
    end
  end

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_sessions, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    previous = %{
      instances: Application.get_env(:salix_store, :agent_vmm_gateway_instances),
      template: Application.get_env(:salix_store, :agent_vmm_gateway_url_template),
      client: Application.get_env(:salix_store, :agent_vmm_host_http_client),
      pid: Application.get_env(:salix_store, :agent_vmm_host_client_test_pid),
      result: Application.get_env(:salix_store, :agent_vmm_host_client_test_result),
      gateway_error_body: Application.get_env(:salix_store, :agent_vmm_gateway_error_body)
    }

    Application.put_env(:salix_store, :agent_vmm_gateway_instances, %{
      "gateway-a" => "https://gateway.internal"
    })

    Application.put_env(:salix_store, :agent_vmm_host_http_client, HTTP)
    Application.put_env(:salix_store, :agent_vmm_host_client_test_pid, self())
    Application.delete_env(:salix_store, :agent_vmm_host_client_test_result)
    Application.delete_env(:salix_store, :agent_vmm_gateway_error_body)

    on_exit(fn ->
      restore(:agent_vmm_gateway_instances, previous.instances)
      restore(:agent_vmm_gateway_url_template, previous.template)
      restore(:agent_vmm_host_http_client, previous.client)
      restore(:agent_vmm_host_client_test_pid, previous.pid)
      restore(:agent_vmm_host_client_test_result, previous.result)
      restore(:agent_vmm_gateway_error_body, previous.gateway_error_body)
    end)

    :ok
  end

  test "HTTP clients preserve import capacity and lifecycle conflict errors" do
    port =
      Enum.find_value(1..10, fn _ ->
        candidate = 40_000 + :erlang.phash2(make_ref(), 20_000)

        case start_supervised(
               {Bandit, plug: GatewayErrorHTTP, port: candidate, ip: {127, 0, 0, 1}},
               id: {:agent_vmm_gateway_error_http, candidate}
             ) do
          {:ok, _pid} -> candidate
          {:error, _reason} -> nil
        end
      end) || raise "could not bind gateway error test server"

    assert {:error,
            {:gateway_error,
             %{
               "code" => "resource_capacity_exhausted",
               "stage" => "import_admission",
               "resource" => "storage_headroom",
               "message" => "Guest storage headroom is unavailable.",
               "available_bytes" => 1_073_741_824,
               "required_bytes" => 2_147_483_648
             }}} =
             AgentVMMHostClient.HTTP.post_import("http://127.0.0.1:#{port}/import", [])

    runtime_error = %{
      "code" => "lifecycle_conflict",
      "stage" => "container_start",
      "resource" => "runtime",
      "message" => "Runtime operation was rejected."
    }

    Application.put_env(:salix_store, :agent_vmm_gateway_error_body, runtime_error)

    assert {:error, {:gateway_error, ^runtime_error}} =
             AgentVMMHostClient.HTTP.post("http://127.0.0.1:#{port}/compute.container.start", %{})

    for code <- ["stale_container_instance", "stale_execution", "workload_execution_busy"] do
      error = %{runtime_error | "code" => code, "stage" => "container_quiesce"}
      Application.put_env(:salix_store, :agent_vmm_gateway_error_body, error)

      assert {:error, {:gateway_error, ^error}} =
               AgentVMMHostClient.HTTP.post(
                 "http://127.0.0.1:#{port}/compute.container.quiesce",
                 %{}
               )
    end

    Application.put_env(:salix_store, :agent_vmm_gateway_error_body, %{
      "code" => "resource_capacity_exhausted",
      "stage" => "image_import",
      "resource" => "storage_headroom",
      "message" => "mismatched canonical fields"
    })

    assert {:error, {:gateway_status, 429}} =
             AgentVMMHostClient.HTTP.post_import("http://127.0.0.1:#{port}/import", [])
  end

  test "dispatches through the current workload, allocation, runtime, and gateway fence" do
    {:ok, _} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: String.duplicate("e", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "pool",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: "registration"
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "3",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "4",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    allocation = Repo.get!(Compute.Allocation, allocation.id)

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: 1
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "4"
      })

    assert {:ok, _runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "4")

    {:ok, allocation} =
      Compute.observe_allocation_facts(
        allocation.id,
        allocation.revision,
        1,
        %{
          "container_status" => "running",
          "current_container" => %{"id" => "main", "instance_id" => "instance-1"},
          "runtime_container_instance_id" => "instance-1",
          "runtime_execution_epoch" => "4",
          "runtime_verified_host_epoch" => "4"
        },
        []
      )

    session_expiry = DateTime.add(DateTime.utc_now(), 720, :second)
    session_expires_unix_millis = DateTime.to_unix(session_expiry, :millisecond)

    tunnel_one =
      issue_open_session_command!(
        allocation,
        workload,
        allocation.generation,
        session_expires_unix_millis
      )

    assert {:error, :stale_session} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => allocation.id,
               "allocationGeneration" => 9,
               "connectionEpoch" => "4",
               "tunnelNonce" => tunnel_one,
               "expiresUnixMillis" => session_expires_unix_millis
             })

    assert {:ok, :ok} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => allocation.id,
               "allocationGeneration" => 1,
               "connectionEpoch" => "4",
               "tunnelNonce" => tunnel_one,
               "expiresUnixMillis" => session_expires_unix_millis
             })

    assert {:ok, %{"path" => "src/main.ex"}} =
             AgentVMMHostClient.call(
               :workspace_stat,
               %{"path" => "src/main.ex"},
               workload.id
             )

    assert_receive {:host_request, first_url, %{"path" => "src/main.ex"}}

    assert first_url ==
             "https://gateway.internal/v1/sessions/registration/allocation/1/4/compute.workspace.stat"

    assert {:ok, execution_target} = AgentVMMHostClient.execution_target(workload.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [runtime_update: %{"phase" => "verifying"}]
    )

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^runtime.id),
      set: [readiness: "pending"]
    )

    assert {:ok, ^execution_target} = AgentVMMHostClient.execution_target(workload.id)

    auth = %{
      "action" => "acquire",
      "target" => execution_target,
      "execution_id" => "auth-verify",
      "kind" => "auth_operation",
      "operation_request_id" => "verify-1",
      "deadline_unix_nano" => Integer.to_string(System.system_time(:nanosecond) + 60_000_000_000)
    }

    assert {:ok, _} = AgentVMMHostClient.runtime_execution("acquire", auth, workload.id)
    assert_receive {:host_request, _, %{"execution_id" => "auth-verify"}}

    assert {:error, :workload_updating} =
             AgentVMMHostClient.runtime_execution(
               "acquire",
               Map.put(auth, "kind", "main_execution"),
               workload.id
             )

    assert {:error, :workload_updating} =
             AgentVMMHostClient.exec_workload(%{"command" => ["true"]}, workload.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [runtime_update: nil]
    )

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^runtime.id),
      set: [readiness: "ready"]
    )

    assert {:ok, _} =
             AgentVMMHostClient.runtime_execution(
               "acquire",
               %{
                 "action" => "acquire",
                 "target" => execution_target,
                 "execution_id" => "execution-1",
                 "kind" => "main_execution",
                 "deadline_unix_nano" => "0"
               },
               workload.id
             )

    assert_receive {:host_request, execution_acquire_url, execution_acquire}
    assert String.contains?(execution_acquire_url, "/allocation/1/4/")
    assert String.ends_with?(execution_acquire_url, "/compute.execution.acquire")
    assert execution_acquire["execution_id"] == "execution-1"
    assert execution_acquire["deadline_unix_nano"] == "0"

    assert {:ok, %{"outcome" => "succeeded"}} =
             AgentVMMHostClient.exec_workload(
               %{"command" => ["printf", "ok"]},
               workload.id
             )

    assert_receive {:host_request, exec_url, args}
    assert String.ends_with?(exec_url, "/compute.exec")
    assert args["command"] == ["printf", "ok"]
    assert Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/, args["request_id"])

    assert {:ok, %{"outcome" => "succeeded"}} =
             AgentVMMHostClient.build_workload(
               %{
                 "dockerfile_path" => "Dockerfile",
                 "image" => "comma/test:latest",
                 "context_base64" => "Y29udGV4dA==",
                 "request_id" => "build-request-1"
               },
               workload.id
             )

    assert_receive {:host_request, build_url, build_args}
    assert String.ends_with?(build_url, "/compute.build.run")
    assert build_args["request_id"] == "build-request-1"

    manifest_digest = "sha256:" <> String.duplicate("b", 64)

    image = %{
      "class" => "external",
      "reference" => "comma.local/runtime/external@" <> manifest_digest,
      "platform" => "linux/arm64",
      "archiveUrl" =>
        "https://comma-release.afk.surf/runtime-bundles/sha256/#{String.duplicate("a", 64)}.oci.tar",
      "archiveSize" => byte_size("oci-archive"),
      "archiveSha256" => String.duplicate("a", 64),
      "manifestDigest" => manifest_digest
    }

    expected_image_reference = image["reference"]

    assert {:ok, %{"reference" => ^expected_image_reference}} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    assert_receive {:host_import_request, import_url, import_headers}
    assert String.ends_with?(import_url, "/compute.image.import")
    assert {"content-length", "0"} in import_headers
    assert {"x-comma-archive-size", Integer.to_string(byte_size("oci-archive"))} in import_headers
    assert {"x-comma-archive-url", image["archiveUrl"]} in import_headers
    assert {"x-comma-image-reference", image["reference"]} in import_headers

    assert {"x-comma-import-request-id", request_id} =
             Enum.find(import_headers, &match?({"x-comma-import-request-id", _}, &1))

    assert byte_size(request_id) == 63

    expected_request_id =
      "import-" <>
        (:crypto.hash(
           :sha256,
           Enum.join(
             [
               image["manifestDigest"],
               image["class"],
               image["archiveSha256"],
               "1",
               workload.id
             ],
             "\n"
           )
         )
         |> Base.encode16(case: :lower)
         |> binary_part(0, 56))

    assert request_id == expected_request_id

    assert {:error, :invalid_image_import} =
             AgentVMMHostClient.import_workload_image(
               %{image | "reference" => "comma.local/runtime/external:mutable"},
               workload.id
             )

    assert {:error, :invalid_image_import} =
             AgentVMMHostClient.import_workload_image(
               Map.delete(image, "manifestDigest"),
               workload.id
             )

    Repo.update_all(AgentVMM.Session,
      set: [expires_at: DateTime.add(DateTime.utc_now(), 600, :second)]
    )

    assert {:error, :insufficient_session_authority} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    refute_receive {:host_import_request, _, _}, 20
    Repo.update_all(AgentVMM.Session, set: [expires_at: session_expiry])

    assert {:ok, %{"outcome" => "succeeded"}} =
             AgentVMMHostClient.start_process(
               %{"command" => ["sh"], "request_id" => "process-request-1"},
               workload.id
             )

    assert_receive {:host_request, process_url, process_args}
    assert String.ends_with?(process_url, "/process.start")
    assert process_args["request_id"] == "process-request-1"

    assert {:error, :invalid_command} =
             AgentVMMHostClient.start_process(
               %{"command" => ["sh"]},
               workload.id
             )

    assert {:error, :invalid_request_id} =
             AgentVMMHostClient.start_process(
               %{"command" => ["sh"], "request_id" => String.duplicate("x", 64)},
               workload.id
             )

    refute_receive {:host_request, _, %{"command" => ["sh"]}}, 20

    assert {:ok, _} =
             AgentVMMHostClient.runtime_execution(
               "release",
               %{
                 "action" => "release",
                 "target" => execution_target,
                 "execution_id" => "execution-1",
                 "kind" => "main_execution"
               },
               workload.id
             )

    assert_receive {:host_request, execution_release_url, execution_release}
    assert String.contains?(execution_release_url, "/allocation/1/4/")
    assert String.ends_with?(execution_release_url, "/compute.execution.release")
    assert execution_release["execution_id"] == "execution-1"
    assert execution_release["expected_instance_id"] == execution_target["container_instance_id"]

    assert {:ok, _} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    assert_receive {:host_import_request, renewed_import_url, renewed_headers}
    assert String.contains?(renewed_import_url, "/allocation/1/4/compute.image.import")

    assert {"x-comma-import-request-id", ^request_id} =
             Enum.find(renewed_headers, &match?({"x-comma-import-request-id", _}, &1))

    Repo.update_all(AgentVMM.Session, set: [gateway_instance_id: "salix-vmm-gateway-1"])

    Repo.update_all(Compute.ProviderBinding,
      set: [
        observation: %{"connection_epoch" => "4", "gateway_instance_id" => "salix-vmm-gateway-1"}
      ]
    )

    Application.put_env(:salix_store, :agent_vmm_gateway_instances, %{})

    Application.put_env(
      :salix_store,
      :agent_vmm_gateway_url_template,
      "https://{instance_id}.salix-vmm-gateway-headless.comma.svc.cluster.local:8443"
    )

    assert {:ok, _} =
             AgentVMMHostClient.call(
               :workspace_stat,
               %{"path" => "replica"},
               workload.id
             )

    assert_receive {:host_request, routed_url, _}

    assert routed_url ==
             "https://salix-vmm-gateway-1.salix-vmm-gateway-headless.comma.svc.cluster.local:8443/v1/sessions/registration/allocation/1/4/compute.workspace.stat"

    revision_before_stale = Repo.get!(Compute.Allocation, allocation.id).revision

    Application.put_env(
      :salix_store,
      :agent_vmm_host_client_test_result,
      :stream_stale
    )

    assert {:error, :stale_session} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    assert Repo.get_by!(AgentVMM.Session, allocation_generation: 1).status == "stale"
    assert Repo.get!(Compute.Allocation, allocation.id).revision == revision_before_stale + 1
    assert_receive {:host_import_request, _, _}

    Repo.update_all(AgentVMM.Session, set: [status: "ready"])
    revision_before_stale = Repo.get!(Compute.Allocation, allocation.id).revision

    Application.put_env(
      :salix_store,
      :agent_vmm_host_client_test_result,
      {:error, :stale_session}
    )

    assert {:error, :stale_session} =
             AgentVMMHostClient.call(:workspace_stat, %{"path" => "vanished"}, workload.id)

    assert Repo.get_by!(AgentVMM.Session, allocation_generation: 1).status == "stale"
    assert Repo.get!(Compute.Allocation, allocation.id).revision == revision_before_stale + 1

    assert {:error, :not_found} =
             AgentVMMHostClient.call(:workspace_stat, %{"path" => "vanished"}, workload.id)

    assert_receive {:host_request, _, %{"path" => "vanished"}}
    refute_receive {:host_request, _, %{"path" => "vanished"}}

    assert {:error, :not_found} =
             AgentVMMHostClient.call(:workspace_stat, %{"path" => "."}, "other")

    assert {:error, :revision_conflict} =
             Compute.update_environment_intent(environment.id, environment.revision, %{
               desired_state: "revoked"
             })

    # Gateway observations can advance revision without changing generation.
    # Lock the current row so this lifecycle assertion cannot race an observation.
    assert {:ok, {:ok, revoked}} =
             Repo.transaction(fn ->
               current =
                 Repo.one!(
                   from(e in Compute.Environment,
                     where: e.id == ^environment.id,
                     lock: "FOR UPDATE"
                   )
                 )

               Compute.update_environment_intent(current.id, current.revision, %{
                 desired_state: "revoked"
               })
             end)

    assert revoked.generation == 2

    assert {:error, :not_found} =
             AgentVMMHostClient.call(
               :workspace_stat,
               %{"path" => "after-revoke"},
               workload.id
             )

    refute_receive {:host_request, _, _}
  end

  test "rejects an unsupported operation without falling back to workspace" do
    assert {:error, :unsupported_workload_operation} =
             AgentVMMHostClient.call(:unknown_operation, %{}, "workload")

    refute_receive {:host_request, _, _}
  end

  defp issue_open_session_command!(
         allocation,
         workload,
         allocation_generation,
         expires_unix_millis
       ) do
    id = Ecto.UUID.generate()

    assert {:ok, command} =
             Compute.enqueue_command(%{
               id: id,
               allocation_id: allocation.id,
               workload_id: workload.id,
               request_id: "open-session:#{allocation.revision}:#{allocation_generation}",
               kind: "runtime.open_session",
               classification: "desired_state",
               target_generation: allocation.generation,
               target_revision: allocation.revision,
               payload: %{
                 "command_json" => %{
                   "openSession" => %{
                     "allocationId" => allocation.id,
                     "allocationGeneration" => allocation_generation,
                     "executionOwnerId" => "runtime:#{workload.id}:#{workload.generation}"
                   }
                 }
               },
               deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert {1, _} =
             Repo.update_all(from(c in Compute.Command, where: c.id == ^id),
               set: [
                 status: "succeeded",
                 evidence: %{
                   "result" => %{
                     "sessionReady" => %{
                       "tunnelNonce" => "tunnel-#{allocation_generation}",
                       "expiresUnixMillis" => Integer.to_string(expires_unix_millis)
                     }
                   }
                 }
               ]
             )

    command && "tunnel-#{allocation_generation}"
  end

  defp restore(key, nil), do: Application.delete_env(:salix_store, key)
  defp restore(key, value), do: Application.put_env(:salix_store, key, value)
end
