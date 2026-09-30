defmodule SalixStore.Repo.Migrations.CreateOauthApps do
  use Ecto.Migration

  # OAuth static client credentials move from S3 to Postgres
  # (docs/salix/control-metadata-postgres.md, PR-1): fixed-provider apps + the
  # deployment-wide default apps in one table, keyed by (scope, provider) where
  # scope is a tenant id or the reserved default sentinel (mirrors how
  # composio_settings folds the deployment default under one scope column).
  # Retires `ctl/oauth/provider_apps/{tenant}/{provider}.json` and
  # `ctl/oauth/default_apps/{provider}.json`.
  #
  # client_secret is stored as-is (the S3 blob held it plaintext too — this moves
  # the store, not the exposure). Remote-MCP provider apps, group bindings, and
  # connections migrate later / stay in S3.
  def change do
    create table(:oauth_provider_apps, primary_key: false) do
      add :scope, :text, primary_key: true
      add :provider, :text, primary_key: true
      add :client_id, :text, null: false, default: ""
      add :client_secret, :text, null: false, default: ""
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
