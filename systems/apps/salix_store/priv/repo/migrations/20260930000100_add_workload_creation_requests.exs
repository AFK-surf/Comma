defmodule SalixStore.Repo.Migrations.AddWorkloadCreationRequests do
  use Ecto.Migration

  def change do
    alter table(:compute_workloads) do
      add(:creation_request_scope, :text)
      add(:creation_request_id, :text)
      add(:creation_request_input, :map)
    end

    create(index(:compute_workloads, [:environment_id, :id]))

    create(
      unique_index(:compute_workloads, [:creation_request_scope, :creation_request_id],
        where: "creation_request_id IS NOT NULL",
        name: :compute_workloads_creation_request_index
      )
    )
  end
end
