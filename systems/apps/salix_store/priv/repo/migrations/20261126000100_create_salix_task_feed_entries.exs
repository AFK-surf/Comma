defmodule SalixStore.Repo.Migrations.CreateSalixTaskFeedEntries do
  use Ecto.Migration

  # Read-only Task Feed projection (`SalixStore.TaskFeed`): one row per Task
  # progression cluster (brief, follow-up, or Loop run), maintained in the
  # Conversation source transaction (`SalixIM.ConversationPGStore`). Expand-only:
  # a new table that earlier runtimes ignore.
  def change do
    create table(:salix_task_feed_entries, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:group_id, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:cluster_key, :text, null: false)
      add(:trigger_kind, :text, null: false)
      add(:trigger_text, :text)
      add(:task_title, :text, null: false, default: "")
      add(:task_status, :text, null: false, default: "active")
      add(:task_updated_at, :bigint, null: false, default: 0)
      add(:review_version, :bigint)
      add(:origin, :text)
      add(:is_loop, :boolean, null: false, default: false)
      add(:loop_kind, :text)
      add(:occurred_at, :bigint, null: false)
      add(:milestones, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:milestone_count, :integer, null: false, default: 0)
      add(:outcome_message_id, :text)
      add(:outcome_text, :text)
      add(:media, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:files, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:pull_request, :jsonb)
      add(:archived, :boolean, null: false, default: false)
      add(:deleted_at, :utc_datetime_usec)
    end

    create(
      unique_index(:salix_task_feed_entries, [:group_id, :conversation_id, :cluster_key],
        name: :salix_task_feed_entries_cluster_uidx
      )
    )

    execute(
      """
      CREATE INDEX salix_task_feed_entries_group_feed_idx
      ON salix_task_feed_entries (group_id, occurred_at DESC, id DESC)
      WHERE archived = false AND deleted_at IS NULL
      """,
      "DROP INDEX IF EXISTS salix_task_feed_entries_group_feed_idx"
    )

    execute(
      """
      CREATE INDEX salix_task_feed_entries_group_attention_idx
      ON salix_task_feed_entries (group_id, task_status, occurred_at DESC, id DESC)
      WHERE archived = false AND deleted_at IS NULL
      """,
      "DROP INDEX IF EXISTS salix_task_feed_entries_group_attention_idx"
    )

    create(
      index(:salix_task_feed_entries, [:group_id, :conversation_id],
        name: :salix_task_feed_entries_conversation_idx
      )
    )
  end
end
