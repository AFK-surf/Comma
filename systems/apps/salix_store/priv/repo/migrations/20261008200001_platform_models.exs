defmodule SalixStore.Repo.Migrations.PlatformModels do
  @moduledoc "Move the platform's models off global templates during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.PlatformModels.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Platform models migration failed: #{inspect(reason)}"
    end
  end
end
