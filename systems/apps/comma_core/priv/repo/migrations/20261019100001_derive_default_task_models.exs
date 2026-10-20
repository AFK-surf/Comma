defmodule Comma.Repo.Migrations.DeriveDefaultTaskModels do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Gives each Workspace whose Task Worker has its own model that model as the
  # Workspace's default Task model (`Comma.Migrations.DefaultTaskModels`).
  # Comma's rows are read through the migrator's repo; the Group records are
  # written through Salix's store. A pass run again changes nothing.
  def up do
    case Comma.Migrations.DefaultTaskModels.run(repo()) do
      {:ok, _counts} -> :ok
      {:error, reason} -> raise "Default Task model migration failed: #{inspect(reason)}"
    end
  end

  def down, do: :ok
end
