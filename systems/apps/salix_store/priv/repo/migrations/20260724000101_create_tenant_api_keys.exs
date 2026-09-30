defmodule SalixStore.Repo.Migrations.CreateTenantApiKeys do
  use Ecto.Migration

  def change do
    create table(:tenant_api_keys, primary_key: false) do
      add :key_hash, :text, primary_key: true
      add :tenant_id, :text, null: false
      add :name, :text, null: false, default: "API key"
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:tenant_api_keys, [:tenant_id])

    # Reusable cutover markers for salix control-metadata migrations
    # (docs/salix/control-metadata-postgres.md). A row certifies that the named
    # dataset's authority now lives in Postgres.
    create table(:salix_cutover_markers, primary_key: false) do
      add :name, :text, primary_key: true
      add :completed_at, :utc_datetime_usec, null: false
      add :evidence, :map, null: false
    end
  end
end
