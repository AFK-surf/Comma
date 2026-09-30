defmodule Comma.Repo.Migrations.EnrichCommaAccounts do
  use Ecto.Migration

  def change do
    alter table(:comma_users) do
      modify(:normalized_email, :text, from: :string)
      add(:auth_epoch, :integer, null: false, default: 0)
    end

    create(index(:comma_users, [:inserted_at, :id], name: :comma_users_inserted_at_id_index))

    create(
      constraint(:comma_users, :comma_users_email_normalized,
        check: "normalized_email = lower(btrim(normalized_email))"
      )
    )

    create(constraint(:comma_users, :comma_users_auth_epoch_valid, check: "auth_epoch >= 0"))

    create(
      constraint(:comma_users, :comma_users_public_id_valid,
        check:
          "id ~ '^usr_[A-Za-z0-9_-]+$' OR id ~ '^usr-[A-Za-z0-9_-]+$' OR id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"
      )
    )

    create table(:comma_user_identities, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:user_id, references(:comma_users, type: :string, on_delete: :restrict), null: false)

      add(:provider, :text, null: false)
      add(:issuer, :text, null: false)
      add(:subject, :text, null: false)
      add(:email_snapshot, :text, null: false)
      add(:email_verified, :boolean, null: false)
      add(:hosted_domain, :text)
      add(:last_authenticated_at, :utc_datetime_usec, null: false)
      add(:disabled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(:comma_user_identities, [:provider, :issuer, :subject],
        name: :comma_user_identities_provider_subject_unique
      )
    )

    create(
      unique_index(:comma_user_identities, [:user_id, :provider],
        name: :comma_user_identities_user_provider_unique
      )
    )

    create(
      constraint(:comma_user_identities, :comma_user_identities_provider_valid,
        check: "provider = 'google'"
      )
    )

    create(
      constraint(:comma_user_identities, :comma_user_identities_email_normalized,
        check: "email_snapshot = lower(btrim(email_snapshot))"
      )
    )

    create(
      constraint(:comma_user_identities, :comma_user_identities_hosted_domain_normalized,
        check: "hosted_domain IS NULL OR hosted_domain = lower(btrim(hosted_domain))"
      )
    )
  end
end
