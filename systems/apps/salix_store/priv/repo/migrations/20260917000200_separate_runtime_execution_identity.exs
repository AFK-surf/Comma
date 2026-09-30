defmodule SalixStore.Repo.Migrations.SeparateRuntimeExecutionIdentity do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:compute_runtime_inputs, [:workload_id, :generation, :status],
        name: :compute_runtime_inputs_unsettled_workload_idx,
        where: "status IN ('pending', 'in_flight')",
        concurrently: true
      )
    )

    # Preserve the existing execution credential and its known container. A
    # fresh Host inventory must still confirm this instance before dispatch.
    execute("""
    UPDATE compute_allocations a
    SET provider_observation = a.provider_observation || jsonb_build_object(
      'runtime_execution_epoch', r.connection_epoch,
      'runtime_container_generation_id', a.provider_observation->'current_container'->>'generation_id',
      'runtime_container_instance_id', a.provider_observation->'current_container'->>'instance_id',
      'runtime_verified_host_epoch', NULL
    )
    FROM compute_runtime_instances r, compute_workloads w, compute_provider_bindings b
    WHERE r.allocation_id = a.id AND w.id = r.workload_id
      AND w.allocation_id = a.id AND r.generation = w.generation
      AND b.id = a.provider_binding_id AND b.provider = 'agent_vmm'
      AND r.bootstrap_consumed_epoch = r.connection_epoch
      AND a.provider_observation->'current_container'->>'generation_id' <> ''
      AND a.provider_observation->'current_container'->>'instance_id' <> ''
    """)
  end

  def down do
    drop_if_exists(
      index(:compute_runtime_inputs, [:workload_id, :generation, :status],
        name: :compute_runtime_inputs_unsettled_workload_idx,
        concurrently: true
      )
    )

    execute("""
    UPDATE compute_allocations
    SET provider_observation = provider_observation
      - 'runtime_execution_epoch' - 'runtime_container_generation_id'
      - 'runtime_container_instance_id' - 'runtime_verified_host_epoch'
    """)
  end
end
