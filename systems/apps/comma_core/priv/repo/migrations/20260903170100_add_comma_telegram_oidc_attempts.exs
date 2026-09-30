defmodule Comma.Repo.Migrations.AddCommaTelegramOIDCAttempts do
  use Ecto.Migration

  def change do
    create table(:comma_telegram_oidc_attempts, primary_key: false) do
      add(:state_hash, :string, null: false, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:owner_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:nonce, :string, null: false)
      add(:pkce_verifier, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:comma_telegram_oidc_attempts, [:workspace_id]))
    create(index(:comma_telegram_oidc_attempts, [:expires_at]))
  end
end
