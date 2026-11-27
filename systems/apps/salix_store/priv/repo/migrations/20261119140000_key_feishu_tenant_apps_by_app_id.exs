defmodule SalixStore.Repo.Migrations.KeyFeishuTenantAppsByAppId do
  use Ecto.Migration

  # A tenant may hold several Feishu custom apps (one per department bot), so
  # the record key becomes (tenant_id, app_id). Every existing row is kept.
  def up do
    execute("ALTER TABLE feishu_tenant_apps DROP CONSTRAINT feishu_tenant_apps_pkey")
    execute("ALTER TABLE feishu_tenant_apps ADD PRIMARY KEY (tenant_id, app_id)")
  end

  # Fails while any tenant holds more than one app.
  def down do
    execute("ALTER TABLE feishu_tenant_apps DROP CONSTRAINT feishu_tenant_apps_pkey")
    execute("ALTER TABLE feishu_tenant_apps ADD PRIMARY KEY (tenant_id)")
  end
end
