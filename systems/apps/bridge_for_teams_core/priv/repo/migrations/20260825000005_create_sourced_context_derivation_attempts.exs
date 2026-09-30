defmodule BridgeForTeams.Repo.Migrations.CreateSourcedContextDerivationAttempts do
  use Ecto.Migration

  def up do
    create table(:sourced_context_derivation_attempts, primary_key: false) do
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
        :parent_derivation_id,
        references(:sourced_context_derivations, type: :uuid, on_delete: :restrict)
      )

      add(
        :requested_by_user_id,
        references(:users, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:client_request_id, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:model_provider, :text, null: false)
      add(:model_id, :text, null: false)
      add(:model_revision, :text, null: false)
      add(:prompt_template_id, :text, null: false)
      add(:prompt_revision, :text, null: false)
      add(:policy_revision, :text, null: false)
      add(:schema_revision, :text, null: false)
      add(:processor_config, :map, null: false, default: %{})
      add(:processor_config_sha256, :string, size: 64, null: false)
      add(:retry_count, :bigint, null: false, default: 0)
      add(:retry_not_before, :utc_datetime_usec)
      add(:last_error_class, :text)
      add(:lease_generation, :bigint, null: false, default: 0)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(:sourced_context_derivation_attempts, [:run_id, :client_request_id],
        name: :sourced_context_derivation_attempts_request_idx
      )
    )

    create(index(:sourced_context_derivation_attempts, [:run_id, :status, :created_at]))

    create(
      constraint(
        :sourced_context_derivation_attempts,
        :sourced_context_derivation_attempts_identity,
        check: """
        length(btrim(client_request_id)) > 0 AND length(client_request_id) <= 256 AND
        length(btrim(model_provider)) > 0 AND length(btrim(model_id)) > 0 AND
        length(btrim(model_revision)) > 0 AND length(btrim(prompt_template_id)) > 0 AND
        length(btrim(prompt_revision)) > 0 AND length(btrim(policy_revision)) > 0 AND
        length(btrim(schema_revision)) > 0 AND
        processor_config_sha256 ~ '^[0-9a-f]{64}$'
        """
      )
    )

    create(
      constraint(
        :sourced_context_derivation_attempts,
        :sourced_context_derivation_attempts_status,
        check: "status IN ('pending', 'processing', 'paused', 'completed', 'failed_terminal')"
      )
    )

    create(
      constraint(
        :sourced_context_derivation_attempts,
        :sourced_context_derivation_attempts_retry_count,
        check: "retry_count >= 0 AND lease_generation >= 0"
      )
    )

    create(
      constraint(
        :sourced_context_derivation_attempts,
        :sourced_context_derivation_attempts_lease,
        check: """
        (status = 'processing' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL) OR
        (status <> 'processing' AND lease_owner IS NULL AND lease_expires_at IS NULL)
        """
      )
    )
  end

  def down do
    drop(table(:sourced_context_derivation_attempts))
  end
end
