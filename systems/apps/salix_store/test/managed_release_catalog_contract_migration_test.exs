defmodule SalixStore.ManagedReleaseCatalogContractMigrationTest do
  use SystemsClock.Case, async: false

  alias SalixStore.Repo

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :salix_store, adapter: Ecto.Adapters.Postgres
  end

  @operations_version 20_260_824_000_001
  @expand_version 20_260_826_000_101
  @contract_version 20_260_827_000_101

  unless Code.ensure_loaded?(SalixStore.Repo.Migrations.CreateAgentVMMInstallOperations) do
    Code.require_file(
      "../priv/repo/migrations/20260824000001_create_agent_vmm_install_operations.exs",
      __DIR__
    )
  end

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
    database = "catalog_contract_" <> String.replace(SystemsRuntime.Proc.uuid(), "-", "")
    Repo.query!("CREATE DATABASE #{database}")
    on_exit(fn -> Repo.query!("DROP DATABASE #{database} WITH (FORCE)") end)

    config =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.merge(database: database, pool_size: 2)

    start_supervised!({MigrationRepo, config})

    for {version, migration} <- [
          {@operations_version, SalixStore.Repo.Migrations.CreateAgentVMMInstallOperations},
          {@expand_version, SalixStore.Repo.Migrations.ExpandManagedReleaseCatalog}
        ] do
      assert :ok = Ecto.Migrator.up(MigrationRepo, version, migration, log: false)
    end

    MigrationRepo.query!("""
    INSERT INTO managed_component_releases (id, component, revision, targets, created_at)
    VALUES ('release', 'agent-vmm-host', 1, '{}'::jsonb, now())
    """)

    MigrationRepo.query!("""
    INSERT INTO managed_release_catalogs (id, created_at)
    VALUES ('catalog', now())
    """)

    MigrationRepo.query!("""
    INSERT INTO managed_release_catalog_components (catalog_id, component, component_release_id)
    VALUES ('catalog', 'agent-vmm-host', 'release')
    """)

    MigrationRepo.query!("""
    INSERT INTO active_release_catalogs (purpose, catalog_id, activated_at)
    VALUES ('runner_install', 'catalog', now())
    """)

    MigrationRepo.query!("""
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
             MigrationRepo.query!("""
             SELECT id, authorization_status
             FROM agent_vmm_install_operations
             WHERE id = 'contract-operation'
             """)

    for column <- ~w(host_component_release_id platform material_digest) do
      assert %{rows: [[false]]} =
               MigrationRepo.query!(
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
      assert %{rows: [[nil]]} = MigrationRepo.query!("SELECT to_regclass($1)", [table])
    end
  end

  defp apply_contract! do
    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               @contract_version,
               SalixStore.Repo.Migrations.ContractManagedReleaseCatalog,
               strict_version_order: false,
               log: false
             )
  end
end
