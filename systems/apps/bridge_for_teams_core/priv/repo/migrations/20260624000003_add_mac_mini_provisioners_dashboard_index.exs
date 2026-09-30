defmodule BridgeForTeams.Repo.Migrations.AddMacMiniProvisionersDashboardIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS mac_mini_provisioners_org_name_id_idx
    ON mac_mini_provisioners (org_id, name, id)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS mac_mini_provisioners_org_name_id_idx")
  end
end
