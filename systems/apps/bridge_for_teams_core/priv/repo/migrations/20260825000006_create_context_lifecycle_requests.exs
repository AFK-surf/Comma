defmodule BridgeForTeams.Repo.Migrations.CreateContextLifecycleRequests do
  use Ecto.Migration

  def up do
    create table(:context_lifecycle_requests, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :bundle_id,
        references(:context_bundles, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:requested_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:command_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:reason, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:base_revision, :bigint, null: false)
      add(:retry_count, :bigint, null: false, default: 0)
      add(:retry_not_before, :utc_datetime_usec)
      add(:last_error_class, :text)
      add(:lease_generation, :bigint, null: false, default: 0)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:cancel_command_id, :text)
      add(:canceled_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:cancel_reason, :text)
      add(:canceled_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(:context_lifecycle_requests, [:bundle_id, :command_id],
        name: :context_lifecycle_requests_command_idx
      )
    )

    create(
      unique_index(:context_lifecycle_requests, [:bundle_id, :cancel_command_id],
        where: "cancel_command_id IS NOT NULL",
        name: :context_lifecycle_requests_cancel_command_idx
      )
    )

    create(
      unique_index(:context_lifecycle_requests, [:bundle_id],
        where: "state IN ('pending', 'processing', 'retry_wait')",
        name: :context_lifecycle_requests_one_active_idx
      )
    )

    create(
      index(:context_lifecycle_requests, [:state, :retry_not_before, :created_at],
        name: :context_lifecycle_requests_retry_idx
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_identity,
        check: """
        command_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' AND
        reason IN (
          'user_request', 'retention_expired', 'organization_request',
          'legal_requirement', 'administrative_cleanup'
        ) AND
        (cancel_command_id IS NULL OR
          cancel_command_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') AND
        (cancel_reason IS NULL OR
          cancel_reason IN ('request_submitted_in_error', 'legal_hold', 'administrative_override'))
        """
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_kind,
        check: "kind IN ('deletion', 'erasure')"
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_state,
        check: """
        state IN (
          'pending', 'processing', 'retry_wait', 'completed', 'canceled', 'failed_terminal'
        )
        """
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_counters,
        check: "base_revision >= 0 AND retry_count >= 0 AND lease_generation >= 0"
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_lease,
        check: """
        (state = 'processing' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL) OR
        (state <> 'processing' AND lease_owner IS NULL AND lease_expires_at IS NULL)
        """
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_completion,
        check: """
        (state = 'completed' AND completed_at IS NOT NULL) OR
        (state <> 'completed' AND completed_at IS NULL)
        """
      )
    )

    create(
      constraint(:context_lifecycle_requests, :context_lifecycle_requests_cancellation,
        check: """
        (state = 'canceled' AND cancel_command_id IS NOT NULL AND
          cancel_reason IS NOT NULL AND canceled_at IS NOT NULL) OR
        (state <> 'canceled' AND cancel_command_id IS NULL AND
          canceled_by_user_id IS NULL AND cancel_reason IS NULL AND canceled_at IS NULL)
        """
      )
    )

    create table(:context_lifecycle_evidence, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :request_id,
        references(:context_lifecycle_requests, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :bundle_id,
        references(:context_bundles, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:source_type, :text, null: false)
      add(:purger, :text, null: false)
      add(:counts, :map, null: false, default: %{})
      add(:counts_sha256, :string, size: 64, null: false)
      add(:completed_at, :utc_datetime_usec, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:context_lifecycle_evidence, [:request_id]))
    create(index(:context_lifecycle_evidence, [:bundle_id, :completed_at]))

    create(
      constraint(:context_lifecycle_evidence, :context_lifecycle_evidence_identity,
        check: """
        length(btrim(source_type)) > 0 AND length(source_type) <= 64 AND
        length(btrim(purger)) > 0 AND length(purger) <= 256 AND
        counts_sha256 ~ '^[0-9a-f]{64}$'
        """
      )
    )
  end

  def down do
    drop(table(:context_lifecycle_evidence))
    drop(table(:context_lifecycle_requests))
  end
end
