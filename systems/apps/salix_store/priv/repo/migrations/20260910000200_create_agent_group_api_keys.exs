defmodule SalixStore.Repo.Migrations.CreateAgentGroupApiKeys do
  use Ecto.Migration

  # Per-group inbound API keys for the Router post_message API
  # (docs/salix/router-post-message-api.md §4.1). Looked up by hash, unique by
  # hash, and expiring: all three are the storage-boundary criteria for
  # Postgres (docs/salix/storage-boundary-goal.md), and the shape mirrors
  # `tenant_api_keys`.
  def change do
    create table(:agent_group_api_keys, primary_key: false) do
      add(:key_hash, :text, primary_key: true)
      add(:key_id, :text, null: false)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:name, :text, null: false)
      add(:prefix, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:created_by, :text, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)
    end

    create(unique_index(:agent_group_api_keys, [:key_id]))
    create(index(:agent_group_api_keys, [:tenant_id]))
    create(index(:agent_group_api_keys, [:group_id]))
  end
end
