defmodule SalixStore.Repo.Migrations.CreateTelegramInteractions do
  use Ecto.Migration

  # New, previously undeployed feature: online expansion only. Older runtimes
  # do not touch this table; rollback retains all rows. No S3 import or cleanup.
  def change do
    create table(:telegram_interactions, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:request_id, :text, primary_key: true)
      add(:connect_id, :text, null: false)
      add(:message_id, :bigint)
      add(:body, :jsonb, null: false)
    end

    create(
      unique_index(:telegram_interactions, [:group_id, :connect_id, :message_id],
        name: :telegram_interactions_prompt_index
      )
    )
  end
end
