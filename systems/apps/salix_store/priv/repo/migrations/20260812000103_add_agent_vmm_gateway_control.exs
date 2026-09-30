defmodule SalixStore.Repo.Migrations.AddAgentVMMGatewayControl do
  use Ecto.Migration

  def change do
    create table(:agent_vmm_sessions, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:registration_id, references(:agent_vmm_registrations, type: :text), null: false)
      add(:runtime_instance_id, references(:compute_runtime_instances, type: :text), null: false)
      add(:allocation_id, references(:compute_allocations, type: :text), null: false)
      add(:lease_id, :text, null: false)
      add(:lease_generation, :bigint, null: false)
      add(:allocation_lease_generation, :bigint, null: false)
      add(:connection_epoch, :text, null: false)
      add(:gateway_instance_id, :text, null: false)
      add(:status, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:agent_vmm_sessions, [
        :registration_id,
        :runtime_instance_id,
        :lease_generation
      ])
    )

    create(index(:agent_vmm_sessions, [:gateway_instance_id, :status, :expires_at]))

    create table(:agent_vmm_audit_events, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :text)
      add(:subject_type, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:action, :text, null: false)
      add(:outcome, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:agent_vmm_audit_events, [:subject_type, :subject_id, :created_at]))
  end
end
