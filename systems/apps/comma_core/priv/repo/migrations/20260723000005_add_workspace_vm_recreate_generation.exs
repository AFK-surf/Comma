defmodule Comma.Repo.Migrations.AddWorkspaceVmRecreateGeneration do
  use Ecto.Migration

  def change do
    alter table(:comma_workspaces) do
      add(:vm_recreate_generation, :bigint)
    end

    create(
      constraint(:comma_workspaces, :comma_workspaces_vm_recreate_generation_check,
        check: "vm_recreate_generation IS NULL OR vm_recreate_generation > 0"
      )
    )
  end
end
