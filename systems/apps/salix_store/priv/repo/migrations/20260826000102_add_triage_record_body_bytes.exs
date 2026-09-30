defmodule SalixStore.Repo.Migrations.AddTriageRecordBodyBytes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @tables ~w(triage_buckets triage_run_fences triage_runs triage_replays)
  @page_size 100
  @lock_timeout "5s"
  @statement_timeout "30s"
  @query_timeout 35_000

  def up do
    bounded_transaction!(fn ->
      query!("""
      CREATE TABLE IF NOT EXISTS triage_record_body_sizes (
        source_table text COLLATE "C" NOT NULL,
        record_key text COLLATE "C" NOT NULL,
        revision bigint NOT NULL,
        body_bytes bigint NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (source_table, record_key),
        CONSTRAINT triage_record_body_sizes_shape CHECK (
          source_table IN ('triage_buckets', 'triage_run_fences', 'triage_runs', 'triage_replays') AND
          revision > 0 AND
          body_bytes > 0
        )
      )
      """)
    end)

    bounded_transaction!(fn ->
      query!("""
      CREATE OR REPLACE FUNCTION sync_triage_record_body_size()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          DELETE FROM triage_record_body_sizes
          WHERE source_table = TG_TABLE_NAME
            AND record_key = OLD.record_key;

          RETURN OLD;
        END IF;

        IF TG_OP = 'UPDATE' AND OLD.record_key IS DISTINCT FROM NEW.record_key THEN
          DELETE FROM triage_record_body_sizes
          WHERE source_table = TG_TABLE_NAME
            AND record_key = OLD.record_key;
        END IF;

        INSERT INTO triage_record_body_sizes
          (source_table, record_key, revision, body_bytes, updated_at)
        VALUES
          (TG_TABLE_NAME, NEW.record_key, NEW.revision, octet_length(NEW.body::text), now())
        ON CONFLICT (source_table, record_key) DO UPDATE SET
          revision = EXCLUDED.revision,
          body_bytes = EXCLUDED.body_bytes,
          updated_at = EXCLUDED.updated_at
        WHERE triage_record_body_sizes.revision <= EXCLUDED.revision;

        RETURN NEW;
      END;
      $$
      """)
    end)

    Enum.each(@tables, &create_sync_trigger/1)
    Enum.each(@tables, &backfill_table/1)
    Enum.each(@tables, &verify_table/1)
  end

  def down do
    Enum.each(@tables, fn table ->
      bounded_transaction!(fn ->
        query!("DROP TRIGGER IF EXISTS #{table}_body_size ON #{table}")
      end)
    end)

    bounded_transaction!(fn ->
      query!("DROP FUNCTION IF EXISTS sync_triage_record_body_size()")
      query!("DROP TABLE IF EXISTS triage_record_body_sizes")
    end)
  end

  defp create_sync_trigger(table) do
    # Drop and recreate atomically so a retry cannot leave a source table
    # without synchronization after a lock timeout or process failure.
    bounded_transaction!(fn ->
      query!("DROP TRIGGER IF EXISTS #{table}_body_size ON #{table}")

      query!("""
      CREATE TRIGGER #{table}_body_size
      AFTER INSERT OR UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION sync_triage_record_body_size()
      """)
    end)
  end

  # The source cursor advances monotonically, so each normal run visits every
  # row once. Every page commits independently; a timeout or deploy retry
  # safely recomputes the deterministic metadata without mutating source rows.
  defp backfill_table(table), do: backfill_table(table, nil)

  defp backfill_table(table, after_key) do
    %{rows: [[last_key, row_count, _upsert_count]]} =
      bounded_transaction!(fn ->
        query!(
          """
          WITH batch AS MATERIALIZED (
            SELECT record_key, revision, octet_length(body::text) AS body_bytes
            FROM #{table}
            WHERE ($1::text IS NULL OR record_key > $1)
            ORDER BY record_key
            LIMIT #{@page_size}
          ),
          upserted AS (
            INSERT INTO triage_record_body_sizes
              (source_table, record_key, revision, body_bytes, updated_at)
            SELECT $2, record_key, revision, body_bytes, now()
            FROM batch
            ON CONFLICT (source_table, record_key) DO UPDATE SET
              revision = EXCLUDED.revision,
              body_bytes = EXCLUDED.body_bytes,
              updated_at = EXCLUDED.updated_at
            WHERE triage_record_body_sizes.revision <= EXCLUDED.revision
            RETURNING record_key
          )
          SELECT max(batch.record_key), count(*), (SELECT count(*) FROM upserted)
          FROM batch
          """,
          [after_key, table]
        )
      end)

    if row_count > 0 do
      backfill_table(table, last_key)
    end
  end

  defp verify_table(table), do: verify_table(table, nil)

  defp verify_table(table, after_key) do
    %{rows: [[last_key, row_count, mismatch_count]]} =
      bounded_transaction!(fn ->
        query!(
          """
          WITH batch AS MATERIALIZED (
            SELECT record_key, revision, octet_length(body::text) AS body_bytes
            FROM #{table}
            WHERE ($1::text IS NULL OR record_key > $1)
            ORDER BY record_key
            LIMIT #{@page_size}
          )
          SELECT
            max(batch.record_key),
            count(*),
            count(*) FILTER (
              WHERE sizes.revision IS DISTINCT FROM batch.revision
                 OR sizes.body_bytes IS DISTINCT FROM batch.body_bytes
            )
          FROM batch
          LEFT JOIN triage_record_body_sizes AS sizes
            ON sizes.source_table = $2
           AND sizes.record_key = batch.record_key
          """,
          [after_key, table]
        )
      end)

    if mismatch_count > 0 do
      raise "triage record body-size backfill incomplete for #{table}"
    end

    if row_count > 0 do
      verify_table(table, last_key)
    end
  end

  defp bounded_transaction!(fun) do
    case repo().transaction(
           fn ->
             query!("SET LOCAL lock_timeout TO '#{@lock_timeout}'")
             query!("SET LOCAL statement_timeout TO '#{@statement_timeout}'")
             fun.()
           end,
           timeout: @query_timeout
         ) do
      {:ok, result} -> result
      {:error, reason} -> raise "triage record body-size migration failed: #{inspect(reason)}"
    end
  end

  defp query!(sql, params \\ []) do
    repo().query!(sql, params, timeout: @query_timeout)
  end
end
