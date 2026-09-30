defmodule SalixStore.Repo.Migrations.CreateComposioSettings do
  use Ecto.Migration

  # Composio settings move from S3 to Postgres (docs/salix/control-metadata-postgres.md).
  # One row per scope: a tenant id, or the reserved default scope for the
  # deployment-wide default record (`ctl/composio/default.json`). Field-parity
  # image of the retired S3 blob; `updated_at` stored as a timestamp, exposed to
  # callers as epoch seconds exactly as the S3 records carried it.
  def change do
    create table(:composio_settings, primary_key: false) do
      add :scope, :text, primary_key: true
      add :api_key, :text, null: false
      add :base_url, :text, null: false, default: ""
      add :enabled, :boolean, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
