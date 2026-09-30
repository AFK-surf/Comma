defmodule SalixStore.Repo.Migrations.CreateComputeControl do
  use Ecto.Migration

  # This migration has never shipped. The unified Compute domain reuses its ledger id
  # for the provider-neutral Compute SSOT instead of preserving Agent VMM product
  # tables or adding a compatibility migration.
  def change do
    create table(:compute_pools, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:name, :text, null: false)
      add(:region, :text, null: false)
      add(:provider_policy, :map, null: false, default: %{})
      add(:capabilities, {:array, :text}, null: false, default: [])
      add(:capacity, :map, null: false, default: %{})
      add(:quota, :map, null: false, default: %{})
      add(:status, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_pools, [:tenant_id, :name]))
    create(index(:compute_pools, [:tenant_id, :status, :updated_at]))

    create table(:compute_environments, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:owner_type, :text, null: false)
      add(:owner_id, :text, null: false)
      add(:pool_id, references(:compute_pools, type: :text), null: false)
      add(:desired_state, :text, null: false)
      add(:observed_state, :text, null: false)
      add(:generation, :bigint, null: false, default: 1)
      add(:revision, :bigint, null: false, default: 1)
      add(:retention, :map, null: false, default: %{"mode" => "retain"})
      add(:inventory_watermark, :bigint, null: false, default: 0)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_environments, [:tenant_id, :owner_type, :owner_id]))
    create(index(:compute_environments, [:tenant_id, :desired_state, :updated_at]))

    create table(:compute_provider_bindings, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:pool_id, references(:compute_pools, type: :text), null: false)
      add(:provider, :text, null: false)
      add(:provider_ref, :text)
      add(:status, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:observation, :map, null: false, default: %{})
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:compute_provider_bindings, [:pool_id, :provider, :status]))

    create table(:compute_allocations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:environment_id, references(:compute_environments, type: :text), null: false)
      add(:provider_binding_id, references(:compute_provider_bindings, type: :text), null: false)
      add(:status, :text, null: false)
      add(:operation_outcome, :text, null: false, default: "pending")
      add(:generation, :bigint, null: false)
      add(:lease_generation, :bigint, null: false, default: 0)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:revision, :bigint, null: false, default: 1)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_allocations, [:environment_id, :generation, :id]))
    create(index(:compute_allocations, [:environment_id, :status, :updated_at]))

    create table(:compute_workloads, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:environment_id, references(:compute_environments, type: :text), null: false)
      add(:allocation_id, references(:compute_allocations, type: :text), null: false)
      add(:kind, :text, null: false)
      add(:spec, :map, null: false, default: %{})
      add(:capability_requirements, {:array, :text}, null: false, default: [])
      add(:desired_state, :text, null: false)
      add(:observed_state, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:compute_workloads, [:environment_id, :generation, :desired_state]))
    create(index(:compute_workloads, [:allocation_id, :observed_state]))

    create table(:compute_runtime_instances, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:workload_id, references(:compute_workloads, type: :text), null: false)
      add(:allocation_id, references(:compute_allocations, type: :text), null: false)
      add(:status, :text, null: false)
      add(:readiness, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:connection_epoch, :text, null: false, default: "0")
      add(:caught_up_epoch, :text, null: false, default: "0")
      add(:revision, :bigint, null: false, default: 1)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_runtime_instances, [:workload_id, :generation]))
    create(index(:compute_runtime_instances, [:status, :readiness, :updated_at]))

    create table(:compute_grants, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:environment_id, references(:compute_environments, type: :text), null: false)
      add(:workload_id, references(:compute_workloads, type: :text))
      add(:principal_type, :text, null: false)
      add(:principal_id, :text, null: false)
      add(:permissions, {:array, :text}, null: false, default: [])
      add(:revision, :bigint, null: false, default: 1)
      add(:revoked_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      index(:compute_grants, [:environment_id, :principal_type, :principal_id, :expires_at],
        where: "revoked_at IS NULL"
      )
    )

    create table(:compute_commands, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:allocation_id, references(:compute_allocations, type: :text), null: false)
      add(:workload_id, references(:compute_workloads, type: :text))
      add(:request_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:classification, :text, null: false)
      add(:target_generation, :bigint, null: false)
      add(:target_revision, :bigint, null: false)
      add(:status, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:evidence, :map, null: false, default: %{})
      add(:deadline_at, :utc_datetime_usec, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_commands, [:allocation_id, :request_id]))
    create(index(:compute_commands, [:status, :deadline_at]))

    # Agent VMM registration and credentials are Provider-private facts. They
    # select a Compute provider binding but never own Environment/Workload state.
    create table(:agent_vmm_registrations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:device_id, :text, null: false)
      add(:status, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:policy_revision, :bigint, null: false, default: 1)
      add(:desired_enabled, :boolean, null: false, default: false)
      add(:enrollment_token_hash, :binary)
      add(:credential_hash, :binary)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:agent_vmm_registrations, [:tenant_id, :device_id]))
    create(index(:agent_vmm_registrations, [:tenant_id, :group_id, :status]))

    create table(:agent_vmm_trust_anchors, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:authority_id, :text, null: false)
      add(:public_key, :binary, null: false)
      add(:key_revision, :bigint, null: false)
      add(:policy_revision, :bigint, null: false)
      add(:not_before, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
    end

    create(unique_index(:agent_vmm_trust_anchors, [:tenant_id, :authority_id, :key_revision]))

    create table(:personal_meshes, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:descriptor, :binary, null: false)
      add(:registry_audience, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:policy_epoch, :bigint, null: false)
      add(:member_limit, :integer, null: false, default: 32)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:personal_mesh_members, primary_key: false) do
      add(:mesh_id, references(:personal_meshes, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:device_id, :text, primary_key: true)
      add(:root_public_key, :binary, null: false)
      add(:root_key_revision, :bigint, null: false)
      add(:permissions, {:array, :text}, null: false, default: [])
      add(:joined_revision, :bigint, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create table(:personal_mesh_tombstones, primary_key: false) do
      add(:mesh_id, references(:personal_meshes, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:device_id, :text, primary_key: true)
      add(:root_key_revision, :bigint, null: false)
      add(:revoked_revision, :bigint, null: false)
      add(:policy_epoch, :bigint, null: false)
      add(:operation_digest, :binary, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create table(:personal_mesh_invites, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:mesh_id, references(:personal_meshes, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:invite_digest, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:personal_mesh_invites, [:mesh_id, :invite_digest]))

    create table(:personal_mesh_operations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:mesh_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:issuer_device_id, :text, null: false)
      add(:expected_revision, :bigint, null: false)
      add(:canonical_payload, :binary, null: false)
      add(:signature, :binary, null: false)
      add(:result_revision, :bigint)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:personal_mesh_operations, [:mesh_id, :created_at]))

    create table(:personal_mesh_endpoints, primary_key: false) do
      add(:mesh_id, :text, primary_key: true)
      add(:device_id, :text, primary_key: true)
      add(:root_key_revision, :bigint, null: false)
      add(:generation, :bigint, null: false)
      add(:observation, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:personal_mesh_endpoints, [:expires_at]))

    execute("""
    ALTER TABLE personal_mesh_endpoints
    ADD CONSTRAINT personal_mesh_endpoints_active_member_fkey
    FOREIGN KEY (mesh_id, device_id)
    REFERENCES personal_mesh_members(mesh_id, device_id)
    ON DELETE CASCADE
    """)
  end
end
