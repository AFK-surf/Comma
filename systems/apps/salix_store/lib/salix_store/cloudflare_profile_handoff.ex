defmodule SalixStore.CloudflareProfileHandoff do
  @moduledoc """
  Finish legacy Cloudflare Group location conversion after old writers exit.

  The online migration converts the rows visible before rollout. This bounded,
  idempotent pass closes the gap for legacy writes committed during rollout.
  Unknown locations remain unchanged for explicit operator repair.

  Every Group location that Salix created before the dual-profile release lived
  in the single standard-2 Sandbox namespace. Salix names those resources either
  by the Group hash (16 hex digits) or, after a discard-source Group cutover, by
  a fresh 32-hex-digit target name. Both shapes convert to `cf-standard-2`.
  """

  alias SalixStore.Repo

  @page_size 100

  def transfer_page(cursor \\ nil)

  def transfer_page(cursor) when cursor in [nil, "allocations", "claims"] do
    Repo.transaction(
      fn ->
        Repo.query!("SET LOCAL lock_timeout = '30s'")

        case cursor do
          "claims" -> transfer_claims()
          _ -> transfer_allocations()
        end
      end,
      timeout: 120_000
    )
  end

  def transfer_page(_), do: {:error, :invalid_cloudflare_profile_cursor}

  defp transfer_allocations do
    %{num_rows: count} = Repo.query!(allocation_page_sql())

    %{
      processed: count,
      next_cursor: if(count == @page_size, do: "allocations", else: "claims")
    }
  end

  defp transfer_claims do
    %{num_rows: count} = Repo.query!(claim_page_sql())
    %{processed: count, next_cursor: if(count == @page_size, do: "claims", else: nil)}
  end

  defp allocation_page_sql do
    """
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
        AND b.provider_ref ~ '^salix-([0-9a-f]{16}|[0-9a-f]{32})$'
      ORDER BY a.id
      LIMIT #{@page_size}
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
    FROM batch WHERE a.id = batch.id
    """
  end

  defp claim_page_sql do
    """
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
      LIMIT #{@page_size}
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
    FROM rewritten WHERE w.id = rewritten.id
    """
  end
end
