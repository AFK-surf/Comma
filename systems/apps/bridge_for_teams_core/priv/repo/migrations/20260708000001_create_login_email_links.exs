defmodule BridgeForTeams.Repo.Migrations.CreateLoginEmailLinks do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create table(:login_email_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create unique_index(:login_email_links, [:token_hash])
    create index(:login_email_links, [:user_id])
    create index(:login_email_links, [:org_id])
    create index(:login_email_links, [:expires_at])
  end
end
