defmodule Comma.Repo.Migrations.AddCommaAdminControlPlane do
  use Ecto.Migration

  def change do
    create table(:comma_admin_access_overrides, primary_key: false) do
      add(
        :user_id,
        references(:comma_users, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:decision, :text, null: false)
      add(:actor_type, :text, null: false)
      add(:actor_user_id, :string)
      add(:reason, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:comma_admin_access_overrides, :comma_admin_access_override_decision_valid,
        check: "decision IN ('allow', 'deny')"
      )
    )

    create(
      constraint(:comma_admin_access_overrides, :comma_admin_access_override_actor_valid,
        check: """
        (actor_type = 'ops' AND actor_user_id IS NULL) OR
        (actor_type = 'comma_user' AND actor_user_id IS NOT NULL)
        """
      )
    )

    create(
      constraint(:comma_admin_access_overrides, :comma_admin_access_override_reason_valid,
        check: "char_length(reason) BETWEEN 3 AND 500"
      )
    )

    create table(:comma_admin_audit_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:actor_key, :text, null: false)
      add(:actor_type, :text, null: false)
      add(:actor_user_id, :string)
      add(:action, :text, null: false)
      add(:target_type, :text, null: false)
      add(:target_id, :text, null: false)
      add(:reason, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:request_fingerprint, :binary, null: false)
      add(:outcome, :text, null: false)
      add(:error_code, :text)
      add(:evidence, :map, null: false, default: %{})
      add(:lease_expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :comma_admin_audit_events,
        [:actor_key, :action, :idempotency_key],
        name: :comma_admin_audit_events_actor_action_idempotency_unique
      )
    )

    create(
      index(
        :comma_admin_audit_events,
        [:target_type, :target_id, :inserted_at],
        name: :comma_admin_audit_events_target_created_at_index
      )
    )

    create(
      index(
        :comma_admin_audit_events,
        [:inserted_at, :id],
        name: :comma_admin_audit_events_inserted_at_id_index
      )
    )

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_actor_valid,
        check: """
        (actor_type = 'ops' AND actor_user_id IS NULL AND actor_key = 'ops') OR
        (actor_type = 'comma_user' AND actor_user_id IS NOT NULL AND actor_key = actor_user_id)
        """
      )
    )

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid,
        check: """
        action IN (
          'create_user',
          'update_user',
          'set_admin_access',
          'create_support_session',
          'bootstrap_workspace',
          'revoke_user_session',
          'revoke_all_user_sessions',
          'create_redeem_code',
          'disable_redeem_code',
          'apply_redeem_code'
        )
        """
      )
    )

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_outcome_valid,
        check: """
        outcome IN ('started', 'succeeded', 'failed', 'rejected') AND
        (
          (outcome = 'started' AND lease_expires_at IS NOT NULL) OR
          (outcome <> 'started' AND lease_expires_at IS NULL)
        )
        """
      )
    )

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_reason_valid,
        check: "char_length(reason) BETWEEN 3 AND 500"
      )
    )

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_idempotency_key_valid,
        check: "char_length(idempotency_key) BETWEEN 8 AND 200"
      )
    )

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_request_fingerprint_valid,
        check: "octet_length(request_fingerprint) = 32"
      )
    )
  end
end
