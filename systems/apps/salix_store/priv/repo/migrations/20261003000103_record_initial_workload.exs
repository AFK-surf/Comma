defmodule SalixStore.Repo.Migrations.RecordInitialWorkload do
  use Ecto.Migration

  def change do
    alter(table(:agent_vmm_install_operations), do: add(:initial_workload_id, :text))
  end
end
