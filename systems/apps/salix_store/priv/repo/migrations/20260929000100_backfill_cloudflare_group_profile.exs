defmodule SalixStore.Repo.Migrations.BackfillCloudflareGroupProfile do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '30s'")
    execute(backfill_sql())
    execute(backfill_gateway_claims_sql())
  end

  def backfill_sql do
    """
    DO $migration$
    DECLARE changed_count integer;
    BEGIN
      LOOP
        WITH batch AS (
          SELECT a.id
          FROM compute_allocations a
          JOIN compute_workloads w ON w.allocation_id = a.id
          JOIN compute_environments e ON e.id = w.environment_id
          JOIN compute_provider_bindings b ON b.id = a.provider_binding_id
          WHERE e.owner_type = 'group'
            AND w.spec->>'group_default' = 'true'
            AND b.provider = 'cloudflare'
            AND COALESCE(a.provider_observation->'provider_spec'->>'profile_key', '') = ''
            AND b.provider_ref = a.provider_observation->>'provider_resource_id'
            AND b.provider_ref = a.provider_observation->>'provider_resource_name'
            AND b.provider_ref ~ '^salix-[0-9a-f]{16}$'
          ORDER BY a.id
          LIMIT 100
          FOR UPDATE OF a
        )
        UPDATE compute_allocations a
        SET provider_observation = jsonb_set(
              jsonb_set(COALESCE(a.provider_observation, '{}'::jsonb),
                        '{provider_spec}',
                        COALESCE(a.provider_observation->'provider_spec', '{}'::jsonb), true),
              '{provider_spec,profile_key}', '"cf-standard-2"'::jsonb, true),
            revision = a.revision + 1,
            updated_at = now()
        FROM batch WHERE a.id = batch.id;

        GET DIAGNOSTICS changed_count = ROW_COUNT;
        EXIT WHEN changed_count = 0;
      END LOOP;
    END
    $migration$;
    """
  end

  def backfill_gateway_claims_sql do
    """
    DO $migration$
    DECLARE changed_count integer;
    BEGIN
      LOOP
        WITH batch AS (
          SELECT w.id, a.provider_observation->'provider_spec'->>'profile_key' AS profile_key,
                 a.provider_observation->>'provider_resource_name' AS resource_name
          FROM compute_workloads w
          JOIN compute_environments e ON e.id = w.environment_id
          JOIN compute_allocations a ON a.id = w.allocation_id
          JOIN compute_provider_bindings b ON b.id = a.provider_binding_id
          WHERE e.owner_type = 'group'
            AND w.spec->>'group_default' = 'true'
            AND b.provider = 'cloudflare'
            AND a.provider_observation->'provider_spec'->>'profile_key'
                IN ('cf-standard-1', 'cf-standard-2')
            AND EXISTS (
              SELECT 1
              FROM jsonb_each(COALESCE(w.spec->'activity'->'active_operations', '{}'::jsonb)) op
              WHERE op.value->>'kind' = 'cloudflare_gateway_attempt'
                AND op.value->>'state' = 'pending_start'
                AND op.value->>'target_resource' = a.provider_observation->>'provider_resource_name'
            )
          ORDER BY w.id
          LIMIT 100
          FOR UPDATE OF w
        ), rewritten AS (
          SELECT w.id,
                 jsonb_object_agg(op.key,
                   CASE WHEN op.value->>'kind' = 'cloudflare_gateway_attempt'
                              AND op.value->>'state' = 'pending_start'
                              AND op.value->>'target_resource' = batch.resource_name
                        THEN jsonb_set(op.value, '{target_resource}',
                                       to_jsonb(batch.profile_key || ':' || batch.resource_name), true)
                        ELSE op.value END) AS operations
          FROM batch
          JOIN compute_workloads w ON w.id = batch.id
          CROSS JOIN LATERAL jsonb_each(w.spec->'activity'->'active_operations') op
          GROUP BY w.id
        )
        UPDATE compute_workloads w
        SET spec = jsonb_set(w.spec, '{activity,active_operations}', rewritten.operations, true),
            revision = w.revision + 1,
            updated_at = now()
        FROM rewritten WHERE w.id = rewritten.id;

        GET DIAGNOSTICS changed_count = ROW_COUNT;
        EXIT WHEN changed_count = 0;
      END LOOP;
    END
    $migration$;
    """
  end

  def down, do: :ok
end
