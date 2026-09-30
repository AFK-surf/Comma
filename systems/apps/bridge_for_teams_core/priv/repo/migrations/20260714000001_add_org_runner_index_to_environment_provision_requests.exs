defmodule BridgeForTeams.Repo.Migrations.AddOrgRunnerIndexToEnvironmentProvisionRequests do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists(
      index(:environment_provision_requests, [:org_id, :provisioner_id, :id],
        name: :environment_provision_requests_org_runner_id_idx,
        include: [:status],
        concurrently: true,
        where: "provisioner_id IS NOT NULL"
      )
    )
  end
end
