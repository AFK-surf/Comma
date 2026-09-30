defmodule SalixStore.Repo.Migrations.ReplaceAgentVMMSessionLeaseIdentity do
  use Ecto.Migration

  def up do
    alter table(:agent_vmm_sessions) do
      add(:allocation_generation, :bigint)
    end

    execute("""
    UPDATE agent_vmm_sessions AS sessions
    SET allocation_generation = allocations.generation
    FROM compute_allocations AS allocations
    WHERE allocations.id = sessions.allocation_id
    """)

    alter table(:agent_vmm_sessions) do
      modify(:allocation_generation, :bigint, null: false)
    end

    drop(
      unique_index(:agent_vmm_sessions, [
        :registration_id,
        :runtime_instance_id,
        :lease_generation
      ])
    )

    execute("""
    DELETE FROM agent_vmm_sessions AS stale
    USING (
      SELECT id
      FROM (
        SELECT sessions.id,
               row_number() OVER (
                 PARTITION BY sessions.registration_id,
                              sessions.runtime_instance_id,
                              sessions.allocation_generation
                 ORDER BY
                   CASE WHEN sessions.lease_generation = allocations.lease_generation THEN 0 ELSE 1 END,
                   CASE WHEN sessions.status = 'ready' THEN 0 ELSE 1 END,
                   sessions.lease_generation DESC,
                   sessions.updated_at DESC,
                   sessions.id DESC
               ) AS position
        FROM agent_vmm_sessions AS sessions
        JOIN compute_allocations AS allocations ON allocations.id = sessions.allocation_id
      ) AS ranked
      WHERE position > 1
    ) AS duplicates
    WHERE stale.id = duplicates.id
    """)

    alter table(:agent_vmm_sessions) do
      remove(:lease_id)
      remove(:lease_generation)
      remove(:allocation_lease_generation)
    end

    create(
      unique_index(:agent_vmm_sessions, [
        :registration_id,
        :runtime_instance_id,
        :allocation_generation
      ])
    )

    execute("""
    UPDATE compute_allocations AS allocations
    SET provider_observation = allocations.provider_observation
          - 'lease_id'
          - 'lease_generation'
          - 'lease_expires_at'
    """)

    alter table(:compute_allocations) do
      remove(:lease_generation)
      remove(:lease_expires_at)
    end

    alter table(:compute_commands) do
      remove(:lease_generation)
    end
  end

  def down do
    raise Ecto.MigrationError,
          "Agent VMM allocation lease identities cannot be reconstructed after the allocation-generation cutover"
  end
end
