defmodule BridgeForTeams.Repo.Migrations.AddPeriodicConvergenceState do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists table(:storage_metering_scans, primary_key: false) do
      add :id, :text, primary_key: true
      add :cursor_project_id, :uuid
      add :generation, :bigint, null: false, default: 1
      add :sampled_at, :utc_datetime_usec
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create_if_not_exists index(:storage_metering_scans, [:lease_expires_at], concurrently: true)

    create_if_not_exists table(:artifact_sweep_scans, primary_key: false) do
      add :id, :text, primary_key: true
      add :cursor_agent_id, :uuid
      add :active_agent_id, :uuid
      add :directory_cursor, :text
      add :file_cursor, :text
      add :active_document_path, :text
      add :member_cursor_user_id, :uuid
      add :generation, :bigint, null: false, default: 1
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create_if_not_exists index(:artifact_sweep_scans, [:lease_expires_at], concurrently: true)

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS users_artifact_suffix_idx " <>
        "ON users ((left(id::text, 8)))",
      "DROP INDEX CONCURRENTLY IF EXISTS users_artifact_suffix_idx"
    )

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS org_memberships_artifact_admin_page_idx " <>
        "ON org_memberships (org_id, user_id) WHERE role IN ('owner', 'admin')",
      "DROP INDEX CONCURRENTLY IF EXISTS org_memberships_artifact_admin_page_idx"
    )

    create_if_not_exists unique_index(
                           :workspace_items,
                           [:project_id, :user_id, :vfs_path],
                           concurrently: true,
                           where: "vfs_path IS NOT NULL",
                           name: :workspace_items_project_user_vfs_path_uniq
                         )
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS org_memberships_artifact_admin_page_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_artifact_suffix_idx")

    drop_if_exists index(:workspace_items, [:project_id, :user_id, :vfs_path],
                     concurrently: true,
                     name: :workspace_items_project_user_vfs_path_uniq
                   )

    drop table(:artifact_sweep_scans)
    drop table(:storage_metering_scans)
  end
end
