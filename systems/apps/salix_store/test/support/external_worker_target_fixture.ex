defmodule SalixStore.TestSupport.ExternalWorkerTargetFixture do
  @moduledoc false
  alias SalixStore.{AgentVMM, Compute, Repo}

  def create(prefix, project_id, group_id, provider, tenant_id \\ "tenant") do
    now = DateTime.utc_now()
    template_key = "external.#{provider}"

    pool =
      Repo.insert!(%Compute.Pool{
        id: "#{prefix}-pool",
        tenant_id: tenant_id,
        name: "#{prefix}-pool",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec", "runtime_process"],
        capacity: %{},
        quota: %{},
        status: "active",
        revision: 1,
        created_at: now,
        updated_at: now
      })

    environment =
      Repo.insert!(%Compute.Environment{
        id: "#{prefix}-environment",
        tenant_id: tenant_id,
        owner_type: "project",
        owner_id: project_id,
        pool_id: pool.id,
        desired_state: "ready",
        observed_state: "ready",
        generation: 1,
        revision: 1,
        retention: %{"mode" => "retain"},
        inventory_watermark: 1,
        created_at: now,
        updated_at: now
      })

    registration =
      Repo.insert!(%AgentVMM.Registration{
        id: "#{prefix}-registration",
        tenant_id: tenant_id,
        group_id: group_id,
        device_id: "#{prefix}-node",
        status: "ready",
        revision: 1,
        policy_revision: 1,
        desired_enabled: true,
        next_controller_sequence: 1,
        created_at: now,
        updated_at: now
      })

    binding =
      Repo.insert!(%Compute.ProviderBinding{
        id: "#{prefix}-binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        status: "available",
        generation: 1,
        revision: 1,
        observation: %{},
        updated_at: now
      })

    allocation =
      Repo.insert!(%Compute.Allocation{
        id: "#{prefix}-allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        status: "ready",
        operation_outcome: "succeeded",
        generation: 1,
        provider_observation: %{
          "current_container" => %{
            "id" => "#{prefix}-container",
            "instance_id" => "#{prefix}-instance"
          },
          "container_status" => "running"
        },
        revision: 1,
        created_at: now,
        updated_at: now
      })

    workload =
      Repo.insert!(%Compute.Workload{
        id: "#{prefix}-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: %{},
        template_key: template_key,
        runtime_revision: "runtime-1",
        capability_requirements: [],
        desired_state: "ready",
        observed_state: "ready",
        generation: 1,
        revision: 1,
        created_at: now,
        updated_at: now
      })

    runtime =
      Repo.insert!(%Compute.RuntimeInstance{
        id: "#{prefix}-runtime",
        workload_id: workload.id,
        allocation_id: allocation.id,
        status: "connected",
        readiness: "ready",
        generation: 1,
        connection_epoch: "1",
        caught_up_epoch: "1",
        revision: 1,
        updated_at: now
      })

    %{
      environment: environment,
      registration: registration,
      workload: workload,
      runtime: runtime
    }
  end

  def add_workload(existing, prefix, provider) do
    now = DateTime.utc_now()

    workload =
      Repo.insert!(%Compute.Workload{
        id: prefix <> "-workload",
        environment_id: existing.environment.id,
        allocation_id: existing.workload.allocation_id,
        kind: "external_worker",
        spec: %{},
        template_key: "external." <> provider,
        runtime_revision: "runtime-1",
        capability_requirements: [],
        desired_state: "ready",
        observed_state: "ready",
        generation: 1,
        revision: 1,
        created_at: now,
        updated_at: now
      })

    runtime =
      Repo.insert!(%Compute.RuntimeInstance{
        id: prefix <> "-runtime",
        workload_id: workload.id,
        allocation_id: workload.allocation_id,
        status: "connected",
        readiness: "ready",
        generation: 1,
        connection_epoch: "1",
        caught_up_epoch: "1",
        revision: 1,
        updated_at: now
      })

    %{existing | workload: workload, runtime: runtime}
  end
end
