defmodule Comma.Repo.Migrations.RemoveDuplicateDevices do
  use Ecto.Migration
  @disable_ddl_transaction true

  # Removes the duplicate devices the desktop app made on 2026-10-08 and
  # 2026-10-09 (`Comma.Devices.DuplicateCleanup`). Comma's tables are only
  # read, through the migrator's repo; the devices are Salix's.
  def up do
    {:ok, _summary} = Comma.Devices.DuplicateCleanup.run(repo())
    :ok
  end

  def down, do: :ok
end
