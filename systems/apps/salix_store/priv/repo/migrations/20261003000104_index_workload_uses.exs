defmodule SalixStore.Repo.Migrations.IndexWorkloadUses do
  use Ecto.Migration

  def change do
    create(index(:external_worker_bindings, [:workload_id, :id]))
    create(index(:service_exports, [:workload_id, :id], where: "revoked_at IS NULL"))
    create(index(:service_imports, [:destination_workload_id, :id], where: "revoked_at IS NULL"))
  end
end
