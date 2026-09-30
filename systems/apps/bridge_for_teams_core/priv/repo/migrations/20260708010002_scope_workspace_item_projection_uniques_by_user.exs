defmodule BridgeForTeams.Repo.Migrations.ScopeWorkspaceItemProjectionUniquesByUser do
  use Ecto.Migration

  def change do
    drop_if_exists index(:workspace_items, [:project_id, :salix_conversation_id],
                     name: :workspace_items_project_conversation_idx
                   )

    drop_if_exists index(:workspace_items, [:project_id, :vfs_path],
                     name: :workspace_items_project_vfs_path_idx
                   )

    drop_if_exists index(:workspace_items, [:project_id, :user_id, :vfs_path],
                     name: :workspace_items_project_vfs_path_idx
                   )

    create unique_index(:workspace_items, [:project_id, :user_id, :salix_conversation_id],
             where: "salix_conversation_id IS NOT NULL",
             name: :workspace_items_project_conversation_idx
           )

    create index(:workspace_items, [:project_id, :user_id, :vfs_path],
             where: "vfs_path IS NOT NULL",
             name: :workspace_items_project_vfs_path_idx
           )
  end
end
