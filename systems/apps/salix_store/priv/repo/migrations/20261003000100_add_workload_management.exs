defmodule SalixStore.Repo.Migrations.AddWorkloadManagement do
  use Ecto.Migration

  def change do
    alter table(:compute_workloads) do
      add(:name, :text)
      add(:deletion, :map)
    end

    create(index(:compute_workloads, [:allocation_id]))
  end
end
