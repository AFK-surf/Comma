defmodule SalixStore.Repo.Migrations.IndexSalixConversationsArchiveStatus do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @unarchived_index "salix_conversations_group_unarchived"
  @kind_unarchived_index "salix_conversations_group_kind_unarchived"
  @status_index "salix_conversations_group_status"

  def up do
    drop_invalid_index(@unarchived_index)
    drop_invalid_index(@kind_unarchived_index)
    drop_invalid_index(@status_index)

    sql!("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@unarchived_index}
      ON salix_conversations
        (group_id, COALESCE(list_timestamp, 0) DESC, conversation_id COLLATE "C" ASC)
      WHERE revision > 0 AND deleted_at IS NULL AND status IS DISTINCT FROM 'archived'
    """)

    sql!("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@kind_unarchived_index}
      ON salix_conversations
        (group_id, kind, COALESCE(list_timestamp, 0) DESC, conversation_id COLLATE "C" ASC)
      WHERE revision > 0 AND deleted_at IS NULL AND status IS DISTINCT FROM 'archived'
    """)

    sql!("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@status_index}
      ON salix_conversations
        (group_id, status, COALESCE(list_timestamp, 0) DESC, conversation_id COLLATE "C" ASC)
      WHERE revision > 0 AND deleted_at IS NULL
    """)

    assert_index_contract!(@unarchived_index, false, [
      "group_id",
      "list_timestamp",
      "conversation_id",
      "IS DISTINCT FROM 'archived'"
    ])

    assert_index_contract!(@kind_unarchived_index, false, [
      "group_id",
      "kind",
      "list_timestamp",
      "conversation_id",
      "IS DISTINCT FROM 'archived'"
    ])

    assert_index_contract!(@status_index, false, [
      "group_id",
      "status",
      "list_timestamp",
      "conversation_id"
    ])
  end

  def down do
    sql!("DROP INDEX CONCURRENTLY IF EXISTS #{@status_index}")
    sql!("DROP INDEX CONCURRENTLY IF EXISTS #{@kind_unarchived_index}")
    sql!("DROP INDEX CONCURRENTLY IF EXISTS #{@unarchived_index}")
  end

  defp drop_invalid_index(name) do
    case repo().query!(
           """
           SELECT index_metadata.indisvalid, index_metadata.indisready
           FROM pg_index AS index_metadata
           JOIN pg_class AS index_class ON index_class.oid = index_metadata.indexrelid
           JOIN pg_namespace AS index_namespace ON index_namespace.oid = index_class.relnamespace
           WHERE index_namespace.nspname = current_schema()
             AND index_class.relname = $1
           """,
           [name]
         ).rows do
      [[false, _ready]] -> sql!("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
      [[_valid, false]] -> sql!("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
      _ -> :ok
    end
  end

  defp assert_index_contract!(name, unique?, required_fragments) do
    case repo().query!(
           """
           SELECT index_metadata.indisvalid, index_metadata.indisready,
                  index_metadata.indisunique, pg_get_indexdef(index_metadata.indexrelid)
           FROM pg_index AS index_metadata
           JOIN pg_class AS index_class ON index_class.oid = index_metadata.indexrelid
           JOIN pg_namespace AS index_namespace ON index_namespace.oid = index_class.relnamespace
           WHERE index_namespace.nspname = current_schema()
             AND index_class.relname = $1
           """,
           [name]
         ).rows do
      [[true, true, ^unique?, definition]] ->
        unless Enum.all?(required_fragments, &String.contains?(definition, &1)) do
          raise "#{name} has an incompatible catalog shape"
        end

      _ ->
        raise "#{name} is missing, invalid, or has an incompatible catalog shape"
    end
  end

  defp sql!(statement), do: repo().query!(statement, [])
end
