defmodule BridgeForTeams.Repo.Migrations.AddOrgIdentityToOrgCreationInvites do
  use Ecto.Migration

  def change do
    alter table(:org_creation_invites) do
      add :org_name, :string, null: false
      add :org_slug, :string, null: false
    end

    create index(:org_creation_invites, [:org_slug])
  end
end
