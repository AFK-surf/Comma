defmodule SalixStore.Repo.Migrations.StationTaskStarts do
  @moduledoc "Keep the invite `start` of station Task Sessions from before it was kept, during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixWeb.Migrations.StationTaskStarts.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Station Task start migration failed: #{inspect(reason)}"
    end
  end
end
