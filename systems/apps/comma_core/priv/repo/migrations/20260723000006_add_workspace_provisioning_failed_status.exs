defmodule Comma.Repo.Migrations.AddWorkspaceProvisioningFailedStatus do
  use Ecto.Migration

  def up do
    drop(constraint(:comma_workspaces, :comma_workspaces_status_check))

    create(
      constraint(:comma_workspaces, :comma_workspaces_status_check,
        check:
          "status IN ('provisioning', 'provisioning_failed', 'active', 'suspended', 'failed', 'deleted')"
      )
    )
  end

  def down do
    execute("UPDATE comma_workspaces SET status = 'failed' WHERE status = 'provisioning_failed'")

    drop(constraint(:comma_workspaces, :comma_workspaces_status_check))

    create(
      constraint(:comma_workspaces, :comma_workspaces_status_check,
        check: "status IN ('provisioning', 'active', 'suspended', 'failed', 'deleted')"
      )
    )
  end
end
