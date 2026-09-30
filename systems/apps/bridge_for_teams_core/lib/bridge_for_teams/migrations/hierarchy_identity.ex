defmodule BridgeForTeams.Migrations.HierarchyIdentity do
  @moduledoc """
  Reads the durable BFT-side tenant/group/agent migration map.

  The Ecto migration writes this record in the same transaction as the BFT
  identity cutover. Comma release passes it to the Salix S3 migration.
  """

  alias SalixStore.HierarchyIdMigration

  @name "hierarchy_v1"

  def name, do: @name

  def read do
    Application.load(:bridge_for_teams_core)
    repos = Application.fetch_env!(:bridge_for_teams_core, :ecto_repos)

    Enum.reduce_while(repos, {:ok, HierarchyIdMigration.empty()}, fn repo, {:ok, acc} ->
      case Ecto.Migrator.with_repo(repo, &read/1) do
        {:ok, {:ok, identity}, _started} ->
          case HierarchyIdMigration.merge(acc, identity) do
            {:ok, merged} -> {:cont, {:ok, merged}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, {:error, reason}, _started} ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def read(repo) do
    case repo.query(
           "SELECT payload FROM salix_identity_migration_maps WHERE name = $1",
           [@name]
         ) do
      {:ok, %{rows: [[payload]]}} -> HierarchyIdMigration.normalize(payload)
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
