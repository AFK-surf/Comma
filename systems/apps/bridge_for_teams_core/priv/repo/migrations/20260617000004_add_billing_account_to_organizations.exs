defmodule BridgeForTeams.Repo.Migrations.AddBillingAccountToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add_if_not_exists :billing_account_id, :string
    end

    create_if_not_exists unique_index(:organizations, [:billing_account_id])
  end
end
