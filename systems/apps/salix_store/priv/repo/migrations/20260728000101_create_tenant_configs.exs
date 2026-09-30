defmodule SalixStore.Repo.Migrations.CreateTenantConfigs do
  use Ecto.Migration

  # Discrete tenant config records move from S3 to Postgres
  # (docs/salix/control-metadata-postgres.md). One row per (tenant_id, name);
  # field-parity image of the retired `ctl/tenant_configs/{tenant_id}/{name}.json`
  # blob. The payload is arbitrary JSON, so `value` is jsonb (the runtime writes
  # `trajectory_eval` and `conversation_links`, both maps). No secrets.
  def change do
    create table(:tenant_configs, primary_key: false) do
      add :tenant_id, :text, primary_key: true
      add :name, :text, primary_key: true
      add :value, :map, null: false, default: %{}
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
