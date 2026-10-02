defmodule SalixStore.Repo.Migrations.AddAgentVMMRecoveryAuthority do
  use Ecto.Migration

  def change do
    alter table(:agent_vmm_install_operations) do
      add(:authorizing_subject_id, :text)
      add(:authorizing_audience, :text)
      add(:recovery_challenge, :map)
    end
  end
end
