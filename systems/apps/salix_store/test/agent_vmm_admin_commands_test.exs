defmodule SalixStore.AgentVMMAdminCommandsTest do
  use SystemsClock.Case, async: false

  import Ecto.Query

  alias SalixStore.{AgentVMMAdminCommands, AgentVMMInstallations, Compute, Repo}
  alias SalixStore.AgentVMMInstallations.Operation

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_admin_command_receipts, agent_vmm_install_operations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
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
    now = SystemsClock.utc_now()

    Repo.insert!(%SalixStore.AgentVMM.Registration{
      id: "initial-host",
      credential_hash: "test-credential",
      tenant_id: "tenant",
      group_id: "group",
      device_id: "device",
      status: "ready",
      desired_enabled: true,
      revision: 1,
      policy_revision: 1,
      next_controller_sequence: 1,
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%Compute.ProviderBinding{
      id: "initial-binding",
      pool_id: "pool",
      environment_id: "environment",
      provider: "agent_vmm",
      provider_ref: "initial-host",
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: now
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

    # Model the provider observation after the connector reconnects.
    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == "initial-binding"),
      set: [status: "available"]
    )

    assert {:ok, replacement} =
             Compute.ensure_node_workload("tenant", "environment", "initial-host")

    refute replacement.id == reused.id
    assert replacement.desired_state == "ready"
    assert {:ok, retried} = Compute.ensure_node_workload("tenant", "environment", "initial-host")
    assert retried.id == replacement.id
    assert Repo.get!(Compute.Workload, reused.id).desired_state == "draining"
    assert Repo.get!(Compute.Allocation, reused.allocation_id).status == "draining"

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == "initial-binding"),
      set: [status: "unavailable"]
    )

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

    # A provider projection cannot grant authority without its live registration.
    assert {:ok, _} =
             SalixStore.AgentVMM.create_registration(%{
               id: "shell-host",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "shell-device",
               enrollment_token: String.duplicate("s", 32)
             })

    Repo.insert!(%Compute.ProviderBinding{
      id: "shell-binding",
      pool_id: "pool",
      environment_id: "environment",
      provider: "agent_vmm",
      provider_ref: "shell-host",
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: SystemsClock.utc_now()
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
  end

  defp retryable_install! do
    {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())
    make_action_required!(descriptor.operation)
  end

  defp make_action_required!(operation) do
    operation_id = operation.id

    {1, _} =
      Repo.update_all(
        from(o in Operation, where: o.id == ^operation_id),
        set: [
          authorization_status: "action_required",
          ticket_status: "revoked",
          error_code: "ticket_retry_exhausted"
        ]
      )

    Repo.get!(Operation, operation.id)
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
      scope_key: "project",
      client_request_id: "request",
      provider: "agent-vmm",
      environment_id: "environment",
      delivery_target_type: "bft_runner",
      delivery_target_id: "runner-a"
    }
  end
end
