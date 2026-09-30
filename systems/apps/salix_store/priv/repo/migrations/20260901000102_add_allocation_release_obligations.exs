defmodule SalixStore.Repo.Migrations.AddAllocationReleaseObligations do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @lock_timeout "5s"
  @identity_index "compute_commands_release_incarnation_idx"
  @due_index "compute_commands_release_due_idx"
  @shape_constraint "compute_commands_release_owner_shape"

  def up do
    sql!("SET lock_timeout TO '#{@lock_timeout}'")

    sql!("""
    ALTER TABLE compute_commands
      ADD COLUMN IF NOT EXISTS release_incarnation text,
      ADD COLUMN IF NOT EXISTS next_attempt_at timestamp(6) without time zone,
      ADD COLUMN IF NOT EXISTS attempt_count bigint NOT NULL DEFAULT 0
    """)

    assert_column_contract!()

    # NOT VALID preserves stored mixed-version rows for the bounded backfill,
    # while every new/updated release row must already use the terminal shape.
    # The rollout's final zero-issue audit is the gate for a later online
    # VALIDATE/NOT NULL contract step; there is no runtime compatibility read.
    sql!("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'compute_commands'::regclass
          AND conname = '#{@shape_constraint}'
      ) THEN
        ALTER TABLE compute_commands
        ADD CONSTRAINT #{@shape_constraint}
        CHECK (
          kind <> 'allocation.release'
          OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
        ) NOT VALID;
      END IF;
    END
    $$
    """)

    assert_constraint_contract!()

    drop_invalid_index(@identity_index)

    sql!("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@identity_index}
    ON compute_commands (release_incarnation)
    WHERE release_incarnation IS NOT NULL
    """)

    assert_index_contract!(@identity_index, true, [
      "(release_incarnation)",
      "WHERE (release_incarnation IS NOT NULL)"
    ])

    drop_invalid_index(@due_index)

    sql!("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@due_index}
    ON compute_commands (status, next_attempt_at, id)
    INCLUDE (allocation_id, target_generation)
    WHERE kind = 'allocation.release'
      AND status IN ('failed', 'unknown_outcome')
      AND next_attempt_at IS NOT NULL
    """)

    assert_index_contract!(@due_index, false, [
      "(status, next_attempt_at, id)",
      "INCLUDE (allocation_id, target_generation)",
      "kind = 'allocation.release'",
      "next_attempt_at IS NOT NULL"
    ])

    sql!("RESET lock_timeout")
  end

  def down do
    sql!("SET lock_timeout TO '#{@lock_timeout}'")
    sql!("DROP INDEX CONCURRENTLY IF EXISTS #{@due_index}")
    sql!("DROP INDEX CONCURRENTLY IF EXISTS #{@identity_index}")

    sql!("ALTER TABLE compute_commands DROP CONSTRAINT IF EXISTS #{@shape_constraint}")

    sql!("""
    ALTER TABLE compute_commands
      DROP COLUMN IF EXISTS attempt_count,
      DROP COLUMN IF EXISTS next_attempt_at,
      DROP COLUMN IF EXISTS release_incarnation
    """)

    sql!("RESET lock_timeout")
  end

  defp assert_column_contract! do
    rows =
      repo().query!("""
      SELECT column_name, data_type, is_nullable, coalesce(column_default, '')
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'compute_commands'
        AND column_name IN ('release_incarnation', 'next_attempt_at', 'attempt_count')
      ORDER BY column_name
      """).rows

    expected = [
      ["attempt_count", "bigint", "NO", "0"],
      ["next_attempt_at", "timestamp without time zone", "YES", ""],
      ["release_incarnation", "text", "YES", ""]
    ]

    if rows != expected,
      do: raise("compute_commands release obligation columns have an incompatible catalog shape")
  end

  defp assert_constraint_contract! do
    case repo().query!(
           """
           SELECT convalidated, pg_get_constraintdef(oid)
           FROM pg_constraint
           WHERE conrelid = 'compute_commands'::regclass
             AND conname = $1
           """,
           [@shape_constraint]
         ).rows do
      [[validated, definition]] when is_boolean(validated) ->
        unless definition =~ "kind <> 'allocation.release'" and
                 definition =~ "release_incarnation IS NOT NULL" and
                 definition =~ "workload_id IS NULL" do
          raise "compute_commands release owner constraint has an incompatible catalog shape"
        end

      _ ->
        raise "compute_commands release owner constraint is missing"
    end
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

  # This migration is intentionally non-transactional and catalog guarded.
  # Execute each stage immediately so a following guard observes the stage
  # that just committed and a process restart can resume at the first missing
  # object.
  defp sql!(statement), do: repo().query!(statement)
end
