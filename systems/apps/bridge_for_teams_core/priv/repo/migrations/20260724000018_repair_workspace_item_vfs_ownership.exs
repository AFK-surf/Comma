defmodule BridgeForTeams.Repo.Migrations.RepairWorkspaceItemVfsOwnership do
  use Ecto.Migration

  def up do
    execute("LOCK TABLE workspace_items IN SHARE MODE")
    execute("DROP INDEX IF EXISTS workspace_items_project_user_vfs_path_uniq")

    execute("""
    WITH duplicate_paths AS (
      SELECT project_id, user_id, vfs_path
      FROM workspace_items
      WHERE vfs_path IS NOT NULL
      GROUP BY project_id, user_id, vfs_path
      HAVING count(*) > 1
    ),
    repairable_paths AS (
      SELECT d.project_id, d.user_id, d.vfs_path
      FROM duplicate_paths d
      JOIN workspace_items item
        ON item.project_id = d.project_id
       AND item.user_id = d.user_id
       AND item.vfs_path = d.vfs_path
      GROUP BY d.project_id, d.user_id, d.vfs_path
      HAVING count(*) FILTER (
        WHERE NULLIF(item.payload->>'vfs_path', '') = item.vfs_path
      ) = 1
    )
    UPDATE workspace_items item
    SET vfs_path = NULL
    FROM repairable_paths path
    WHERE item.project_id = path.project_id
      AND item.user_id = path.user_id
      AND item.vfs_path = path.vfs_path
      AND NULLIF(item.payload->>'vfs_path', '') IS DISTINCT FROM item.vfs_path
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM workspace_items
        WHERE vfs_path IS NOT NULL
        GROUP BY project_id, user_id, vfs_path
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION
          'workspace item VFS ownership repair found an ambiguous duplicate path';
      END IF;
    END
    $$;
    """)

    create unique_index(
             :workspace_items,
             [:project_id, :user_id, :vfs_path],
             where: "vfs_path IS NOT NULL AND NULLIF(payload->>'vfs_path', '') = vfs_path",
             name: :workspace_items_project_user_vfs_path_uniq
           )
  end

  def down do
    raise "workspace item VFS ownership repair is forward-only"
  end
end
