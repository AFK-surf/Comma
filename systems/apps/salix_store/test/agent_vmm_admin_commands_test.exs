defmodule SalixStore.AgentVMMAdminCommandsTest do
  use SystemsClock.Case, async: false

  import Ecto.Query

  alias SalixStore.{AgentVMM, AgentVMMAdminCommands, AgentVMMRegistrations, Compute, Repo}
  alias SalixStore.AgentVMM.Registration

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_admin_command_receipts, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "default",
        region: "auto",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec", "runtime_process", "service_private"]
      })

    {:ok, _environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    :ok
  end

  test "node initialization is concurrent-idempotent, scoped, and preserves existing work" do
    previous = SystemsRuntime.get_env(:salix_store, :runtime_bundle_root)

    SystemsRuntime.put_env(
      :salix_store,
      :runtime_bundle_root,
      Path.expand("fixtures/runtime-bundle", __DIR__)
    )

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :runtime_bundle_root, previous) end)

    {:ok, _registration} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: "initial-host",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        credential: String.duplicate("s", 32),
        desired_enabled: true
      })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == "initial-host"),
      set: [status: "ready", credential_hash: "test-credential"]
    )

    connect_host!("initial-host", "1")

    {:ok, _binding} =
      Compute.create_provider_binding(%{
        id: "initial-binding",
        pool_id: "pool",
        environment_id: "environment",
        provider: "agent_vmm",
        provider_ref: "initial-host"
      })

    assert {:error, :not_found} =
             Compute.ensure_node_workload("other", "environment", "initial-host")

    assert {:error, :compute_node_not_ready} =
             Compute.ensure_node_workload("tenant", "environment", "other-host")

    results =
      1..6
      |> SystemsClock.async_stream(
        fn _ ->
          Compute.ensure_node_workload("tenant", "environment", "initial-host")
        end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, {:ok, workload}} -> workload.id end)

    assert length(Enum.uniq(results)) == 1
    assert Repo.aggregate(Compute.Workload, :count) == 1
    assert {:ok, reused} = Compute.ensure_node_workload("tenant", "environment", "initial-host")
    assert reused.id == hd(results)
    assert reused.template_key == "shell.default"

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^reused.id),
      set: [observed_state: "failed"]
    )

    assert {:ok, same_failed} =
             Compute.ensure_node_workload("tenant", "environment", "initial-host")

    assert same_failed.id == reused.id
    assert Repo.aggregate(Compute.Workload, :count) == 1

    registration = Repo.get!(SalixStore.AgentVMM.Registration, "initial-host")

    assert {:ok, disabled} =
             SalixStore.AgentVMM.configure_registration(
               registration.id,
               registration.revision,
               false
             )

    assert Repo.get!(Compute.Workload, reused.id).desired_state == "draining"
    assert Repo.get!(Compute.Allocation, reused.allocation_id).status == "draining"

    assert {:error, :compute_node_not_ready} =
             Compute.ensure_node_workload("tenant", "environment", "initial-host")

    assert {:ok, _enabled} =
             SalixStore.AgentVMM.configure_registration(disabled.id, disabled.revision, true)

    assert {:ok, replacement} =
             Compute.ensure_node_workload("tenant", "environment", "initial-host")

    refute replacement.id == reused.id
    assert replacement.desired_state == "ready"
    assert {:ok, retried} = Compute.ensure_node_workload("tenant", "environment", "initial-host")
    assert retried.id == replacement.id
    assert Repo.get!(Compute.Workload, reused.id).desired_state == "draining"
    assert Repo.get!(Compute.Allocation, reused.allocation_id).status == "draining"

    assert {:ok, _} = AgentVMM.mark_connection_lost("initial-host", "gateway", "1")

    assert {:error, :compute_node_not_ready} =
             Compute.ensure_node_workload("tenant", "environment", "initial-host")

    assert Repo.aggregate(Compute.Workload, :count) == 2
  end

  test "Shell creation is tenant scoped and response-loss replay creates only one workload" do
    previous = SystemsRuntime.get_env(:salix_store, :runtime_bundle_root)

    SystemsRuntime.put_env(
      :salix_store,
      :runtime_bundle_root,
      Path.expand("fixtures/runtime-bundle", __DIR__)
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :runtime_bundle_root, previous),
        else: SystemsRuntime.delete_env(:salix_store, :runtime_bundle_root)
    end)

    # Shell placement uses the enrolled Host and its current connection.
    assert {:ok, _} =
             SalixStore.AgentVMMFixtures.registration(%{
               id: "shell-host",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "shell-device",
               credential: String.duplicate("s", 32)
             })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == "shell-host"),
      set: [status: "ready", desired_enabled: true]
    )

    connect_host!("shell-host", "1")

    {:ok, _binding} =
      Compute.create_provider_binding(%{
        id: "shell-binding",
        pool_id: "pool",
        environment_id: "environment",
        provider: "agent_vmm",
        provider_ref: "shell-host"
      })

    command = %{
      action: "create_shell_workload",
      tenant_id: "tenant",
      target_id: "environment",
      expected_revision: 1
    }

    assert {:error, :not_found} =
             AgentVMMAdminCommands.execute(SystemsRuntime.Proc.uuid(), %{
               command
               | tenant_id: "other"
             })

    assert {:error, :revision_conflict} =
             AgentVMMAdminCommands.execute(SystemsRuntime.Proc.uuid(), %{
               command
               | expected_revision: 999
             })

    command_id = SystemsRuntime.Proc.uuid()
    assert {:ok, %{accepted: true}} = AgentVMMAdminCommands.execute(command_id, command)
    assert {:already_applied, _} = AgentVMMAdminCommands.execute(command_id, command)
    assert Repo.aggregate(Compute.Workload, :count) == 1
    workload = Repo.get!(Compute.Workload, "workload_" <> command_id)
    assert workload.kind == "shell"
    assert workload.template_key == "shell.default"
    assert workload.environment_id == "environment"
  end

  test "execute scopes the target and fences its exact revision" do
    operation = retryable_install!()

    assert {:error, :not_found} =
             AgentVMMAdminCommands.execute(
               SystemsRuntime.Proc.uuid(),
               retry_command(%{operation | tenant_id: "other-tenant"})
             )

    assert {:error, :revision_conflict} =
             AgentVMMAdminCommands.execute(
               SystemsRuntime.Proc.uuid(),
               retry_command(%{operation | revision: operation.revision + 1})
             )

    command_id = SystemsRuntime.Proc.uuid()
    assert {:ok, result} = AgentVMMAdminCommands.execute(command_id, retry_command(operation))
    assert result.target == "registration:" <> operation.id

    assert {:already_applied, ^result} =
             AgentVMMAdminCommands.execute(command_id, retry_command(operation))
  end

  defp connect_host!(registration_id, epoch) do
    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration_id, "gateway", %{
               "connectionEpoch" => epoch,
               "inventoryWatermark" => 0,
               "inventory" => []
             })
  end

  defp retryable_install! do
    {:ok, descriptor} = AgentVMMRegistrations.request(request_attrs())
    make_action_required!(descriptor.registration)
  end

  defp make_action_required!(registration) do
    Repo.update_all(from(r in Registration, where: r.id == ^registration.id),
      set: [error_code: "local.install_failed"]
    )

    Repo.get!(Registration, registration.id)
  end

  defp retry_command(operation) do
    %{
      action: "retry_agent_vmm_install",
      tenant_id: operation.tenant_id,
      target_id: operation.id,
      expected_revision: operation.revision
    }
  end

  defp request_attrs do
    %{
      tenant_id: "tenant",
      group_id: "group",
      surface: "bft",
      owner_id: "project",
      client_request_id: "request",
      provider: "agent-vmm",
      environment_id: "environment",
      delivery_target_type: "bft_runner",
      delivery_target_id: "runner-a"
    }
  end
end
