defmodule SalixStore.Repo.Migrations.IndexConversationStatusPublication do
  use Ecto.Migration

  def change do
    alter table(:conversation_log_recovery) do
      add(:status_version, :bigint, null: false, default: 0)
    end
  end
end
