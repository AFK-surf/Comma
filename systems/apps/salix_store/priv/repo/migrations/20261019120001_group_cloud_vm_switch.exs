defmodule SalixStore.Repo.Migrations.GroupCloudVMSwitch do
  @moduledoc "Move Cloud VM access from Agents to their Group's switch, during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.GroupCloudVMSwitch.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Group Cloud VM switch migration failed: #{inspect(reason)}"
    end
  end
end
