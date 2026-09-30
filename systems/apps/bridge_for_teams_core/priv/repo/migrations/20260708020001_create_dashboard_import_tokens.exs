defmodule BridgeForTeams.Repo.Migrations.CreateDashboardImportTokens do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  def change do
    create table(:dashboard_import_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:token_hash, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(@ts)
    end

    create(unique_index(:dashboard_import_tokens, [:token_hash]))

    # Single active token per (user, project): the mint path revokes prior
    # active rows, this index makes finding them cheap.
    create(index(:dashboard_import_tokens, [:user_id, :project_id, :revoked_at]))
  end
end
