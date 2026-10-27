defmodule SalixEnv.ComputeReconcilerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  require SystemsClock

  use SystemsClock.Test,
    scope: ["Elixir.SalixEnv", "Elixir.SalixStore", "Elixir.ThousandIsland", "Elixir.Bandit"]

  import Ecto.Query

  alias SalixEnv.ComputeReconciler
  alias SalixStore.{AgentVMM, Compute, Repo, RuntimeBundleCatalog}

  defmodule HostHTTP do
    @request_id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/

    def post(url, body) do
      execution_lifecycle? =
        String.ends_with?(url, "/compute.execution.acquire") or
          String.ends_with?(url, "/compute.execution.release")

      unless execution_lifecycle?,
        do:
          SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:compute_host_request, url, body})

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
              # A started container runs as a new execution instance.
              if instance = Process.get(:compute_reconciler_start_instance),
                do: Process.put(:compute_reconciler_container_instance, instance)

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
        "start_request_instance_id" => "instance-1",
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
          body["owner_uid"] in [1_000, 10_001] and body["owner_gid"] == body["owner_uid"] and
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

      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:compute_host_import_request, url, headers}
      )

      case Process.get(:compute_reconciler_inspect_claim) do
        {workload_id, generation} ->
          claim =
            SalixStore.Repo.get_by(SalixStore.Compute.ReconcilerClaim,
              provider: "agent_vmm",
              workload_id: workload_id,
              generation: generation
            )

          SystemsRuntime.Proc.send(
            SystemsRuntime.Proc.self(),
            {:compute_claim_at_import, claim && claim.last_error}
          )

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

  defmodule ConcurrentHostHTTP do
    def post(url, body) do
      seed(url)
      HostHTTP.post(url, body)
    end

    def post_import(url, headers) do
      seed(url)
      owner = SystemsRuntime.fetch_env!(:salix_store, :compute_reconciler_test_pid)
      SystemsRuntime.Proc.send(owner, {:blocked_import, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
        :release_import -> HostHTTP.post_import(url, headers)
      after
        10_000 -> {:error, :test_import_timeout}
      end
    end

    defp seed(url) do
      unless Process.get(:scheduler_fixture_seeded) do
        fixtures = SystemsRuntime.fetch_env!(:salix_store, :compute_scheduler_fixtures)
        key = if String.contains?(url, "fast-allocation"), do: :fast, else: :slow
        Enum.each(fixtures[key], fn {k, v} -> Process.put(k, v) end)
        Process.put(:scheduler_fixture_seeded, true)
      end
    end
  end

  defmodule RecoveryHost do
    use SystemsRuntime.Server

    def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

    def post(url, body) do
      SystemsRuntime.Server.call(
        SystemsRuntime.fetch_env!(:salix_store, :compute_recovery_host),
        {:post, url, body}
      )
    end

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_call(:lose_start_evidence, _from, state) do
      container =
        Map.merge(state.container, %{
          "state" => "stopped",
          "instance_id" => "",
          "start_request_instance_id" => ""
        })

      {:reply, :ok, %{state | container: container}}
    end

    def handle_call({:post, url, body}, _from, state) do
      {response, state} = request(url, body, state)
      SystemsRuntime.Proc.send(state.owner, {:recovery_host_request, url, body})
      {:reply, response, state}
    end

    defp request(url, body, state) when is_binary(url) do
      cond do
        String.ends_with?(url, "/compute.container.list") ->
          if state.rename_first_list and state.lists == 0 do
            SalixStore.Repo.update_all(
              from(w in SalixStore.Compute.Workload, where: w.id == ^state.workload_id),
              set: [name: "Renamed during inventory"],
              inc: [revision: 1]
            )
          end

          {{:ok, %{"containers" => [state.container]}}, %{state | lists: state.lists + 1}}

        String.ends_with?(url, "/compute.container.start") ->
          case Map.fetch(state.receipts, body["request_id"]) do
            {:ok, receipt} ->
              {{:ok, receipt}, state}

            :error ->
              container =
                state.container
                |> Map.put("state", "running")
                |> Map.put("instance_id", "instance-recovered")
                |> Map.put("start_request_instance_id", "instance-recovered")

              receipt = %{"container" => container}

              next = %{
                state
                | container: container,
                  starts: state.starts + 1,
                  receipts: Map.put(state.receipts, body["request_id"], receipt),
                  lose_reply: false
              }

              if state.lose_reply,
                do: {{:error, {:gateway_status, 502}}, next},
                else: {{:ok, receipt}, next}
          end

        true ->
          {{:error, {:unexpected_host_request, url}}, state}
      end
    end
  end

  setup do
    SalixStore.RepoTestSetup.exclusively(fn ->
      Repo.query!(
        "TRUNCATE compute_runtime_release, session_work_candidates, compute_reconciler_claims, compute_reconciler_cursors, agent_vmm_audit_events, agent_vmm_sessions, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
      )
    end)

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
      instances: SystemsRuntime.get_env(:salix_store, :agent_vmm_gateway_instances),
      client: SystemsRuntime.get_env(:salix_store, :agent_vmm_host_http_client),
      pid: SystemsRuntime.get_env(:salix_store, :agent_vmm_host_client_test_pid),
      runtime_url: SystemsRuntime.get_env(:salix_store, :compute_runtime_base_url),
      runtime_secret: SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret),
      auth_pid: SystemsRuntime.get_env(:salix_store, :compute_reconciler_test_pid)
    }

    SystemsRuntime.put_env(:salix_store, :agent_vmm_gateway_instances, %{
      "gateway-a" => "https://gateway.internal"
    })

    SystemsRuntime.put_env(:salix_store, :agent_vmm_host_http_client, HostHTTP)

    SystemsRuntime.put_env(
      :salix_store,
      :agent_vmm_host_client_test_pid,
      SystemsRuntime.Proc.self()
    )

    SystemsRuntime.put_env(:salix_store, :compute_reconciler_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_store, :compute_runtime_base_url, "https://runtime.internal")

    SystemsRuntime.put_env(
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
      restore(:agent_vmm_gateway_instances, previous.instances)
      restore(:agent_vmm_host_http_client, previous.client)
      restore(:agent_vmm_host_client_test_pid, previous.pid)
      restore(:compute_runtime_base_url, previous.runtime_url)
      restore(:compute_workload_credential_secret, previous.runtime_secret)
      restore(:compute_reconciler_test_pid, previous.auth_pid)
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

    # This fixture exercises the Shell reconciler and its single-target Host script.
    # Group Station preparation has its own placement tests.
    station = Repo.get_by!(Compute.Workload, template_key: "station.default")
    Repo.delete!(station)
    Repo.delete!(Repo.get!(Compute.Allocation, station.allocation_id))

    {:ok, image} = RuntimeBundleCatalog.image_for_workload(workload)

    %{
      allocation: allocation,
      workload: workload,
      image: image,
      image_reference: image["reference"]
    }
  end

  for {kind, template} <- [{"shell", "shell.default"}, {"service", "station.default"}] do
    @tag :guest_restart
    test "the coordinator recovers a stopped ready #{kind} without replacing its identity",
         fixture do
      kind = unquote(kind)
      template = unquote(template)
      open_host_session!(fixture, "guest-restart")

      {:ok, materialized} =
        RuntimeBundleCatalog.materialize(template, %{owner_id: fixture.workload.id, generation: 1})

      Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
        set: [
          kind: kind,
          template_key: template,
          runtime_revision: materialized.runtime_revision,
          spec: materialized.spec,
          observed_state: "ready"
        ]
      )

      workload = Repo.get!(Compute.Workload, fixture.workload.id)
      {:ok, image} = RuntimeBundleCatalog.image_for_workload(workload)

      old_container = %{
        "id" => expected_container_id(workload.id, 1),
        "generation_id" => "container-1",
        "instance_id" => "instance-before-restart",
        "start_request_instance_id" => "instance-before-restart",
        "state" => "running"
      }

      allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

      cached_container =
        if kind == "service",
          do:
            Map.merge(old_container, %{"state" => "stopped", "start_request_instance_id" => ""}),
          else: old_container

      Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
        set: [
          provider_observation: %{
            "current_container" => cached_container,
            "container_status" => cached_container["state"],
            "container_generation_id" => "container-1",
            "runtime_container_generation_id" => "container-1",
            "runtime_container_instance_id" => "instance-before-restart",
            "runtime_verified_host_epoch" => "6",
            "imported_reference" => image["reference"]
          }
        ]
      )

      legacy_start_key =
        "salix-" <>
          (:crypto.hash(:sha256, "start:container-1:" <> workload.id <> ":1")
           |> Base.encode16(case: :lower)
           |> binary_part(0, 56))

      host =
        start_supervised!(
          {RecoveryHost,
           owner: SystemsRuntime.Proc.self(),
           container: Map.merge(old_container, %{"state" => "stopped", "instance_id" => ""}),
           receipts: %{legacy_start_key => %{"container" => old_container}},
           starts: 0,
           lists: 0,
           workload_id: workload.id,
           rename_first_list: kind == "service",
           lose_reply: kind == "service"}
        )

      SystemsRuntime.put_env(:salix_store, :agent_vmm_host_http_client, RecoveryHost)
      SystemsRuntime.put_env(:salix_store, :compute_recovery_host, host)
      on_exit(fn -> SystemsRuntime.delete_env(:salix_store, :compute_recovery_host) end)

      coordinator =
        start_supervised!(
          {ComputeReconciler, name: nil, start_sweeper?: true, interval_ms: 5_000}
        )

      ComputeReconciler.host_session_ready(allocation.id, coordinator)

      assert settle_until(fn ->
               SystemsRuntime.Server.call(host, :state).lists > 0 and
                 Repo.get!(Compute.Allocation, allocation.id).provider_observation[
                   "container_status"
                 ] == "stopped"
             end)

      assert Repo.get!(Compute.Workload, workload.id).observed_state == "pending"

      assert settle_until(fn ->
               state = SystemsRuntime.Server.call(host, :state)

               state.starts == 1 and
                 Repo.get!(Compute.Workload, workload.id).observed_state == "ready"
             end)

      current = Repo.get!(Compute.Workload, workload.id)
      assert current.id == workload.id
      assert current.generation == workload.generation
      assert current.allocation_id == allocation.id
      if kind == "service", do: assert(current.name == "Renamed during inventory")
      assert Repo.get!(Compute.Allocation, allocation.id).generation == allocation.generation
      assert SystemsRuntime.Server.call(host, :state).starts == 1
      assert Repo.get_by(Compute.ReconcilerClaim, workload_id: workload.id, generation: 1) == nil

      if kind == "shell" do
        current_allocation = Repo.get!(Compute.Allocation, allocation.id)
        before_lists = SystemsRuntime.Server.call(host, :state).lists

        stale =
          current_allocation.provider_observation
          |> Map.put("container_status", "stopped")
          |> Map.put("runtime_container_instance_id", nil)
          |> Map.update!("current_container", &Map.put(&1, "state", "stopped"))

        Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
          set: [provider_observation: stale]
        )

        ComputeReconciler.host_session_ready(allocation.id, coordinator)

        assert settle_until(fn ->
                 SystemsRuntime.Server.call(host, :state).lists > before_lists and
                   is_nil(
                     Repo.get_by(Compute.ReconcilerClaim, workload_id: workload.id, generation: 1)
                   )
               end)

        assert Repo.get!(Compute.Workload, workload.id).observed_state == "ready"
        assert SystemsRuntime.Server.call(host, :state).starts == 1

        :ok = SystemsRuntime.Server.call(host, :lose_start_evidence)
        ComputeReconciler.host_session_ready(allocation.id, coordinator)

        assert settle_until(fn ->
                 case Repo.get_by(Compute.ReconcilerClaim,
                        workload_id: workload.id,
                        generation: 1
                      ) do
                   %{last_error: %{"kind" => "action_required"} = error} ->
                     error["code"] == "container_start_evidence_unavailable"

                   _ ->
                     false
                 end
               end)

        assert Repo.get!(Compute.Workload, workload.id).observed_state == "pending"
        assert SystemsRuntime.Server.call(host, :state).starts == 1
      end
    end
  end

  test "deletion continues the same cleanup request across lost delivery without reopening runtime",
       fixture do
    alias SalixStore.ComputeWorkloadDeletion, as: Deletion
    workload = Repo.get!(Compute.Workload, fixture.workload.id)

    assert {:ok, _} =
             Deletion.start(
               "tenant",
               "project",
               workload.id,
               workload.generation,
               "delete-offline",
               fn -> :ok end
             )

    assert {:ok, %{command: first}} =
             ComputeReconciler.reconcile_workload(workload.id, workload.generation)

    assert {:ok, claimed} = AgentVMM.claim_registration_command("registration", "gateway-a", "7")
    assert claimed.id == first.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               claimed.id,
               "failed",
               %{"result" => %{"reason" => "ERROR_REASON_FEATURE_MISMATCH"}}
             )

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(workload.id, workload.generation)

    assert Repo.get!(Compute.Workload, workload.id).deletion["error"] == "host_update_required"
    now_ms = SystemsClock.utc_now() |> DateTime.to_unix(:millisecond) |> Integer.to_string()

    assert {:ok, :ok} =
             AgentVMM.settle_registration_observation(
               "registration",
               "gateway-a",
               "7",
               %{
                 "sequence" => "1",
                 "observedUnixMillis" => now_ms,
                 "protocolVersion" => "1",
                 "hostApiVersion" => "host.v1",
                 "supportedFeatures" => ["allocation-disposal-v1"],
                 "health" => %{"status" => "healthy", "components" => []},
                 "inventoryWatermark" => "0",
                 "inventoryObservedUnixMillis" => now_ms
               }
             )

    assert {:ok, %{command: upgraded}} =
             ComputeReconciler.reconcile_workload(workload.id, workload.generation)

    assert upgraded.id == first.id
    assert {:ok, claimed} = AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               claimed.id,
               "failed",
               %{"result" => %{"reason" => "ERROR_REASON_UNAVAILABLE"}}
             )

    assert {:ok, %{command: retry}} =
             ComputeReconciler.reconcile_workload(workload.id, workload.generation)

    assert retry.id == first.id
    assert retry.operation_id == first.operation_id

    assert retry.payload["command_json"]["disposeAllocation"] ==
             first.payload["command_json"]["disposeAllocation"]

    assert {:ok, claimed_again} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert claimed_again.id == first.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               claimed_again.id,
               "unknown_outcome",
               %{"reason" => "connection_lost_after_admission"}
             )

    assert {:ok, %{command: unknown_retry}} =
             ComputeReconciler.reconcile_workload(workload.id, workload.generation)

    assert unknown_retry.id == first.id

    assert unknown_retry.payload["command_json"]["disposeAllocation"] ==
             first.payload["command_json"]["disposeAllocation"]

    assert {:ok, receipt_retry} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert receipt_retry.id == first.id

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               receipt_retry.id,
               "failed",
               %{
                 "result" => %{
                   "reason" => "ERROR_REASON_DISPOSAL_REVISION_NOT_ACCEPTED",
                   "allocation" => %{
                     "allocationId" => fixture.allocation.id,
                     "generation" => "1",
                     "revision" => "8"
                   }
                 }
               }
             )

    assert {:ok, %{command: refreshed}} =
             ComputeReconciler.reconcile_workload(workload.id, workload.generation)

    assert refreshed.id == first.id

    assert refreshed.payload["command_json"]["disposeAllocation"]["requestId"] ==
             first.payload["command_json"]["disposeAllocation"]["requestId"]

    assert refreshed.payload["command_json"]["disposeAllocation"]["expectedRevision"] == 8
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"
    assert Repo.get!(Compute.Workload, workload.id).desired_state == "draining"
    refute_received {:compute_host_request, _, _}
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
    session_expires_unix_millis = SystemsClock.system_time(:millisecond) + 720_000

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

    short_authority = DateTime.add(SystemsClock.utc_now(), 300, :second)
    Repo.update_all(AgentVMM.Session, set: [expires_at: short_authority])

    assert {:ok, %{outcome: :pending, command: refresh_command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert refresh_command.kind == "runtime.open_session"

    refute_received {:compute_host_import_request, _, _}

    assert {:ok, %Compute.Command{id: refresh_command_id, status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    assert refresh_command_id == refresh_command.id
    refreshed_expiry_unix_millis = SystemsClock.system_time(:millisecond) + 900_000

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

    settle_receive({:compute_host_request, _image_list_url, %{}})
    settle_receive({:compute_host_import_request, import_url, import_headers})
    assert String.ends_with?(import_url, "/compute.image.import")
    assert {"x-comma-image-reference", fixture.image_reference} in import_headers
    assert {"x-comma-archive-url", fixture.image["archiveUrl"]} in import_headers
    settle_receive({:compute_host_request, _image_list_after_import_url, %{}})

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    settle_receive({:compute_host_request, _container_list_url, %{}})
    settle_receive({:compute_host_request, image_list_before_create_url, %{}})
    assert String.ends_with?(image_list_before_create_url, "/compute.image.list")
    settle_receive({:compute_host_request, _create_url, create_args})
    assert create_args["image"] == fixture.image_reference
    assert String.starts_with?(create_args["container_id"], "salix-")
    assert byte_size(create_args["container_id"]) <= 41
    refute Enum.any?(create_args["env"], &String.starts_with?(&1, "SALIX_COMPUTE_RUNTIME_"))

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    settle_receive({:compute_host_request, before_start_url, %{}})
    assert String.ends_with?(before_start_url, "/compute.container.list")
    settle_receive({:compute_host_request, _start_url, start_args})
    assert start_args["container_id"] == create_args["container_id"]
    settle_receive({:compute_host_request, _container_list_after_start_url, %{}})
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

    # Already-ready Shells still need one bounded sweep after Host epoch changes.
    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation:
          Map.put(allocation.provider_observation, "runtime_verified_host_epoch", "6")
      ]
    )

    Repo.delete_all(from(c in Compute.ReconcilerClaim, where: c.workload_id == ^workload.id))
    ComputeReconciler.sweep(1)
    allocation = Repo.get!(Compute.Allocation, allocation.id)
    assert allocation.provider_observation["runtime_verified_host_epoch"] == "7"

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

  test "a busy import slot retries the claim while missing storage headroom awaits action",
       fixture do
    Process.put(:compute_reconciler_image_reference, fixture.image_reference)
    Process.put(:compute_reconciler_manifest_digest, "sha256:" <> String.duplicate("c", 64))

    assert {:ok, %{outcome: :pending, command: session_command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert {:ok, %Compute.Command{status: "admitted"}} =
             AgentVMM.claim_registration_command("registration", "gateway-a", "7")

    expires_unix_millis = SystemsClock.system_time(:millisecond) + 900_000

    session = %{
      "allocationId" => fixture.allocation.id,
      "allocationGeneration" => fixture.allocation.generation,
      "tunnelNonce" => "tunnel-1",
      "expiresUnixMillis" => expires_unix_millis
    }

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway-a",
               "7",
               session_command.id,
               "succeeded",
               %{"result" => %{"sessionReady" => session}}
             )

    assert {:ok, :ok} =
             AgentVMM.observe_session(
               "registration",
               "gateway-a",
               Map.put(session, "connectionEpoch", "7")
             )

    claim = fn ->
      Repo.get_by!(Compute.ReconcilerClaim,
        provider: "agent_vmm",
        workload_id: fixture.workload.id,
        generation: fixture.workload.generation
      )
    end

    capacity_error = fn stage, resource ->
      {:error,
       {:gateway_error,
        %{
          "code" => "resource_capacity_exhausted",
          "stage" => stage,
          "resource" => resource,
          "message" => "capacity exhausted"
        }}}
    end

    Process.put(
      :compute_reconciler_image_import_result,
      capacity_error.("import_slot", "import_slot")
    )

    ComputeReconciler.sweep(1)
    settle_receive({:compute_host_import_request, _url, _headers})

    retrying = claim.()
    assert retrying.last_error["resource"] == "import_slot"
    assert retrying.last_error["kind"] == "provider_error"
    assert %DateTime{} = retrying.next_retry_at

    Repo.delete_all(Compute.ReconcilerClaim)
    Repo.query!("TRUNCATE compute_reconciler_cursors")

    Process.put(
      :compute_reconciler_image_import_result,
      capacity_error.("import_admission", "storage_headroom")
    )

    ComputeReconciler.sweep(1)
    settle_receive({:compute_host_import_request, _url, _headers})

    parked = claim.()
    assert parked.last_error["resource"] == "storage_headroom"
    assert parked.last_error["kind"] == "action_required"
    assert parked.next_retry_at == nil
  end

  test "an async busy import slot re-dispatches allocation.ensure while storage headroom awaits action",
       fixture do
    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "allocating"]
    )

    fail_with = fn dimension ->
      assert {:ok, %{outcome: :pending, command: ensure}} =
               ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

      assert ensure.kind == "allocation.ensure"

      assert {:ok, %Compute.Command{id: claimed_id}} =
               AgentVMM.claim_registration_command("registration", "gateway-a", "7")

      assert claimed_id == ensure.id

      assert :ok =
               AgentVMM.commit_registration_result(
                 "registration",
                 "gateway-a",
                 "7",
                 ensure.id,
                 "failed",
                 %{
                   "result" => %{
                     "reason" => "ERROR_REASON_CAPACITY_EXHAUSTED",
                     "capacityDimension" => dimension
                   }
                 }
               )

      ensure
    end

    parked = fn ->
      Repo.get_by(Compute.ReconcilerClaim,
        provider: "agent_vmm",
        workload_id: fixture.workload.id,
        claim_token: "capacity-action-required"
      )
    end

    first = fail_with.("CAPACITY_DIMENSION_IMPORT_SLOT")
    refute parked.()

    # The next reconciler pass reissues the same deterministic request.
    retried = fail_with.("CAPACITY_DIMENSION_STORAGE_HEADROOM")
    assert retried.request_id == first.request_id

    assert %{last_error: %{"kind" => "action_required", "resource" => "storage_headroom"}} =
             parked.()
  end

  defmodule StationServerURL do
    @behaviour SalixEnv.Ports.PublicURL
    @impl true
    def connector_server_url, do: "https://salix.example.test"
  end

  test "a station container dials Salix with its Workload's connect credential", fixture do
    previous = SystemsRuntime.get_env(:salix_env, :public_url_mod)
    SystemsRuntime.put_env(:salix_env, :public_url_mod, StationServerURL)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_env, :public_url_mod, previous),
        else: SystemsRuntime.delete_env(:salix_env, :public_url_mod)
    end)

    Repo.delete_all(
      from(workload in Compute.Workload, where: workload.id == ^fixture.workload.id)
    )

    assert {:ok, station} =
             Compute.create_workload(%{
               id: fixture.workload.id,
               environment_id: fixture.workload.environment_id,
               allocation_id: fixture.workload.allocation_id,
               kind: "shell",
               template_key: "station.default",
               capability_requirements: ["runtime_exec"],
               generation: fixture.workload.generation
             })

    assert {:ok, image} = RuntimeBundleCatalog.image_for_workload(station)
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, image["reference"])
    Process.put(:compute_reconciler_manifest_digest, image["manifestDigest"])
    open_host_session!(fixture, "station-container")

    assert {:ok, %{outcome: :pending}} =
             reconcile_until_container_create(fixture.workload.id, 6)

    settle_receive({:compute_host_request, create_url, create_args})
    assert String.ends_with?(create_url, "/compute.container.create")
    assert create_args["image"] == image["reference"]
    assert "HOME=/workspace" in create_args["env"]
    assert "SALIX_SERVER=https://salix.example.test" in create_args["env"]

    assert ["SALIX_WORKLOAD_CREDENTIAL=" <> credential] =
             Enum.filter(
               create_args["env"],
               &String.starts_with?(&1, "SALIX_WORKLOAD_CREDENTIAL=")
             )

    assert {:ok, %Compute.Workload{id: id}} =
             Compute.WorkloadCredential.verify_connect(credential)

    assert id == fixture.workload.id
    refute Enum.any?(create_args["env"], &String.starts_with?(&1, "SALIX_COMPUTE_"))
  end

  test "a station container sleeps stopped on its Host and starts again", fixture do
    previous = SystemsRuntime.get_env(:salix_env, :public_url_mod)
    SystemsRuntime.put_env(:salix_env, :public_url_mod, StationServerURL)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_env, :public_url_mod, previous),
        else: SystemsRuntime.delete_env(:salix_env, :public_url_mod)
    end)

    Repo.delete_all(
      from(workload in Compute.Workload, where: workload.id == ^fixture.workload.id)
    )

    assert {:ok, station} =
             Compute.create_workload(%{
               id: fixture.workload.id,
               environment_id: fixture.workload.environment_id,
               allocation_id: fixture.workload.allocation_id,
               kind: "shell",
               template_key: "station.default",
               capability_requirements: ["runtime_exec"],
               generation: fixture.workload.generation
             })

    assert {:ok, image} = RuntimeBundleCatalog.image_for_workload(station)
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, image["reference"])
    Process.put(:compute_reconciler_manifest_digest, image["manifestDigest"])
    open_host_session!(fixture, "station-sleep")
    assert {:ok, _} = reconcile_until_container_create(fixture.workload.id, 6)
    settle_receive({:compute_host_request, _create_url, _create_args})
    Process.put(:compute_reconciler_container_state, "running")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    workload = Repo.get!(Compute.Workload, fixture.workload.id)

    assert {:ok, :stopped} =
             SalixEnv.ComputeProviders.AgentVMM.stop_container(allocation, workload, "sleep-1")

    for operation <- ~w(container.list container.quiesce container.stop container.list) do
      settle_receive({:compute_host_request, url, _args})
      assert String.ends_with?(url, "/compute." <> operation)
    end

    assert Process.get(:compute_reconciler_container_state) == "stopped"
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["container_status"] == "stopped"

    # A repeated stop only confirms it.
    assert {:ok, :stopped} =
             SalixEnv.ComputeProviders.AgentVMM.stop_container(allocation, workload, "sleep-1")

    settle_receive({:compute_host_request, list_url, _})
    assert String.ends_with?(list_url, "/compute.container.list")
    refute_received {:compute_host_request, _, _}

    # Its volume stays; reconciling the Workload starts the same container.
    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert_received {:compute_host_request, start_url, %{"container_id" => _} = start_args}
    assert String.ends_with?(start_url, "/compute.container.start")
    assert start_args["container_id"] == Process.get(:compute_reconciler_container_id)
    assert Process.get(:compute_reconciler_container_state) == "running"
  end

  # guest: the Guest starts its container again when it boots.
  # salix: the container stays stopped and Salix starts it.
  for {restart, host_state, instance_key} <- [
        {"guest", "running", :compute_reconciler_container_instance},
        {"salix", "stopped", :compute_reconciler_start_instance}
      ] do
    @tag :guest_restart
    test "a ready service returns to ready after a VM restart starts a new instance (#{restart})",
         fixture do
      previous = SystemsRuntime.get_env(:salix_env, :public_url_mod)
      SystemsRuntime.put_env(:salix_env, :public_url_mod, StationServerURL)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_env, :public_url_mod, previous),
          else: SystemsRuntime.delete_env(:salix_env, :public_url_mod)
      end)

      Repo.delete_all(
        from(workload in Compute.Workload, where: workload.id == ^fixture.workload.id)
      )

      assert {:ok, service} =
               Compute.create_workload(%{
                 id: fixture.workload.id,
                 environment_id: fixture.workload.environment_id,
                 allocation_id: fixture.workload.allocation_id,
                 kind: "service",
                 template_key: "station.default",
                 capability_requirements: ["runtime_exec", "runtime_process"],
                 generation: fixture.workload.generation
               })

      assert {:ok, image} = RuntimeBundleCatalog.image_for_workload(service)
      Process.put(:compute_reconciler_image_imported, true)
      Process.put(:compute_reconciler_image_reference, image["reference"])
      Process.put(:compute_reconciler_manifest_digest, image["manifestDigest"])
      open_host_session!(fixture, "service-before-restart")
      assert {:ok, _} = reconcile_until_container_create(fixture.workload.id, 6)
      assert reconcile_until_observed(fixture.workload.id, "ready", 4)

      allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
      assert allocation.provider_observation["runtime_container_instance_id"] == "instance-1"
      assert allocation.provider_observation["runtime_verified_host_epoch"] == "7"

      # The VM restarts: the Host connection drops, the Host comes back with a
      # new connection epoch, and its container is stopped. A stopped
      # container still names its last execution instance.
      assert {:ok, _} = AgentVMM.mark_connection_lost("registration", "gateway-a", "7")
      Process.put(:compute_reconciler_container_state, "stopped")
      reconnect_host!(fixture, "8")
      open_host_session!(fixture, "service-after-restart", "8")
      assert reconcile_until_observed(fixture.workload.id, "pending", 2)

      Process.put(:compute_reconciler_container_state, unquote(host_state))
      Process.put(unquote(instance_key), "instance-after-restart")

      assert reconcile_until_observed(fixture.workload.id, "ready", 4)
      assert Process.get(:compute_reconciler_container_state) == "running"
      allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

      assert allocation.provider_observation["runtime_container_instance_id"] ==
               "instance-after-restart"

      assert allocation.provider_observation["runtime_verified_host_epoch"] == "8"
      assert allocation.provider_observation["container_generation_id"] == "container-1"
    end
  end

  defp reconcile_until_observed(workload_id, observed_state, steps) do
    Enum.reduce_while(1..steps, false, fn _step, false ->
      _ = ComputeReconciler.reconcile_workload(workload_id, 1)

      if Repo.get!(Compute.Workload, workload_id).observed_state == observed_state,
        do: {:halt, true},
        else: {:cont, false}
    end)
  end

  test "a running station container is adopted by its created generation when no runtime fact names it",
       fixture do
    Repo.delete_all(
      from(workload in Compute.Workload, where: workload.id == ^fixture.workload.id)
    )

    assert {:ok, station} =
             Compute.create_workload(%{
               id: fixture.workload.id,
               environment_id: fixture.workload.environment_id,
               allocation_id: fixture.workload.allocation_id,
               kind: "shell",
               template_key: "station.default",
               capability_requirements: ["runtime_exec"],
               generation: fixture.workload.generation
             })

    assert {:ok, image} = RuntimeBundleCatalog.image_for_workload(station)
    Process.put(:compute_reconciler_image_imported, true)
    Process.put(:compute_reconciler_image_reference, image["reference"])
    Process.put(:compute_reconciler_manifest_digest, image["manifestDigest"])
    open_host_session!(fixture, "station-adopt")

    # The Host runs the container Salix recorded (its delete fence names the
    # generation), but no runtime_* fact was written: `create_container`
    # stopped between recording the container and its runtime generation.
    container_id = expected_container_id(fixture.workload.id, 1)
    Process.put(:compute_reconciler_container_id, container_id)
    Process.put(:compute_reconciler_container_state, "running")
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    facts =
      Map.merge(allocation.provider_observation, %{
        "imported_reference" => image["reference"],
        "current_container" => %{
          "id" => container_id,
          "generation_id" => "container-1",
          "instance_id" => "instance-1",
          "state" => "running"
        },
        "container_status" => "running",
        "container_generation_id" => "container-1"
      })

    refute Enum.any?(Map.keys(facts), &String.starts_with?(&1, "runtime_"))

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [provider_observation: facts]
    )

    # A container of another generation than the recorded one is not adopted.
    Process.put(:compute_reconciler_container_generation, "container-2")

    assert {:error, :runtime_instance_changed} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    settle_receive({:compute_host_request, _list_url, %{}})
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert is_nil(allocation.provider_observation["runtime_container_generation_id"])

    Process.delete(:compute_reconciler_container_generation)

    assert {:ok, %Compute.Workload{observed_state: "ready"}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    settle_receive({:compute_host_request, list_url, %{}})
    assert String.ends_with?(list_url, "/compute.container.list")
    refute_received {:compute_host_request, _, _}

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["runtime_container_generation_id"] == "container-1"
    assert allocation.provider_observation["runtime_container_instance_id"] == "instance-1"
    assert allocation.provider_observation["runtime_verified_host_epoch"] == "7"
    assert allocation.provider_observation["current_container"]["id"] == container_id
  end

  # Reconciles one step at a time, draining the Host requests of each step,
  # until a step asks the Host to create the container.
  defp reconcile_until_container_create(workload_id, steps) when steps > 0 do
    result = ComputeReconciler.reconcile_workload(workload_id, 1)

    {:messages, messages} = Process.info(SystemsRuntime.Proc.self(), :messages)

    creates? =
      Enum.any?(messages, fn
        {:compute_host_request, url, _} -> String.ends_with?(url, "/compute.container.create")
        _ -> false
      end)

    if creates? do
      Enum.each(messages, fn
        {:compute_host_request, url, _} = message ->
          unless String.ends_with?(url, "/compute.container.create"),
            do: receive(do: (^message -> :ok))

        {:compute_host_import_request, _, _} = message ->
          receive(do: (^message -> :ok))

        _ ->
          :ok
      end)

      result
    else
      reconcile_until_container_create(workload_id, steps - 1)
    end
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

    settle_receive({:compute_host_request, first_list_url, %{}})
    assert String.ends_with?(first_list_url, "/compute.container.list")
    settle_receive({:compute_host_request, stop_url, stop_args})
    assert String.ends_with?(stop_url, "/compute.container.stop")
    assert stop_args["container_id"] == superseded["id"]
    refute_received {:compute_host_request, _delete_url, _}

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)

    settle_receive({:compute_host_request, second_list_url, %{}})
    assert String.ends_with?(second_list_url, "/compute.container.list")
    settle_receive({:compute_host_request, delete_url, delete_args})
    assert String.ends_with?(delete_url, "/compute.container.delete")
    assert delete_args["container_id"] == superseded["id"]
    assert delete_args["expected_generation_id"] == superseded["generation_id"]

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["current_container"] == %{}
    assert is_nil(allocation.provider_observation["container_status"])

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)

    settle_receive({:compute_host_request, _cleanup_list_url, %{}})
    settle_receive({:compute_host_request, _current_list_url, %{}})
    settle_receive({:compute_host_request, image_list_url, %{}})
    assert String.ends_with?(image_list_url, "/compute.image.list")
    settle_receive({:compute_host_request, create_url, create_args})
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

    settle_receive({:compute_host_request, list_url, %{}})
    assert String.ends_with?(list_url, "/compute.container.list")
    refute_received {:compute_host_request, _mutation_url, _}
  end

  test "materialized templates drive allocation limits and egress", fixture do
    cases = [
      {"shell.default", "shell", "EGRESS_MODE_DENY_ALL"},
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

  test "bounded sweep repairs a runtime that disconnected after its workload became ready",
       fixture do
    assert {:ok, materialized} =
             RuntimeBundleCatalog.materialize(
               "meeting.meetnative",
               %{owner_id: fixture.workload.id, generation: fixture.workload.generation}
             )

    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "meeting_runtime",
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
      updated_at: SystemsClock.utc_now()
    })

    assert :complete = ComputeReconciler.sweep(32)

    assert %Compute.Command{kind: "runtime.open_session", status: "pending"} =
             Repo.get_by!(Compute.Command,
               allocation_id: fixture.allocation.id,
               workload_id: fixture.workload.id
             )
  end

  for failure <- [:stale, :expired] do
    @tag session_failure: failure
    test "bounded sweep replaces a #{failure} shell session without a Host reconnect", fixture do
      open_host_session!(fixture, "original")
      {:ok, session} = AgentVMM.current_host_session_for_workload(fixture.workload.id)
      allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
      container_id = expected_container_id(fixture.workload.id, 1)
      Process.put(:compute_reconciler_container_id, container_id)
      Process.put(:compute_reconciler_container_state, "running")

      facts =
        Map.merge(allocation.provider_observation, %{
          "runtime_verified_host_epoch" => "7",
          "imported_reference" => fixture.image_reference,
          "container_status" => "running",
          "runtime_container_generation_id" => "container-1",
          "runtime_container_instance_id" => "instance-1",
          "current_container" => %{
            "id" => container_id,
            "generation_id" => "container-1",
            "instance_id" => "instance-1",
            "state" => "running"
          }
        })

      Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
        set: [provider_observation: facts]
      )

      Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
        set: [observed_state: "ready"]
      )

      assert :complete = ComputeReconciler.sweep(32)

      refute Repo.exists?(
               from(c in Compute.ReconcilerClaim, where: c.workload_id == ^fixture.workload.id)
             )

      case fixture.session_failure do
        :stale ->
          assert :ok =
                   AgentVMM.invalidate_host_session(
                     fixture.workload.id,
                     Map.put(Map.from_struct(session), :session_id, session.id)
                   )

          assert Repo.get!(Compute.Workload, fixture.workload.id).observed_state == "pending"

        :expired ->
          Repo.update_all(from(s in AgentVMM.Session, where: s.id == ^session.id),
            set: [expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
          )
      end

      assert :complete = ComputeReconciler.sweep(32)

      assert %Compute.Command{kind: "runtime.open_session", status: "pending"} =
               Repo.get_by(Compute.Command, workload_id: fixture.workload.id, status: "pending")

      open_host_session!(fixture, "replacement")
      assert {:ok, current} = AgentVMM.current_host_session_for_workload(fixture.workload.id)
      assert current.connection_epoch == session.connection_epoch
      assert current.status == "ready"

      assert {:ok, %Compute.Workload{observed_state: "ready"}} =
               ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

      assert {:ok, _} = SalixStore.AgentVMMHostClient.list_processes(%{}, fixture.workload.id)
    end
  end

  @tag session_failure: :delayed_response
  test "an old stale response cannot invalidate a renewed same-epoch session", fixture do
    open_host_session!(fixture, "original")
    {:ok, old} = AgentVMM.current_host_session_for_workload(fixture.workload.id)

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [observed_state: "ready"]
    )

    Repo.update_all(from(s in AgentVMM.Session, where: s.id == ^old.id),
      set: [status: "stale"]
    )

    open_host_session!(fixture, "replacement", "7", 721_000)
    {:ok, replacement} = AgentVMM.current_host_session_for_workload(fixture.workload.id)
    refute replacement.expires_at == old.expires_at

    assert :ok =
             AgentVMM.invalidate_host_session(
               fixture.workload.id,
               Map.put(Map.from_struct(old), :session_id, old.id)
             )

    assert {:ok, current} = AgentVMM.current_host_session_for_workload(fixture.workload.id)
    assert current.expires_at == replacement.expires_at
    assert Repo.get!(Compute.Workload, fixture.workload.id).observed_state == "ready"
  end

  test "does not scan or reconcile a stale generation", fixture do
    assert {:error, :stale_generation} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 2)
  end

  @tag :runtime_recovery
  test "Host reconnect keeps the execution credential and resumes only its exact container",
       fixture do
    fixture = running_meeting_runtime!(fixture)

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

    assert {:ok, %Compute.Workload{observed_state: "ready"}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_received {:compute_host_request, _, %{"quiesce_request_id" => _}}
    refute_received {:compute_host_request, _, %{"expected_generation_id" => _}}
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
        expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)
      ]
    )

    assert {:error, :runtime_control_unavailable} =
             Compute.open_runtime_carrier(credential["token"], runtime_handshake())
  end

  @tag :runtime_recovery
  test "same container name cannot authorize another execution instance", fixture do
    fixture = running_meeting_runtime!(fixture)

    Repo.update_all(
      from(r in Compute.RuntimeInstance, where: r.workload_id == ^fixture.workload.id),
      set: [status: "disconnected", readiness: "pending"]
    )

    Process.put(:compute_reconciler_container_instance, "replacement-instance")

    assert {:error, :runtime_instance_changed} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    refute_received {:compute_host_request, _, %{"quiesce_request_id" => _}}

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).provider_observation[
             "runtime_container_instance_id"
           ] == "instance-1"
  end

  @tag :runtime_recovery
  test "authoritative stopped container replaces a stale running projection", fixture do
    fixture = running_meeting_runtime!(fixture)
    Process.put(:compute_reconciler_container_state, "stopped")
    Process.put(:compute_reconciler_container_instance, nil)

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    settle_receive({:compute_host_request, list_url, %{}})
    assert String.ends_with?(list_url, "/compute.container.list")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.provider_observation["container_status"] == "stopped"
    assert allocation.provider_observation["current_container"]["state"] == "stopped"
    assert is_nil(allocation.provider_observation["runtime_container_instance_id"])

    assert {:ok, %{outcome: :pending}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    settle_receive({:compute_host_request, _list_url, %{}})
    settle_receive({:compute_host_request, delete_url, delete_args})
    assert String.ends_with?(delete_url, "/compute.container.delete")
    assert delete_args["expected_generation_id"] == "container-1"
  end

  @tag :guest_restart
  test "a fresh container observation cannot overwrite a terminal Workload owner",
       fixture do
    fixture = running_meeting_runtime!(fixture)
    workload = Repo.get!(Compute.Workload, fixture.workload.id)
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    Process.put(:compute_reconciler_container_state, "stopped")
    Process.put(:compute_reconciler_container_instance, nil)

    Process.put(:compute_reconciler_container_list_hook, fn ->
      assert {:ok, _} = Compute.stop_workload(workload.id, workload.revision, "meeting_ended")
    end)

    assert {:error, _} = ComputeReconciler.reconcile_workload(workload.id, 1)
    refute_received {:compute_host_request, _, %{"expected_generation_id" => _}}

    assert Repo.get!(Compute.Allocation, allocation.id).provider_observation ==
             allocation.provider_observation

    assert Repo.get!(Compute.Workload, workload.id).observed_state == "ready"
    assert Repo.get!(Compute.Workload, workload.id).desired_state == "stopped"
  end

  @tag :host_start_fence
  test "fresh container proof cannot start through a replacement Workload generation", fixture do
    open_host_session!(fixture, "start-fence")
    id = expected_container_id(fixture.workload.id, 1)

    container = %{
      "id" => id,
      "generation_id" => "container-1",
      "instance_id" => nil,
      "start_request_instance_id" => "instance-1",
      "state" => "stopped"
    }

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation: %{
          "current_container" => container,
          "container_status" => "stopped",
          "container_generation_id" => "container-1",
          "runtime_container_generation_id" => "container-1",
          "runtime_container_instance_id" => nil,
          "imported_reference" => fixture.image_reference
        }
      ]
    )

    Process.put(:compute_reconciler_container_id, id)
    Process.put(:compute_reconciler_container_state, "stopped")
    Process.put(:compute_reconciler_container_instance, nil)

    Process.put(:compute_reconciler_container_list_hook, fn ->
      Process.delete(:compute_reconciler_container_list_hook)
      Repo.update_all(Compute.Workload, set: [generation: 2], inc: [revision: 1])
      Repo.update_all(Compute.Environment, set: [generation: 2])
      Repo.update_all(Compute.Allocation, set: [generation: 2])
      Repo.update_all(Compute.ProviderBinding, set: [generation: 2])
      Repo.update_all(Compute.RuntimeInstance, set: [generation: 2])
      Repo.update_all(AgentVMM.Session, set: [allocation_generation: 2])
    end)

    assert {:error, _} = ComputeReconciler.reconcile_workload(fixture.workload.id, 1)
    refute_received {:compute_host_request, _, %{"expected_generation_id" => _}}
    assert Process.get(:compute_reconciler_container_state) == "stopped"
    assert Repo.get!(Compute.Workload, fixture.workload.id).generation == 2
  end

  defp running_meeting_runtime!(fixture) do
    open_host_session!(fixture, "runtime-before-reconnect")

    {:ok, materialized} =
      RuntimeBundleCatalog.materialize(
        "meeting.meetnative",
        %{owner_id: fixture.workload.id, generation: 1}
      )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [
        kind: "meeting_runtime",
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
          DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), -60, :second)),
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

  defp open_host_session!(fixture, tunnel_nonce, epoch \\ "7", ttl_ms \\ 720_000) do
    assert {:ok, %{outcome: :pending, command: command}} =
             ComputeReconciler.reconcile_workload(fixture.workload.id, 1)

    assert command.kind == "runtime.open_session"
    expires_unix_millis = SystemsClock.system_time(:millisecond) + ttl_ms

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

  defp expected_container_id(workload_id, generation) do
    digest =
      :crypto.hash(:sha256, workload_id <> ":" <> Integer.to_string(generation))
      |> Base.encode16(case: :lower)

    "salix-" <> binary_part(digest, 0, 32)
  end

  test "a leftover worker binding still owns a shell Workload", fixture do
    now = SystemsClock.utc_now()

    Repo.insert_all(Compute.ExternalWorkerBinding, [
      %{
        id: "shell-binding",
        tenant_id: "tenant",
        agent_id: "agent",
        source_kind: "compute_workload",
        workload_id: fixture.workload.id,
        status: "active",
        binding_revision: 1,
        runtime_spec: %{},
        created_at: now,
        updated_at: now
      }
    ])

    workload = Repo.get!(Compute.Workload, fixture.workload.id)

    assert {:error, :business_owner_required} =
             SalixStore.ComputeWorkloadDeletion.start(
               "tenant",
               "project",
               workload.id,
               workload.generation,
               "delete-shell",
               fn -> :ok end
             )

    assert Repo.exists?(from(b in Compute.ExternalWorkerBinding, where: b.id == "shell-binding"))
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
      set: [lease_expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
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

  test "backfill adopts a succeeded release without another provider operation",
       fixture do
    legacy_release_succeeded!(fixture, "legacy-backfill-event")

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "draining"]
    )

    assert {:ok, :adopted} =
             Compute.backfill_release_obligation(fixture.allocation.id, SystemsClock.utc_now())

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "released"
  end

  test "concurrent disconnect and release backfill preserve the release obligation", fixture do
    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "draining"]
    )

    disconnect =
      SystemsRuntime.Task.async(fn ->
        AgentVMM.mark_connection_lost("registration", "gateway-a", "7")
      end)

    backfill =
      SystemsRuntime.Task.async(fn ->
        Compute.backfill_release_obligation(fixture.allocation.id, SystemsClock.utc_now())
      end)

    assert {:ok, _} = settled_await(disconnect)
    assert {:ok, status} = settled_await(backfill)
    assert status in [:inserted, :present]
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

    expired_at = DateTime.add(SystemsClock.utc_now(), -1, :second)

    Repo.update_all(
      from(c in Compute.Command, where: c.id == ^release_command.id),
      set: [deadline_at: expired_at]
    )

    Repo.update_all(
      from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      inc: [revision: 1]
    )

    current_allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    settle_at = SystemsClock.utc_now()

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

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_store, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_store, key, value)

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
            deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
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
