defmodule SalixStore.Repo.Migrations.AddWorkloadRuntimeUpdate do
  use Ecto.Migration

  def change do
    alter table(:compute_workloads) do
      add(:runtime_update, :map)
    end
  end
end
