defmodule SalixStore.Repo.Migrations.CreateColabVmLeases do
  use Ecto.Migration

  # Single-authority Postgres tables for Google Colab GPU plugin accounts,
  # group install convergence, OAuth attempts, retirement fences, and VM leases.
  # Expand-only additive migration: old runtimes ignore these tables.
  def up do
    create table(:colab_vm_leases, primary_key: false) do
      add(:vm_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:owner_scope, :text, null: false)
      add(:requester_principal, :text)
      add(:account_id, :text, null: false)
      add(:google_sub, :text)
      add(:notebook_hash, :text, null: false)
      add(:endpoint, :text)
      add(:variant, :text, null: false)
      add(:accelerator, :text, null: false)
      add(:high_mem, :boolean, null: false, default: false)
      add(:state, :text, null: false)
      add(:generation, :bigint, null: false, default: 1)
      add(:owner_node, :text)
      add(:proxy_url, :text)
      add(:host_key_fingerprint, :text)
      add(:created_at, :timestamptz, null: false)
      add(:last_used_at, :timestamptz, null: false)
      add(:busy_until, :timestamptz)
      add(:hold_until, :timestamptz)
      add(:reap_after, :timestamptz)
      add(:last_error, :text)
    end

    execute("""
    CREATE UNIQUE INDEX colab_vm_leases_account_endpoint_uidx
      ON colab_vm_leases (account_id, endpoint)
      WHERE endpoint IS NOT NULL
    """)

    execute("""
    CREATE INDEX colab_vm_leases_owner_idx
      ON colab_vm_leases (tenant_id, group_id, owner_scope, state)
    """)

    execute("""
    CREATE INDEX colab_vm_leases_capacity_idx
      ON colab_vm_leases (tenant_id, account_id, accelerator, state)
    """)

    execute("""
    CREATE INDEX colab_vm_leases_reap_idx
      ON colab_vm_leases (state, reap_after)
    """)

    execute("""
    CREATE INDEX colab_vm_leases_idle_idx
      ON colab_vm_leases (state, last_used_at)
    """)

    execute("""
    CREATE INDEX colab_vm_leases_sub_unconfirmed_idx
      ON colab_vm_leases (tenant_id, google_sub, state)
      WHERE state = 'unassign_unconfirmed' AND google_sub IS NOT NULL
    """)

    execute("""
    CREATE INDEX colab_vm_leases_group_account_idx
      ON colab_vm_leases (tenant_id, group_id, account_id, state)
    """)

    create table(:colab_accounts, primary_key: false) do
      add(:binding_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:alias, :text, null: false)
      add(:google_sub, :text, null: false)
      add(:email, :text)
      add(:credentials_ciphertext, :binary, null: false)
      add(:credential_revision, :bigint, null: false, default: 1)
      add(:reconnect_revision, :bigint, null: false, default: 1)
      add(:refresh_claim_id, :text)
      add(:refresh_claim_expires_at, :timestamptz)
      add(:status, :text, null: false, default: "ok")
      add(:state, :text, null: false, default: "active")
      add(:delete_token, :text)
      add(:delete_started_at, :timestamptz)
      add(:ccu_balance, :float)
      add(:ccu_rate_hourly, :float)
      add(:eligible_gpus, :jsonb)
      add(:ccu_observed_at, :timestamptz)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
    end

    execute("""
    CREATE UNIQUE INDEX colab_accounts_group_alias_uidx
      ON colab_accounts (tenant_id, group_id, alias)
      WHERE state != 'retired'
    """)

    execute("""
    CREATE UNIQUE INDEX colab_accounts_group_sub_uidx
      ON colab_accounts (tenant_id, group_id, google_sub)
      WHERE state != 'retired'
    """)

    execute("""
    CREATE INDEX colab_accounts_group_state_idx
      ON colab_accounts (tenant_id, group_id, state)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS colab_accounts_retired_idx
      ON colab_accounts (tenant_id, group_id, binding_id)
      WHERE state = 'retired'
    """)

    create table(:colab_group_install_states, primary_key: false) do
      add(:tenant_id, :text, primary_key: true, null: false)
      add(:group_id, :text, primary_key: true, null: false)
      add(:generation, :bigint, null: false, default: 0)
      add(:desired_state, :text, null: false, default: "uninstalled")
      add(:binding_id, :text)
      add(:plugin_synced_generation, :bigint, null: false, default: 0)
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
    end

    execute("""
    CREATE INDEX colab_group_install_states_unsynced_idx
      ON colab_group_install_states (updated_at ASC, tenant_id ASC, group_id ASC)
      WHERE plugin_synced_generation < generation
    """)

    create table(:colab_oauth_attempts, primary_key: false) do
      add(:attempt_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:initiator_user_id, :text, null: false)
      add(:operation, :text, null: false)
      add(:target_binding_id, :text)
      add(:target_alias, :text, null: false)
      add(:expected_revision, :bigint)
      add(:expected_reconnect_revision, :bigint)
      add(:state_token, :text, null: false)
      add(:code_verifier, :text)
      add(:redirect_uri, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:exchange_claim_id, :text)
      add(:exchanging_started_at, :timestamptz)
      add(:exchanged_ciphertext, :binary)
      add(:result_binding_id, :text)
      add(:result_generation, :bigint)
      add(:expires_at, :timestamptz, null: false)
      add(:created_at, :timestamptz, null: false, default: fragment("now()"))
      add(:updated_at, :timestamptz, null: false, default: fragment("now()"))
    end

    execute("""
    CREATE INDEX colab_oauth_attempts_group_status_idx
      ON colab_oauth_attempts (tenant_id, group_id, status)
    """)

    execute("""
    CREATE INDEX colab_oauth_attempts_expires_idx
      ON colab_oauth_attempts (expires_at)
    """)

    create table(:colab_retired_scopes, primary_key: false) do
      add(:scope_key, :text, primary_key: true)
      add(:retired_at, :timestamptz, null: false, default: fragment("now()"))
    end
  end

  def down do
    drop(table(:colab_retired_scopes))
    drop(table(:colab_oauth_attempts))
    drop(table(:colab_group_install_states))
    execute("DROP INDEX IF EXISTS colab_accounts_retired_idx")
    drop(table(:colab_accounts))
    drop(table(:colab_vm_leases))
  end
end
