defmodule BridgeForTeams.Repo.Migrations.WidenWorkspaceItemVfsPath do
  use Ecto.Migration

  def change do
    alter table(:workspace_items) do
      modify :vfs_path, :text
    end
  end
end
