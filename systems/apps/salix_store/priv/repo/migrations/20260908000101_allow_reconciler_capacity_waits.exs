defmodule SalixStore.Repo.Migrations.AllowReconcilerCapacityWaits do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE compute_capacity_queue ALTER COLUMN command_id DROP NOT NULL",
      "ALTER TABLE compute_capacity_queue ALTER COLUMN command_id SET NOT NULL"
    )
  end
end
