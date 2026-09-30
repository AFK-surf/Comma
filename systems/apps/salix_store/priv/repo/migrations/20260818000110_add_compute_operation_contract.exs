defmodule SalixStore.Repo.Migrations.AddComputeOperationContract do
  use Ecto.Migration

  def change do
    alter table(:compute_allocations) do
      add(:provider_observation, :map, null: false, default: %{})
    end

    alter table(:agent_vmm_registrations) do
      add(:next_controller_sequence, :bigint, null: false, default: 1)
    end

    alter table(:compute_commands) do
      add(:operation_id, :text)
      add(:target_ref, :text)
      add(:lease_generation, :bigint, null: false, default: 0)
      add(:connection_epoch, :text, null: false, default: "0")
      add(:outcome, :text, null: false, default: "pending")
    end

    create(unique_index(:compute_commands, [:operation_id], where: "operation_id IS NOT NULL"))
  end
end
