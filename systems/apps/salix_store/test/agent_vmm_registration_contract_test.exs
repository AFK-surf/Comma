defmodule SalixStore.AgentVMMRegistrationContractTest do
  use SystemsClock.Case, async: false
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
    database = "vmm_contract_" <> String.replace(SystemsRuntime.Proc.uuid(), "-", "")
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
               SalixStore.Repo.Migrations.AddAgentVMMScopedRegistrationIndex,
               log: false
             )

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               2,
               SalixStore.Repo.Migrations.AddAgentVMMActiveRegistrationIndex,
               log: false
             )

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

  test "single Registration cutover preserves bound credentials, pending request identity and accepted work" do
    Code.require_file(
      "../priv/repo/migrations/20261103150000_unify_agent_vmm_registration.exs",
      __DIR__
    )

    database = "vmm_single_" <> String.replace(SystemsRuntime.Proc.uuid(), "-", "")
    Repo.query!("CREATE DATABASE #{database}")
    on_exit(fn -> Repo.query!("DROP DATABASE #{database} WITH (FORCE)") end)

    config =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.merge(database: database, pool_size: 2)

    start_supervised!({MigrationRepo, config})

    MigrationRepo.query!("""
    CREATE TABLE agent_vmm_registrations (
      id text PRIMARY KEY, tenant_id text NOT NULL, group_id text NOT NULL,
      device_id text NOT NULL, status text NOT NULL, revision bigint NOT NULL DEFAULT 1,
      policy_revision bigint NOT NULL DEFAULT 1, desired_enabled boolean NOT NULL DEFAULT false,
      authorization_expires_at timestamp NOT NULL, credential_hash bytea, enrollment_token_hash bytea,
      created_at timestamp NOT NULL, updated_at timestamp NOT NULL)
    """)

    MigrationRepo.query!("CREATE TABLE compute_environments (id text PRIMARY KEY)")
    MigrationRepo.query!("INSERT INTO compute_environments VALUES ('owner-env')")

    MigrationRepo.query!("""
    CREATE TABLE agent_vmm_install_operations (
      id text PRIMARY KEY, registration_id text NOT NULL, tenant_id text NOT NULL,
      group_id text NOT NULL, surface text, client_request_id text, environment_id text,
      initial_workload_id text, delivery_target_type text, delivery_target_id text,
      authorizing_subject_id text, authorizing_audience text, host_identity_digest bytea,
      authorization_status text, ticket_status text, ticket_secret_hash bytea,
      ticket_expires_at timestamp, error_code text, revision bigint NOT NULL DEFAULT 1,
      created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now(),
      CONSTRAINT agent_vmm_install_operations_environment_id_fkey
        FOREIGN KEY (environment_id) REFERENCES compute_environments(id))
    """)

    MigrationRepo.query!(
      "CREATE FUNCTION bump_agent_vmm_install_operation_revision() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$"
    )

    MigrationRepo.query!(
      "CREATE TRIGGER agent_vmm_install_operation_revision BEFORE UPDATE ON agent_vmm_install_operations FOR EACH ROW EXECUTE FUNCTION bump_agent_vmm_install_operation_revision()"
    )

    MigrationRepo.query!("CREATE TABLE accepted_work (id text PRIMARY KEY, outcome text)")

    MigrationRepo.query!(
      "INSERT INTO accepted_work VALUES ('accepted-command','unknown_outcome')"
    )

    credential = :crypto.hash(:sha256, "existing-bearer")
    commitment = :crypto.hash(:sha256, "existing-root")

    MigrationRepo.query!(
      """
      INSERT INTO agent_vmm_registrations
        (id,tenant_id,group_id,device_id,status,credential_hash,authorization_expires_at,created_at,updated_at)
      VALUES ('bound','tenant','original-group','host','ready',$1,now()+interval '7 days',now(),now())
      """,
      [credential]
    )

    MigrationRepo.query!(
      """
      INSERT INTO agent_vmm_install_operations
        (id,registration_id,tenant_id,group_id,surface,client_request_id,environment_id,
         delivery_target_type,delivery_target_id,authorization_status,ticket_status,ticket_secret_hash,
         ticket_expires_at,host_identity_digest)
      VALUES ('old-bound-operation','bound','tenant','original-group','comma','bound-request','owner-env',
        'comma_main_device','old-session','handed_off','consumed',$1,now()+interval '15 minutes',$2),
        ('old-pending-operation','reserved-registration','tenant','original-group','comma','pending-request','owner-env',
        'comma_main_device','old-session','requested','active',$1,now()+interval '15 minutes',NULL)
      """,
      [:crypto.hash(:sha256, "old-ticket"), commitment]
    )

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               1,
               SalixStore.Repo.Migrations.UnifyAgentVMMRegistration,
               log: false
             )

    assert [
             ["bound", "bound-request", "owner-env", "original-group", ^credential, ^commitment],
             ["reserved-registration", "pending-request", "owner-env", "original-group", nil, nil]
           ] =
             MigrationRepo.query!(
               "SELECT id,client_request_id,environment_id,group_id,credential_hash,host_identity_digest FROM agent_vmm_registrations ORDER BY id"
             ).rows

    assert [["bound", false], ["reserved-registration", true]] =
             MigrationRepo.query!(
               "SELECT id,desired_enabled FROM agent_vmm_registrations ORDER BY id"
             ).rows

    assert [[nil], [nil]] =
             MigrationRepo.query!(
               "SELECT ticket_secret_hash FROM agent_vmm_registrations ORDER BY id"
             ).rows

    assert [["accepted-command", "unknown_outcome"]] =
             MigrationRepo.query!("SELECT id,outcome FROM accepted_work").rows

    # Old Pods keep reading while they drain. Their install writes fail and new
    # Registrations can no longer carry an enrollment token.
    assert %{num_rows: 2} =
             MigrationRepo.query!("SELECT enrollment_token_hash FROM agent_vmm_registrations")

    assert %{num_rows: 2} = MigrationRepo.query!("SELECT id FROM agent_vmm_install_operations")

    for write <- [
          "INSERT INTO agent_vmm_install_operations (id,registration_id,tenant_id,group_id) VALUES ('late','late','tenant','group')",
          "UPDATE agent_vmm_install_operations SET error_code='late'",
          "DELETE FROM agent_vmm_install_operations"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception}}} =
               MigrationRepo.query(write)
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             MigrationRepo.query("""
             INSERT INTO agent_vmm_registrations
               (id,tenant_id,group_id,device_id,status,authorization_expires_at,enrollment_token_hash,
                created_at,updated_at)
             VALUES ('late','tenant','group','device','enrolling',now(),'\\x00',now(),now())
             """)

    assert %{num_rows: 1} =
             MigrationRepo.query!("DELETE FROM compute_environments WHERE id='owner-env'")

    Code.require_file(
      "../priv/release_migrations/20261103150100_contract_agent_vmm_install_operations.exs",
      __DIR__
    )

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               2,
               SalixStore.Repo.Migrations.ContractAgentVMMInstallOperations,
               log: false
             )

    assert [[nil, nil]] =
             MigrationRepo.query!("""
             SELECT to_regclass('agent_vmm_install_operations')::text,
               (SELECT column_name::text FROM information_schema.columns
                WHERE table_name='agent_vmm_registrations' AND column_name='enrollment_token_hash')
             """).rows
  end
end
