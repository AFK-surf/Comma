defmodule Comma.Repo.Migrations.AddCommaTelegramDMLinks do
  use Ecto.Migration

  def change do
    create table(:comma_telegram_dm_links, primary_key: false) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:owner_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:telegram_user_id, :string, null: false)
      add(:telegram_username, :string)
      add(:connect_id, :string, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_telegram_dm_links, [:telegram_user_id]))
    create(index(:comma_telegram_dm_links, [:owner_user_id]))

    create table(:comma_telegram_dm_claim_codes, primary_key: false) do
      add(:code, :string, null: false, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:owner_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:comma_telegram_dm_claim_codes, [:workspace_id]))
    create(index(:comma_telegram_dm_claim_codes, [:expires_at]))
  end
end
