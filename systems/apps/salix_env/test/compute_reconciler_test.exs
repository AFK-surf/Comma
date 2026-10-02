defmodule SalixEnv.ComputeReconcilerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixEnv.ComputeReconciler
  alias SalixStore.{AgentVMM, Compute, Repo, RuntimeBundleCatalog, SessionWorkCandidates}

  defmodule HostHTTP do
    @request_id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/

    def post(url, body) do
      execution_lifecycle? =
        String.ends_with?(url, "/compute.execution.acquire") or
          String.ends_with?(url, "/compute.execution.release")

      unless execution_lifecycle?, do: send(self(), {:compute_host_request, url, body})

      cond do
        String.ends_with?(url, "/compute.execution.acquire") ->
          {:ok, %{"execution_id" => body["execution_id"]}}

        String.ends_with?(url, "/compute.execution.release") ->
          {:ok, %{"released" => true}}

        String.ends_with?(url, "/compute.image.list") ->
          images =
            if Process.get(:compute_reconciler_image_imported, false),
              do: [
                %{
                  "reference" => Process.get(:compute_reconciler_image_reference),
                  "digest" => Process.get(:compute_reconciler_manifest_digest),
                  "platforms" => ["linux/arm64"],
                  "generation_id" => "image-1"
                }
              ],
              else: []

          if images == [], do: {:ok, %{}}, else: {:ok, %{"images" => images}}

        String.ends_with?(url, "/compute.container.get") ->
          case Enum.find(container_inventory(), &(&1["id"] == body["container_id"])) do
            nil -> {:error, {:gateway_error, %{"code" => "not_found", "stage" => "runtime"}}}
            container -> {:ok, %{"container" => container}}
          end

        String.ends_with?(url, "/compute.container.list") ->
          if hook = Process.get(:compute_reconciler_container_list_hook), do: hook.()
          containers = container_inventory()
          if containers == [], do: {:ok, %{}}, else: {:ok, %{"containers" => containers}}

        String.ends_with?(url, "/compute.volume.list") ->
          volumes = Process.get(:compute_reconciler_volumes, %{}) |> Map.values()
          if volumes == [], do: {:ok, %{}}, else: {:ok, %{"volumes" => volumes}}

        String.ends_with?(url, "/compute.volume.create") ->
          guest_create_volume(body)

        String.ends_with?(url, "/compute.container.create") ->
          guest_create(body)

        String.ends_with?(url, "/compute.container.start") ->
          case Process.get(:compute_reconciler_start_error) do
            nil ->
              container = mutate_container(body["container_id"], "running")
              {:ok, %{"container" => container}}

            error ->
              {:error, {:gateway_error, error}}
          end

        String.ends_with?(url, "/compute.container.stop") ->
          case Process.get(:compute_reconciler_stop_error) do
            nil ->
              mutate_container(body["container_id"], "stopped")
              {:ok, %{"stopped" => true}}

            error ->
              {:error, error}
          end

        String.ends_with?(url, "/compute.container.quiesce") ->
          {:ok, %{"quiesced" => true}}

        String.ends_with?(url, "/compute.container.delete") ->
          delete_container(body["container_id"])
          {:ok, %{"deleted" => true}}

        true ->
          {:ok, %{"outcome" => "succeeded"}}
      end
    end

    defp container_inventory do
      primary =
        case Process.get(:compute_reconciler_container_state) do
          nil -> []
          state -> [container(state)]
        end

      primary ++ Process.get(:compute_reconciler_additional_containers, [])
    end

    defp mutate_container(id, state) do
      if Process.get(:compute_reconciler_container_id) == id do
        Process.put(:compute_reconciler_container_state, state)
        container(state)
      else
        containers = Process.get(:compute_reconciler_additional_containers, [])

        updated =
          Enum.map(containers, &if(&1["id"] == id, do: Map.put(&1, "state", state), else: &1))

        Process.put(:compute_reconciler_additional_containers, updated)
        Enum.find(updated, &(&1["id"] == id))
      end
    end

    defp delete_container(id) do
      if Process.get(:compute_reconciler_container_id) == id do
        Process.delete(:compute_reconciler_container_state)
        Process.delete(:compute_reconciler_container_id)
      else
        Process.put(
          :compute_reconciler_additional_containers,
          Enum.reject(
            Process.get(:compute_reconciler_additional_containers, []),
            &(&1["id"] == id)
          )
        )
      end
    end

    defp container(state) do
      %{
        "id" => Process.get(:compute_reconciler_container_id, "salix-test-container"),
        "generation_id" => Process.get(:compute_reconciler_container_generation, "container-1"),
        "instance_id" => Process.get(:compute_reconciler_container_instance, "instance-1"),
        "state" => state,
        "image" =>
          Process.get(
            :compute_reconciler_container_image,
            Process.get(:compute_reconciler_image_reference)
          )
      }
    end

    defp guest_create(body) do
      request_id = body["request_id"]
      fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(body, [:deterministic]))
      ledger = Process.get(:compute_reconciler_guest_dedupe, %{})

      case Map.get(ledger, request_id) do
        nil ->
          result = execute_guest_create(body)

          Process.put(
            :compute_reconciler_guest_dedupe,
            Map.put(ledger, request_id, {fingerprint, result})
          )

          result

        {^fingerprint, result} ->
          result

        {_different_fingerprint, _result} ->
          {:error, {:gateway_status, 502}}
      end
    end

    defp execute_guest_create(body) do
      mounts = Map.get(body, "volumes", [])
      volumes = Process.get(:compute_reconciler_volumes, %{})

      valid? =
        is_binary(body["request_id"]) and Regex.match?(@request_id_pattern, body["request_id"]) and
          is_binary(body["container_id"]) and body["container_id"] != "" and
          is_binary(body["image"]) and body["image"] != "" and
          Process.get(:compute_reconciler_image_imported, false) and
          is_list(body["entrypoint"]) and length(body["entrypoint"]) <= 256 and
          is_list(body["command"]) and length(body["command"]) <= 256 and
          is_list(body["env"]) and length(body["env"]) <= 256 and
          is_list(mounts) and
          Enum.all?(mounts, fn mount ->
            is_map(mount) and mount["destination"] == "/workspace" and
              mount["read_only"] == false and Map.has_key?(volumes, mount["volume_id"])
          end) and
          (mounts == [] or "HOME=/workspace" in body["env"]) and
          is_integer(body["log_limit_bytes"]) and body["log_limit_bytes"] >= 1_048_576 and
          body["log_limit_bytes"] <= 67_108_864

      cond do
        not valid? ->
          {:error, {:gateway_status, 502}}

        Process.get(:compute_reconciler_fail_first_create, false) and
            not Process.get(:compute_reconciler_first_create_failed, false) ->
          Process.put(:compute_reconciler_first_create_failed, true)
          {:error, {:gateway_status, 502}}

        true ->
          Process.put(:compute_reconciler_container_id, body["container_id"])
          Process.put(:compute_reconciler_container_state, "created")
          Process.put(:compute_reconciler_container_image, body["image"])

          if next = Process.get(:compute_reconciler_new_generation),
            do: Process.put(:compute_reconciler_container_generation, next)

          {:ok, %{"container" => container("created")}}
      end
    end

    defp guest_create_volume(body) do
      valid? =
        is_binary(body["request_id"]) and Regex.match?(@request_id_pattern, body["request_id"]) and
          is_binary(body["volume_id"]) and body["volume_id"] != "" and
          body["owner_uid"] == 1_000 and body["owner_gid"] == 1_000 and
          body["mode"] == 0o700

      if valid? do
        volume = %{"id" => body["volume_id"], "mounted_by" => []}

        Process.put(
          :compute_reconciler_volumes,
          Map.put(Process.get(:compute_reconciler_volumes, %{}), body["volume_id"], volume)
        )

        {:ok, %{"volume" => volume}}
      else
        {:error, {:gateway_status, 502}}
      end
    end

    def post_import(url, headers) do
      if hook = Process.get(:compute_reconciler_import_hook), do: hook.()
      send(self(), {:compute_host_import_request, url, headers})

      case Process.get(:compute_reconciler_inspect_claim) do
        {workload_id, generation} ->
          claim =
            SalixStore.Repo.get_by(SalixStore.Compute.ReconcilerClaim,
              provider: "agent_vmm",
              workload_id: workload_id,
              generation: generation
            )

          send(self(), {:compute_claim_at_import, claim && claim.last_error})

        _ ->
          :ok
      end

      case Process.get(:compute_reconciler_image_import_result) do
        nil ->
          Process.put(:compute_reconciler_image_imported, true)
          {:ok, %{"reference" => Process.get(:compute_reconciler_image_reference)}}

        result ->
          result
      end
    end
  end

  defmodule ComputeAuthDispatcher do
    def call(runtime_instance_id, connection_epoch, request) do
      send(
        Application.fetch_env!(:salix_store, :compute_reconciler_test_pid),
        {:compute_auth_request, runtime_instance_id, connection_epoch, request}
      )

      if request["method"] == "agent_runtime_quiet" do
        if hook = Process.get(:compute_reconciler_quiet_hook), do: hook.()

        if Process.get(:compute_reconciler_quiet, true),
          do: {:ok, %{"quiet" => true}},
          else: {:error, :runtime_auth_failed}
      else
        authenticated? =
          Application.get_env(:salix_store, :compute_reconciler_auth_ready, false)

        {:ok,
         %{
           "auth" => %{
             "schema_version" => 1,
             "status" => if(authenticated?, do: "authenticated", else: "unauthenticated"),
             "requires_openai_auth" => true,
             "observed_at" => System.system_time(:millisecond)
           },
           "native_ready" => authenticated?,
           "ready" => authenticated?
         }}
      end
    end
  end

  defmodule ConcurrentHostHTTP do
    def post(url, body) do
      seed(url)
      HostHTTP.post(url, body)
    end

    def post_import(url, headers) do
      seed(url)
      owner = Application.fetch_env!(:salix_store, :compute_reconciler_test_pid)
      send(owner, {:blocked_import, self()})

      receive do
        :release_import -> HostHTTP.post_import(url, headers)
      after
        10_000 -> {:error, :test_import_timeout}
      end
    end

    defp seed(url) do
      unless Process.get(:scheduler_fixture_seeded) do
        fixtures = Application.fetch_env!(:salix_store, :compute_scheduler_fixtures)
        key = if String.contains?(url, "fast-allocation"), do: :fast, else: :slow
        Enum.each(fixtures[key], fn {k, v} -> Process.put(k, v) end)
        Process.put(:scheduler_fixture_seeded, true)
      end
    end
  end

  setup do
    Repo.query!(
      "TRUNCATE compute_runtime_release, session_work_candidates, compute_reconciler_claims, compute_reconciler_cursors, agent_vmm_audit_events, agent_vmm_sessions, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: String.duplicate("a", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    previous = %{
      instances: Application.get_env(:salix_store, :agent_vmm_gateway_instances),
      client: Application.get_env(:salix_store, :agent_vmm_host_http_client),
      pid: Application.get_env(:salix_store, :agent_vmm_host_client_test_pid),
      runtime_url: Application.get_env(:salix_store, :compute_runtime_base_url),
      runtime_secret: Application.get_env(:salix_store, :compute_workload_credential_secret),
      rpc_dispatcher: Application.get_env(:salix_store, :compute_runtime_rpc_dispatcher),
      auth_pid: Application.get_env(:salix_store, :compute_reconciler_test_pid),
      auth_ready: Application.get_env(:salix_store, :compute_reconciler_auth_ready)
    }

    Application.put_env(:salix_store, :agent_vmm_gateway_instances, %{
      "gateway-a" => "https://gateway.internal"
    })

    Application.put_env(:salix_store, :agent_vmm_host_http_client, HostHTTP)
    Application.put_env(:salix_store, :agent_vmm_host_client_test_pid, self())
    Application.put_env(:salix_store, :compute_reconciler_test_pid, self())
    Application.put_env(:salix_store, :compute_runtime_rpc_dispatcher, ComputeAuthDispatcher)
    Application.put_env(:salix_store, :compute_reconciler_auth_ready, false)
    Application.put_env(:salix_store, :compute_runtime_base_url, "https://runtime.internal")

    Application.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("w", 32)
    )

    Process.delete(:compute_reconciler_image_imported)
    Process.delete(:compute_reconciler_image_import_result)
    Process.delete(:compute_reconciler_inspect_claim)
    Process.delete(:compute_reconciler_image_reference)
    Process.delete(:compute_reconciler_manifest_digest)
    Process.delete(:compute_reconciler_container_state)
    Process.delete(:compute_reconciler_container_list_hook)
    Process.delete(:compute_reconciler_container_id)
    Process.delete(:compute_reconciler_additional_containers)
    Process.delete(:compute_reconciler_guest_dedupe)
    Process.delete(:compute_reconciler_fail_first_create)
    Process.delete(:compute_reconciler_first_create_failed)
    Process.delete(:compute_reconciler_volumes)

    on_exit(fn ->
      Repo.query!("DELETE FROM compute_runtime_release")
      restore(:agent_vmm_gateway_instances, previous.instances)
      restore(:agent_vmm_host_http_client, previous.client)
      restore(:agent_vmm_host_client_test_pid, previous.pid)
      restore(:compute_runtime_base_url, previous.runtime_url)
      restore(:compute_workload_credential_secret, previous.runtime_secret)
      restore(:compute_runtime_rpc_dispatcher, previous.rpc_dispatcher)
      restore(:compute_reconciler_test_pid, previous.auth_pid)
      restore(:compute_reconciler_auth_ready, previous.auth_ready)
      Process.delete(:compute_reconciler_image_imported)
      Process.delete(:compute_reconciler_image_import_result)
      Process.delete(:compute_reconciler_inspect_claim)
      Process.delete(:compute_reconciler_image_reference)
      Process.delete(:compute_reconciler_manifest_digest)
      Process.delete(:compute_reconciler_container_state)
      Process.delete(:compute_reconciler_container_list_hook)
      Process.delete(:compute_reconciler_container_id)
      Process.delete(:compute_reconciler_additional_containers)
      Process.delete(:compute_reconciler_volumes)
    end)

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "default",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec", "runtime_process"]
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
        provider_ref: registration.id,
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-a", %{
               "connectionEpoch" => "6",
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

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded")

    # Allocation membership changed after the epoch-6 empty observation. The
    # controller must reconnect and settle an exact fresh HostHello before a
    # runtime command can be claimed.
    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-a", %{
               "connectionEpoch" => "7",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => Integer.to_string(allocation.revision),
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "shell",
        template_key: "shell.default",
        capability_requirements: ["runtime_exec", "runtime_process"],
        generation: 1
      })

    {:ok, image} = RuntimeBundleCatalog.image_for_workload(workload)

    %{
      allocation: allocation,
      workload: workload,
      image: image,
      image_reference: image["reference"]
    }
  end

  for automatic? <- [false, true] do
    @tag :workload_update
    test "update (automatic=#{automatic?}) imports, drains and retains Workload storage",
         fixture do
      {fixture, attrs} = update_fixture!(fixture)
      volume = hd(fixture.workload.spec["volume_requirements"])
      volume_id = volume["volume_id"]

      Process.put(:compute_reconciler_volumes, %{
        volume_id => %{"id" => volume_id, "mounted_by" => []}
      })

      Process.put(:compute_reconciler_new_generation, "replacement-generation")
      alias SalixEnv.ComputeWorkloadUpdate, as: Update

      if unquote(automatic?) do
        assert :ok = SalixStore.ComputeRuntimeRelease.publish("release-1", 10)

        Process.put(:compute_reconciler_import_hook, fn ->
          Task.async(fn ->
            alias SalixStore.ComputeRuntimeCarrier, as: Carrier
            runtime_id = "runtime:" <> fixture.workload.id
            assert {:ok, _} = Carrier.submit(runtime_id, "7", %{"dispatch_id" => "during-import"})
            assert {:ok, [input]} = Carrier.claim_inputs(runtime_id, "7", nil, 1)
            assert {:ok, _} = Carrier.ack(input["id"], runtime_id, "7")
          end)
          |> Task.await(1_000)
        end)

        assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      else
        assert {:error, :workload_operation_busy} =
                 SalixStore.ComputeWorkloadUpdate.with_lock(fixture.workload.id, fn ->
                   Task.async(fn -> Update.start(attrs) end) |> Task.await(5_000)
                 end)

        assert {:error, :workload_not_found} = Update.start(Map.put(attrs, "tenant_id", "other"))

        assert {:error, :release_target_changed} =
                 Update.start(
                   Map.put(
                     attrs,
                     "target_runtime_revision",
                     "sha256:" <> String.duplicate("f", 64)
                   )
                 )

        assert {:ok, started} = Update.start(attrs)
        assert started.update["phase"] == "preparing"
        assert {:ok, ^started} = Update.start(attrs)
      end

      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert_receive {:compute_host_import_request, _, _}
      assert {:ok, %{update: %{"phase" => "draining"}}} = Update.status(attrs)
      alias SalixStore.ComputeRuntimeCarrier, as: Carrier
      runtime_id = "runtime:" <> fixture.workload.id
      payload = %{"dispatch_id" => "during-update", "command" => "echo retained"}
      assert {:ok, %{"accepted" => true}} = Carrier.submit(runtime_id, "7", payload)
      assert {:ok, []} = Carrier.claim_inputs(runtime_id, "7", nil, 1)
      Process.put(:compute_reconciler_quiet, false)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert Process.get(:compute_reconciler_container_state) == "running"
      assert {:ok, %{update: %{"phase" => "draining"}}} = Update.status(attrs)
      Process.put(:compute_reconciler_quiet, true)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert {:ok, %{update: %{"phase" => "stopping"}}} = Update.status(attrs)

      assert {:error, :workload_updating} =
               SalixStore.AgentVMMHostClient.exec_workload(
                 %{"command" => ["true"]},
                 fixture.workload.id
               )

      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert Process.get(:compute_reconciler_container_state) == "stopped"
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

      assert Repo.get!(Compute.RuntimeInstance, "runtime:" <> fixture.workload.id).connection_epoch !=
               "7"

      assert {:ok, %{update: %{"phase" => "replacing"}}} = Update.status(attrs)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert Process.get(:compute_reconciler_container_state) == nil
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert {:ok, %{update: %{"phase" => "verifying"}}} = Update.status(attrs)

      now = DateTime.utc_now()

      Repo.delete_all(
        from(c in Compute.ReconcilerClaim, where: c.workload_id == ^fixture.workload.id)
      )

      Repo.insert!(%Compute.ReconcilerClaim{
        id: "agent_vmm:#{fixture.workload.id}:1",
        provider: "agent_vmm",
        workload_id: fixture.workload.id,
        generation: 1,
        claim_token: "parked",
        attempt_count: 1,
        last_error: %{"code" => "workload_update_action_required", "kind" => "action_required"},
        created_at: now,
        updated_at: now
      })

      # Re-enter through the normal reconciler after every durable phase, as a
      # replacement server does. Old facts may require one observation pass.
      for _ <- 1..8 do
        assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

        if Process.get(:compute_reconciler_container_state) == "running" do
          runtime = Repo.get!(Compute.RuntimeInstance, "runtime:" <> fixture.workload.id)

          assert {:ok, connected} =
                   Compute.observe_runtime(%{
                     id: runtime.id,
                     workload_id: fixture.workload.id,
                     allocation_id: fixture.allocation.id,
                     generation: 1,
                     connection_epoch: runtime.connection_epoch
                   })

          assert {:ok, _} =
                   Compute.complete_runtime_catch_up(
                     connected.id,
                     connected.revision,
                     connected.connection_epoch
                   )

          Application.put_env(:salix_store, :compute_reconciler_auth_ready, true)
        end
      end

      assert {:ok, done} = Update.status(attrs)
      assert done.update["phase"] == "complete"

      assert Repo.get!(Compute.ReconcilerClaim, "agent_vmm:#{fixture.workload.id}:1").last_error ==
               %{}

      assert done.runtime_revision == attrs["target_runtime_revision"]
      runtime = Repo.get!(Compute.RuntimeInstance, runtime_id)
      assert {:error, :stale_runtime_capability} = Carrier.claim_inputs(runtime_id, "7", nil, 1)

      assert {:ok, [retained]} =
               Carrier.claim_inputs(runtime_id, runtime.connection_epoch, nil, 1)

      assert retained["payload"] == payload
      assert {:ok, _} = Carrier.ack(retained["id"], runtime_id, runtime.connection_epoch)
      assert :ok = SalixStore.ComputeRuntimeRelease.publish("same-runtime-new-server", 11)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      assert {:ok, unchanged} = Update.status(attrs)
      assert unchanged.update["operation_id"] == done.update["operation_id"]
      assert unchanged.update["phase"] == "complete"
      current = Repo.get!(Compute.Workload, fixture.workload.id)
      assert current.id == fixture.workload.id
      assert current.generation == fixture.workload.generation
      assert current.spec["volume_requirements"] == fixture.workload.spec["volume_requirements"]
      assert Process.get(:compute_reconciler_volumes) |> Map.has_key?(volume_id)
      refute_receive {:compute_host_request, _, %{"volume_id" => _, "owner_uid" => _}}

      refute_receive {:compute_host_request, _,
                      %{"volume_id" => _, "expected_generation_id" => _}}
    end
  end

  @tag :workload_update
  test "failed import preserves admission and drain timeout requires an explicit decision",
       fixture do
    {fixture, attrs} = update_fixture!(fixture)
    alias SalixEnv.ComputeWorkloadUpdate, as: Update
    assert {:ok, _} = Update.start(attrs)

    Process.put(
      :compute_reconciler_image_import_result,
      {:error,
       {:gateway_error, %{"code" => "private-unknown-code", "message" => "private-host-detail"}}}
    )

    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, diagnostic} = Update.status(attrs)
    assert diagnostic.update["error"] == "provider_unavailable"
    refute Jason.encode!(diagnostic) =~ "private-"
    current = Repo.get!(Compute.Workload, fixture.workload.id)
    refute SalixStore.ComputeWorkloadUpdate.input_paused?(current)
    assert Process.get(:compute_reconciler_container_state) == "running"
    Process.delete(:compute_reconciler_image_import_result)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    current = Repo.get!(Compute.Workload, fixture.workload.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^current.id),
      set: [runtime_update: Map.put(current.runtime_update, "drain_deadline", 0)]
    )

    assert {:error, {:gateway_error, %{"code" => "workload_update_action_required"}}} =
             ComputeReconciler.reconcile_workload(current.id, 1)

    assert Process.get(:compute_reconciler_container_state) == "running"
    assert {:ok, paused} = Update.status(attrs)
    assert paused.update["error"] == "update_drain_timeout"
    assert {:ok, cancelled} = Update.cancel(Map.put(attrs, "expected_revision", paused.revision))
    assert cancelled.update["phase"] == "cancelled"
    refute SalixStore.ComputeWorkloadUpdate.input_paused?(Repo.get!(Compute.Workload, current.id))
  end

  @tag :workload_update
  test "update storage exhaustion parks until operator retry", fixture do
    {_fixture, attrs} = update_fixture!(fixture)
    alias SalixEnv.ComputeWorkloadUpdate, as: Update
    assert {:ok, _} = Update.start(attrs)

    Process.put(
      :compute_reconciler_image_import_result,
      {:error,
       {:gateway_error,
        %{
          "code" => "resource_capacity_exhausted",
          "stage" => "import_admission",
          "resource" => "storage_headroom"
        }}}
    )

    assert :more = ComputeReconciler.sweep(1)
    assert_receive {:compute_host_import_request, _, _}
    assert {:ok, parked} = Update.status(attrs)
    assert parked.update["action_required"]
    assert parked.update["error"] == "update_storage_action_required"
    for _ <- 1..3, do: assert(:complete = ComputeReconciler.sweep(1))
    refute_receive {:compute_host_import_request, _, _}
    assert Process.get(:compute_reconciler_container_state) == "running"
    Process.delete(:compute_reconciler_image_import_result)
    assert {:ok, _} = Update.retry(Map.put(attrs, "expected_revision", parked.revision))
    assert :more = ComputeReconciler.sweep(1)
    assert {:ok, %{update: %{"phase" => "draining"}}} = Update.status(attrs)
  end

  @tag :workload_update
  test "post-cutover forward repair rebases onto the exact serving target", fixture do
    fixture = running_external_runtime!(fixture)
    alias SalixEnv.ComputeWorkloadUpdate, as: Update
    workload = Repo.get!(Compute.Workload, fixture.workload.id)

    {:ok, serving} =
      RuntimeBundleCatalog.materialize(workload.template_key, %{
        owner_id: workload.id,
        generation: 1
      })

    intermediate_digest = "sha256:" <> String.duplicate("d", 64)
    intermediate_reference = "comma.local/runtime/external@" <> intermediate_digest

    intermediate_artifact =
      workload.spec["runtime_artifact"]
      |> Map.put("manifest_digest", intermediate_digest)
      |> Map.put("reference", intermediate_reference)

    parked = %{
      "operation_id" => "upgrade-before-release",
      "phase" => "verifying",
      "attempt" => 1,
      "source_revision" => "sha256:" <> String.duplicate("e", 64),
      "source_artifact" => workload.spec["runtime_artifact"],
      "target_revision" => intermediate_digest,
      "target_artifact" => intermediate_artifact,
      "deadline" => System.system_time(:second) - 1,
      "error" => "update_deadline_exceeded",
      "action_required" => true
    }

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [
        runtime_revision: intermediate_digest,
        spec: Map.put(workload.spec, "runtime_artifact", intermediate_artifact),
        runtime_update: parked
      ]
    )

    workload = Repo.get!(Compute.Workload, workload.id)

    attrs = %{
      "tenant_id" => "tenant",
      "project_id" => "project",
      "workload_id" => workload.id,
      "operation_id" => parked["operation_id"],
      "repair_operation_id" => "forward-repair-after-release",
      "expected_revision" => workload.revision,
      "target_runtime_revision" => serving.runtime_revision
    }

    assert {:error, :release_target_changed} =
             Update.forward_repair(
               Map.put(attrs, "target_runtime_revision", "sha256:" <> String.duplicate("f", 64))
             )

    assert {:ok, repaired} = Comma.Release.workload_update("forward_repair", attrs)
    assert repaired.update["phase"] == "preparing"
    assert repaired.update["operation_id"] == attrs["repair_operation_id"]
    assert repaired.update["supersedes_operation_id"] == attrs["operation_id"]
    assert repaired.update["source_revision"] == intermediate_digest
    assert repaired.update["target_revision"] == serving.runtime_revision
    assert repaired.update["attempt"] == 2
    refute repaired.update["action_required"]

    assert SalixStore.ComputeWorkloadUpdate.input_paused?(
             Repo.get!(Compute.Workload, workload.id)
           )

    Process.put(
      :compute_reconciler_image_reference,
      serving.spec["runtime_artifact"]["reference"]
    )

    Process.put(:compute_reconciler_manifest_digest, serving.runtime_revision)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(workload.id, 1)
    assert_receive {:compute_host_import_request, _, _}
    assert {:ok, %{update: %{"phase" => "draining"}}} = Update.status(attrs)
  end

  @tag :workload_update
  test "stopping cannot cancel and retry releases the previous quiesce before a fresh stop",
       fixture do
    {fixture, attrs} = update_fixture!(fixture)
    alias SalixEnv.ComputeWorkloadUpdate, as: Update
    assert {:ok, _} = Update.start(attrs)
    assert {:error, :update_in_progress} = Update.start(Map.put(attrs, "operation_id", "another"))
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    Process.put(:compute_reconciler_quiet, true)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, stopping} = Update.status(attrs)

    assert {:error, :update_transition_not_allowed} =
             Update.cancel(Map.put(attrs, "expected_revision", stopping.revision))

    Process.put(
      :compute_reconciler_stop_error,
      {:gateway_error,
       %{
         "code" => "workload_stop_unresolved",
         "stage" => "runtime",
         "resource" => "runtime",
         "message" => "private-host-detail"
       }}
    )

    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, diagnostic} = Update.status(attrs)
    assert diagnostic.update["error"] == "workload_stop_unresolved"
    refute Jason.encode!(diagnostic) =~ "private-host-detail"
    assert_receive {:compute_host_request, _, %{"quiesce_request_id" => previous_quiesce}}
    current = Repo.get!(Compute.Workload, fixture.workload.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^current.id),
      set: [runtime_update: Map.put(current.runtime_update, "deadline", 0)]
    )

    assert {:error, {:gateway_error, %{"code" => "workload_update_action_required"}}} =
             ComputeReconciler.reconcile_workload(current.id, 1)

    assert {:ok, parked} = Update.status(attrs)
    assert {:ok, _} = Update.retry(Map.put(attrs, "expected_revision", parked.revision))
    # A second recovery attempt can start before the previous quiesce was
    # cancelled. It must still address the original Host request.
    current = Repo.get!(Compute.Workload, current.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^current.id),
      set: [runtime_update: Map.put(current.runtime_update, "deadline", 0)]
    )

    assert {:error, {:gateway_error, %{"code" => "workload_update_action_required"}}} =
             ComputeReconciler.reconcile_workload(current.id, 1)

    assert {:ok, parked} = Update.status(attrs)
    assert {:ok, _} = Update.retry(Map.put(attrs, "expected_revision", parked.revision))
    assert {:ok, _} = ComputeReconciler.reconcile_workload(current.id, 1)

    assert_receive {:compute_host_request, _,
                    %{"request_id" => ^previous_quiesce, "cancel" => true}}

    assert Process.get(:compute_reconciler_container_state) == "running"
    Process.delete(:compute_reconciler_stop_error)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(current.id, 1)
    assert_receive {:compute_host_request, _, %{"quiesce_request_id" => next_quiesce}}
    assert next_quiesce != previous_quiesce
    assert Process.get(:compute_reconciler_container_state) == "stopped"
  end

  @tag :workload_update
  test "an absent source can update only after accepted execution settles", fixture do
    {fixture, attrs} = update_fixture!(fixture)
    alias SalixStore.ComputeRuntimeCarrier, as: Carrier
    runtime_id = "runtime:" <> fixture.workload.id
    assert {:ok, _} = Carrier.submit(runtime_id, "7", %{"dispatch_id" => "accepted-before-loss"})
    assert {:ok, [input]} = Carrier.claim_inputs(runtime_id, "7", nil, 1)
    Process.delete(:compute_reconciler_container_state)
    assert :ok = SalixStore.ComputeRuntimeRelease.publish("release", 1)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, waiting} = SalixEnv.ComputeWorkloadUpdate.status(attrs)
    assert waiting.update["phase"] == "preparing"
    assert waiting.update["error"] == "runtime_execution_unresolved"
    assert Repo.get!(Compute.RuntimeInstance, runtime_id).connection_epoch == "7"
    assert {:ok, _} = Carrier.ack(input["id"], runtime_id, "7")
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, replacing} = SalixEnv.ComputeWorkloadUpdate.status(attrs)
    assert replacing.update["phase"] == "replacing"
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, verifying} = SalixEnv.ComputeWorkloadUpdate.status(attrs)
    assert verifying.runtime_revision == attrs["target_runtime_revision"]
    refute_receive {:compute_host_request, _, %{"quiesce_request_id" => _}}
    current = Repo.get!(Compute.Workload, fixture.workload.id)
    assert current.spec["volume_requirements"] == fixture.workload.spec["volume_requirements"]
  end

  @tag :workload_update
  test "automatic retry cancels an old quiesce before renewing its stop attempt", fixture do
    {fixture, attrs} = update_fixture!(fixture)
    assert :ok = SalixStore.ComputeRuntimeRelease.publish("release", 1)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    Process.put(
      :compute_reconciler_stop_error,
      {:gateway_error, %{"code" => "workload_stop_unresolved"}}
    )

    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert_receive {:compute_host_request, _, %{"quiesce_request_id" => prior}}
    current = Repo.get!(Compute.Workload, fixture.workload.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^current.id),
      set: [runtime_update: Map.put(current.runtime_update, "deadline", 0)]
    )

    assert {:ok, _} = ComputeReconciler.reconcile_workload(current.id, 1)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(current.id, 1)
    assert_receive {:compute_host_request, _, %{"cancel" => true, "request_id" => ^prior}}
    Process.delete(:compute_reconciler_stop_error)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(current.id, 1)
    assert_receive {:compute_host_request, _, %{"quiesce_request_id" => next}}
    assert next != prior
    assert {:ok, status} = SalixEnv.ComputeWorkloadUpdate.status(attrs)
    refute status.update["action_required"]
    assert status.update["attempt"] == 2
    assert Process.get(:compute_reconciler_container_state) == "stopped"
  end

  @tag :workload_update
  test "automatic targets survive a different serving catalog and status reads are paged",
       fixture do
    {fixture, attrs} = update_fixture!(fixture)
    alias SalixStore.ComputeRuntimeRelease, as: Release
    assert :ok = Release.publish("committed", 50)
    previous_root = Application.fetch_env!(:salix_store, :runtime_bundle_root)

    try do
      Application.put_env(:salix_store, :runtime_bundle_root, "/unavailable-local-catalog")
      Process.put(:compute_reconciler_quiet, false)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      alias SalixStore.ComputeRuntimeCarrier, as: Carrier
      runtime_id = "runtime:" <> fixture.workload.id
      assert {:ok, _} = Carrier.submit(runtime_id, "7", %{"dispatch_id" => "while-preparing"})
      assert {:ok, [input]} = Carrier.claim_inputs(runtime_id, "7", nil, 1)
      assert {:ok, _} = Carrier.ack(input["id"], runtime_id, "7")
      Process.put(:compute_reconciler_quiet, true)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      update = Repo.get!(Compute.Workload, fixture.workload.id).runtime_update
      assert update["target_revision"] == attrs["target_runtime_revision"]
      assert update["phase"] == "draining"
    after
      Application.put_env(:salix_store, :runtime_bundle_root, previous_root)
    end

    for index <- 1..50 do
      copy = %{
        fixture.workload
        | id: "page-" <> String.pad_leading(Integer.to_string(index), 3, "0")
      }

      Repo.insert!(copy)
    end

    assert {:ok, first} = Release.status_page()
    assert length(first.items) == 50
    assert first.next_cursor != nil
    assert {:ok, last} = Release.status_page(first.next_cursor)
    assert length(last.items) == 1
    assert last.next_cursor == nil
    ids = Enum.map(first.items ++ last.items, & &1.workload_id)
    assert length(Enum.uniq(ids)) == 51
  end

  @tag :workload_update
  test "automatic update retries past deadlines and respects explicit cancellation", fixture do
    {fixture, attrs} = update_fixture!(fixture)
    alias SalixStore.ComputeRuntimeRelease, as: Release
    alias SalixEnv.ComputeWorkloadUpdate, as: Update
    assert :ok = Release.publish("new", 20)
    assert :ok = Release.publish("new", 20)
    assert {:error, :runtime_release_superseded} = Release.publish("late", 19)
    assert {:error, :runtime_release_superseded} = Release.publish("conflict", 20)

    # The existing bounded sweep must find an idle, disconnected old image.
    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [status: "disconnected", readiness: "pending"]
    )

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [provider_observation: %{}]
    )

    assert ComputeReconciler.sweep(1) in [:more, :complete]
    assert {:ok, started} = Update.status(attrs)
    assert started.update["automatic"]
    assert started.update["phase"] == "preparing"

    refute SalixStore.ComputeWorkloadUpdate.input_paused?(
             Repo.get!(Compute.Workload, fixture.workload.id)
           )

    # Reconnect restores quiet evidence. No notification from the Connector
    # is needed to resume the durable update operation.
    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [status: "connected", readiness: "ready"]
    )

    allocation = fixture.allocation

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [provider_observation: allocation.provider_observation]
    )

    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, started} = Update.status(attrs)
    assert started.update["phase"] == "draining"
    operation = started.update["operation_id"]
    update = started.update |> Map.put("deadline", 0) |> Map.put("drain_deadline", 0)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [runtime_update: update]
    )

    Process.put(:compute_reconciler_quiet, false)
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, waiting} = Update.status(attrs)
    refute waiting.update["action_required"]
    assert waiting.update["phase"] == "draining"
    assert Process.get(:compute_reconciler_container_state) == "running"
    assert {:ok, %{items: [%{state: "waiting", stage: "draining"}]}} = Release.status_page()

    assert {:ok, _} =
             Update.cancel(%{
               attrs
               | "operation_id" => operation,
                 "expected_revision" => waiting.revision
             })

    assert :ok = Release.publish("unrelated-server-change", 21)
    # Ordinary recovery may still need to observe the source image. It must
    # not replace the operator's cancellation with another automatic update.
    _ = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert {:ok, cancelled} = Update.status(attrs)
    assert cancelled.update["phase"] == "cancelled"
    assert cancelled.update["operation_id"] == operation
  end

  defp update_fixture!(fixture) do
    fixture = running_external_runtime!(fixture)
    workload = Repo.get!(Compute.Workload, fixture.workload.id)
    {:ok, target} = RuntimeBundleCatalog.image_for_workload(workload)
    old_digest = "sha256:" <> String.duplicate("e", 64)
    old_reference = "comma.local/runtime/external@" <> old_digest

    old =
      workload.spec["runtime_artifact"]
      |> Map.put("manifest_digest", old_digest)
      |> Map.put("reference", old_reference)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [runtime_revision: old_digest, spec: Map.put(workload.spec, "runtime_artifact", old)]
    )

    workload = Repo.get!(Compute.Workload, workload.id)
    Process.put(:compute_reconciler_container_image, old_reference)
    Process.put(:compute_reconciler_image_reference, target["reference"])
    Process.put(:compute_reconciler_manifest_digest, target["manifestDigest"])

    attrs = %{
      "tenant_id" => "tenant",
      "project_id" => "project",
      "workload_id" => workload.id,
      "operation_id" => "upgrade-connector",
      "expected_revision" => workload.revision,
      "target_runtime_revision" => target["manifestDigest"]
    }

    {%{fixture | workload: workload}, attrs}
  end

  defp expire_runtime_bootstrap!(fixture) do
    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [
        status: "disconnected",
        readiness: "pending",
        caught_up_epoch: "0",
        bootstrap_consumed_epoch: "0"
      ]
    )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          Map.put(
            allocation.provider_observation,
            "runtime_bootstrap_expires_at",
            DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
          )
      ]
    )
  end

  test "legacy workload requires rebuild and is not advanced", fixture do
    legacy_spec = Map.delete(fixture.workload.spec, "runtime_artifact")

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [spec: legacy_spec, runtime_revision: "retired-runtime-revision"]
    )

    assert {:error, :runtime_artifact_rebuild_required} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    unchanged = Repo.get!(Compute.Workload, fixture.workload.id)
    assert unchanged.generation == 1
    assert unchanged.runtime_revision == "retired-runtime-revision"
    refute Map.has_key?(unchanged.spec, "runtime_artifact")
  end

  test "runtime digest and descriptor must agree", fixture do
    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [runtime_revision: "sha256:" <> String.duplicate("9", 64)]
    )

    assert {:error, :invalid_runtime_artifact} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert Repo.get!(Compute.Workload, fixture.workload.id).generation == 1
  end

  test "missing connection observation waits without creating commands; malformed epoch requires action",
       fixture do
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [observation: %{}]
    )

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert Repo.aggregate(Compute.Command, :count) == 0

    for epoch <- ["0", "01", "invalid"] do
      Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
        set: [observation: %{"connection_epoch" => epoch}]
      )

      assert {:error, :invalid_connection_epoch} =
               ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

      assert Repo.aggregate(Compute.Command, :count) == 0
    end

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [observation: binding.observation]
    )

    assert {:ok, %{outcome: :pending, command: command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert command.kind == "runtime.open_session"
  end

  test "reconciles one exact shell generation through session, bundle import, container and ready",
       fixture do
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, "sha256:" <> String.duplicate("c", 64))

    assert {:ok, %{outcome: :pending, command: session_command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert session_command.kind == "runtime.open_session"
    refute Map.has_key?(session_command.payload["command_json"], "leaseGeneration")
    assert session_command.payload["command_json"]["openSession"]["allocationGeneration"] == 1

    session_command_id = session_command.id
    session_expires_unix_millis = System.system_time(:millisecond) + 720_000

    assert {:ok, %Compute.Command{id: ^session_command_id, status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               session_command.id,
               "succeeded",
               %{
                 "result" => %{
                   "sessionReady" => %{
                     "allocationId" => fixture.allocation.id,
                     "allocationGeneration" => fixture.allocation.generation,
                     "tunnelNonce" => "tunnel-1",
                     "expiresUnixMillis" => session_expires_unix_millis
                   }
                 }
               }
             )

    assert {:ok, :ok} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => fixture.allocation.id,
               "allocationGeneration" => fixture.allocation.generation,
               "connectionEpoch" => "7",
               "tunnelNonce" => "tunnel-1",
               "expiresUnixMillis" => session_expires_unix_millis
             })

    short_authority = DateTime.add(DateTime.utc_now(), 300, :second)
    Repo.update_all(AgentVMM.Session, set: [expires_at: short_authority])

    assert {:ok, %{outcome: :pending, command: refresh_command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert refresh_command.kind == "runtime.open_session"

    refute_receive {:compute_host_import_request, _, _}, 20

    assert {:ok, %Compute.Command{id: refresh_command_id, status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert refresh_command_id == refresh_command.id
    refreshed_expiry_unix_millis = System.system_time(:millisecond) + 900_000

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               refresh_command.id,
               "succeeded",
               %{
                 "result" => %{
                   "sessionReady" => %{
                     "allocationId" => fixture.allocation.id,
                     "allocationGeneration" => fixture.allocation.generation,
                     "tunnelNonce" => "tunnel-2",
                     "expiresUnixMillis" => refreshed_expiry_unix_millis
                   }
                 }
               }
             )

    assert {:ok, :ok} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => fixture.allocation.id,
               "allocationGeneration" => fixture.allocation.generation,
               "connectionEpoch" => "7",
               "tunnelNonce" => "tunnel-2",
               "expiresUnixMillis" => refreshed_expiry_unix_millis
             })

    assert DateTime.compare(Repo.one!(AgentVMM.Session).expires_at, short_authority) == :gt

    # The production command/result and fair-reconcile path can consume two
    # bounded 60-second stages, and Host inventory has a 95-second bound. Model
    # those elapsed stages before the import decision. The refreshed session
    # must still carry the complete 660-second stream authority.
    delayed_expiry =
      refreshed_expiry_unix_millis
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.add(-215, :second)

    Repo.update_all(AgentVMM.Session, set: [expires_at: delayed_expiry])

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _image_list_url, %{}}
    assert_receive {:compute_host_import_request, import_url, import_headers}
    assert String.ends_with?(import_url, "/compute.image.import")
    assert {"x-comma-image-reference", fixture.image_reference} in import_headers
    assert {"x-comma-archive-url", fixture.image["archiveUrl"]} in import_headers
    assert_receive {:compute_host_request, _image_list_after_import_url, %{}}

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _container_list_url, %{}}
    assert_receive {:compute_host_request, image_list_before_create_url, %{}}
    assert String.ends_with?(image_list_before_create_url, "/compute.image.list")
    assert_receive {:compute_host_request, _create_url, create_args}
    assert create_args["image"] == fixture.image_reference
    assert String.starts_with?(create_args["container_id"], "salix-")
    assert byte_size(create_args["container_id"]) <= 41
    refute Enum.any?(create_args["env"], &String.starts_with?(&1, "SALIX_COMPUTE_RUNTIME_"))

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _start_url, start_args}
    assert start_args["container_id"] == create_args["container_id"]
    assert_receive {:compute_host_request, _container_list_after_start_url, %{}}

    assert {:ok, workload} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert workload.observed_state == "ready"

    ready_revision = workload.revision
    ready_allocation_revision = Repo.get!(Compute.Allocation, fixture.allocation.id).revision

    assert {:ok, unchanged} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert unchanged.revision == ready_revision

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.revision == ready_allocation_revision

    assert allocation.provider_observation["current_container"]["id"] ==
             create_args["container_id"]

    Repo.update_all(
      Compute.Allocation,
      set: [
        provider_observation:
          Map.put(allocation.provider_observation, "container_status", "unexpected")
      ]
    )

    assert {:error, :invalid_container_state} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
  end

  test "reimports a cached Pi image and keeps Pi auth in the persistent workspace",
       fixture do
    Repo.delete_all(
      from(workload in Compute.Workload, where: workload.id == ^fixture.workload.id)
    )

    assert {:ok, pi_workload} =
             Compute.create_workload(%{
               id: fixture.workload.id,
               environment_id: fixture.workload.environment_id,
               allocation_id: fixture.workload.allocation_id,
               kind: "external_worker",
               template_key: "external.pi",
               capability_requirements: ["runtime_exec", "runtime_process"],
               generation: fixture.workload.generation
             })

    assert {:ok, pi_image} = RuntimeBundleCatalog.image_for_workload(pi_workload)
    Process.put(:compute_reconciler_image_reference, pi_image["reference"])
    Process.put(:compute_reconciler_manifest_digest, pi_image["manifestDigest"])

    open_host_session!(fixture, "tunnel-materialization-loss")

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, initial_list_url, %{}}
    assert String.ends_with?(initial_list_url, "/compute.image.list")
    assert_receive {:compute_host_import_request, _initial_import_url, _}
    assert_receive {:compute_host_request, initial_verify_url, %{}}
    assert String.ends_with?(initial_verify_url, "/compute.image.list")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["imported_reference"] == pi_image["reference"]

    # The durable Server fact remains intact while the Host loses the actual
    # materialized rootfs. ListImages is the create-time authority.
    Process.put(:compute_reconciler_image_imported, false)

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, container_list_url, %{}}
    assert String.ends_with?(container_list_url, "/compute.container.list")
    assert_receive {:compute_host_request, actual_image_list_url, %{}}
    assert String.ends_with?(actual_image_list_url, "/compute.image.list")
    assert_receive {:compute_host_import_request, reimport_url, _}
    assert String.ends_with?(reimport_url, "/compute.image.import")
    assert_receive {:compute_host_request, verify_reimport_url, %{}}
    assert String.ends_with?(verify_reimport_url, "/compute.image.list")
    assert_receive {:compute_host_request, volume_list_url, %{}}
    assert String.ends_with?(volume_list_url, "/compute.volume.list")
    assert_receive {:compute_host_request, volume_create_url, _}
    assert String.ends_with?(volume_create_url, "/compute.volume.create")
    assert_receive {:compute_host_request, create_url, create_args}
    assert String.ends_with?(create_url, "/compute.container.create")
    assert create_args["image"] == pi_image["reference"]
    assert "HOME=/workspace" in create_args["env"]
    assert "PI_CODING_AGENT_DIR=/workspace" in create_args["env"]
  end

  test "stops and deletes one superseded generation before creating the current container",
       fixture do
    open_host_session!(fixture, "superseded-container")
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, fixture.image["manifestDigest"])

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [generation: 2, observed_state: "pending"],
      inc: [revision: 1]
    )

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [generation: 2]
    )

    superseded = %{
      "id" => "salix-" <> String.duplicate("a", 32),
      "generation_id" => "container-old-generation",
      "state" => "CONTAINER_STATE_RUNNING",
      "image" => fixture.image_reference
    }

    Process.put(:compute_reconciler_additional_containers, [superseded])

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("imported_reference", fixture.image_reference)
          |> Map.put("current_container", superseded)
          |> Map.put("container_status", "running")
          |> Map.put("container_generation_id", superseded["generation_id"])
      ]
    )

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)

    assert_receive {:compute_host_request, first_list_url, %{}}
    assert String.ends_with?(first_list_url, "/compute.container.list")
    assert_receive {:compute_host_request, stop_url, stop_args}
    assert String.ends_with?(stop_url, "/compute.container.stop")
    assert stop_args["container_id"] == superseded["id"]
    refute_receive {:compute_host_request, _delete_url, _}

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)

    assert_receive {:compute_host_request, second_list_url, %{}}
    assert String.ends_with?(second_list_url, "/compute.container.list")
    assert_receive {:compute_host_request, delete_url, delete_args}
    assert String.ends_with?(delete_url, "/compute.container.delete")
    assert delete_args["container_id"] == superseded["id"]
    assert delete_args["expected_generation_id"] == superseded["generation_id"]

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["current_container"] == %{}
    assert is_nil(allocation.provider_observation["container_status"])

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)

    assert_receive {:compute_host_request, _cleanup_list_url, %{}}
    assert_receive {:compute_host_request, _current_list_url, %{}}
    assert_receive {:compute_host_request, image_list_url, %{}}
    assert String.ends_with?(image_list_url, "/compute.image.list")
    assert_receive {:compute_host_request, create_url, create_args}
    assert String.ends_with?(create_url, "/compute.container.create")
    refute create_args["container_id"] == superseded["id"]
  end

  test "fails closed on an unowned container inventory entry", fixture do
    open_host_session!(fixture, "unknown-container")
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, fixture.image["manifestDigest"])

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [generation: 2, observed_state: "pending"],
      inc: [revision: 1]
    )

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [generation: 2]
    )

    Process.put(:compute_reconciler_additional_containers, [
      %{
        "id" => "operator-container",
        "generation_id" => "operator-generation",
        "state" => "CONTAINER_STATE_STOPPED",
        "image" => fixture.image_reference
      }
    ])

    assert {:error, :invalid_container_inventory} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)

    assert_receive {:compute_host_request, list_url, %{}}
    assert String.ends_with?(list_url, "/compute.container.list")
    refute_receive {:compute_host_request, _mutation_url, _}
  end

  test "materialized templates drive allocation limits and egress", fixture do
    cases = [
      {"shell.default", "shell", "EGRESS_MODE_DENY_ALL"},
      {"external.codex", "external_worker", "EGRESS_MODE_PUBLIC_INTERNET"},
      {"external.pi", "external_worker", "EGRESS_MODE_PUBLIC_INTERNET"},
      {"external.claude", "external_worker", "EGRESS_MODE_PUBLIC_INTERNET"},
      {"meeting.meetnative", "meeting_runtime", "EGRESS_MODE_PUBLIC_INTERNET"}
    ]

    for {template, kind, egress} <- cases do
      workload =
        if template == "shell.default" do
          fixture.workload
        else
          id = "workload-" <> String.replace(template, ".", "-")

          assert {:ok, workload} =
                   Compute.create_workload(%{
                     id: id,
                     environment_id: fixture.workload.environment_id,
                     allocation_id: fixture.allocation.id,
                     kind: kind,
                     template_key: template,
                     capability_requirements: ["runtime_exec", "runtime_process"],
                     generation: 1
                   })

          workload
        end

      assert {:ok, %{command: command}} =
               SalixEnv.ComputeProviders.AgentVMM.allocate(fixture.allocation, workload, [])

      ensure = command.payload["command_json"]["ensureAllocation"]

      assert ensure["generation"] == fixture.allocation.generation

      assert ensure["resourcesV2"] == %{
               "pidMax" => 512,
               "writableQuotaBytes" => 2 * 1024 * 1024 * 1024
             }

      assert ensure["egressMode"] == egress
      assert command.payload["command_json"]["targetRevision"] == 1
      refute Map.has_key?(command.payload["command_json"], "leaseGeneration")
      assert ensure["policyRevision"] == 1
    end
  end

  test "a retained allocation is terminal and is never ensured again", fixture do
    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [observed_state: "ready"]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "8",
               "inventoryWatermark" => 2,
               "inventory" => [
                 %{
                   "allocationId" => fixture.allocation.id,
                   "revision" => "20",
                   "state" => "ALLOCATION_STATE_RETAINED"
                 }
               ]
             })

    retained = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert retained.status == "ready"
    assert retained.provider_observation["allocation_state"] == "retained"
    assert retained.provider_observation["allocation_revision"] == 20

    assert {:error, :allocation_retained} =
             ComputeReconciler.reconcile_workload(
               fixture.workload.id,
               fixture.workload.generation
             )

    refute Repo.get_by(Compute.Command,
             allocation_id: fixture.allocation.id,
             kind: "allocation.ensure"
           )
  end

  test "bounded sweep repairs a runtime that disconnected after its workload became ready",
       fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    Repo.insert!(%Compute.RuntimeInstance{
      id: "runtime:" <> fixture.workload.id,
      workload_id: fixture.workload.id,
      allocation_id: fixture.allocation.id,
      status: "disconnected",
      readiness: "pending",
      generation: fixture.workload.generation,
      connection_epoch: "6",
      caught_up_epoch: "5",
      revision: 1,
      updated_at: DateTime.utc_now()
    })

    demand_external_workload!(fixture.workload.id)

    assert :complete = ComputeReconciler.sweep(32)

    assert %Compute.Command{kind: "runtime.open_session", status: "pending"} =
             Repo.get_by!(Compute.Command,
               allocation_id: fixture.allocation.id,
               workload_id: fixture.workload.id
             )
  end

  test "bounded sweep reopens a runtime whose ready marker has no current host session",
       fixture do
    now = DateTime.utc_now()

    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    # The Runtime Agent previously reported ready on epoch 6, but the provider
    # binding has since advanced to epoch 7 and the host session has expired.
    # The reconciler must not trust the RuntimeInstance row by itself: it must
    # enqueue a fresh Host session so the carrier can claim new input.
    Repo.insert!(%Compute.RuntimeInstance{
      id: "runtime:" <> fixture.workload.id,
      workload_id: fixture.workload.id,
      allocation_id: fixture.allocation.id,
      status: "connected",
      readiness: "ready",
      generation: fixture.workload.generation,
      connection_epoch: "6",
      caught_up_epoch: "6",
      revision: 1,
      updated_at: now
    })

    Repo.insert!(%AgentVMM.Session{
      id: "session-stale",
      registration_id: "registration",
      runtime_instance_id: "runtime:" <> fixture.workload.id,
      allocation_id: fixture.allocation.id,
      allocation_generation: fixture.allocation.generation,
      connection_epoch: "6",
      gateway_instance_id: "gateway-a",
      status: "ready",
      expires_at: DateTime.add(now, -60, :second),
      updated_at: now
    })

    demand_external_workload!(fixture.workload.id)

    assert :complete = ComputeReconciler.sweep(32)

    assert %Compute.Command{kind: "runtime.open_session", status: "pending"} =
             Repo.get_by!(Compute.Command,
               allocation_id: fixture.allocation.id,
               workload_id: fixture.workload.id
             )
  end

  test "create retries bind fresh bootstrap material to fresh request identity", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec
      ]
    )

    fixture = %{
      fixture
      | workload: %{
          fixture.workload
          | kind: "external_worker",
            template_key: materialized.template_key,
            runtime_revision: materialized.runtime_revision,
            spec: materialized.spec
        }
    }

    assert {:ok, external_image} = RuntimeBundleCatalog.image_for_workload(fixture.workload)
    fixture = %{fixture | image_reference: external_image["reference"]}

    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, external_image["manifestDigest"])

    demand_external_workload!(fixture.workload.id)

    assert {:ok, %{outcome: :pending, command: session_command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    session_command_id = session_command.id
    session_expires_unix_millis = System.system_time(:millisecond) + 720_000

    assert {:ok, %Compute.Command{id: ^session_command_id, status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               session_command.id,
               "succeeded",
               %{
                 "result" => %{
                   "sessionReady" => %{
                     "allocationId" => fixture.allocation.id,
                     "allocationGeneration" => fixture.allocation.generation,
                     "tunnelNonce" => "tunnel-expiry",
                     "expiresUnixMillis" => session_expires_unix_millis
                   }
                 }
               }
             )

    assert {:ok, :ok} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => fixture.allocation.id,
               "allocationGeneration" => fixture.allocation.generation,
               "connectionEpoch" => "7",
               "tunnelNonce" => "tunnel-expiry",
               "expiresUnixMillis" => session_expires_unix_millis
             })

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _image_list_url, %{}}
    assert_receive {:compute_host_import_request, _image_import_url, _}
    assert_receive {:compute_host_request, _image_list_after_import_url, %{}}

    Process.put(:compute_reconciler_fail_first_create, true)

    assert {:error, {:gateway_status, 502}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _container_list_url, %{}}
    assert_receive {:compute_host_request, image_list_before_first_create_url, %{}}
    assert String.ends_with?(image_list_before_first_create_url, "/compute.image.list")
    assert_receive {:compute_host_request, volume_list_url, %{}}
    assert String.ends_with?(volume_list_url, "/compute.volume.list")
    assert_receive {:compute_host_request, volume_create_url, volume_create_args}
    assert String.ends_with?(volume_create_url, "/compute.volume.create")
    assert volume_create_args["owner_uid"] == 1_000
    assert volume_create_args["owner_gid"] == 1_000
    assert volume_create_args["mode"] == 0o700
    assert_receive {:compute_host_request, _create_url, first_create_args}
    assert first_create_args["log_limit_bytes"] == 1_048_576

    assert first_create_args["volumes"] == [
             %{
               "volume_id" => volume_create_args["volume_id"],
               "destination" => "/workspace",
               "read_only" => false
             }
           ]

    assert "HOME=/workspace" in first_create_args["env"]
    assert "CODEX_HOME=/workspace" in first_create_args["env"]
    assert "SALIX_COMPUTE_RUNTIME_PROVIDER=codex" in first_create_args["env"]
    assert "SALIX_COMPUTE_TENANT_ID=tenant" in first_create_args["env"]
    assert "SALIX_COMPUTE_PROJECT_ID=project" in first_create_args["env"]

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _container_list_retry_url, %{}}
    assert_receive {:compute_host_request, image_list_before_retry_url, %{}}
    assert String.ends_with?(image_list_before_retry_url, "/compute.image.list")
    assert_receive {:compute_host_request, retry_volume_list_url, %{}}
    assert String.ends_with?(retry_volume_list_url, "/compute.volume.list")
    assert_receive {:compute_host_request, _create_retry_url, second_create_args}

    assert second_create_args["request_id"] != first_create_args["request_id"]
    assert second_create_args["container_id"] == first_create_args["container_id"]
    assert second_create_args["log_limit_bytes"] == 1_048_576

    first_token =
      Enum.find(
        first_create_args["env"],
        &String.starts_with?(&1, "SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN=")
      )

    second_token =
      Enum.find(
        second_create_args["env"],
        &String.starts_with?(&1, "SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN=")
      )

    assert is_binary(first_token)
    assert is_binary(second_token)
    assert first_token != second_token

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    persisted_observation = Jason.encode!(allocation.provider_observation)
    refute String.contains?(persisted_observation, "SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN")

    refute String.contains?(
             persisted_observation,
             String.replace_prefix(second_token, "SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN=", "")
           )

    expired_observation =
      Map.put(
        allocation.provider_observation,
        "runtime_bootstrap_expires_at",
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
      )

    Repo.update_all(Compute.Allocation, set: [provider_observation: expired_observation])

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _expired_container_list_url, %{}}
    assert_receive {:compute_host_request, delete_url, delete_args}
    assert String.ends_with?(delete_url, "/compute.container.delete")
    assert delete_args["expected_generation_id"] == "container-1"
    assert_receive {:compute_host_request, _container_list_after_delete_url, %{}}

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _container_list_for_recreate_url, %{}}
    assert_receive {:compute_host_request, image_list_before_recreate_url, %{}}
    assert String.ends_with?(image_list_before_recreate_url, "/compute.image.list")
    assert_receive {:compute_host_request, recreate_volume_list_url, %{}}
    assert String.ends_with?(recreate_volume_list_url, "/compute.volume.list")
    assert_receive {:compute_host_request, recreate_url, recreate_args}
    assert String.ends_with?(recreate_url, "/compute.container.create")
    assert recreate_args["request_id"] != second_create_args["request_id"]
    assert recreate_args["container_id"] == second_create_args["container_id"]
    assert recreate_args["log_limit_bytes"] == 1_048_576
    assert recreate_args["volumes"] == first_create_args["volumes"]

    assert Enum.any?(
             recreate_args["env"],
             &String.starts_with?(&1, "SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN=")
           )

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _start_recreated_url, _start_recreated_args}
    assert_receive {:compute_host_request, _list_after_recreated_start_url, %{}}

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    execution_epoch = allocation.provider_observation["runtime_execution_epoch"]
    assert execution_epoch != "7"

    assert {:ok, runtime} =
             Compute.observe_runtime(%{
               id: "runtime:" <> fixture.workload.id,
               workload_id: fixture.workload.id,
               allocation_id: allocation.id,
               generation: fixture.workload.generation,
               connection_epoch: execution_epoch
             })

    assert {:ok, _runtime} =
             Compute.complete_runtime_catch_up(runtime.id, runtime.revision, execution_epoch)

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_auth_request, "runtime:workload", ^execution_epoch, auth_read}
    assert auth_read["method"] == "runtime_auth_read"

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["runtime_auth_status"] == "unauthenticated"
    assert allocation.provider_observation["runtime_auth_ready"] == false
    refute Map.has_key?(allocation.provider_observation, "health")

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [provider_observation: Map.put(allocation.provider_observation, "health", "sleeping")],
      inc: [revision: 1]
    )

    Application.put_env(:salix_store, :compute_reconciler_auth_ready, true)

    assert {:ok, ready_workload} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert ready_workload.observed_state == "ready"
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["runtime_auth_status"] == "authenticated"
    assert allocation.provider_observation["runtime_native_ready"] == true
    refute Map.has_key?(allocation.provider_observation, "health")
  end

  test "Claude readiness creates temporary state on the writable provider volume", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.claude",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec
      ]
    )

    fixture = %{
      fixture
      | workload: %{
          fixture.workload
          | kind: "external_worker",
            template_key: materialized.template_key,
            runtime_revision: materialized.runtime_revision,
            spec: materialized.spec
        }
    }

    assert {:ok, external_image} = RuntimeBundleCatalog.image_for_workload(fixture.workload)
    fixture = %{fixture | image_reference: external_image["reference"]}

    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, external_image["manifestDigest"])

    open_host_session!(fixture, "tunnel-claude-writable-tmp")

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _image_list_url, %{}}
    assert_receive {:compute_host_import_request, _image_import_url, _}
    assert_receive {:compute_host_request, _image_list_after_import_url, %{}}

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _container_list_url, %{}}
    assert_receive {:compute_host_request, _image_list_before_create_url, %{}}
    assert_receive {:compute_host_request, _volume_list_url, %{}}
    assert_receive {:compute_host_request, _volume_create_url, _volume_create_args}
    assert_receive {:compute_host_request, _create_url, create_args}

    assert create_args["read_only_root"]
    assert create_args["volumes"] |> Enum.any?(&(&1["destination"] == "/workspace"))
    assert "HOME=/workspace" in create_args["env"]
    assert "TMPDIR=/workspace" in create_args["env"]
    assert "SALIX_COMPUTE_RUNTIME_PROVIDER=claude" in create_args["env"]
  end

  test "a cold external workload remains sleeping until a candidate arrives", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec
      ]
    )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [provider_observation: Map.put(allocation.provider_observation, "health", "ready")]
    )

    assert {:ok, sleeping} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert sleeping.observed_state == "ready"
    refute Repo.get_by(Compute.Command, workload_id: fixture.workload.id)
    refute_receive {:compute_host_request, _, _}

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["current_container"] == %{}
    assert allocation.provider_observation["container_status"] == "absent"
    refute Map.has_key?(allocation.provider_observation, "health")

    demand_external_workload!(fixture.workload.id)

    assert {:ok, %{outcome: :pending, command: command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert command.kind == "runtime.open_session"
  end

  test "the sweep excludes an idle external workload and claims it after demand", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("imported_reference", materialized.spec["runtime_artifact"]["reference"])
          |> Map.put("current_container", %{})
          |> Map.put("container_status", "absent")
      ]
    )

    assert :complete = ComputeReconciler.sweep(1)
    refute Repo.get_by(Compute.ReconcilerClaim, workload_id: fixture.workload.id)
    refute Repo.get_by(Compute.Command, workload_id: fixture.workload.id)

    demand_external_workload!(fixture.workload.id)

    assert :more = ComputeReconciler.sweep(1)

    assert Repo.get_by(Compute.Command,
             workload_id: fixture.workload.id,
             kind: "runtime.open_session"
           )
  end

  test "a deferred external candidate wakes its workload only after it is due", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    token = "deferred-demand-#{fixture.workload.id}"

    assert :ok =
             SessionWorkCandidates.insert(%{
               "token" => token,
               "agent_id" => "agent-deferred-demand",
               "runtime_kind" => "external",
               "session_id" => "session-deferred-demand",
               "workload_id" => fixture.workload.id,
               "base_revision" => "revision-deferred-demand",
               "recover_after_ms" => System.system_time(:millisecond) + 60_000,
               "reasons" => ["dependency_wait"],
               "updated_at" => System.system_time(:second)
             })

    assert :complete = ComputeReconciler.sweep(1)
    refute Repo.get_by(Compute.ReconcilerClaim, workload_id: fixture.workload.id)
    refute Repo.get_by(Compute.Command, workload_id: fixture.workload.id)

    Repo.query!(
      "UPDATE session_work_candidates SET due_at_ms = floor(extract(epoch FROM statement_timestamp()) * 1000)::bigint - 1000 WHERE candidate_token = $1",
      [token]
    )

    assert :more = ComputeReconciler.sweep(1)

    assert Repo.get_by(Compute.Command,
             workload_id: fixture.workload.id,
             kind: "runtime.open_session"
           )
  end

  test "pressure reclaim checks live facts and drains obligations while no-pressure idle stays warm",
       fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    fixture = %{
      fixture
      | workload: %{
          fixture.workload
          | kind: "external_worker",
            template_key: materialized.template_key,
            runtime_revision: materialized.runtime_revision,
            spec: materialized.spec,
            observed_state: "ready"
        }
    }

    assert {:ok, external_image} = RuntimeBundleCatalog.image_for_workload(fixture.workload)
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, external_image["reference"])
    Process.put(:compute_reconciler_manifest_digest, external_image["manifestDigest"])

    open_host_session!(fixture, "tunnel-idle-stop")

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.id == ^("runtime:" <> fixture.workload.id)),
      set: [
        status: "connected",
        readiness: "ready",
        caught_up_epoch: "7",
        bootstrap_consumed_epoch: "7"
      ],
      inc: [revision: 1]
    )

    container_id = expected_container_id(fixture.workload.id, fixture.workload.generation)
    Process.put(:compute_reconciler_container_id, container_id)
    Process.put(:compute_reconciler_container_state, "running")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.merge(%{
            "runtime_execution_epoch" => "7",
            "runtime_container_generation_id" => "container-1",
            "runtime_container_instance_id" => "instance-1",
            "runtime_verified_host_epoch" => "7"
          })
          |> Map.put("current_container", %{})
          |> Map.put("container_status", nil)
          |> Map.put("container_generation_id", nil)
          |> Map.put("imported_reference", external_image["reference"])
      ]
    )

    assert :ok = SessionWorkCandidates.delete_exact("demand-#{fixture.workload.id}")

    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    refute_receive {:compute_host_request, _, _}

    for attrs <- [
          %{"allocationId" => "another-tenant-allocation"},
          %{"expiresUnixMillis" => Integer.to_string(System.system_time(:millisecond) - 1)}
        ] do
      offer_reclaim!(fixture, attrs)
      assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
      refute_receive {:compute_host_request, _, _}
    end

    offer_reclaim!(fixture)

    Process.put(:compute_reconciler_quiet, false)

    assert {:error, :runtime_auth_failed} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _, %{}}
    assert_receive {:compute_host_request, _, %{"minimum_idle_seconds" => 60}}
    assert_receive {:compute_auth_request, "runtime:workload", "7", _}
    assert_receive {:compute_host_request, cancel_url, %{"cancel" => true}}
    assert String.ends_with?(cancel_url, "/compute.container.quiesce")
    refute_receive {:compute_host_request, _, %{"quiesce_request_id" => _}}
    Process.delete(:compute_reconciler_quiet)

    Process.put(:compute_reconciler_quiet_hook, fn ->
      demand_external_workload!(fixture.workload.id)
    end)

    assert {:error, :reclaim_cancelled} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _, %{}}
    assert_receive {:compute_host_request, _, %{"minimum_idle_seconds" => 60}}
    assert_receive {:compute_auth_request, _, _, _}
    assert_receive {:compute_host_request, _, %{"cancel" => true}}
    refute_receive {:compute_host_request, _, %{"quiesce_request_id" => _}}
    Process.delete(:compute_reconciler_quiet_hook)
    assert :ok = SessionWorkCandidates.delete_exact("demand-#{fixture.workload.id}")

    assert {:ok, sleeping} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert sleeping.observed_state == "ready"
    assert_receive {:compute_host_request, list_url, %{}}
    assert String.ends_with?(list_url, "/compute.container.list")
    assert_receive {:compute_host_request, quiesce_url, quiesce_args}
    assert String.ends_with?(quiesce_url, "/compute.container.quiesce")
    assert quiesce_args["expected_instance_id"] == "instance-1"
    assert quiesce_args["minimum_idle_seconds"] == 60
    assert_receive {:compute_auth_request, "runtime:workload", "7", quiet_request}
    assert quiet_request["method"] == "agent_runtime_quiet"
    assert_receive {:compute_host_request, stop_url, stop_args}
    assert String.ends_with?(stop_url, "/compute.container.stop")
    assert stop_args["expected_instance_id"] == "instance-1"
    assert stop_args["quiesce_request_id"] == quiesce_args["request_id"]
    assert_receive {:compute_host_request, verify_url, %{}}
    assert String.ends_with?(verify_url, "/compute.container.list")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["container_status"] == "stopped"
    refute Map.has_key?(allocation.provider_observation, "health")

    demand_external_workload!(fixture.workload.id)

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _inspect_stopped_url, %{}}
    assert_receive {:compute_host_request, delete_url, delete_args}
    assert String.ends_with?(delete_url, "/compute.container.delete")
    assert delete_args["container_id"] == container_id
    assert delete_args["expected_generation_id"] == "container-1"
    refute_receive {:compute_host_request, _, %{"volume_id" => _}}
  end

  test "an idle external workload replaces an expired bootstrap before runtime quiet", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.pi",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    fixture = %{
      fixture
      | workload: %{
          fixture.workload
          | kind: "external_worker",
            template_key: materialized.template_key,
            runtime_revision: materialized.runtime_revision,
            spec: materialized.spec,
            observed_state: "ready"
        }
    }

    assert {:ok, external_image} = RuntimeBundleCatalog.image_for_workload(fixture.workload)
    container_id = expected_container_id(fixture.workload.id, fixture.workload.generation)
    Process.put(:compute_reconciler_container_id, container_id)
    Process.put(:compute_reconciler_container_state, "running")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("current_container", %{
            "id" => container_id,
            "generation_id" => "container-expired-bootstrap",
            "instance_id" => "instance-expired-bootstrap",
            "state" => "running"
          })
          |> Map.put("container_status", "running")
          |> Map.put("container_generation_id", "container-expired-bootstrap")
          |> Map.put("imported_reference", external_image["reference"])
          |> Map.put(
            "runtime_bootstrap_expires_at",
            DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
          )
      ]
    )

    assert :ok = SessionWorkCandidates.delete_exact("demand-#{fixture.workload.id}")

    assert {:ok, %{outcome: :pending, command: command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert command.kind == "runtime.open_session"
    refute_receive {:compute_host_request, _, _}

    open_host_session!(fixture, "tunnel-idle-expired-bootstrap")

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.id == ^("runtime:" <> fixture.workload.id)),
      set: [status: "disconnected", readiness: "pending", caught_up_epoch: "0"],
      inc: [revision: 1]
    )

    assert :ok = SessionWorkCandidates.delete_exact("demand-#{fixture.workload.id}")

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, list_url, %{}}
    assert String.ends_with?(list_url, "/compute.container.list")
    refute_receive {:compute_host_request, _, %{"cancel" => true}}
    assert_receive {:compute_host_request, quiesce_url, quiesce_args}
    assert String.ends_with?(quiesce_url, "/compute.container.quiesce")
    assert quiesce_args["expected_instance_id"] == "instance-1"
    assert_receive {:compute_host_request, stop_url, stop_args}
    assert String.ends_with?(stop_url, "/compute.container.stop")
    assert stop_args["expected_instance_id"] == "instance-1"
    assert stop_args["quiesce_request_id"] == quiesce_args["request_id"]
    assert_receive {:compute_host_request, verify_url, %{}}
    assert String.ends_with?(verify_url, "/compute.container.list")
    refute_receive {:compute_auth_request, _, _, _}

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["container_status"] == "stopped"
    assert is_nil(allocation.provider_observation["runtime_container_instance_id"])
  end

  test "lost demand opens an inspection session before resolving stale container facts",
       fixture do
    offer_reclaim!(fixture)

    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    container_id = expected_container_id(fixture.workload.id, fixture.workload.generation)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("imported_reference", materialized.spec["runtime_artifact"]["reference"])
          |> Map.put("current_container", %{
            "id" => container_id,
            "generation_id" => "container-stale",
            "instance_id" => "instance-stale",
            "state" => "running"
          })
          |> Map.put("container_status", "running")
          |> Map.put("container_generation_id", "container-stale")
      ]
    )

    assert :more = ComputeReconciler.sweep(1)

    command = Repo.get_by!(Compute.Command, workload_id: fixture.workload.id)
    assert command.kind == "runtime.open_session"
    refute_receive {:compute_host_request, _, _}
  end

  test "an observed stopped external workload does not open a session", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    container_id = expected_container_id(fixture.workload.id, fixture.workload.generation)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("imported_reference", materialized.spec["runtime_artifact"]["reference"])
          |> Map.put("health", "sleeping")
          |> Map.put("current_container", %{
            "id" => container_id,
            "generation_id" => "container-sleeping",
            "state" => "stopped"
          })
          |> Map.put("container_status", "stopped")
          |> Map.put("container_generation_id", "container-sleeping")
      ]
    )

    assert :more = ComputeReconciler.sweep(1)

    refute Repo.get_by(Compute.Command, workload_id: fixture.workload.id)

    refute Map.has_key?(
             Repo.get!(Compute.Allocation, allocation.id).provider_observation,
             "health"
           )

    refute_receive {:compute_host_request, _, _}
  end

  test "a retained allocation reopens a session without replacing allocation or runtime identity",
       fixture do
    offer_reclaim!(fixture)

    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    container_id = expected_container_id(fixture.workload.id, fixture.workload.generation)

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.put("imported_reference", materialized.spec["runtime_artifact"]["reference"])
          |> Map.put("current_container", %{
            "id" => container_id,
            "generation_id" => "container-stale",
            "instance_id" => "instance-stale",
            "state" => "running"
          })
          |> Map.put("container_status", "running")
          |> Map.put("container_generation_id", "container-stale")
      ]
    )

    runtime_id = "runtime-instance-inspection"

    assert {:ok, _runtime} =
             Compute.prepare_runtime_bootstrap(%{
               id: runtime_id,
               workload_id: fixture.workload.id,
               allocation_id: allocation.id,
               generation: fixture.workload.generation,
               connection_epoch: "17"
             })

    assert :more = ComputeReconciler.sweep(1)

    open_session =
      Repo.get_by!(Compute.Command,
        workload_id: fixture.workload.id,
        kind: "runtime.open_session"
      )

    assert open_session.kind == "runtime.open_session"

    assert open_session.payload["command_json"]["openSession"] == %{
             "allocationId" => allocation.id,
             "allocationGeneration" => allocation.generation,
             "executionOwnerId" => "#{runtime_id}:#{fixture.workload.generation}"
           }

    assert {:ok, claimed} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert claimed.id == open_session.id

    expires_unix_millis = System.system_time(:millisecond) + 60_000

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               open_session.id,
               "succeeded",
               %{
                 "result" => %{
                   "sessionReady" => %{
                     "allocationId" => allocation.id,
                     "allocationGeneration" => allocation.generation,
                     "tunnelNonce" => "inspection-tunnel",
                     "expiresUnixMillis" => Integer.to_string(expires_unix_millis)
                   }
                 }
               }
             )

    assert Repo.get_by!(Compute.RuntimeInstance,
             workload_id: fixture.workload.id,
             allocation_id: allocation.id,
             generation: fixture.workload.generation
           ).id == runtime_id

    assert {:ok, :ok} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => allocation.id,
               "allocationGeneration" => allocation.generation,
               "connectionEpoch" => "7",
               "tunnelNonce" => "inspection-tunnel",
               "expiresUnixMillis" => Integer.to_string(expires_unix_millis)
             })

    assert {:ok, session} = AgentVMM.current_host_session_for_workload(fixture.workload.id)
    assert session.runtime_instance_id == runtime_id

    refute_receive {:compute_host_request, _, _}
  end

  test "new demand cancels an idle quiesce before using a running workload", fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "external.codex",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(Compute.Workload,
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    workload = %{
      fixture.workload
      | kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
    }

    assert {:ok, external_image} = RuntimeBundleCatalog.image_for_workload(workload)
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, external_image["reference"])
    Process.put(:compute_reconciler_manifest_digest, external_image["manifestDigest"])
    Application.put_env(:salix_store, :compute_reconciler_auth_ready, true)
    open_host_session!(fixture, "tunnel-demand-cancel")

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.id == ^("runtime:" <> fixture.workload.id)),
      set: [
        status: "connected",
        readiness: "ready",
        caught_up_epoch: "7",
        bootstrap_consumed_epoch: "7"
      ],
      inc: [revision: 1]
    )

    container_id = expected_container_id(fixture.workload.id, fixture.workload.generation)
    Process.put(:compute_reconciler_container_id, container_id)
    Process.put(:compute_reconciler_container_state, "running")
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          allocation.provider_observation
          |> Map.merge(%{
            "runtime_execution_epoch" => "7",
            "runtime_container_generation_id" => "container-1",
            "runtime_container_instance_id" => "instance-1",
            "runtime_verified_host_epoch" => "7"
          })
          |> Map.put("current_container", %{
            "id" => container_id,
            "generation_id" => "container-1",
            "instance_id" => "instance-1",
            "state" => "running"
          })
          |> Map.put("container_status", "running")
          |> Map.put("container_generation_id", "container-1")
          |> Map.put("imported_reference", external_image["reference"])
      ]
    )

    demand_external_workload!(fixture.workload.id)

    assert {:ok, ready} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    assert ready.observed_state == "ready"
    assert_receive {:compute_host_request, list_url, %{}}
    assert String.ends_with?(list_url, "/compute.container.list")
    assert_receive {:compute_host_request, quiesce_url, quiesce_args}
    assert String.ends_with?(quiesce_url, "/compute.container.quiesce")
    assert quiesce_args["container_id"] == container_id
    assert quiesce_args["expected_instance_id"] == "instance-1"
    assert quiesce_args["cancel"] == true
    assert_receive {:compute_auth_request, "runtime:workload", "7", read_request}
    assert read_request["method"] == "runtime_auth_read"
  end

  test "does not scan or reconcile a stale generation", fixture do
    assert {:error, :stale_generation} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)
  end

  test "bounded sweep skips workloads owned by unsupported providers", fixture do
    now = DateTime.utc_now()
    old = DateTime.add(now, -60, :second)

    Repo.insert!(%Compute.ProviderBinding{
      id: "unsupported-binding",
      pool_id: "pool",
      provider: "cloudflare",
      provider_ref: "unsupported",
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: old
    })

    Repo.insert!(%Compute.Allocation{
      id: "unsupported-allocation",
      environment_id: "environment",
      provider_binding_id: "unsupported-binding",
      status: "ready",
      operation_outcome: "succeeded",
      provider_observation: %{},
      generation: 1,
      revision: 1,
      created_at: old,
      updated_at: old
    })

    Repo.insert!(%Compute.Workload{
      id: "unsupported-workload",
      environment_id: "environment",
      allocation_id: "unsupported-allocation",
      kind: "shell",
      spec: %{},
      template_key: "shell.default",
      runtime_revision: "unsupported",
      capability_requirements: [],
      desired_state: "ready",
      observed_state: "pending",
      generation: 1,
      revision: 1,
      created_at: old,
      updated_at: old
    })

    assert :more = ComputeReconciler.sweep(1)

    assert Repo.get_by(Compute.Command,
             workload_id: fixture.workload.id,
             kind: "runtime.open_session"
           )

    refute Repo.get_by(Compute.Command, workload_id: "unsupported-workload")
  end

  @tag :runtime_recovery
  test "Host reconnect keeps the execution credential and resumes only its exact container",
       fixture do
    fixture = running_external_runtime!(fixture)

    {:ok, credential} =
      Compute.WorkloadCredential.issue_for_runtime(
        fixture.workload.id,
        "runtime:" <> fixture.workload.id,
        ["runtime"],
        60
      )

    assert {:ok, _} = AgentVMM.mark_connection_lost("registration", "gateway-a", "7")
    reconnect_host!(fixture, "8")
    open_host_session!(fixture, "same-instance-new-host", "8")
    runtime = Repo.get!(Compute.RuntimeInstance, "runtime:" <> fixture.workload.id)
    assert runtime.connection_epoch == "7"
    assert runtime.bootstrap_consumed_epoch == "7"

    assert {:error, :runtime_control_unavailable} =
             Compute.open_runtime_carrier(credential["token"], runtime_handshake())

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_receive {:compute_host_request, _, %{"quiesce_request_id" => _}}
    refute_receive {:compute_host_request, _, %{"expected_generation_id" => _}}
    assert {:ok, resumed} = Compute.open_runtime_carrier(credential["token"], runtime_handshake())
    assert resumed.runtime.connection_epoch == "7"
    assert {:ok, session} = AgentVMM.current_session_for_workload(fixture.workload.id)
    assert session.connection_epoch == "8"

    Repo.update_all(from(s in AgentVMM.Session, where: s.id == ^session.id),
      set: [gateway_instance_id: "retired-gateway"]
    )

    assert {:error, :runtime_control_unavailable} =
             Compute.open_runtime_carrier(credential["token"], runtime_handshake())

    Repo.update_all(from(s in AgentVMM.Session, where: s.id == ^session.id),
      set: [
        gateway_instance_id: "gateway-a",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      ]
    )

    assert {:error, :runtime_control_unavailable} =
             Compute.open_runtime_carrier(credential["token"], runtime_handshake())
  end

  @tag :runtime_recovery
  test "expired recovery returns a bounded error but automatically resumes the same execution",
       fixture do
    fixture = running_external_runtime!(fixture)

    {:ok, credential} =
      Compute.WorkloadCredential.issue_for_runtime(
        fixture.workload.id,
        "runtime:" <> fixture.workload.id,
        ["runtime"],
        60
      )

    assert {:ok, _} = AgentVMM.mark_connection_lost("registration", "gateway-a", "7")
    reconnect_host!(fixture, "8")
    open_host_session!(fixture, "recovered-after-budget", "8")

    Repo.delete_all(Compute.ReconcilerClaim)

    # Reproduce a persisted claim from an older release that parked at 900s.
    expired = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -901, :second))
    now = DateTime.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{fixture.workload.id}:1",
      provider: "agent_vmm",
      workload_id: fixture.workload.id,
      generation: 1,
      claim_token: "old-claim",
      attempt_count: 2,
      created_at: now,
      updated_at: now,
      last_error: %{
        "kind" => "action_required",
        "code" => "runtime_recovery_expired",
        "runtime_recovery_deadline" => expired
      }
    })

    assert {:error, :runtime_recovery_expired} =
             Compute.open_runtime_carrier(credential["token"], runtime_handshake())

    drain_host_requests()

    assert {:error, {:gateway_error, %{"code" => "runtime_recovery_expired"}}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_receive {:compute_host_request, _, _}

    # No operator retry and no deadline reset. The ordinary sweep repairs proof.
    assert :complete = ComputeReconciler.sweep(32)
    assert_receive {:compute_host_request, _, %{}}
    claim = Repo.get_by!(Compute.ReconcilerClaim, workload_id: fixture.workload.id)
    assert claim.last_error["runtime_recovery_deadline"] == expired
    assert claim.last_error["kind"] == "retryable"
    assert DateTime.compare(claim.next_retry_at, now) == :gt

    assert {:ok, resumed} = Compute.open_runtime_carrier(credential["token"], runtime_handshake())
    assert resumed.runtime.connection_epoch == "7"
    runtime = Repo.get!(Compute.RuntimeInstance, "runtime:" <> fixture.workload.id)
    assert Compute.runtime_control_current?(runtime)

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).provider_observation[
             "runtime_container_instance_id"
           ] == "instance-1"

    refute_received {:compute_host_request, _, %{"quiesce_request_id" => _}}

    # An operator may advance the next attempt, but cannot erase outage age.
    assert {:ok, %{retry: "scheduled"}} =
             ComputeReconciler.retry_runtime_recovery(fixture.workload.id, 1, expired)

    assert Repo.get!(Compute.ReconcilerClaim, claim.id).last_error["runtime_recovery_deadline"] ==
             expired

    ComputeReconciler.sweep(32)

    assert Repo.get_by!(Compute.ReconcilerClaim, workload_id: fixture.workload.id).last_error ==
             %{}
  end

  @tag :runtime_recovery
  test "a new Host Session bypasses recovery backoff while a different import holds its slot",
       fixture do
    fixture = running_external_runtime!(fixture)
    runtime = Repo.get!(Compute.RuntimeInstance, "runtime:" <> fixture.workload.id)
    {:ok, session} = AgentVMM.current_host_session_for_workload(fixture.workload.id)
    fast_id = "fast-workload"
    container_id = expected_container_id(fast_id, 1)

    fast_facts =
      fixture.allocation.provider_observation
      |> put_in(["current_container", "id"], container_id)
      |> Map.put("runtime_verified_host_epoch", "old-host")

    clone_row(fixture.allocation, %{id: "fast-allocation", provider_observation: fast_facts})
    clone_row(fixture.workload, %{id: fast_id, allocation_id: "fast-allocation"})

    clone_row(runtime, %{
      id: "runtime:" <> fast_id,
      workload_id: fast_id,
      allocation_id: "fast-allocation",
      status: "disconnected",
      readiness: "pending"
    })

    clone_row(session, %{
      id: "fast-host-session",
      runtime_instance_id: "runtime:" <> fast_id,
      allocation_id: "fast-allocation"
    })

    demand_external_workload!(fast_id)
    now = DateTime.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{fast_id}:1",
      provider: "agent_vmm",
      workload_id: fast_id,
      generation: 1,
      claim_token: "old-fast-claim",
      attempt_count: 4,
      next_retry_at: DateTime.add(now, 60, :second),
      created_at: now,
      updated_at: now,
      last_error: %{
        "kind" => "action_required",
        "code" => "runtime_recovery_expired",
        "runtime_recovery_deadline" => DateTime.to_iso8601(DateTime.add(now, -901, :second))
      }
    })

    # The slow Workload needs an image import. Its task must not own another
    # Workload's lease while it waits for the provider response.
    facts = Map.delete(fixture.allocation.provider_observation, "imported_reference")

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [provider_observation: facts]
    )

    seed =
      Process.get()
      |> Enum.filter(fn {key, _} ->
        is_atom(key) and String.starts_with?(Atom.to_string(key), "compute_reconciler_")
      end)

    slow = Keyword.put(seed, :compute_reconciler_image_imported, false)
    fast = Keyword.put(seed, :compute_reconciler_container_id, container_id)
    Application.put_env(:salix_store, :compute_scheduler_fixtures, %{slow: slow, fast: fast})
    Application.put_env(:salix_store, :agent_vmm_host_http_client, ConcurrentHostHTTP)
    on_exit(fn -> Application.delete_env(:salix_store, :compute_scheduler_fixtures) end)

    scheduler =
      start_supervised!({ComputeReconciler, name: :recovery_scheduler_test, interval_ms: 60_000})

    assert_receive {:blocked_import, importer}, 5_000
    slow_claim = Repo.get_by!(Compute.ReconcilerClaim, workload_id: fixture.workload.id)
    ComputeReconciler.host_session_ready(fixture.allocation.id, scheduler)
    ComputeReconciler.host_session_ready("fast-allocation", scheduler)

    eventually(fn ->
      Repo.get!(Compute.Allocation, "fast-allocation").provider_observation[
        "runtime_verified_host_epoch"
      ] == "7"
    end)

    assert Repo.get!(Compute.ReconcilerClaim, slow_claim.id).claim_token == slow_claim.claim_token
    refute_receive {:blocked_import, _}, 50

    {:ok, credential} =
      Compute.WorkloadCredential.issue_for_runtime(
        fast_id,
        "runtime:" <> fast_id,
        ["runtime"],
        60
      )

    assert {:ok, resumed} = Compute.open_runtime_carrier(credential["token"], runtime_handshake())
    assert resumed.runtime.connection_epoch == "7"
    # A failed local provider task releases its claim for a later retry.
    Process.exit(importer, :kill)

    eventually(fn ->
      is_nil(Repo.get!(Compute.ReconcilerClaim, slow_claim.id).lease_expires_at)
    end)

    assert Process.alive?(scheduler)
    stop_supervised(ComputeReconciler)
  end

  defp clone_row(%module{} = row, changes) do
    attrs = row |> Map.from_struct() |> Map.delete(:__meta__) |> Map.merge(changes)
    Repo.insert!(struct(module, attrs))
  end

  defp eventually(assertion, attempts \\ 100)
  defp eventually(assertion, 0), do: assert(assertion.())

  defp eventually(assertion, attempts) do
    unless assertion.() do
      Process.sleep(20)
      eventually(assertion, attempts - 1)
    end
  end

  @tag :runtime_recovery
  test "same container name cannot authorize another execution instance", fixture do
    fixture = running_external_runtime!(fixture)

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [status: "disconnected", readiness: "pending"]
    )

    Process.put(:compute_reconciler_container_instance, "replacement-instance")

    assert {:error, :runtime_instance_changed} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_receive {:compute_host_request, _, %{"quiesce_request_id" => _}}

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).provider_observation[
             "runtime_container_instance_id"
           ] == "instance-1"
  end

  @tag :runtime_recovery
  test "authoritative stopped container replaces a stale running projection", fixture do
    fixture = running_external_runtime!(fixture)
    Process.put(:compute_reconciler_container_state, "stopped")
    Process.put(:compute_reconciler_container_instance, nil)

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, list_url, %{}}
    assert String.ends_with?(list_url, "/compute.container.list")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["container_status"] == "stopped"
    assert allocation.provider_observation["current_container"]["state"] == "stopped"
    assert is_nil(allocation.provider_observation["runtime_container_instance_id"])

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, _list_url, %{}}
    assert_receive {:compute_host_request, delete_url, delete_args}
    assert String.ends_with?(delete_url, "/compute.container.delete")
    assert delete_args["expected_generation_id"] == "container-1"
  end

  @tag :runtime_recovery
  test "expired bootstrap rejects a running container without execution identity", fixture do
    fixture = running_external_runtime!(fixture)
    expire_runtime_bootstrap!(fixture)
    Process.put(:compute_reconciler_container_state, "running")
    Process.put(:compute_reconciler_container_instance, nil)

    assert {:error, :container_instance_unavailable} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_receive {:compute_host_request, _, %{"minimum_idle_seconds" => 0}}
  end

  @tag :runtime_recovery
  test "expired bootstrap rejects a stopped container without delete fence", fixture do
    fixture = running_external_runtime!(fixture)
    expire_runtime_bootstrap!(fixture)
    Process.put(:compute_reconciler_container_state, "stopped")
    Process.put(:compute_reconciler_container_generation, nil)

    assert {:error, :container_generation_unavailable} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_receive {:compute_host_request, _, %{"expected_generation_id" => _}}
  end

  @tag :runtime_recovery
  test "an empty inventory from a replaced Host session cannot clear container facts", fixture do
    fixture = running_external_runtime!(fixture)
    Process.delete(:compute_reconciler_container_state)

    Process.put(:compute_reconciler_container_list_hook, fn ->
      Process.delete(:compute_reconciler_container_list_hook)

      Repo.update_all(AgentVMM.Session,
        set: [gateway_instance_id: "replacement-gateway"]
      )
    end)

    assert {:error, :runtime_instance_changed} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["container_status"] == "running"
    assert allocation.provider_observation["runtime_container_instance_id"] == "instance-1"
  end

  @tag :runtime_recovery
  test "normal sleep clears its recovery deadline and wake recreates with a new execution epoch",
       fixture do
    fixture = running_external_runtime!(fixture)
    runtime_id = "runtime:" <> fixture.workload.id

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^runtime_id),
      set: [status: "disconnected", readiness: "pending"]
    )

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    claim = Repo.get_by!(Compute.ReconcilerClaim, workload_id: fixture.workload.id)
    assert is_binary(claim.last_error["runtime_recovery_deadline"])
    Process.put(:compute_reconciler_container_state, "stopped")
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    facts =
      allocation.provider_observation
      |> Map.put("container_status", "stopped")
      |> put_in(["current_container", "state"], "stopped")

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [provider_observation: facts]
    )

    assert :ok = SessionWorkCandidates.delete_exact("demand-#{fixture.workload.id}")
    assert {:ok, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    refute Repo.get!(Compute.ReconcilerClaim, claim.id).last_error["runtime_recovery_deadline"]
    demand_external_workload!(fixture.workload.id)

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, delete_url,
                    %{"expected_generation_id" => "container-1"}}

    assert String.ends_with?(delete_url, "/compute.container.delete")

    deadline =
      Repo.get!(Compute.ReconcilerClaim, claim.id).last_error["runtime_recovery_deadline"]

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_receive {:compute_host_request, create_url, %{"env" => env, "volumes" => [_]}}
    assert String.ends_with?(create_url, "/compute.container.create")
    refute "SALIX_COMPUTE_CONNECTION_EPOCH=7" in env
    assert Repo.get!(Compute.RuntimeInstance, runtime_id).connection_epoch != "7"

    assert Repo.get!(Compute.ReconcilerClaim, claim.id).last_error["runtime_recovery_deadline"] ==
             deadline

    refute_receive {:compute_host_request, _, %{"volume_id" => _, "expected_generation_id" => _}}
  end

  defp running_external_runtime!(fixture) do
    open_host_session!(fixture, "runtime-before-reconnect")

    {:ok, materialized} =
      RuntimeBundleCatalog.materialize(
        "external.codex",
        %{owner_id: fixture.workload.id, generation: 1}
      )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "external_worker",
        template_key: materialized.template_key,
        runtime_revision: materialized.runtime_revision,
        spec: materialized.spec,
        observed_state: "ready"
      ]
    )

    workload = Repo.get!(Compute.Workload, fixture.workload.id)
    {:ok, image} = RuntimeBundleCatalog.image_for_workload(workload)
    id = expected_container_id(workload.id, 1)

    container = %{
      "id" => id,
      "generation_id" => "container-1",
      "instance_id" => "instance-1",
      "state" => "running"
    }

    Process.put(:compute_reconciler_container_id, id)
    Process.put(:compute_reconciler_container_state, "running")
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, image["reference"])
    Process.put(:compute_reconciler_manifest_digest, image["manifestDigest"])
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    facts =
      Map.merge(allocation.provider_observation, %{
        "current_container" => container,
        "container_status" => "running",
        "container_generation_id" => "container-1",
        "runtime_container_generation_id" => "container-1",
        "runtime_container_instance_id" => "instance-1",
        "runtime_execution_epoch" => "7",
        "runtime_verified_host_epoch" => "7",
        "runtime_bootstrap_expires_at" =>
          DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second)),
        "imported_reference" => image["reference"]
      })

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [provider_observation: facts]
    )

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.workload_id == ^workload.id),
      set: [
        status: "connected",
        readiness: "ready",
        caught_up_epoch: "7",
        bootstrap_consumed_epoch: "7"
      ]
    )

    demand_external_workload!(workload.id)
    %{fixture | workload: workload, allocation: Repo.get!(Compute.Allocation, allocation.id)}
  end

  defp reconnect_host!(fixture, epoch) do
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => epoch,
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => Integer.to_string(allocation.revision),
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })
  end

  defp runtime_handshake do
    %{
      "protocol_version" => 1,
      "supported_features" => [
        "runtime.input.v1",
        "runtime.event.v1",
        "runtime.auth.v1",
        "runtime.execution.v1"
      ],
      "input_cursor" => "",
      "event_cursor" => ""
    }
  end

  defp drain_host_requests do
    receive do
      {:compute_host_request, _, _} -> drain_host_requests()
    after
      0 -> :ok
    end
  end

  defp open_host_session!(fixture, tunnel_nonce, epoch \\ "7") do
    if Repo.get!(Compute.Workload, fixture.workload.id).kind == "external_worker" do
      demand_external_workload!(fixture.workload.id)
    end

    assert {:ok, %{outcome: :pending, command: command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert command.kind == "runtime.open_session"
    expires_unix_millis = System.system_time(:millisecond) + 720_000

    assert {:ok, %Compute.Command{id: command_id, status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", epoch)

    assert command_id == command.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               epoch,
               command.id,
               "succeeded",
               %{
                 "result" => %{
                   "sessionReady" => %{
                     "allocationId" => fixture.allocation.id,
                     "allocationGeneration" => fixture.allocation.generation,
                     "tunnelNonce" => tunnel_nonce,
                     "expiresUnixMillis" => expires_unix_millis
                   }
                 }
               }
             )

    assert {:ok, :ok} =
             AgentVMM.observe_session("registration", "gateway-a", %{
               "allocationId" => fixture.allocation.id,
               "allocationGeneration" => fixture.allocation.generation,
               "connectionEpoch" => epoch,
               "tunnelNonce" => tunnel_nonce,
               "expiresUnixMillis" => expires_unix_millis
             })
  end

  defp demand_external_workload!(workload_id) do
    assert :ok =
             SessionWorkCandidates.insert(%{
               "token" => "demand-#{workload_id}",
               "agent_id" => "agent-demand",
               "runtime_kind" => "external",
               "session_id" => "session-demand",
               "workload_id" => workload_id,
               "base_revision" => "revision-demand",
               "reasons" => ["queued_input"],
               "updated_at" => System.system_time(:second)
             })
  end

  defp expected_container_id(workload_id, generation) do
    digest =
      :crypto.hash(:sha256, workload_id <> ":" <> Integer.to_string(generation))
      |> Base.encode16(case: :lower)

    "salix-" <> binary_part(digest, 0, 32)
  end

  test "persists a high-watermark cursor and clears it after a bounded pass", fixture do
    assert :more = ComputeReconciler.sweep(1)

    claim =
      Repo.get_by(Compute.ReconcilerClaim,
        provider: "agent_vmm",
        workload_id: fixture.workload.id,
        generation: fixture.workload.generation
      )

    assert claim.attempt_count == 1
    assert is_binary(claim.claim_token)
    assert byte_size(claim.claim_token) > 20
    assert %DateTime{} = claim.next_retry_at

    cursor = Repo.get!(Compute.ReconcilerCursor, "compute-reconciler-agent-vmm")
    assert cursor.provider == "agent_vmm"
    assert cursor.cursor_workload_id == fixture.workload.id
    assert cursor.high_watermark_workload_id == fixture.workload.id

    assert :complete = ComputeReconciler.sweep(1)

    cursor = Repo.get!(Compute.ReconcilerCursor, "compute-reconciler-agent-vmm")
    assert is_nil(cursor.cursor_workload_id)
    assert is_nil(cursor.high_watermark_workload_id)
  end

  test "claim acquisition preserves the previous cause until a new failure replaces it",
       fixture do
    open_host_session!(fixture, "tunnel-claim-error-preservation")
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, fixture.image["manifestDigest"])

    Process.put(
      :compute_reconciler_inspect_claim,
      {fixture.workload.id, fixture.workload.generation}
    )

    error = %{
      "code" => "unauthenticated",
      "stage" => "image_import",
      "resource" => "runtime",
      "message" => "Image import authentication failed."
    }

    Process.put(
      :compute_reconciler_image_import_result,
      {:error, {:gateway_error, error}}
    )

    now = DateTime.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{fixture.workload.id}:#{fixture.workload.generation}",
      provider: "agent_vmm",
      workload_id: fixture.workload.id,
      generation: fixture.workload.generation,
      claim_token: "previous-token",
      attempt_count: 1,
      last_error: %{"kind" => "error", "reason" => "previous transport cause"},
      created_at: now,
      updated_at: now
    })

    assert :more = ComputeReconciler.sweep(1)
    assert_receive {:compute_host_import_request, _, _}
    assert_receive {:compute_claim_at_import, %{"reason" => "previous transport cause"}}

    claim = Repo.get!(Compute.ReconcilerClaim, "agent_vmm:#{fixture.workload.id}:1")
    assert claim.last_error == Map.put(error, "kind", "provider_error")
    assert %DateTime{} = claim.next_retry_at
  end

  test "a malformed import error does not park an action-required claim", fixture do
    open_host_session!(fixture, "tunnel-mismatched-capacity-error")
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, fixture.image["manifestDigest"])

    Process.put(
      :compute_reconciler_image_import_result,
      {:error,
       {:gateway_error,
        %{
          "code" => "resource_capacity_exhausted",
          "stage" => "image_import",
          "resource" => "storage_headroom",
          "message" => "mismatched canonical fields"
        }}}
    )

    assert :more = ComputeReconciler.sweep(1)
    assert_receive {:compute_host_import_request, _, _}

    claim = Repo.get!(Compute.ReconcilerClaim, "agent_vmm:#{fixture.workload.id}:1")
    assert %DateTime{} = claim.next_retry_at
  end

  test "capacity import errors require action without timer retry", fixture do
    open_host_session!(fixture, "tunnel-capacity-error")
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, fixture.image["manifestDigest"])

    error = %{
      "code" => "resource_capacity_exhausted",
      "stage" => "import_admission",
      "resource" => "storage_headroom",
      "message" => "Guest storage headroom is unavailable.",
      "available_bytes" => 1_073_741_824,
      "required_bytes" => 2_147_483_648
    }

    Process.put(:compute_reconciler_image_import_result, {:error, {:gateway_error, error}})

    assert :more = ComputeReconciler.sweep(1)
    assert_receive {:compute_host_import_request, _, _}

    claim = Repo.get!(Compute.ReconcilerClaim, "agent_vmm:#{fixture.workload.id}:1")
    assert claim.last_error == Map.put(error, "kind", "action_required")
    assert is_nil(claim.lease_expires_at)
    assert is_nil(claim.next_retry_at)

    # A later caller timeout must not convert a capacity decision into an
    # automatic retry. The existing operator-action boundary still applies.
    expired_error =
      Map.put(
        claim.last_error,
        "runtime_recovery_deadline",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -901, :second))
      )

    Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.id == ^claim.id),
      set: [last_error: expired_error]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [kind: "external_worker"]
    )

    assert {:error, {:gateway_error, %{"code" => "resource_capacity_exhausted"}}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert Repo.get!(Compute.ReconcilerClaim, claim.id).last_error == expired_error

    for _ <- 1..3 do
      assert :complete = ComputeReconciler.sweep(1)
    end

    refute_receive {:compute_host_import_request, _, _}
  end

  test "does not skip workloads beyond the per-tenant fair share", fixture do
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, fixture.image["manifestDigest"])
    Process.put(:compute_reconciler_image_imported, true)

    for index <- 1..9 do
      assert {:ok, _workload} =
               Compute.create_workload(%{
                 id: "workload-fair-#{String.pad_leading(Integer.to_string(index), 2, "0")}",
                 environment_id: fixture.workload.environment_id,
                 allocation_id: fixture.allocation.id,
                 kind: "shell",
                 template_key: "shell.default",
                 capability_requirements: ["runtime_exec", "runtime_process"],
                 generation: 1
               })
    end

    # The synchronous ops sweep now claims only at execution time. Its bounded
    # cursor must still reach every Workload beyond the former eight-row page.
    assert :complete = ComputeReconciler.sweep(32)
    assert Repo.aggregate(Compute.ReconcilerClaim, :count, :id) == 10
    assert :complete = ComputeReconciler.sweep(32)
  end

  test "an expired claim token cannot start or settle a provider pass", fixture do
    assert :more = ComputeReconciler.sweep(1)

    claim =
      Repo.get_by!(Compute.ReconcilerClaim,
        provider: "agent_vmm",
        workload_id: fixture.workload.id,
        generation: fixture.workload.generation
      )

    Repo.update_all(
      Compute.ReconcilerClaim,
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, :claim_lost} =
             ComputeReconciler.reconcile_workload(
               fixture.workload.id,
               fixture.workload.generation,
               claim_token: claim.claim_token
             )
  end

  test "a stopped workload gets a durable provider release intent", fixture do
    assert {:ok, stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert stopped.desired_state == "stopped"
    assert :more = ComputeReconciler.sweep(1)

    assert Repo.one!(
             from(c in Compute.Command,
               where:
                 c.allocation_id == ^fixture.allocation.id and is_nil(c.workload_id) and
                   c.kind == "allocation.release"
             )
           )
  end

  test "a stopped workload with a pre-admission rejection still uses its allocation obligation",
       fixture do
    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [
        status: "allocating",
        operation_outcome: "pending",
        provider_observation: %{}
      ]
    )

    assert {:ok, %{outcome: :pending, command: ensure_command}} =
             ComputeReconciler.reconcile_workload(
               fixture.workload.id,
               fixture.workload.generation
             )

    assert ensure_command.kind == "allocation.ensure"

    assert {:ok, %Compute.Command{id: ensure_id}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert ensure_id == ensure_command.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               ensure_id,
               "failed",
               %{
                 "result" => %{
                   "outcome" => "COMMAND_OUTCOME_REJECTED",
                   "reason" => "ERROR_REASON_CAPACITY_EXHAUSTED",
                   "capacityDimension" => "CAPACITY_DIMENSION_STORAGE_HEADROOM"
                 }
               }
             )

    assert {:ok, stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert {:ok, %{command: release}} =
             ComputeReconciler.reconcile_workload(stopped.id, stopped.generation)

    assert release.kind == "allocation.release"
    assert release.workload_id == nil

    assert get_in(release.payload, ["command_json", "releaseAllocation", "expectedGeneration"]) ==
             fixture.allocation.generation

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "draining"
  end

  test "drain adopts a succeeded release without another provider operation",
       fixture do
    legacy_release_succeeded!(fixture, "legacy-drain-event")

    assert {:ok, _stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "released"
  end

  test "backfill adopts a succeeded release without another provider operation",
       fixture do
    legacy_release_succeeded!(fixture, "legacy-backfill-event")

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "draining"]
    )

    assert {:ok, :adopted} =
             Compute.backfill_release_obligation(fixture.allocation.id, DateTime.utc_now())

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "released"
  end

  test "concurrent disconnect and release backfill preserve the release obligation", fixture do
    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "draining"]
    )

    disconnect =
      Task.async(fn -> AgentVMM.mark_connection_lost("registration", "gateway-a", "7") end)

    backfill =
      Task.async(fn ->
        Compute.backfill_release_obligation(fixture.allocation.id, DateTime.utc_now())
      end)

    assert {:ok, _} = Task.await(disconnect, 5_000)
    assert {:ok, status} = Task.await(backfill, 5_000)
    assert status in [:inserted, :present]
  end

  test "a stopped workload with an ambiguous pre-admission failure still requests release",
       fixture do
    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [
        status: "allocating",
        operation_outcome: "pending",
        provider_observation: %{}
      ]
    )

    assert {:ok, %{outcome: :pending, command: ensure_command}} =
             ComputeReconciler.reconcile_workload(
               fixture.workload.id,
               fixture.workload.generation
             )

    assert {:ok, %Compute.Command{id: ensure_id}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert ensure_id == ensure_command.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               ensure_id,
               "failed",
               %{
                 "result" => %{
                   "outcome" => "COMMAND_OUTCOME_UNKNOWN",
                   "reason" => "ERROR_REASON_UNAVAILABLE"
                 }
               }
             )

    assert {:ok, stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert {:ok, %{outcome: :pending, command: release}} =
             ComputeReconciler.reconcile_workload(stopped.id, stopped.generation)

    assert release.kind == "allocation.release"

    refute match?(
             %{status: "released", operation_outcome: "succeeded"},
             Repo.get!(Compute.Allocation, fixture.allocation.id)
           )
  end

  test "the settlement owner retries one stable allocation release at the current revision",
       fixture do
    environment = Repo.get!(Compute.Environment, fixture.workload.environment_id)

    assert {:ok, draining_environment} =
             Compute.update_environment_intent(
               environment.id,
               environment.revision,
               %{desired_state: "draining"}
             )

    assert draining_environment.desired_state == "draining"

    release_command =
      Repo.get_by!(Compute.Command,
        allocation_id: fixture.allocation.id,
        kind: "allocation.release"
      )

    assert release_command.kind == "allocation.release"
    assert release_command.workload_id == nil
    refute Map.has_key?(release_command.payload["command_json"], "leaseGeneration")

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(
      from(c in Compute.Command, where: c.id == ^release_command.id),
      set: [deadline_at: expired_at]
    )

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      inc: [revision: 1]
    )

    current_allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    settle_at = DateTime.utc_now()

    assert {:ok, %{settled: 1, release_retries: 0}} =
             AgentVMM.settle_expired_commands(32, settle_at)

    assert {:ok, %{settled: 0, release_retries: 1}} =
             AgentVMM.settle_expired_commands(32, DateTime.add(settle_at, 6, :second))

    reissued_release = Repo.get!(Compute.Command, release_command.id)

    assert reissued_release.id == release_command.id
    assert reissued_release.request_id == release_command.request_id
    assert reissued_release.release_incarnation == release_command.release_incarnation
    assert reissued_release.target_revision == current_allocation.revision
    assert reissued_release.attempt_count == 1

    assert Repo.aggregate(
             from(c in Compute.Command,
               where:
                 c.allocation_id == ^fixture.allocation.id and
                   c.kind == "allocation.release"
             ),
             :count
           ) == 1

    assert {:ok, %Compute.Command{id: command_id, status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert command_id == reissued_release.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               reissued_release.id,
               "succeeded",
               %{
                 "result" => %{
                   "allocation" => %{
                     "allocationId" => fixture.allocation.id,
                     "revision" => 2
                   }
                 }
               }
             )

    current_workload = Repo.get!(Compute.Workload, fixture.workload.id)

    assert {:error, :allocation_released} =
             ComputeReconciler.reconcile_workload(
               current_workload.id,
               current_workload.generation
             )

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "released"
  end

  defp restore(key, nil), do: Application.delete_env(:salix_store, key)
  defp restore(key, value), do: Application.put_env(:salix_store, key, value)

  defp offer_reclaim!(fixture, attrs \\ %{}) do
    candidate =
      Map.merge(
        %{
          "registrationId" => "registration",
          "allocationId" => fixture.allocation.id,
          "containerId" =>
            expected_container_id(fixture.workload.id, fixture.workload.generation),
          "containerInstanceId" => "instance-1",
          "expiresUnixMillis" => Integer.to_string(System.system_time(:millisecond) + 30_000)
        },
        attrs
      )

    observation =
      capacity_observation(System.unique_integer([:positive, :monotonic]), 0)
      |> Map.put("reclaimCandidate", candidate)

    assert {:ok, :ok} =
             AgentVMM.settle_registration_observation(
               "registration",
               "gateway-a",
               "7",
               observation
             )
  end

  defp capacity_observation(sequence, disk_bytes) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    %{
      "sequence" => Integer.to_string(sequence),
      "observedUnixMillis" => Integer.to_string(now),
      "protocolVersion" => "1",
      "hostApiVersion" => "host.v1",
      "connectorRelease" => "test",
      "supportedFeatures" => ["connection-epoch-v1"],
      "capacity" => %{
        "perEnvironmentLimits" => %{},
        "maxEgressMode" => "EGRESS_MODE_DENY_ALL"
      },
      "health" => %{"status" => "healthy", "components" => []},
      "usage" => %{"stale" => false, "diskBytes" => disk_bytes},
      "inventoryWatermark" => "1",
      "inventoryObservedUnixMillis" => Integer.to_string(now)
    }
  end

  defp legacy_release_succeeded!(fixture, suffix) do
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.query!(
      "ALTER TABLE compute_commands DROP CONSTRAINT compute_commands_release_owner_shape"
    )

    command =
      try do
        {:ok, command} =
          Compute.enqueue_command(%{
            id: "legacy-release-#{suffix}",
            allocation_id: allocation.id,
            workload_id: fixture.workload.id,
            request_id: "legacy-release-request-#{suffix}",
            kind: "allocation.release",
            classification: "desired_state",
            target_generation: allocation.generation,
            target_revision: allocation.revision,
            deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
          })

        Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
          set: [status: "succeeded", outcome: "succeeded"]
        )

        command
      after
        Repo.query!("""
        ALTER TABLE compute_commands
        ADD CONSTRAINT compute_commands_release_owner_shape
        CHECK (
          kind <> 'allocation.release'
          OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
        ) NOT VALID
        """)
      end

    command
  end
end
