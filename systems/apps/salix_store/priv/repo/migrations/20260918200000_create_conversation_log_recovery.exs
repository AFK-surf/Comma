defmodule SalixStore.Repo.Migrations.CreateConversationLogRecovery do
  use Ecto.Migration

  def change do
    create table(:conversation_log_recovery, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:conversation_id, :text, primary_key: true)
      add(:target_seq, :bigint, null: false)
      add(:due_at_ms, :bigint, null: false)
    end

    create(index(:conversation_log_recovery, [:due_at_ms, :group_id, :conversation_id]))
  end
end
