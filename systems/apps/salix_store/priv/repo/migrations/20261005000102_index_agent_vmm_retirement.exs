defmodule SalixStore.Repo.Migrations.IndexAgentVMMRetirement do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:compute_commands, [:allocation_id, :id],
        where: "status = 'pending' AND delivery_started_at IS NULL",
        name: :compute_undelivered_retirement_page,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:agent_vmm_registrations, [:id],
        where: "status = 'revoked'",
        name: :agent_vmm_retired_page,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:compute_provider_bindings, [:provider_ref, :id],
        where: "provider = 'agent_vmm'",
        name: :compute_agent_vmm_retirement_page,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:compute_allocations, [:provider_binding_id, :id],
        name: :compute_binding_allocation_page,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:compute_workloads, [:allocation_id, :id],
        name: :compute_allocation_workload_page,
        concurrently: true
      )
    )
  end

  def down do
    drop(
      index(:compute_commands, [:allocation_id, :id],
        name: :compute_undelivered_retirement_page,
        concurrently: true
      )
    )

    drop(
      index(:compute_workloads, [:allocation_id, :id],
        name: :compute_allocation_workload_page,
        concurrently: true
      )
    )

    drop(
      index(:compute_allocations, [:provider_binding_id, :id],
        name: :compute_binding_allocation_page,
        concurrently: true
      )
    )

    drop(
      index(:compute_provider_bindings, [:provider_ref, :id],
        name: :compute_agent_vmm_retirement_page,
        concurrently: true
      )
    )

    drop(
      index(:agent_vmm_registrations, [:id], name: :agent_vmm_retired_page, concurrently: true)
    )
  end
end
