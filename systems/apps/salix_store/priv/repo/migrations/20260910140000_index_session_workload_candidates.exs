defmodule SalixStore.Repo.Migrations.IndexSessionWorkloadCandidates do
  use Ecto.Migration

  def up do
    drop(constraint(:agent_vmm_registration_observations, :agent_vmm_observation_shape))

    alter table(:agent_vmm_registration_observations) do
      remove(:inventory_count)
    end

    create(
      constraint(:agent_vmm_registration_observations, :agent_vmm_observation_shape,
        check:
          "observation_sequence > 0 AND inventory_watermark >= 0 AND health_status IN ('healthy','degraded','unavailable') AND char_length(gateway_instance_id) BETWEEN 1 AND 128 AND char_length(connection_epoch) BETWEEN 1 AND 20 AND char_length(protocol_version) BETWEEN 1 AND 32 AND char_length(host_api_version) BETWEEN 1 AND 32 AND (connector_release IS NULL OR char_length(connector_release) <= 128) AND (health_message IS NULL OR char_length(health_message) <= 256) AND cardinality(supported_features) <= 32"
      )
    )

    alter table(:session_work_candidates) do
      add(:workload_id, :text)
    end

    alter table(:session_work_backfill_expected_candidates) do
      add(:workload_id, :text)
    end

    create(
      index(
        :session_work_candidates,
        [:workload_id, :agent_id, :runtime_kind, :session_id, :candidate_token],
        name: :session_work_candidates_workload_eager_index,
        where: "workload_id IS NOT NULL AND due_at_ms IS NULL"
      )
    )

    create(
      index(
        :session_work_candidates,
        [:workload_id, :due_at_ms, :candidate_token],
        name: :session_work_candidates_workload_due_index,
        where: "workload_id IS NOT NULL AND due_at_ms IS NOT NULL"
      )
    )

    drop(constraint(:compute_capacity_queue, :compute_capacity_queue_reason_check))

    execute("""
    UPDATE compute_capacity_queue
    SET reason = CASE
      WHEN reason = 'queued_memory' THEN 'queued_memory_pressure'
      ELSE 'queued_run_slot'
    END
    WHERE reason IN (
      'queued_cpu_guarantee',
      'queued_cpu_max',
      'queued_memory',
      'queued_pids',
      'queued_writable_storage'
    )
    """)

    execute("""
    INSERT INTO compute_reconciler_claims (
      id, provider, workload_id, generation, claim_token, attempt_count,
      next_retry_at, lease_expires_at, last_error, created_at, updated_at
    )
    SELECT
      'agent_vmm:' || workload_id || ':' || generation,
      'agent_vmm',
      workload_id,
      generation,
      'capacity-cutover-action-required',
      1,
      NULL,
      NULL,
      jsonb_build_object(
        'kind', 'action_required',
        'code', 'resource_capacity_exhausted',
        'resource', CASE
          WHEN reason = 'queued_storage_headroom' THEN 'storage_headroom'
          ELSE 'import_slot'
        END
      ),
      now(),
      now()
    FROM compute_capacity_queue
    WHERE provider = 'agent_vmm'
      AND status = 'queued'
      AND reason IN ('queued_storage_headroom', 'queued_import_slot')
    ON CONFLICT (provider, workload_id, generation) DO UPDATE
      SET next_retry_at = NULL,
          lease_expires_at = NULL,
          last_error = EXCLUDED.last_error,
          updated_at = EXCLUDED.updated_at
    """)

    execute("""
    DELETE FROM compute_capacity_queue
    WHERE provider = 'agent_vmm'
      AND reason IN ('queued_storage_headroom', 'queued_import_slot')
    """)

    create(
      constraint(:compute_capacity_queue, :compute_capacity_queue_reason_check,
        check: "reason IN ('queued_run_slot', 'queued_memory_pressure')"
      )
    )
  end

  def down, do: raise("This storage cutover requires forward repair after commit")
end
