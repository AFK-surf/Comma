defmodule Comma.Repo.Migrations.AdoptGroupTaskAgents do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Records each Workspace's Task Worker as its Group's Task agent
  # (`Comma.Migrations.GroupTaskAgents`). Comma's rows are read through the
  # migrator's repo; the Group records are written through Salix's store. A
  # pass run again changes nothing.
  def up do
    case Comma.Migrations.GroupTaskAgents.run(repo()) do
      {:ok, _counts} -> :ok
      {:error, reason} -> raise "Group Task agent migration failed: #{inspect(reason)}"
    end
  end

  def down, do: :ok
end
