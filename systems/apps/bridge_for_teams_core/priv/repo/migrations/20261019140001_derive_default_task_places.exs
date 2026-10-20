defmodule BridgeForTeams.Repo.Migrations.DeriveDefaultTaskPlaces do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Each live Agent Swarm whose live Workers all run on its Cloud VM gets the
  # Cloud VM as its default place to run Tasks
  # (`BridgeForTeams.Migrations.DefaultTaskPlaces`). Projects are read through
  # the migrator's repo; the Group records are written through Salix's store.
  # A pass run again changes nothing.
  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case BridgeForTeams.Migrations.DefaultTaskPlaces.run(
           repo(),
           &SalixAgent.Migrations.DefaultTaskPlaces.derive/2
         ) do
      {:ok, _counts} -> :ok
      {:error, reason} -> raise "Default place to run Tasks migration failed: #{inspect(reason)}"
    end
  end

  def down, do: :ok
end
