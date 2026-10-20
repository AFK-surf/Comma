defmodule SalixStore.Repo.Migrations.AgentModelChoices do
  @moduledoc "Store Agent catalog and runtime choices as model values during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.AgentModelChoices.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Agent model choices migration failed: #{inspect(reason)}"
    end
  end
end
