defmodule BridgeForTeams.Repo.Migrations.CreateObservabilityTables do
  @moduledoc """
  BFT Operations read-model tables from the observability RFC.

  These tables store redacted, org-scoped operator facts. They intentionally do
  not replace the subsystem source-of-truth tables.
  """
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]
  @ts_create_only [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  def up do
    create table(:operation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :environment_id, :binary_id
      add :runner_type, :text
      add :runner_id, :binary_id
      add :run_type, :text, null: false
      add :external_run_id, :text
      add :request_id, :text
      add :status, :text, null: false
      add :reason_class, :text
      add :exit_code, :integer
      add :duration_ms, :integer
      add :evidence, :map, null: false, default: %{}
      add :evidence_size_bytes, :integer, null: false, default: 0
      add :stderr_tail_redacted, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create index(:operation_runs, [:org_id, :created_at])
    create index(:operation_runs, [:org_id, :run_type, :created_at])
    create index(:operation_runs, [:org_id, :status, :created_at])
    create index(:operation_runs, [:org_id, :project_id, :created_at])
    create index(:operation_runs, [:org_id, :runner_type, :runner_id, :created_at])

    create unique_index(:operation_runs, [:org_id, :external_run_id],
             where: "external_run_id IS NOT NULL"
           )

    create index(:operation_runs, [:org_id, :request_id])

    create table(:check_results, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :check_family, :text, null: false
      add :surface, :text, null: false
      add :subject_type, :text, null: false
      add :subject_id, :text, null: false
      add :status, :text, null: false
      add :reason_class, :text
      add :result, :map, null: false, default: %{}
      add :result_size_bytes, :integer, null: false, default: 0
      add :ran_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :invocation_id, :text
      add :ran_at, :utc_datetime_usec, null: false

      timestamps(@ts_create_only)
    end

    create index(:check_results, [:org_id, :created_at])
    create index(:check_results, [:org_id, :check_family, :surface, :created_at])
    create index(:check_results, [:org_id, :project_id, :created_at])
    create index(:check_results, [:org_id, :subject_type, :subject_id, :created_at])

    create unique_index(:check_results, [:org_id, :invocation_id],
             where: "invocation_id IS NOT NULL"
           )

    create table(:observability_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :conversation_id, :binary_id
      add :environment_id, :binary_id
      add :runner_type, :text
      add :runner_id, :binary_id
      add :run_record_id, references(:operation_runs, type: :binary_id, on_delete: :nilify_all)
      add :check_result_id, references(:check_results, type: :binary_id, on_delete: :nilify_all)
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :domain, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :text
      add :source, :text, null: false
      add :event_type, :text, null: false
      add :severity, :text, null: false
      add :status, :text
      add :reason_class, :text
      add :summary, :text, null: false
      add :evidence, :map, null: false, default: %{}
      add :evidence_size_bytes, :integer, null: false, default: 0
      add :correlation_id, :text
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(@ts_create_only)
    end

    create index(:observability_events, [:org_id, :occurred_at])
    create index(:observability_events, [:org_id, :domain, :occurred_at])
    create index(:observability_events, [:org_id, :severity, :occurred_at])
    create index(:observability_events, [:org_id, :project_id, :occurred_at])
    create index(:observability_events, [:org_id, :resource_type, :resource_id, :occurred_at])
    create index(:observability_events, [:org_id, :run_record_id])
    create index(:observability_events, [:org_id, :check_result_id])
    create index(:observability_events, [:org_id, :correlation_id])

    alter table(:audit_logs) do
      add :actor_type, :text, null: false, default: "system"
      add :actor_label, :text
      add :impersonator_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :resource_type, :text, null: false, default: "legacy"
      add :resource_id, :text
      add :resource_label, :text
      add :result, :text, null: false, default: "unknown"
      add :reason_class, :text
      add :request_id, :text
      add :redacted_diff, :map, null: false, default: %{}
      add :metadata_size_bytes, :integer, null: false, default: 0
    end

    execute("""
    UPDATE audit_logs
    SET
      actor_type = CASE WHEN actor_user_id IS NULL THEN 'system' ELSE 'user' END,
      metadata = COALESCE(metadata, '{}'::jsonb),
      metadata_size_bytes = octet_length(COALESCE(metadata, '{}'::jsonb)::text)
    """)

    execute(legacy_audit_backfill_sql())

    alter table(:audit_logs) do
      modify :metadata, :map, null: false, default: %{}
    end

    create index(:audit_logs, [:org_id, :actor_user_id, :created_at])
    create index(:audit_logs, [:org_id, :resource_type, :resource_id, :created_at])
    create index(:audit_logs, [:org_id, :action, :created_at])
    create index(:audit_logs, [:org_id, :result, :created_at])
    create index(:audit_logs, [:org_id, :request_id])
  end

  def down do
    drop_if_exists index(:audit_logs, [:org_id, :request_id])
    drop_if_exists index(:audit_logs, [:org_id, :result, :created_at])
    drop_if_exists index(:audit_logs, [:org_id, :action, :created_at])
    drop_if_exists index(:audit_logs, [:org_id, :resource_type, :resource_id, :created_at])
    drop_if_exists index(:audit_logs, [:org_id, :actor_user_id, :created_at])

    alter table(:audit_logs) do
      modify :metadata, :map, null: true
      remove :metadata_size_bytes
      remove :redacted_diff
      remove :request_id
      remove :reason_class
      remove :result
      remove :resource_label
      remove :resource_id
      remove :resource_type
      remove :impersonator_user_id
      remove :actor_label
      remove :actor_type
    end

    drop table(:observability_events)
    drop table(:check_results)
    drop table(:operation_runs)
  end

  defp legacy_audit_backfill_sql do
    """
    WITH legacy_audit AS (
      SELECT
        id,
        target,
        CASE
          WHEN position(':' in target) > 0 THEN COALESCE(NULLIF(split_part(target, ':', 1), ''), 'legacy')
          ELSE COALESCE(NULLIF(target, ''), 'legacy')
        END AS parsed_resource_type,
        CASE
          WHEN position(':' in target) > 0 THEN NULLIF(substring(target from position(':' in target) + 1), '')
          ELSE NULL
        END AS parsed_resource_id,
        COALESCE(metadata, '{}'::jsonb) AS existing_metadata
      FROM audit_logs
      WHERE target IS NOT NULL AND target <> ''
    ),
    prepared AS (
      SELECT
        id,
        target,
        parsed_resource_type,
        parsed_resource_id,
        CASE
          WHEN existing_metadata ? 'legacy_target' THEN existing_metadata
          ELSE jsonb_set(existing_metadata, '{legacy_target}', to_jsonb(target), true)
        END AS backfilled_metadata
      FROM legacy_audit
    )
    UPDATE audit_logs AS a
    SET
      resource_type = COALESCE(NULLIF(a.resource_type, 'legacy'), p.parsed_resource_type, 'legacy'),
      resource_id = COALESCE(NULLIF(a.resource_id, ''), p.parsed_resource_id),
      resource_label = COALESCE(NULLIF(a.resource_label, ''), p.target),
      metadata = p.backfilled_metadata,
      metadata_size_bytes = octet_length(p.backfilled_metadata::text)
    FROM prepared AS p
    WHERE a.id = p.id
      AND (
        a.resource_type IS NULL OR a.resource_type = 'legacy' OR
        (p.parsed_resource_id IS NOT NULL AND (a.resource_id IS NULL OR a.resource_id = '')) OR
        a.resource_label IS NULL OR a.resource_label = '' OR
        a.metadata IS NULL OR NOT (COALESCE(a.metadata, '{}'::jsonb) ? 'legacy_target') OR
        a.metadata_size_bytes IS NULL OR a.metadata_size_bytes = 0
      )
    """
  end
end
