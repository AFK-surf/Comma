defmodule BridgeForTeams.Repo.Migrations.CreateSourcedContextImportStorage do
  use Ecto.Migration

  def up do
    alter table(:slack_history_import_runs) do
      add(:policy_revision, :text)
      add(:coverage_profile, :text)
      add(:audience_scope, :text)
    end

    alter table(:slack_history_import_channels) do
      add(:channel_name, :text)
      add(:visibility, :text)
      add(:authority_revision, :text)
    end

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_product_contract,
        check: """
        (policy_revision IS NULL OR policy_revision = 'context-lifecycle:v1') AND
        (coverage_profile IS NULL OR coverage_profile = 'slack-root-bounded:v1') AND
        (audience_scope IS NULL OR audience_scope = 'project-public-channels:v1')
        """
      )
    )

    create table(:sourced_context_snapshots, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:normalization_revision, :text, null: false)
      add(:coverage_profile, :text, null: false)
      add(:manifest_sha256, :string, size: 64, null: false)
      add(:object_count, :bigint, null: false)
      add(:byte_count, :bigint, null: false)
      add(:coverage, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finalized_at, :utc_datetime_usec, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:sourced_context_snapshots, [:run_id]))

    create table(:slack_history_stream_checkpoints, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:channel_id, :text, null: false)
      add(:stream_kind, :text, null: false)
      add(:root_ts, :text, null: false, default: "")
      add(:next_page_ordinal, :bigint, null: false, default: 0)
      add(:timestamp_boundary, :text)
      add(:provider_cursor_ciphertext, :text)
      add(:complete, :boolean, null: false, default: false)
      add(:object_count, :bigint, null: false, default: 0)
      add(:byte_count, :bigint, null: false, default: 0)
      add(:retry_count, :bigint, null: false, default: 0)
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(
        :slack_history_stream_checkpoints,
        [:run_id, :channel_id, :stream_kind, :root_ts],
        name: :slack_history_stream_checkpoints_identity_idx
      )
    )

    create(index(:slack_history_stream_checkpoints, [:run_id, :complete]))

    create table(:slack_history_page_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:channel_id, :text, null: false)
      add(:stream_kind, :text, null: false)
      add(:root_ts, :text, null: false, default: "")
      add(:page_ordinal, :bigint, null: false)
      add(:receipt_key, :text, null: false)
      add(:response_sha256, :string, size: 64, null: false)
      add(:accepted_connect_generation, :text, null: false)
      add(:object_count, :bigint, null: false)
      add(:byte_count, :bigint, null: false)
      add(:timestamp_boundary, :text)
      add(:next_cursor_ciphertext, :text)
      add(:stream_complete, :boolean, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:slack_history_page_receipts, [:run_id, :receipt_key],
        name: :slack_history_page_receipts_identity_idx
      )
    )

    create(index(:slack_history_page_receipts, [:run_id, :channel_id, :page_ordinal]))

    create table(:sourced_context_objects, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, :text, null: false)
      add(:channel_id, :text, null: false)
      add(:message_ts, :text, null: false)
      add(:thread_ts, :text)
      add(:observable_version, :text, null: false)
      add(:actor_ref_sha256, :string, size: 64)
      add(:payload_ciphertext, :text, null: false)
      add(:payload_sha256, :string, size: 64, null: false)
      add(:byte_count, :bigint, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :sourced_context_objects,
        [:run_id, :workspace_id, :channel_id, :message_ts, :observable_version],
        name: :sourced_context_objects_source_identity_idx
      )
    )

    create(index(:sourced_context_objects, [:run_id, :message_ts]))

    create table(:sourced_context_derivations, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :snapshot_id,
        references(:sourced_context_snapshots, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :parent_derivation_id,
        references(:sourced_context_derivations, type: :uuid, on_delete: :restrict)
      )

      add(:model_provider, :text, null: false)
      add(:model_id, :text, null: false)
      add(:model_revision, :text, null: false)
      add(:prompt_template_id, :text, null: false)
      add(:prompt_revision, :text, null: false)
      add(:policy_revision, :text, null: false)
      add(:schema_revision, :text, null: false)
      add(:processor_config, :map, null: false, default: %{})
      add(:output_sha256, :string, size: 64, null: false)
      add(:artifact_count, :bigint, null: false)
      add(:warnings, :map, null: false, default: %{})
      add(:created_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :sourced_context_derivations,
        [
          :snapshot_id,
          :model_provider,
          :model_id,
          :model_revision,
          :prompt_template_id,
          :prompt_revision,
          :policy_revision,
          :schema_revision
        ],
        name: :sourced_context_derivations_evidence_idx
      )
    )

    create table(:sourced_context_artifacts, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :derivation_id,
        references(:sourced_context_derivations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:stable_key, :text, null: false)
      add(:payload_ciphertext, :text, null: false)
      add(:payload_sha256, :string, size: 64, null: false)
      add(:confidence_millis, :integer, null: false)
      add(:mapped_user_id, references(:users, type: :uuid, on_delete: :restrict))
      add(:mapped_project_id, references(:projects, type: :uuid, on_delete: :restrict))
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:sourced_context_artifacts, [:derivation_id, :kind, :stable_key],
        name: :sourced_context_artifacts_identity_idx
      )
    )

    create table(:sourced_context_artifact_sources, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :artifact_id,
        references(:sourced_context_artifacts, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :source_object_id,
        references(:sourced_context_objects, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:sourced_context_artifact_sources, [:artifact_id, :source_object_id],
        name: :sourced_context_artifact_sources_identity_idx
      )
    )

    create table(:sourced_context_review_revisions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :snapshot_id,
        references(:sourced_context_snapshots, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :derivation_id,
        references(:sourced_context_derivations, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :parent_revision_id,
        references(:sourced_context_review_revisions, type: :uuid, on_delete: :restrict)
      )

      add(:revision, :bigint, null: false)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:selection_sha256, :string, size: 64, null: false)
      add(:selected_count, :bigint, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:sourced_context_review_revisions, [:run_id, :revision],
        name: :sourced_context_review_revisions_number_idx
      )
    )

    create table(:sourced_context_review_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :review_revision_id,
        references(:sourced_context_review_revisions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :artifact_id,
        references(:sourced_context_artifacts, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:kind, :text, null: false)
      add(:payload_ciphertext, :text, null: false)
      add(:payload_sha256, :string, size: 64, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:sourced_context_review_items, [:review_revision_id, :artifact_id],
        name: :sourced_context_review_items_identity_idx
      )
    )

    create table(:sourced_context_publications, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :bundle_id,
        references(:context_bundles, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :review_revision_id,
        references(:sourced_context_review_revisions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:status, :text, null: false)
      add(:audience_scope, :text, null: false)

      add(:committed_by_user_id, references(:users, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:commit_command_id, :text, null: false)
      add(:activated_at, :utc_datetime_usec, null: false)
      add(:deactivated_at, :utc_datetime_usec)
      add(:deactivation_reason, :text)
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(unique_index(:sourced_context_publications, [:run_id]))
    create(index(:sourced_context_publications, [:status, :run_id]))

    create(
      constraint(:sourced_context_publications, :sourced_context_publications_status,
        check:
          "(status = 'active' AND deactivated_at IS NULL) OR " <>
            "(status = 'inactive' AND deactivated_at IS NOT NULL)"
      )
    )

    execute("""
    CREATE FUNCTION reject_sourced_context_immutable_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'sourced context evidence is immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    for table <- [
          "sourced_context_snapshots",
          "slack_history_page_receipts",
          "sourced_context_objects",
          "sourced_context_derivations",
          "sourced_context_artifacts",
          "sourced_context_artifact_sources",
          "sourced_context_review_revisions",
          "sourced_context_review_items"
        ] do
      execute("""
      CREATE TRIGGER #{table}_immutable
      BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION reject_sourced_context_immutable_update()
      """)
    end
  end

  def down do
    drop(constraint(:slack_history_import_runs, :slack_history_import_runs_product_contract))

    drop(table(:sourced_context_publications))
    drop(table(:sourced_context_review_items))
    drop(table(:sourced_context_review_revisions))
    drop(table(:sourced_context_artifact_sources))
    drop(table(:sourced_context_artifacts))
    drop(table(:sourced_context_derivations))
    drop(table(:sourced_context_objects))
    drop(table(:slack_history_page_receipts))
    drop(table(:slack_history_stream_checkpoints))
    drop(table(:sourced_context_snapshots))
    execute("DROP FUNCTION IF EXISTS reject_sourced_context_immutable_update()")

    alter table(:slack_history_import_channels) do
      remove(:channel_name)
      remove(:visibility)
      remove(:authority_revision)
    end

    alter table(:slack_history_import_runs) do
      remove(:policy_revision)
      remove(:coverage_profile)
      remove(:audience_scope)
    end
  end
end
