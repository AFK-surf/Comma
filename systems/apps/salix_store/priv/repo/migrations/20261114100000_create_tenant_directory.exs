defmodule SalixStore.Repo.Migrations.CreateTenantDirectory do
  use Ecto.Migration

  # The Tenant directory (SalixStore.TenantDirectory): a search projection of
  # the S3 Tenant records for the dashboard's Tenant list. Expand-only: a new
  # table that old runtimes ignore. The release's post-rollout job fills it
  # from S3 (SalixWeb.Migrations.TenantDirectoryBackfill).
  #
  # Pages are keyset pages newest first, with or without a product filter
  # (`product IS NULL` is the "other" bucket). Name and Tenant id search is a
  # case-insensitive substring match: trigram GIN indexes, as pg_trgm is
  # already installed by 20260909000001. The table is small and rarely
  # written, so the indexes skip the GIN pending list (fastupdate off).
  def up do
    create table(:tenant_directory, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:name, :text, null: false)
      add(:product, :text)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:tenant_directory, :tenant_directory_product_valid,
        check: "product IS NULL OR product IN ('comma', 'cft')"
      )
    )

    execute(
      "CREATE INDEX tenant_directory_created ON tenant_directory (created_at DESC, tenant_id DESC)"
    )

    execute(
      "CREATE INDEX tenant_directory_product_created ON tenant_directory (product, created_at DESC, tenant_id DESC)"
    )

    execute(
      "CREATE INDEX tenant_directory_name_trgm ON tenant_directory USING gin (name gin_trgm_ops) WITH (fastupdate = off)"
    )

    execute(
      "CREATE INDEX tenant_directory_id_trgm ON tenant_directory USING gin (tenant_id gin_trgm_ops) WITH (fastupdate = off)"
    )
  end

  def down do
    drop(table(:tenant_directory))
  end
end
