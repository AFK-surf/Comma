defmodule SalixStore.Repo.Migrations.AddExternalWorkerTargetPageIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:compute_workloads, [:environment_id, "updated_at DESC", "id DESC"],
        name: :compute_workloads_environment_page_idx,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:compute_workloads, [],
        name: :compute_workloads_environment_page_idx,
        concurrently: true
      )
    )
  end
end
