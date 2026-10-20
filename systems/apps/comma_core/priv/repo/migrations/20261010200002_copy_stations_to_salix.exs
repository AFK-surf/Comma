defmodule Comma.Repo.Migrations.CopyStationsToSalix do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Copies the station roster, signing keys and revocations into the tables
  # Salix migration 20261010200001 made (`Comma.Stations.SalixCopy`), so the
  # release manifest runs it after that migration. Comma's tables stay. Comma's
  # rows are read through the migrator's repo; Salix's are written through
  # SalixStore.Repo, which the pass starts when Comma has a row to copy.
  def up do
    {:ok, _} = Comma.Stations.SalixCopy.run(repo())
    :ok
  end

  def down, do: :ok
end
