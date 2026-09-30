defmodule BridgeForTeams.Repo.Migrations.CreateWorkspaceItemConversationCursors do
  use Ecto.Migration

  def change do
    create table(:workspace_item_conversation_cursors, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)

      add(:org_id, references(:organizations, type: :uuid, on_delete: :delete_all), null: false)

      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:salix_conversation_id, :text, null: false)
      add(:last_seen_message_id, :text)
      add(:last_scanned_at, :utc_datetime_usec)
      add(:catchup_pending, :boolean, null: false, default: false)
      add(:catchup_generation, :bigint, null: false, default: 0)
      add(:catchup_after_message_id, :text)
      add(:catchup_boundary_seen, :boolean, null: false, default: false)
      add(:pending_followup_message_ids, {:array, :text}, null: false, default: [])
      add(:reconciled_followup_message_ids, {:array, :text}, null: false, default: [])
      add(:lease_token, :text)
      add(:lease_expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      unique_index(
        :workspace_item_conversation_cursors,
        [:user_id, :project_id, :salix_conversation_id],
        name: :workspace_item_conversation_cursors_identity_idx
      )
    )

    create(index(:workspace_item_conversation_cursors, [:project_id]))

    create(
      index(:workspace_item_conversation_cursors, [:user_id, :project_id, :last_scanned_at],
        name: :workspace_item_conversation_cursors_scan_order_idx
      )
    )
  end
end
