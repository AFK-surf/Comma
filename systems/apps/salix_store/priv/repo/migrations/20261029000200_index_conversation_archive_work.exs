defmodule SalixStore.Repo.Migrations.IndexConversationArchiveWork do
  use Ecto.Migration

  def change do
    alter table(:salix_conversation_messages) do
      # The epoch makes imported and old hot bodies eligible immediately. It
      # is a scheduling projection, not their historical write timestamp.
      add(:body_updated_at, :timestamptz,
        null: false,
        default: fragment("'1970-01-01 00:00:00+00'::timestamptz")
      )
    end

    execute(
      """
      CREATE INDEX salix_conversation_messages_hot_bodies
        ON salix_conversation_messages (group_id, conversation_id, seq)
        INCLUDE (body_updated_at)
        WHERE seq IS NOT NULL AND NOT tombstone
          AND payload IS NOT NULL AND archive_first_seq IS NULL
      """,
      "DROP INDEX salix_conversation_messages_hot_bodies"
    )
  end
end
