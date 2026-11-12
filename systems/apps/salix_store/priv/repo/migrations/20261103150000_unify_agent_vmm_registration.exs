defmodule SalixStore.Repo.Migrations.UnifyAgentVMMRegistration do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    # This runs online while old Pods still serve. Hold their writers for the
    # conversion, then fence only what the new owner stops reading: old Pods
    # keep authenticating Hosts, and an install write fails as unavailable.
    execute(
      "LOCK TABLE agent_vmm_install_operations, agent_vmm_registrations IN ACCESS EXCLUSIVE MODE"
    )

    alter table(:agent_vmm_registrations) do
      modify(:device_id, :text, null: true)
      add(:surface, :text)
      add(:client_request_id, :text)
      add(:environment_id, :text)
      add(:initial_workload_id, :text)
      add(:delivery_target_type, :text)
      add(:delivery_target_id, :text)
      add(:authorizing_subject_id, :text)
      add(:authorizing_audience, :text)
      add(:ticket_secret_hash, :binary)
      add(:ticket_expires_at, :utc_datetime_usec)
      add(:host_identity_digest, :binary)
      add(:recovery_challenge, :map)
      add(:error_code, :text)
    end

    # Pending requests already reserved this Registration ID. Preserve that ID
    # and the original request even where no Registration row exists yet.
    execute("""
    INSERT INTO agent_vmm_registrations
      (id,tenant_id,group_id,status,revision,policy_revision,desired_enabled,
       authorization_expires_at,created_at,updated_at)
    SELECT registration_id,tenant_id,group_id,
      CASE WHEN authorization_status='revoked' THEN 'revoked' ELSE 'enrolling' END,
      revision,1,(authorization_status <> 'revoked'),created_at+interval '7 days',created_at,updated_at
    FROM agent_vmm_install_operations ON CONFLICT (id) DO NOTHING
    """)

    execute("""
    UPDATE agent_vmm_registrations r SET
      surface=o.surface,client_request_id=o.client_request_id,environment_id=o.environment_id,
      initial_workload_id=o.initial_workload_id,delivery_target_type=o.delivery_target_type,
      delivery_target_id=o.delivery_target_id,authorizing_subject_id=o.authorizing_subject_id,
      authorizing_audience=o.authorizing_audience,host_identity_digest=o.host_identity_digest,
      ticket_secret_hash=NULL,
      ticket_expires_at=o.ticket_expires_at,error_code=o.error_code,
      revision=GREATEST(r.revision,o.revision)
    FROM agent_vmm_install_operations o WHERE r.id=o.registration_id
    """)

    # Old tickets, enrollment tokens and material delivery close at this
    # cutover. A current owner can issue a new ticket for the same never-bound
    # Registration. Contract step salix-20261103150100 removes this storage.
    execute("UPDATE agent_vmm_registrations SET enrollment_token_hash=NULL")

    execute("""
    ALTER TABLE agent_vmm_registrations ADD CONSTRAINT agent_vmm_registration_enrollment_retired
    CHECK (enrollment_token_hash IS NULL)
    """)

    # The new owner never touches this table, so it must not hold back the
    # deletion of a Compute Environment.
    execute(
      "ALTER TABLE agent_vmm_install_operations DROP CONSTRAINT agent_vmm_install_operations_environment_id_fkey"
    )

    execute("""
    CREATE FUNCTION reject_retired_agent_vmm_install_write() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'agent_vmm_install_operations is retired';
    END
    $$
    """)

    execute("""
    CREATE TRIGGER agent_vmm_install_operation_retired
    BEFORE INSERT OR UPDATE OR DELETE ON agent_vmm_install_operations
    FOR EACH ROW EXECUTE FUNCTION reject_retired_agent_vmm_install_write()
    """)

    create(
      unique_index(:agent_vmm_registrations, [:surface, :environment_id, :client_request_id],
        name: :agent_vmm_registration_request
      )
    )

    create(
      index(:agent_vmm_registrations, [:ticket_expires_at, :id],
        where:
          "host_identity_digest IS NULL AND credential_hash IS NULL AND ticket_secret_hash IS NOT NULL",
        name: :agent_vmm_pending_ticket_expiry
      )
    )

    create(
      index(:agent_vmm_registrations, [:delivery_target_type, :delivery_target_id, :id],
        name: :agent_vmm_registration_delivery
      )
    )

    create(
      unique_index(:agent_vmm_registrations, [:environment_id],
        where:
          "surface='bft' AND status <> 'revoked' AND (host_identity_digest IS NOT NULL OR ticket_secret_hash IS NOT NULL)",
        name: :agent_vmm_bft_live_owner
      )
    )
  end

  def down do
    raise "single Registration cutover requires forward repair"
  end
end
