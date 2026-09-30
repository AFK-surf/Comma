defmodule SalixStore.Repo.Migrations.RemoveWorkloadRunCapacityQueue do
  use Ecto.Migration

  def up do
    # A capacity rejection performed no operation. Preserve the original command
    # and deadline when removing the wait projection. Terminal commands stay terminal.
    execute("""
    UPDATE compute_commands c
    SET status = 'pending', outcome = 'pending', next_attempt_at = NULL, updated_at = now()
    FROM compute_capacity_queue q, compute_workloads w, compute_allocations a
    WHERE q.command_id = c.id AND q.status = 'queued'
      AND q.workload_id = w.id AND q.generation = w.generation
      AND w.desired_state = 'ready' AND a.id = c.allocation_id
      AND a.generation = c.target_generation AND a.status != 'released'
      AND c.status = 'failed' AND c.deadline_at > now()
      AND c.evidence->'result'->>'reason' = 'ERROR_REASON_CAPACITY_EXHAUSTED'
      AND c.evidence->'result'->>'capacityDimension' IN
        ('CAPACITY_DIMENSION_RUN_SLOT', 'CAPACITY_DIMENSION_MEMORY_PRESSURE')
      AND q.reason IN ('queued_run_slot', 'queued_memory_pressure')
    """)

    execute("""
    UPDATE compute_reconciler_claims
    SET last_error = NULL, next_retry_at = now(), lease_expires_at = NULL
    WHERE provider = 'agent_vmm'
      AND last_error->>'resource' IN ('run_slot', 'memory_pressure')
    """)

    drop(table(:compute_capacity_queue))

    alter table(:compute_provider_bindings) do
      remove(:capacity_event_epoch)
    end
  end

  def down do
    raise "Run-capacity removal requires forward repair."
  end
end
