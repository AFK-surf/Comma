defmodule BridgeForTeams.Repo.Migrations.BindWorkerSlackConnectionsToTasks do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Each live Agent Swarm's Slack connections that deliver to a Worker bind to
  # Tasks instead, which run the Worker's model or the default Task model
  # (`BridgeForTeams.Migrations.SlackTaskBindings`). Projects are read through
  # the migrator's repo; the connection records are written through Salix's
  # store. A pass run again changes nothing.
  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case BridgeForTeams.Migrations.SlackTaskBindings.run(
           repo(),
           &SalixAgent.Migrations.SlackTaskBindings.bind/2
         ) do
      {:ok, _counts} -> :ok
      {:error, reason} -> raise "Slack Task binding migration failed: #{inspect(reason)}"
    end
  end

  def down, do: :ok
end
