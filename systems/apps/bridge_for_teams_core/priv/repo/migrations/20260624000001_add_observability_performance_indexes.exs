defmodule BridgeForTeams.Repo.Migrations.AddObservabilityPerformanceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS check_results_org_ran_at_id_desc_idx
    ON check_results (org_id, ran_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS check_results_org_status_ran_at_id_desc_idx
    ON check_results (org_id, status, ran_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS check_results_org_family_surface_ran_at_id_desc_idx
    ON check_results (org_id, check_family, surface, ran_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS check_results_org_project_ran_at_id_desc_idx
    ON check_results (org_id, project_id, ran_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS check_results_org_subject_ran_at_id_desc_idx
    ON check_results (org_id, subject_type, subject_id, ran_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS observability_events_occurred_at_idx
    ON observability_events (occurred_at)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS operation_runs_created_at_idx
    ON operation_runs (created_at)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS operation_runs_stderr_tail_created_at_idx
    ON operation_runs (created_at)
    WHERE stderr_tail_redacted IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS check_results_ran_at_idx
    ON check_results (ran_at)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS observability_events_org_source_occurred_id_desc_idx
    ON observability_events (org_id, source, occurred_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS observability_events_org_runner_type_occurred_id_desc_idx
    ON observability_events (org_id, runner_type, occurred_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS obs_events_org_runner_type_id_occurred_id_desc_idx
    ON observability_events (org_id, runner_type, runner_id, occurred_at DESC, id DESC)
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS obs_events_org_runner_type_id_occurred_id_desc_idx"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS observability_events_org_runner_type_runner_id_occurred_id_desc"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS observability_events_org_runner_type_occurred_id_desc_idx"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS observability_events_org_source_occurred_id_desc_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS check_results_ran_at_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS operation_runs_stderr_tail_created_at_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS operation_runs_created_at_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS observability_events_occurred_at_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS check_results_org_subject_ran_at_id_desc_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS check_results_org_project_ran_at_id_desc_idx")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS check_results_org_family_surface_ran_at_id_desc_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS check_results_org_status_ran_at_id_desc_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS check_results_org_ran_at_id_desc_idx")
  end
end
