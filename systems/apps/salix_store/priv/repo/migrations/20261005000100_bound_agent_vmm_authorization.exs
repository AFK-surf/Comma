defmodule SalixStore.Repo.Migrations.BoundAgentVMMAuthorization do
  use Ecto.Migration

  def up do
    alter table(:agent_vmm_registrations) do
      add(:authorization_expires_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE agent_vmm_registrations r
    SET authorization_expires_at = GREATEST(now() + interval '20 minutes', COALESCE(
      (SELECT o.received_at FROM agent_vmm_registration_observations o WHERE o.registration_id = r.id),
      r.created_at
    ) + interval '7 days')
    """)

    alter table(:agent_vmm_registrations) do
      modify(:authorization_expires_at, :utc_datetime_usec,
        null: false,
        default: fragment("now() + interval '7 days'")
      )
    end

    create(
      index(:agent_vmm_registrations, [:authorization_expires_at, :id],
        where: "status <> 'revoked'",
        name: :agent_vmm_authorization_expiry
      )
    )
  end

  def down do
    drop(
      index(:agent_vmm_registrations, [:authorization_expires_at, :id],
        name: :agent_vmm_authorization_expiry
      )
    )

    alter table(:agent_vmm_registrations) do
      remove(:authorization_expires_at)
    end
  end
end
