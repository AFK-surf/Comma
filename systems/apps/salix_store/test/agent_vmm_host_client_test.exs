defmodule SalixStore.AgentVMMHostClientTest do
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  import Ecto.Query
  alias SalixStore.{AgentVMM, AgentVMMHostClient, Compute, Repo}

  defmodule SessionCaller do
    def session_call(instance_id, session, "compute.image.import", payload, timeout_ms) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_store, :agent_vmm_host_client_test_pid),
        {
          :host_import_request,
          instance_id,
          session,
          payload
        }
      )

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_store, :agent_vmm_host_client_test_pid),
        {:host_import_timeout, timeout_ms}
      )

      case SystemsRuntime.get_env(:salix_store, :agent_vmm_host_client_test_result) do
        :stream_stale -> {:error, :stale_session}
        _ -> {:ok, 200, %{"reference" => payload["x-comma-image-reference"]}}
      end
    end

    def session_call(instance_id, session, operation, payload, timeout_ms) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_store, :agent_vmm_host_client_test_pid),
        {
          :host_request,
          instance_id,
          session,
          operation,
          payload
        }
      )

      if operation == "compute.exec" do
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_store, :agent_vmm_host_client_test_pid),
          {:host_exec_timeout, timeout_ms}
        )
      end

      case SystemsRuntime.get_env(:salix_store, :agent_vmm_host_client_test_result) do
        {:error, _} = error ->
          error

        _ ->
          successful_call(operation, payload)
      end
    end

    defp successful_call("compute.exec", _body),
      do: {:ok, 200, %{"outcome" => "succeeded", "exit_code" => 0}}

    defp successful_call(_operation, %{"path" => path}) when is_binary(path),
      do: {:ok, 200, %{"path" => path, "kind" => "WORKSPACE_ENTRY_KIND_FILE"}}

    defp successful_call(_operation, _body),
      do: {:ok, 200, %{"outcome" => "succeeded"}}
  end

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_sessions, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    previous = %{
      caller: SystemsRuntime.get_env(:salix_store, :agent_vmm_session_caller),
      pid: SystemsRuntime.get_env(:salix_store, :agent_vmm_host_client_test_pid),
      result: SystemsRuntime.get_env(:salix_store, :agent_vmm_host_client_test_result)
    }

    SystemsRuntime.put_env(:salix_store, :agent_vmm_session_caller, SessionCaller)

    SystemsRuntime.put_env(
      :salix_store,
      :agent_vmm_host_client_test_pid,
      SystemsRuntime.Proc.self()
    )

    SystemsRuntime.delete_env(:salix_store, :agent_vmm_host_client_test_result)

    on_exit(fn ->
      restore(:agent_vmm_session_caller, previous.caller)
      restore(:agent_vmm_host_client_test_pid, previous.pid)
      restore(:agent_vmm_host_client_test_result, previous.result)
    end)

    :ok
  end

  test "import errors retain progress and deterministic artifact identity across the worker boundary" do
    for {code, resource} <- [
          {"import_in_progress", "runtime"},
          {"data_loss", "image"},
          {"invalid_argument", "image"},
          {"not_found", "image"},
          {"permission_denied", "image"},
          {"data_loss", "runtime"}
        ] do
      error = %{
        "code" => code,
        "stage" => "image_import",
        "resource" => resource,
        "message" => "Image import result."
      }

      assert {:error, {:gateway_error, ^error}} =
               AgentVMMHostClient.HTTP.import_result(503, error)
    end
  end

  test "one dispatch resolves current authority once and the next dispatch observes revocation" do
    %{workload: workload} = ready_host_workload!("meeting_runtime")
    caller = self()
    handler = "vmm-current-target"

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _event, _measurements, _metadata, _ ->
        if self() == caller, do: send(caller, :vmm_target_query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = AgentVMMHostClient.exec_workload(%{"command" => ["true"]}, workload.id)
    settle_receive({:host_request, _, _, _, %{"command" => ["true"]}})
    assert_received :vmm_target_query
    refute_received :vmm_target_query

    Repo.update_all(AgentVMM.Registration, set: [status: "revoked"])
    assert_received :vmm_target_query

    assert {:error, :not_found} =
             AgentVMMHostClient.exec_workload(%{"command" => ["false"]}, workload.id)

    assert_received :vmm_target_query
    refute_received :vmm_target_query
    settle_refute_receive({:host_request, _, _, _, _})
  end

  test "dispatches through the current workload, allocation, runtime, and gateway fence" do
    %{
      workload: workload,
      allocation: allocation,
      runtime: runtime,
      environment: environment,
      session_expiry: session_expiry
    } = ready_host_workload!("meeting_runtime")

    assert {:ok, %{"path" => "src/main.ex"}} =
             AgentVMMHostClient.call(
               :workspace_stat,
               %{"path" => "src/main.ex"},
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", first_session, "compute.workspace.stat",
       %{"path" => "src/main.ex"}}
    )

    assert first_session == %{
             registration_id: "registration",
             allocation_id: "allocation",
             allocation_generation: 1,
             connection_epoch: "4"
           }

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
      "deadline_unix_nano" =>
        Integer.to_string(SystemsClock.system_time(:nanosecond) + 60_000_000_000)
    }

    assert {:ok, _} = AgentVMMHostClient.runtime_execution("acquire", auth, workload.id)
    settle_receive({:host_request, _, _, _, %{"execution_id" => "auth-verify"}})

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

    settle_receive(
      {:host_request, "gateway-a", ^first_session, "compute.execution.acquire", execution_acquire}
    )

    assert execution_acquire["execution_id"] == "execution-1"
    assert execution_acquire["deadline_unix_nano"] == "0"

    assert {:ok, %{"outcome" => "succeeded"}} =
             AgentVMMHostClient.exec_workload(
               %{"command" => ["printf", "ok"]},
               workload.id
             )

    settle_receive({:host_request, "gateway-a", ^first_session, "compute.exec", args})
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

    settle_receive({:host_request, "gateway-a", ^first_session, "compute.build.run", build_args})
    assert build_args["request_id"] == "build-request-1"

    manifest_digest = "sha256:" <> String.duplicate("b", 64)

    image = %{
      "class" => "station",
      "reference" => "comma.local/runtime/station@" <> manifest_digest,
      "platform" => "linux/arm64",
      "archiveUrl" =>
        "https://comma-release.afk.surf/runtime-bundles/sha256/#{String.duplicate("a", 64)}.erofs.zst",
      "archiveSize" => byte_size("erofs-archive"),
      "archiveSha256" => String.duplicate("a", 64),
      "manifestDigest" => manifest_digest
    }

    expected_image_reference = image["reference"]

    assert {:ok, %{"reference" => ^expected_image_reference}} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    settle_receive({:host_import_request, "gateway-a", ^first_session, import_headers})
    assert_received {:host_import_timeout, 760_000}
    assert import_headers["content-length"] == "0"
    assert import_headers["x-comma-archive-size"] == Integer.to_string(byte_size("erofs-archive"))
    assert import_headers["x-comma-archive-url"] == image["archiveUrl"]
    assert import_headers["x-comma-image-reference"] == image["reference"]

    legacy_oci_image = %{
      image
      | "archiveUrl" =>
          "https://comma-release.afk.surf/runtime-bundles/sha256/#{String.duplicate("a", 64)}.oci.tar"
    }

    assert {:ok, %{"reference" => ^expected_image_reference}} =
             AgentVMMHostClient.import_workload_image(legacy_oci_image, workload.id)

    settle_receive({:host_import_request, "gateway-a", ^first_session, legacy_headers})
    assert_received {:host_import_timeout, 760_000}
    assert legacy_headers["x-comma-archive-url"] == legacy_oci_image["archiveUrl"]

    request_id = Map.fetch!(import_headers, "x-comma-import-request-id")

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
               %{image | "reference" => "comma.local/runtime/station:mutable"},
               workload.id
             )

    assert {:error, :invalid_image_import} =
             AgentVMMHostClient.import_workload_image(
               %{
                 image
                 | "class" => "external",
                   "reference" => "comma.local/runtime/external@" <> manifest_digest
               },
               workload.id
             )

    assert {:error, :invalid_image_import} =
             AgentVMMHostClient.import_workload_image(
               Map.delete(image, "manifestDigest"),
               workload.id
             )

    Repo.update_all(AgentVMM.Session,
      set: [expires_at: DateTime.add(SystemsClock.utc_now(), 779, :second)]
    )

    assert {:error, :insufficient_session_authority} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    settle_refute_receive({:host_import_request, _, _, _}, 20)
    Repo.update_all(AgentVMM.Session, set: [expires_at: session_expiry])

    assert {:ok, %{"outcome" => "succeeded"}} =
             AgentVMMHostClient.start_process(
               %{"command" => ["sh"], "request_id" => "process-request-1"},
               workload.id
             )

    settle_receive({:host_request, "gateway-a", ^first_session, "process.start", process_args})
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

    settle_refute_receive({:host_request, _, _, _, %{"command" => ["sh"]}}, 20)

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

    settle_receive(
      {:host_request, "gateway-a", ^first_session, "compute.execution.release", execution_release}
    )

    assert execution_release["execution_id"] == "execution-1"
    assert execution_release["expected_instance_id"] == execution_target["container_instance_id"]

    assert {:ok, _} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    settle_receive({:host_import_request, "gateway-a", ^first_session, renewed_headers})
    assert renewed_headers["x-comma-import-request-id"] == request_id

    Repo.update_all(AgentVMM.Session, set: [gateway_instance_id: "comma-1"])

    Repo.update_all(AgentVMM.Registration,
      set: [current_gateway_instance_id: "comma-1"]
    )

    assert {:ok, _} =
             AgentVMMHostClient.call(
               :workspace_stat,
               %{"path" => "replica"},
               workload.id
             )

    settle_receive({:host_request, "comma-1", ^first_session, "compute.workspace.stat", _})

    revision_before_stale = Repo.get!(Compute.Allocation, allocation.id).revision

    SystemsRuntime.put_env(
      :salix_store,
      :agent_vmm_host_client_test_result,
      :stream_stale
    )

    assert {:error, :stale_session} =
             AgentVMMHostClient.import_workload_image(image, workload.id)

    assert Repo.get_by!(AgentVMM.Session, allocation_generation: 1).status == "stale"
    assert Repo.get!(Compute.Allocation, allocation.id).revision == revision_before_stale + 1
    settle_receive({:host_import_request, _, _, _})
    Repo.update_all(AgentVMM.Session, set: [status: "ready"])
    revision_before_stale = Repo.get!(Compute.Allocation, allocation.id).revision

    SystemsRuntime.put_env(
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

    settle_receive({:host_request, _, _, _, %{"path" => "vanished"}})
    settle_refute_receive({:host_request, _, _, _, %{"path" => "vanished"}})

    assert {:error, :not_found} =
             AgentVMMHostClient.call(:workspace_stat, %{"path" => "."}, "other")

    assert {:error, :revision_conflict} =
             Compute.update_environment_intent(environment.id, environment.revision - 1, %{
               desired_state: "revoked"
             })

    # Lock the current row for the lifecycle mutation.
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

    settle_refute_receive({:host_request, _, _, _, _})
  end

  test "a session on a node whose worker does not answer is unavailable, not stale" do
    %{workload: workload} = ready_host_workload!("shell")
    previous_worker = SystemsRuntime.get_env(:salix_store, :agent_vmm_worker)
    on_exit(fn -> restore(:agent_vmm_worker, previous_worker) end)

    # No session caller or worker is configured: target is unavailable.
    SystemsRuntime.delete_env(:salix_store, :agent_vmm_session_caller)

    assert {:error, :runtime_execution_target_unavailable} =
             AgentVMMHostClient.list_processes(%{}, workload.id)

    # A node that runs workers resolves the target, and finds no worker of that instance.
    SystemsRuntime.put_env(:salix_store, :agent_vmm_worker, [])
    assert {:error, :gateway_unavailable} = AgentVMMHostClient.list_processes(%{}, workload.id)
    settle_refute_receive({:host_request, _, _, _, _})

    # The Host may still hold the session on the node that left: Salix keeps it.
    assert {:ok, session} = AgentVMM.current_host_session_for_workload(workload.id)
    assert session.status == "ready"
  end

  test "Shell commands use Host authority without a Runtime Agent and retain target fences" do
    %{workload: workload, runtime: runtime, allocation: allocation} =
      ready_host_workload!("shell")

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^runtime.id),
      set: [status: "disconnected", readiness: "pending", caught_up_epoch: "0"]
    )

    assert {:ok, _} = AgentVMMHostClient.list_processes(%{}, workload.id)
    settle_receive({:host_request, "gateway-a", session, "process.list", %{}})

    assert session == %{
             registration_id: "registration",
             allocation_id: "allocation",
             allocation_generation: 1,
             connection_epoch: "4"
           }

    assert {:ok, _} =
             AgentVMMHostClient.start_process(
               %{"command" => ["printf", "ok"], "request_id" => "shell-start"},
               workload.id
             )

    settle_receive({:host_request, _, _, _, %{"request_id" => "shell-start"}})
    assert {:error, :not_found} = AgentVMMHostClient.execution_target(workload.id)

    for kind <- ["external_worker", "meeting_runtime", "service"] do
      Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id), set: [kind: kind])
      assert {:error, :not_found} = AgentVMMHostClient.list_processes(%{}, workload.id)
    end

    Repo.update_all(Compute.Workload, set: [kind: "shell"])

    for phase <- ["stopping", "replacing", "verifying"] do
      Repo.update_all(Compute.Workload, set: [runtime_update: %{"phase" => phase}])
      assert {:error, :workload_updating} = AgentVMMHostClient.list_processes(%{}, workload.id)
    end

    Repo.update_all(Compute.Workload, set: [runtime_update: nil])
    Repo.update_all(AgentVMM.Registration, set: [status: "revoked"])
    assert {:error, :not_found} = AgentVMMHostClient.list_processes(%{}, workload.id)
    Repo.update_all(AgentVMM.Registration, set: [status: "ready"])
    Repo.update_all(AgentVMM.Session, set: [status: "stale"])
    assert {:error, :not_found} = AgentVMMHostClient.list_processes(%{}, workload.id)
    Repo.update_all(AgentVMM.Session, set: [status: "ready"])
    Repo.update_all(Compute.Allocation, set: [generation: allocation.generation + 1])
    assert {:error, :not_found} = AgentVMMHostClient.list_processes(%{}, workload.id)
    Repo.update_all(Compute.Allocation, set: [generation: allocation.generation])
    settle_refute_receive({:host_request, _, _, _, _})
    assert {:ok, _} = AgentVMMHostClient.list_processes(%{}, workload.id)
    settle_receive({:host_request, "gateway-a", ^session, "process.list", %{}})
  end

  test "workspace list, read, and write bind the workload /workspace volume_id while stat omits it" do
    %{workload: workload} = ready_host_workload!("shell")
    volume_id = "salix-vol-" <> String.duplicate("a", 52)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [
        spec: %{
          "volume_requirements" => [
            %{
              "role" => "provider_state",
              "volume_id" => volume_id,
              "destination" => "/workspace",
              "owner_uid" => 10_001,
              "owner_gid" => 10_001,
              "mode" => 0o755,
              "read_only" => false
            }
          ]
        }
      ]
    )

    assert {:ok, _} = AgentVMMHostClient.call(:workspace_list, %{"path" => "."}, workload.id)

    settle_receive(
      {:host_request, "gateway-a", _, "compute.workspace.list",
       %{"path" => ".", "volume_id" => ^volume_id}}
    )

    assert {:ok, _} =
             AgentVMMHostClient.call(
               :workspace_read,
               %{"path" => "note.txt", "volume_id" => ""},
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", _, "compute.workspace.read",
       %{"path" => "note.txt", "volume_id" => ^volume_id}}
    )

    assert {:ok, _} =
             AgentVMMHostClient.call(
               :workspace_write,
               %{"path" => "note.txt", "content_base64" => Base.encode64("hi")},
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", _, "compute.workspace.write",
       %{"path" => "note.txt", "volume_id" => ^volume_id}}
    )

    assert {:ok, _} =
             AgentVMMHostClient.call(
               :workspace_read,
               %{"path" => "note.txt", "volume_id" => "explicit-vol"},
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", _, "compute.workspace.read",
       %{"path" => "note.txt", "volume_id" => "explicit-vol"}}
    )

    assert {:ok, _} = AgentVMMHostClient.call(:workspace_stat, %{"path" => "."}, workload.id)
    settle_receive({:host_request, "gateway-a", _, "compute.workspace.stat", stat_payload})
    refute Map.has_key?(stat_payload, "volume_id")
  end

  test "tail_process validates wait_ms bounds and forwards valid wait_ms" do
    %{workload: workload} = ready_host_workload!("shell")

    assert {:ok, _} =
             AgentVMMHostClient.tail_process(
               %{"process_id" => "proc-1", "wait_ms" => 0},
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", _, "process.tail", %{"process_id" => "proc-1", "wait_ms" => 0}}
    )

    assert {:ok, _} =
             AgentVMMHostClient.tail_process(
               %{"process_id" => "proc-1", "wait_ms" => 30_000},
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", _, "process.tail",
       %{"process_id" => "proc-1", "wait_ms" => 30_000}}
    )

    for invalid <- [-1, 30_001, "100", 1.5] do
      assert {:error, :invalid_wait_ms} =
               AgentVMMHostClient.tail_process(
                 %{"process_id" => "proc-1", "wait_ms" => invalid},
                 workload.id
               )
    end

    settle_refute_receive({:host_request, _, _, "process.tail", _})
  end

  test "stop_process validates optional signal values" do
    %{workload: workload} = ready_host_workload!("shell")

    for signal <- ["term", "int", "kill", "TERM"] do
      assert {:ok, _} =
               AgentVMMHostClient.stop_process(
                 %{"process_id" => "proc-1", "signal" => signal},
                 workload.id
               )

      settle_receive(
        {:host_request, "gateway-a", _, "process.stop",
         %{"process_id" => "proc-1", "signal" => ^signal}}
      )
    end

    for invalid <- ["hup", "SIGKILL", 9] do
      assert {:error, :invalid_process_signal} =
               AgentVMMHostClient.stop_process(
                 %{"process_id" => "proc-1", "signal" => invalid},
                 workload.id
               )
    end

    settle_refute_receive({:host_request, _, _, "process.stop", _})
  end

  test "exec_workload validates optional timeout_ms, allows full option set, and scales worker timeout" do
    %{workload: workload} = ready_host_workload!("shell")

    assert {:ok, _} =
             AgentVMMHostClient.exec_workload(
               %{
                 "command" => ["sh", "-c", "echo ok"],
                 "env" => ["A=1"],
                 "workdir" => "/workspace",
                 "user" => "10001:10001",
                 "timeout_ms" => 180_000,
                 "request_id" => "exec-timeout-valid"
               },
               workload.id
             )

    settle_receive(
      {:host_request, "gateway-a", _, "compute.exec",
       %{"command" => ["sh", "-c", "echo ok"], "timeout_ms" => 180_000}}
    )

    assert_received {:host_exec_timeout, 200_000}

    assert {:ok, _} =
             AgentVMMHostClient.exec_workload(
               %{"command" => ["true"], "timeout_ms" => 1_000},
               workload.id
             )

    settle_receive({:host_request, "gateway-a", _, "compute.exec", %{"timeout_ms" => 1_000}})
    assert_received {:host_exec_timeout, 95_000}

    assert {:ok, _} =
             AgentVMMHostClient.exec_workload(
               %{"command" => ["true"], "timeout_ms" => 300_000},
               workload.id
             )

    settle_receive({:host_request, "gateway-a", _, "compute.exec", %{"timeout_ms" => 300_000}})
    assert_received {:host_exec_timeout, 320_000}

    for invalid <- [0, 999, 300_001, "60000", 1.5] do
      assert {:error, :invalid_timeout_ms} =
               AgentVMMHostClient.exec_workload(
                 %{"command" => ["true"], "timeout_ms" => invalid},
                 workload.id
               )
    end

    settle_refute_receive({:host_request, _, _, "compute.exec", _})
  end

  defp ready_host_workload!(kind) do
    {:ok, _} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        credential: String.duplicate("e", 32)
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
        kind: kind,
        template_key: if(kind == "shell", do: "shell.default"),
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

    session_expiry = DateTime.add(SystemsClock.utc_now(), 900, :second)
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

    %{
      workload: workload,
      allocation: allocation,
      runtime: runtime,
      environment: environment,
      session_expiry: session_expiry
    }
  end

  defp issue_open_session_command!(
         allocation,
         workload,
         allocation_generation,
         expires_unix_millis
       ) do
    id = SystemsRuntime.Proc.uuid()

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
               deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
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

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_store, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_store, key, value)
end
