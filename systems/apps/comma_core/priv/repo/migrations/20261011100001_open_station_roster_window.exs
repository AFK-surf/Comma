defmodule Comma.Repo.Migrations.OpenStationRosterWindow do
  use Ecto.Migration
  @disable_ddl_transaction true

  # The release whose servers read and write the station roster in Salix
  # (`SalixStore.Stations`) and no longer in Comma's tables. An online step,
  # run before its first server starts, while the servers of the release
  # before serve: Salix's rows become Comma's and the window opens
  # (`Comma.Stations.SalixCopy.open_window/1`). During the rollout those
  # servers still write Comma's tables, and this release's servers merge what
  # they wrote before reading (`Comma.Stations.Window`). After the rollout
  # `SalixCopy.finish/1` merges once more and closes the window
  # (`Comma.Release`). Run again, this step only merges. Comma's tables stay.
  def up do
    case Comma.Stations.SalixCopy.open_window(repo()) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "opening the station roster window failed: #{inspect(reason)}"
    end
  end

  def down, do: :ok
end
