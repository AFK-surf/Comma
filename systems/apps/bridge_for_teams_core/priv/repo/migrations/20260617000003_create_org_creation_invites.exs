defmodule BridgeForTeams.Repo.Migrations.CreateOrgCreationInvites do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create table(:org_creation_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :code_hash, :string, null: false
      add :expires_at, :utc_datetime_usec
      add :used_at, :utc_datetime_usec

      add :used_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :used_org_id, references(:organizations, type: :binary_id, on_delete: :nilify_all)

      add :note, :string

      timestamps(@ts)
    end

    create unique_index(:org_creation_invites, [:code_hash])
    create index(:org_creation_invites, [:expires_at])
    create index(:org_creation_invites, [:used_at])
  end
end
