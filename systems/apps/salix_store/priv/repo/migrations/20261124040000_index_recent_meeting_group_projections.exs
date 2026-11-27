defmodule SalixStore.Repo.Migrations.IndexRecentMeetingGroupProjections do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "meeting_group_projections_group_recent_idx"

  def up do
    drop_invalid_index(@index_name)

    sql!("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
      ON meeting_group_projections (group_id, inserted_at DESC, meeting_id DESC)
    """)

    assert_index_contract!(@index_name, false, ["group_id", "inserted_at DESC", "meeting_id DESC"])
  end

  def down do
    sql!("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}")
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
