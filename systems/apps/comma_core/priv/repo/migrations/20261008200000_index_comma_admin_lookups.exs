defmodule Comma.Repo.Migrations.IndexCommaAdminLookups do
  use Ecto.Migration

  # Admin search reads accounts by an email prefix, and the Audit log filters by action or by operator, newest first.
  def change do
    create(
      index(:comma_users, ["normalized_email text_pattern_ops"],
        name: :comma_users_normalized_email_pattern_index
      )
    )

    create(
      index(:comma_admin_audit_events, [:action, :inserted_at, :id],
        name: :comma_admin_audit_events_action_inserted_at_index
      )
    )

    create(
      index(:comma_admin_audit_events, [:actor_user_id, :inserted_at, :id],
        name: :comma_admin_audit_events_actor_inserted_at_index
      )
    )
  end
end
