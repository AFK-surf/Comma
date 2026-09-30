defmodule BridgeForTeams.Repo.Migrations.DropProvisionRequestExecutionBoundary do
  use Ecto.Migration

  # The provision request no longer records an execution boundary. The column
  # stays in place so a runtime that still reads or writes it keeps working;
  # new rows leave it NULL.
  def up do
    alter table(:environment_provision_requests) do
      modify :execution_boundary, :string, null: true, default: nil
    end
  end

  def down do
    execute(
      "UPDATE environment_provision_requests SET execution_boundary = 'connector-direct' WHERE execution_boundary IS NULL"
    )

    alter table(:environment_provision_requests) do
      modify :execution_boundary, :string, null: false, default: "connector-direct"
    end
  end
end
