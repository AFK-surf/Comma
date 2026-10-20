defmodule SalixStore.Repo.Migrations.StationBoundWorkers do
  @moduledoc "Bind every External Runtime Worker to a station, during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.StationBoundWorkers.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Station-bound Workers migration failed: #{inspect(reason)}"
    end
  end
end
