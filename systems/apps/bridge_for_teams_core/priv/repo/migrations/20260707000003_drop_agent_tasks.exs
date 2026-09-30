defmodule BridgeForTeams.Repo.Migrations.DropAgentTasks do
  use Ecto.Migration

  def up do
    drop_if_exists(table(:agent_tasks))
  end

  def down do
    :ok
  end
end
