defmodule BridgeForTeams.Repo.Migrations.CreateContextLifecycleAndSlackHistoryImportRuns do
  use Ecto.Migration

  def up do
    create table(:context_bundles, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:organizations, type: :uuid, on_delete: :restrict), null: false)
      add(:project_id, references(:projects, type: :uuid, on_delete: :restrict))
      add(:source_type, :text, null: false)
      add(:source_ref, :text, null: false)
      add(:classification, :text, null: false)
      add(:policy_ref, :text, null: false)
      add(:lifecycle_state, :text, null: false, default: "registered")
      add(:subject_index_state, :text, null: false, default: "pending")
      add(:lifecycle_revision, :bigint, null: false, default: 0)
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(:context_bundles, :context_bundles_nonempty_identity,
        check: """
        btrim(source_type) <> '' AND length(source_type) <= 64 AND
        btrim(source_ref) <> '' AND length(source_ref) <= 1024 AND
        btrim(classification) <> '' AND length(classification) <= 64 AND
        btrim(policy_ref) <> '' AND length(policy_ref) <= 256
        """
      )
    )

    create(
      constraint(:context_bundles, :context_bundles_lifecycle_state,
        check: """
        lifecycle_state IN (
          'registered', 'erasure_pending', 'deletion_pending', 'deleted', 'failed'
        )
        """
      )
    )

    create(
      constraint(:context_bundles, :context_bundles_subject_index_state,
        check: "subject_index_state IN ('pending', 'complete', 'failed')"
      )
    )

    create(
      constraint(:context_bundles, :context_bundles_lifecycle_revision,
        check: "lifecycle_revision >= 0"
      )
    )

    create(
      unique_index(:context_bundles, [:org_id, :source_type, :source_ref],
        name: :context_bundles_source_identity_idx
      )
    )

    create(index(:context_bundles, [:project_id, :lifecycle_state]))

    create table(:context_bundle_subjects, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :bundle_id,
        references(:context_bundles, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:ref, :text, null: false)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      constraint(:context_bundle_subjects, :context_bundle_subjects_nonempty_identity,
        check: """
        btrim(kind) <> '' AND length(kind) <= 64 AND
        btrim(ref) <> '' AND length(ref) <= 512
        """
      )
    )

    create(
      unique_index(:context_bundle_subjects, [:bundle_id, :kind, :ref],
        name: :context_bundle_subjects_identity_idx
      )
    )

    create(index(:context_bundle_subjects, [:kind, :ref]))

    create table(:slack_history_import_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:organizations, type: :uuid, on_delete: :restrict), null: false)
      add(:project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false)

      add(
        :requested_by_user_id,
        references(:users, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:client_request_id, :uuid, null: false)
      add(:source_workspace_id, :text, null: false)
      add(:connect_id, :text, null: false)
      add(:connect_generation, :text, null: false)

      add(
        :replaces_run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :restrict)
      )

      add(:range_start, :utc_datetime_usec, null: false)
      add(:range_end, :utc_datetime_usec, null: false)
      add(:state, :text, null: false, default: "created")
      add(:generation, :bigint, null: false, default: 0)
      add(:resume_phase, :text)
      add(:paused_reason, :text)
      add(:retry_not_before, :utc_datetime_usec)
      add(:snapshot_id, :uuid)
      add(:derivation_id, :uuid)
      add(:review_revision_id, :uuid)
      add(:publication_id, :uuid)
      add(:failure_reason, :text)

      add(
        :context_bundle_id,
        references(:context_bundles, type: :uuid, on_delete: :restrict)
      )

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_nonempty_identity,
        check: """
        btrim(source_workspace_id) <> '' AND length(source_workspace_id) <= 256 AND
        btrim(connect_id) <> '' AND length(connect_id) <= 256 AND
        btrim(connect_generation) <> '' AND length(connect_generation) <= 256
        """
      )
    )

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_range,
        check: "range_start < range_end"
      )
    )

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_state,
        check: """
        state IN (
          'created', 'acquiring', 'paused', 'stale_source', 'acquired', 'deriving',
          'preview_ready', 'committed', 'canceled', 'rolled_back', 'failed_terminal'
        )
        """
      )
    )

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_generation,
        check: "generation >= 0"
      )
    )

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_replacement,
        check: "replaces_run_id IS NULL OR replaces_run_id <> id"
      )
    )

    create(
      unique_index(
        :slack_history_import_runs,
        [:org_id, :requested_by_user_id, :client_request_id],
        name: :slack_history_import_runs_client_request_idx
      )
    )

    create(index(:slack_history_import_runs, [:project_id, :state, :created_at]))

    create(
      index(:slack_history_import_runs, [:project_id, :created_at, :id],
        name: :slack_history_import_runs_project_history_idx
      )
    )

    create(index(:slack_history_import_runs, [:replaces_run_id]))

    create table(:slack_history_import_channels, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:channel_id, :text, null: false)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      constraint(:slack_history_import_channels, :slack_history_import_channels_identity,
        check: "btrim(channel_id) <> '' AND length(channel_id) <= 256"
      )
    )

    create(
      unique_index(:slack_history_import_channels, [:run_id, :channel_id],
        name: :slack_history_import_channels_identity_idx
      )
    )

    execute("""
    CREATE FUNCTION reject_context_bundle_identity_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF ROW(
        OLD.org_id,
        OLD.project_id,
        OLD.source_type,
        OLD.source_ref,
        OLD.classification,
        OLD.policy_ref
      ) IS DISTINCT FROM ROW(
        NEW.org_id,
        NEW.project_id,
        NEW.source_type,
        NEW.source_ref,
        NEW.classification,
        NEW.policy_ref
      ) THEN
        RAISE EXCEPTION 'context bundle source identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER context_bundles_immutable_identity
    BEFORE UPDATE ON context_bundles
    FOR EACH ROW EXECUTE FUNCTION reject_context_bundle_identity_mutation()
    """)

    execute("""
    CREATE FUNCTION reject_slack_history_import_identity_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF ROW(
        OLD.org_id,
        OLD.project_id,
        OLD.requested_by_user_id,
        OLD.client_request_id,
        OLD.source_workspace_id,
        OLD.connect_id,
        OLD.connect_generation,
        OLD.replaces_run_id,
        OLD.range_start,
        OLD.range_end
      ) IS DISTINCT FROM ROW(
        NEW.org_id,
        NEW.project_id,
        NEW.requested_by_user_id,
        NEW.client_request_id,
        NEW.source_workspace_id,
        NEW.connect_id,
        NEW.connect_generation,
        NEW.replaces_run_id,
        NEW.range_start,
        NEW.range_end
      ) THEN
        RAISE EXCEPTION 'slack history import source identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER slack_history_import_runs_immutable_identity
    BEFORE UPDATE ON slack_history_import_runs
    FOR EACH ROW EXECUTE FUNCTION reject_slack_history_import_identity_mutation()
    """)
  end

  def down do
    drop(table(:slack_history_import_channels))
    drop(table(:slack_history_import_runs))
    drop(table(:context_bundle_subjects))
    drop(table(:context_bundles))
    execute("DROP FUNCTION reject_slack_history_import_identity_mutation()")
    execute("DROP FUNCTION reject_context_bundle_identity_mutation()")
  end
end
