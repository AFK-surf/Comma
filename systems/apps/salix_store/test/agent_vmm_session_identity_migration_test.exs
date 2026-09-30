defmodule SalixStore.AgentVMMSessionIdentityMigrationTest do
  use ExUnit.Case, async: false

  alias SalixStore.{AgentVMM, Compute, Repo}

  @migration_version 20_260_921_090_000

  setup do
    ensure_current_schema!()

    Repo.query!(
      "TRUNCATE agent_vmm_sessions, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    on_exit(fn -> ensure_current_schema!() end)
    :ok
  end

  test "session cutover keeps the current allocation session when old lease generations collide" do
    assert {:ok, registration} =
             AgentVMM.create_registration(%{
               id: "migration-registration",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "device",
               enrollment_token: String.duplicate("a", 32)
             })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, pool} =
             Compute.create_pool(%{
               id: "migration-pool",
               tenant_id: "tenant",
               name: "migration",
               region: "local",
               provider_policy: %{"providers" => ["agent_vmm"]}
             })

    assert {:ok, environment} =
             Compute.create_environment(%{
               id: "migration-environment",
               tenant_id: "tenant",
               owner_type: "project",
               owner_id: "project",
               pool_id: pool.id
             })

    assert {:ok, binding} =
             Compute.create_provider_binding(%{
               id: "migration-binding",
               pool_id: pool.id,
               environment_id: environment.id,
               provider: "agent_vmm",
               provider_ref: registration.id,
               generation: 1
             })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    assert {:ok, allocation} =
             Compute.allocate(%{
               id: "migration-allocation",
               environment_id: environment.id,
               provider_binding_id: binding.id,
               generation: 1
             })

    assert {:ok, workload} =
             Compute.create_workload(%{
               id: "migration-workload",
               environment_id: environment.id,
               allocation_id: allocation.id,
               kind: "external_worker",
               generation: 1
             })

    assert {:ok, runtime} =
             Compute.observe_runtime(%{
               id: "migration-runtime",
               workload_id: workload.id,
               allocation_id: allocation.id,
               generation: 1,
               connection_epoch: "1"
             })

    now = DateTime.utc_now()

    {1, nil} =
      Repo.insert_all(AgentVMM.Session, [
        %{
          id: "current-session",
          registration_id: registration.id,
          runtime_instance_id: runtime.id,
          allocation_id: allocation.id,
          allocation_generation: allocation.generation,
          connection_epoch: "1",
          gateway_instance_id: "gateway",
          status: "ready",
          expires_at: DateTime.add(now, 300, :second),
          updated_at: now
        }
      ])

    restore_legacy_schema!(allocation.id)

    Repo.query!("""
    INSERT INTO agent_vmm_sessions (
      id, registration_id, runtime_instance_id, allocation_id,
      lease_id, lease_generation, allocation_lease_generation,
      connection_epoch, gateway_instance_id, status, expires_at, updated_at
    )
    SELECT
      'stale-session', registration_id, runtime_instance_id, allocation_id,
      'lease-1', 1, 1,
      'old-epoch', 'old-gateway', 'stale', expires_at, updated_at - interval '1 hour'
    FROM agent_vmm_sessions
    WHERE id = 'current-session'
    """)

    Repo.query!("DELETE FROM salix_schema_migrations WHERE version = $1", [@migration_version])

    migrations_path = Application.app_dir(:salix_store, "priv/repo/migrations")

    assert [@migration_version] ==
             Ecto.Migrator.run(Repo, migrations_path, :up,
               to: @migration_version,
               log: false
             )

    assert [["current-session", 1]] =
             Repo.query!("""
             SELECT id, allocation_generation
             FROM agent_vmm_sessions
             WHERE registration_id = 'migration-registration'
             """).rows

    assert [[%{}]] =
             Repo.query!("""
             SELECT provider_observation
             FROM compute_allocations
             WHERE id = 'migration-allocation'
             """).rows
  end

  defp restore_legacy_schema!(allocation_id) do
    drop_identity_index!("allocation_generation")

    unless column_exists?("compute_allocations", "lease_generation") do
      Repo.query!(
        "ALTER TABLE compute_allocations ADD COLUMN lease_generation bigint NOT NULL DEFAULT 0"
      )
    end

    unless column_exists?("compute_allocations", "lease_expires_at") do
      Repo.query!(
        "ALTER TABLE compute_allocations ADD COLUMN lease_expires_at timestamp(6) with time zone"
      )
    end

    unless column_exists?("compute_commands", "lease_generation") do
      Repo.query!(
        "ALTER TABLE compute_commands ADD COLUMN lease_generation bigint NOT NULL DEFAULT 0"
      )
    end

    Repo.query!(
      """
      UPDATE compute_allocations
      SET lease_generation = 2,
          lease_expires_at = now() + interval '5 minutes',
          provider_observation = jsonb_build_object(
            'lease_id', 'lease-2',
            'lease_generation', 2,
            'lease_expires_at', extract(epoch FROM now() + interval '5 minutes')
          )
      WHERE id = $1
      """,
      [allocation_id]
    )

    Repo.query!("ALTER TABLE agent_vmm_sessions ADD COLUMN lease_id text")
    Repo.query!("ALTER TABLE agent_vmm_sessions ADD COLUMN lease_generation bigint")
    Repo.query!("ALTER TABLE agent_vmm_sessions ADD COLUMN allocation_lease_generation bigint")

    Repo.query!("""
    UPDATE agent_vmm_sessions
    SET lease_id = 'lease-2', lease_generation = 2, allocation_lease_generation = 2
    """)

    Repo.query!("ALTER TABLE agent_vmm_sessions ALTER COLUMN lease_id SET NOT NULL")
    Repo.query!("ALTER TABLE agent_vmm_sessions ALTER COLUMN lease_generation SET NOT NULL")

    Repo.query!(
      "ALTER TABLE agent_vmm_sessions ALTER COLUMN allocation_lease_generation SET NOT NULL"
    )

    Repo.query!("ALTER TABLE agent_vmm_sessions DROP COLUMN allocation_generation")

    old_index =
      Ecto.Migration.unique_index(:agent_vmm_sessions, [
        :registration_id,
        :runtime_instance_id,
        :lease_generation
      ]).name

    Repo.query!("""
    CREATE UNIQUE INDEX #{old_index}
    ON agent_vmm_sessions (registration_id, runtime_instance_id, lease_generation)
    """)
  end

  defp drop_identity_index!(column) do
    [[name]] =
      Repo.query!(
        """
        SELECT indexname
        FROM pg_indexes
        WHERE tablename = 'agent_vmm_sessions'
          AND indexdef LIKE $1
        """,
        ["%#{column}%"]
      ).rows

    Repo.query!("DROP INDEX #{name}")
  end

  defp ensure_current_schema! do
    if column_exists?("agent_vmm_sessions", "lease_id") do
      Repo.query!("DELETE FROM salix_schema_migrations WHERE version = $1", [@migration_version])

      migrations_path = Application.app_dir(:salix_store, "priv/repo/migrations")

      Ecto.Migrator.run(Repo, migrations_path, :up,
        to: @migration_version,
        log: false
      )
    else
      index =
        Ecto.Migration.unique_index(:agent_vmm_sessions, [
          :registration_id,
          :runtime_instance_id,
          :allocation_generation
        ]).name

      Repo.query!("""
      CREATE UNIQUE INDEX IF NOT EXISTS #{index}
      ON agent_vmm_sessions (registration_id, runtime_instance_id, allocation_generation)
      """)
    end
  end

  defp column_exists?(table, column) do
    [[exists?]] =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = $1
            AND column_name = $2
        )
        """,
        [table, column]
      ).rows

    exists?
  end
end
