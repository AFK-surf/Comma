defmodule SalixStore.Repo.Migrations.CreateFeishuTenantApps do
  use Ecto.Migration

  # Feishu bot app records (app id + bot secrets) move from S3 to Postgres
  # (docs/salix/control-metadata-postgres.md). One row per tenant; field-parity
  # image of the retired `ctl/feishu/tenant_apps/{tenant_id}.json` blob.
  # Secrets are stored as-is (the S3 blob held them plaintext too — this moves
  # the store, not the exposure).
  def change do
    create table(:feishu_tenant_apps, primary_key: false) do
      add :tenant_id, :text, primary_key: true
      add :app_id, :text, null: false, default: ""
      add :app_secret, :text, null: false, default: ""
      add :verification_token, :text, null: false, default: ""
      add :encrypt_key, :text, null: false, default: ""
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
