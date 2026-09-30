defmodule SalixStore.Repo.Migrations.AgentCreationDefaults do
  @moduledoc "Preserve tenant-inherited Agent templates during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.AgentCreationDefaults.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Agent creation defaults migration failed: #{inspect(reason)}"
    end
  end
end
