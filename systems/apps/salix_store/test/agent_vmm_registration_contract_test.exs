defmodule SalixStore.AgentVMMRegistrationContractTest do
  use ExUnit.Case, async: false
  alias SalixStore.Repo

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :salix_store, adapter: Ecto.Adapters.Postgres
  end

  for file <- [
        "20260824000002_add_agent_vmm_scoped_registration_index.exs",
        "20260824000005_add_agent_vmm_active_registration_index.exs",
        "20261001000200_contract_agent_vmm_active_registration_uniqueness.exs"
      ] do
    Code.require_file("../priv/repo/migrations/" <> file, __DIR__)
  end

  test "online expand protects active identities before contract permits a retained revoked predecessor" do
    database = "vmm_contract_" <> String.replace(Ecto.UUID.generate(), "-", "")
    Repo.query!("CREATE DATABASE #{database}")
    on_exit(fn -> Repo.query!("DROP DATABASE #{database} WITH (FORCE)") end)

    config =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.merge(database: database, pool_size: 2)

    start_supervised!({MigrationRepo, config})

    MigrationRepo.query!(
      "CREATE TABLE agent_vmm_registrations (id text PRIMARY KEY, tenant_id text NOT NULL, group_id text NOT NULL, device_id text NOT NULL, status text NOT NULL)"
    )

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               1,
               SalixStore.Repo.Migrations.AddAgentVMMScopedRegistrationIndex, log: false)

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               2,
               SalixStore.Repo.Migrations.AddAgentVMMActiveRegistrationIndex, log: false)

    MigrationRepo.query!(
      "INSERT INTO agent_vmm_registrations VALUES ('old', 'tenant', 'group', 'device', 'revoked')"
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             MigrationRepo.query(
               "INSERT INTO agent_vmm_registrations VALUES ('new', 'tenant', 'group', 'device', 'ready')"
             )

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               3,
               SalixStore.Repo.Migrations.ContractAgentVMMActiveRegistrationUniqueness,
               log: false
             )

    MigrationRepo.query!(
      "INSERT INTO agent_vmm_registrations VALUES ('new', 'tenant', 'group', 'device', 'ready')"
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             MigrationRepo.query(
               "INSERT INTO agent_vmm_registrations VALUES ('conflict', 'tenant', 'group', 'device', 'ready')"
             )

    assert [["new", "ready"], ["old", "revoked"]] =
             MigrationRepo.query!("SELECT id, status FROM agent_vmm_registrations ORDER BY id").rows
  end
end
