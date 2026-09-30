defmodule SalixStore.ManagedReleaseCatalogContractMigrationTest do
  use ExUnit.Case, async: false

  alias SalixStore.Repo

  @expand_version 20_260_826_000_101
  @contract_version 20_260_827_000_101

  unless Code.ensure_loaded?(SalixStore.Repo.Migrations.ExpandManagedReleaseCatalog) do
    Code.require_file(
      "../priv/repo/migrations/20260826000101_expand_managed_release_catalog.exs",
      __DIR__
    )
  end

  unless Code.ensure_loaded?(SalixStore.Repo.Migrations.ContractManagedReleaseCatalog) do
    Code.require_file(
      "../priv/release_migrations/20260827000101_contract_managed_release_catalog.exs",
      __DIR__
    )
  end

  test "contract migration removes the catalog graph and obsolete operation identity" do
    on_exit(&restore_expand_schema!/0)
    restore_expand_schema!()

    Repo.query!("""
    INSERT INTO managed_component_releases (id, component, revision, targets, created_at)
    VALUES ('release', 'agent-vmm-host', 1, '{}'::jsonb, now())
    """)

    Repo.query!("""
    INSERT INTO managed_release_catalogs (id, created_at)
    VALUES ('catalog', now())
    """)

    Repo.query!("""
    INSERT INTO managed_release_catalog_components (catalog_id, component, component_release_id)
    VALUES ('catalog', 'agent-vmm-host', 'release')
    """)

    Repo.query!("""
    INSERT INTO active_release_catalogs (purpose, catalog_id, activated_at)
    VALUES ('runner_install', 'catalog', now())
    """)

    Repo.query!("""
    INSERT INTO agent_vmm_install_operations (
      id, tenant_id, group_id, surface, scope_key, client_request_id, provider,
      delivery_target_type, delivery_target_id, registration_id,
      authorization_status, ticket_generation, ticket_secret_hash, ticket_status,
      ticket_expires_at, host_component_release_id, platform, material_digest,
      created_at, updated_at
    ) VALUES (
      'contract-operation', 'tenant', 'group', 'surface', 'scope', 'request', 'agent_vmm',
      'conversation', 'conversation', 'registration',
      'revoked', 1, decode(repeat('11', 32), 'hex'), 'revoked',
      now(), 'release', 'darwin-arm64', decode(repeat('22', 32), 'hex'),
      now(), now()
    )
    """)

    apply_contract!()

    assert %{rows: [["contract-operation", "revoked"]]} =
             Repo.query!("""
             SELECT id, authorization_status
             FROM agent_vmm_install_operations
             WHERE id = 'contract-operation'
             """)

    for column <- ~w(host_component_release_id platform material_digest) do
      assert %{rows: [[false]]} =
               Repo.query!(
                 """
                 SELECT EXISTS (
                   SELECT 1
                   FROM information_schema.columns
                   WHERE table_schema = current_schema()
                     AND table_name = 'agent_vmm_install_operations'
                     AND column_name = $1
                 )
                 """,
                 [column]
               )
    end

    for table <- ~w(
          active_release_catalogs
          managed_release_catalog_components
          managed_release_catalogs
          managed_component_releases
        ) do
      assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass($1)", [table])
    end
  end

  defp restore_expand_schema! do
    Repo.query!("""
    ALTER TABLE agent_vmm_install_operations
      DROP CONSTRAINT IF EXISTS agent_vmm_install_operations_host_component_release_id_fkey,
      DROP CONSTRAINT IF EXISTS agent_vmm_install_operation_platform,
      DROP COLUMN IF EXISTS host_component_release_id,
      DROP COLUMN IF EXISTS platform,
      ADD COLUMN IF NOT EXISTS material_digest bytea
    """)

    Repo.query!("DROP TABLE IF EXISTS active_release_catalogs")
    Repo.query!("DROP TABLE IF EXISTS managed_release_catalog_components")
    Repo.query!("DROP TABLE IF EXISTS managed_release_catalogs")
    Repo.query!("DROP TABLE IF EXISTS managed_component_releases")

    Repo.query!("DELETE FROM salix_schema_migrations WHERE version IN ($1, $2)", [
      @expand_version,
      @contract_version
    ])

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @expand_version,
               SalixStore.Repo.Migrations.ExpandManagedReleaseCatalog,
               strict_version_order: false,
               log: false
             )
  end

  defp apply_contract! do
    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @contract_version,
               SalixStore.Repo.Migrations.ContractManagedReleaseCatalog,
               strict_version_order: false,
               log: false
             )
  end
end
