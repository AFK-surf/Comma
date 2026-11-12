defmodule SalixStore.Repo.Migrations.RestoreS3RuntimeSearchProjection do
  use Ecto.Migration

  def up do
    %{rows: rows} =
      repo().query!("SELECT 1 FROM salix_schema_migrations WHERE version = 20261027000200")

    if rows != [] do
      execute("""
      CREATE TABLE IF NOT EXISTS conversation_search_discovery_cursors (
        id text PRIMARY KEY, writer_generation text NOT NULL,
        group_start_after text, current_group_id text, conversation_start_after text,
        completed_cycles bigint NOT NULL DEFAULT 0,
        cycle_started_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        last_cycle_completed_at timestamp(0) without time zone,
        claim_token text, claim_until timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT conversation_search_discovery_cursors_shape CHECK (
          btrim(id) <> '' AND btrim(writer_generation) <> '' AND completed_cycles >= 0 AND
          ((claim_token IS NULL AND claim_until IS NULL) OR
           (btrim(claim_token) <> '' AND claim_until IS NOT NULL)))
      )
      """)

      execute("""
      ALTER TABLE conversation_search_backfill_runs
      ADD COLUMN IF NOT EXISTS required_discovery_cycle bigint
        CHECK (required_discovery_cycle IS NULL OR required_discovery_cycle > 0)
      """)

      execute("""
      UPDATE conversation_search_backfill_runs r
      SET required_discovery_cycle=(m.evidence->>'required_discovery_cycle')::bigint
      FROM salix_cutover_markers m
      WHERE m.name='conversation_search_projection_v1'
        AND m.evidence->>'writer_generation'=r.writer_generation
        AND r.required_discovery_cycle IS NULL
      """)

      # Restart discovery from canonical S3. Do not invent completed scan evidence.
      execute("""
      INSERT INTO conversation_search_discovery_cursors
        (id,writer_generation,completed_cycles,cycle_started_at,inserted_at,updated_at)
      SELECT 'main',r.writer_generation,0,now(),now(),now()
      FROM conversation_search_backfill_runs r
      JOIN salix_cutover_markers m
        ON m.name='conversation_search_projection_v1'
        AND m.evidence->>'writer_generation'=r.writer_generation
      WHERE r.retired_at IS NULL
      ON CONFLICT (id) DO NOTHING
      """)
    end
  end

  def down do
    raise "RestoreS3RuntimeSearchProjection preserves the active S3 runtime schema"
  end
end
