defmodule BridgeForTeams.Repo.Migrations.CreateAccountRecoveryLinks do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create table(:account_recovery_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      add :note, :string

      timestamps(@ts)
    end

    create unique_index(:account_recovery_links, [:token_hash])
    create index(:account_recovery_links, [:user_id])
    create index(:account_recovery_links, [:expires_at])
    create index(:account_recovery_links, [:used_at])
  end
end
