defmodule SalixStore.Repo.Migrations.RetireExternalRuntimeConfig do
  @moduledoc "Remove the External Runtime configuration from Agent records, during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.RetireExternalRuntimeConfig.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "External runtime config migration failed: #{inspect(reason)}"
    end
  end
end
