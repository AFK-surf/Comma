defmodule SalixStore.Repo.Migrations.DifficultyRouteTables do
  @moduledoc "Convert each Group's retired difficulty table to a route table."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixWeb.Migrations.DifficultyRouteTables.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Difficulty route table migration failed: #{inspect(reason)}"
    end
  end
end
