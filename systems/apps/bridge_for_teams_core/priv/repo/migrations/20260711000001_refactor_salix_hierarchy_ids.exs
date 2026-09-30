defmodule BridgeForTeams.Repo.Migrations.RefactorSalixHierarchyIds do
  use Ecto.Migration

  alias BridgeForTeams.Migrations.HierarchyIdentity
  alias SalixStore.{HierarchyIdMigration, Ids}

  @jsonb_columns [
    {"agents", "llm_config"},
    {"agents", "runtime_config"},
    {"agents", "vm"},
    {"reconcile_outbox", "payload"},
    {"operation_runs", "evidence"},
    {"check_results", "result"},
    {"observability_events", "evidence"},
    {"workspace_items", "payload"},
    {"workspace_items", "metadata"},
    {"workspace_items", "source_refs"},
    {"workspace_items", "latest_artifact"},
    {"workspace_items", "artifact_manifest"},
    {"user_onboardings", "capabilities"},
    {"user_onboardings", "profile"},
    {"user_dashboard_prefs", "home_layout"},
    {"user_dashboard_prefs", "widget_sizes"},
    {"audit_logs", "metadata"},
    {"audit_logs", "redacted_diff"},
    {"environment_provision_requests", "spec"},
    {"environment_provision_requests", "progress"},
    {"mac_mini_provisioners", "capabilities"},
    {"mac_mini_install_codes", "release_snapshot"},
    {"mac_mini_install_codes", "audit_metadata"},
    {"org_sso_connections", "provider_config"},
    {"org_sso_identities", "provider_profile"}
  ]

  @embedded_text_columns [
    {"observability_events", "resource_id"},
    {"observability_events", "correlation_id"},
    {"audit_logs", "resource_id"}
  ]

  def up do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    create table(:salix_identity_migration_maps, primary_key: false) do
      add(:name, :text, primary_key: true)
      add(:payload, :map, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    flush()

    repo = repo()
    existing = read_existing_map(repo)
    tenants = build_tenants(repo, existing)
    groups = build_groups(repo, tenants, existing)
    agents = build_agents(repo, groups, existing)

    identity = %{
      tenants: tenants.mappings,
      groups: groups.mappings,
      agents: agents.mappings
    }

    {:ok, identity} = HierarchyIdMigration.normalize(identity)
    persist_map(repo, identity)
    update_tenants(repo, tenants.rows)
    update_groups(repo, groups.rows)
    update_agents(repo, agents.rows)
    enforce_identity_presence(repo)
    rewrite_exact_columns(repo, identity)
    create_rewrite_functions(repo)
    rewrite_jsonb_columns(repo, identity)
    refresh_payload_sizes(repo)
    rewrite_embedded_text_columns(repo, identity)
  end

  def down do
    raise "Salix hierarchy identity migration is irreversible"
  end

  defp read_existing_map(repo) do
    case repo.query!(
           "SELECT payload FROM salix_identity_migration_maps WHERE name = $1",
           [HierarchyIdentity.name()]
         ).rows do
      [] ->
        HierarchyIdMigration.empty()

      [[payload]] ->
        case HierarchyIdMigration.normalize(payload) do
          {:ok, identity} -> identity
          {:error, reason} -> raise "invalid existing hierarchy identity map: #{inspect(reason)}"
        end
    end
  end

  defp build_tenants(repo, existing) do
    rows =
      repo.query!("""
      SELECT id::text, salix_tenant_id
      FROM organizations
      ORDER BY created_at, id
      """).rows

    state = new_state(existing.tenants)

    {state, mapped_rows, by_org} =
      Enum.reduce(rows, {state, [], %{}}, fn [org_id, source], {state, mapped, by_org} ->
        source = trim(source)
        state = claim_source!(state, source, :tenant)

        {target, state} =
          target_id(
            state,
            source,
            &Ids.valid_tenant_id?/1,
            &Ids.new_tenant_id/0,
            :tenant
          )

        {state, [{org_id, source, target} | mapped], Map.put(by_org, org_id, target)}
      end)

    %{mappings: state.mappings, rows: Enum.reverse(mapped_rows), by_org: by_org}
  end

  defp build_groups(repo, tenants, existing) do
    rows =
      repo.query!("""
      SELECT id::text, org_id::text, salix_group_id
      FROM projects
      ORDER BY created_at, id
      """).rows

    state = new_state(existing.groups)

    {state, mapped_rows, by_project} =
      Enum.reduce(rows, {state, [], %{}}, fn [project_id, org_id, source],
                                             {state, mapped, by_project} ->
        tenant_id = Map.fetch!(tenants.by_org, org_id)
        source = trim(source)
        state = claim_source!(state, source, :group)

        {target, state} =
          target_id(
            state,
            source,
            &Ids.valid_group_id_for_tenant?(&1, tenant_id),
            fn -> Ids.new_group_id(tenant_id) end,
            :group
          )

        {state, [{project_id, source, target} | mapped], Map.put(by_project, project_id, target)}
      end)

    %{mappings: state.mappings, rows: Enum.reverse(mapped_rows), by_project: by_project}
  end

  defp build_agents(repo, groups, existing) do
    rows =
      repo.query!("""
      SELECT id::text, project_id::text, salix_agent_id
      FROM agents
      ORDER BY created_at, id
      """).rows

    state = new_state(existing.agents)

    {state, mapped_rows} =
      Enum.reduce(rows, {state, []}, fn [agent_row_id, project_id, source], {state, mapped} ->
        group_id = Map.fetch!(groups.by_project, project_id)
        source = trim(source)
        state = claim_source!(state, source, :agent)

        {target, state} =
          target_id(
            state,
            source,
            &Ids.valid_agent_id_for_group?(&1, group_id),
            fn -> Ids.new_agent_id(group_id) end,
            :agent
          )

        {state, [{agent_row_id, source, target} | mapped]}
      end)

    %{mappings: state.mappings, rows: Enum.reverse(mapped_rows)}
  end

  defp new_state(existing) do
    %{
      mappings: existing,
      targets: MapSet.new(Map.values(existing)),
      claimed_sources: MapSet.new()
    }
  end

  defp claim_source!(state, "", _kind), do: state

  defp claim_source!(state, source, kind) do
    if MapSet.member?(state.claimed_sources, source) do
      raise "duplicate #{kind} identity source #{inspect(source)}"
    end

    %{state | claimed_sources: MapSet.put(state.claimed_sources, source)}
  end

  defp target_id(state, source, valid?, generate, kind) do
    case Map.fetch(state.mappings, source) do
      {:ok, target} when source != "" ->
        if valid?.(target) do
          {target, state}
        else
          raise "#{kind} identity #{inspect(source)} has invalid reserved target #{inspect(target)}"
        end

      _ ->
        target =
          if source != "" and valid?.(source), do: source, else: fresh_target(state, generate)

        state =
          state
          |> Map.update!(:targets, &MapSet.put(&1, target))
          |> maybe_put_mapping(source, target)

        {target, state}
    end
  end

  defp fresh_target(state, generate) do
    target = generate.()
    if MapSet.member?(state.targets, target), do: fresh_target(state, generate), else: target
  end

  defp maybe_put_mapping(state, "", _target), do: state

  defp maybe_put_mapping(state, source, target),
    do: Map.update!(state, :mappings, &Map.put(&1, source, target))

  defp persist_map(repo, identity) do
    payload = %{
      "version" => 1,
      "tenants" => identity.tenants,
      "groups" => identity.groups,
      "agents" => identity.agents
    }

    case repo.query!(
           """
           INSERT INTO salix_identity_migration_maps (name, payload, inserted_at, updated_at)
           VALUES ($1, $2, now(), now())
           ON CONFLICT (name) DO NOTHING
           RETURNING payload
           """,
           [HierarchyIdentity.name(), payload]
         ).rows do
      [[^payload]] ->
        :ok

      [] ->
        case HierarchyIdentity.read(repo) do
          {:ok, ^identity} -> :ok
          {:ok, other} -> raise "hierarchy identity map conflict: #{inspect(other)}"
          {:error, reason} -> raise "cannot read hierarchy identity map: #{inspect(reason)}"
        end
    end
  end

  defp update_tenants(repo, rows) do
    Enum.each(rows, fn {id, _source, target} ->
      update_identity_column(repo, "organizations", "salix_tenant_id", id, target)
    end)
  end

  defp update_groups(repo, rows) do
    Enum.each(rows, fn {id, _source, target} ->
      update_identity_column(repo, "projects", "salix_group_id", id, target)
    end)
  end

  defp update_agents(repo, rows) do
    Enum.each(rows, fn {id, _source, target} ->
      update_identity_column(repo, "agents", "salix_agent_id", id, target)
    end)
  end

  defp enforce_identity_presence(repo) do
    repo.query!("ALTER TABLE projects ALTER COLUMN salix_group_id SET NOT NULL")
    repo.query!("ALTER TABLE agents ALTER COLUMN salix_agent_id SET NOT NULL")
  end

  defp update_identity_column(repo, table, column, id, target) do
    repo.query!(
      "UPDATE #{table} SET #{column} = $1, updated_at = now() WHERE id::text = $2",
      [target, id]
    )
  end

  defp rewrite_exact_columns(repo, identity) do
    Enum.each(identity.groups, fn {source, target} ->
      rewrite_exact_column(
        repo,
        "environment_provision_requests",
        "salix_group_id",
        source,
        target
      )
    end)

    Enum.each(identity.agents, fn {source, target} ->
      rewrite_exact_column(repo, "workspace_items", "salix_agent_id", source, target)
    end)
  end

  defp rewrite_exact_column(_repo, _table, _column, source, source), do: :ok

  defp rewrite_exact_column(repo, table, column, source, target) do
    repo.query!("UPDATE #{table} SET #{column} = $1 WHERE #{column} = $2", [target, source])
  end

  defp create_rewrite_functions(repo) do
    repo.query!("""
    CREATE OR REPLACE FUNCTION pg_temp.bft_hierarchy_exact(
      value jsonb,
      mappings jsonb
    ) RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE
      result jsonb;
      item jsonb;
      object_key text;
      object_value jsonb;
      next_key text;
      next_value jsonb;
    BEGIN
      CASE jsonb_typeof(value)
        WHEN 'string' THEN
          RETURN to_jsonb(coalesce(mappings ->> (value #>> '{}'), value #>> '{}'));
        WHEN 'array' THEN
          result := '[]'::jsonb;
          FOR item IN SELECT * FROM jsonb_array_elements(value) LOOP
            result := result || jsonb_build_array(pg_temp.bft_hierarchy_exact(item, mappings));
          END LOOP;
          RETURN result;
        WHEN 'object' THEN
          result := '{}'::jsonb;
          FOR object_key, object_value IN SELECT * FROM jsonb_each(value) LOOP
            next_key := coalesce(mappings ->> object_key, object_key);
            next_value := pg_temp.bft_hierarchy_exact(object_value, mappings);
            IF result ? next_key AND result -> next_key IS DISTINCT FROM next_value THEN
              RAISE EXCEPTION 'hierarchy identity key collision: %', next_key;
            END IF;
            result := result || jsonb_build_object(next_key, next_value);
          END LOOP;
          RETURN result;
        ELSE
          RETURN value;
      END CASE;
    END;
    $$;
    """)

    repo.query!("""
    CREATE OR REPLACE FUNCTION pg_temp.bft_hierarchy_identity_text(
      value text,
      tenant_map jsonb,
      group_map jsonb,
      agent_map jsonb
    ) RETURNS text LANGUAGE plpgsql AS $$
    BEGIN
      IF value IS NULL THEN RETURN NULL; END IF;
      RETURN coalesce((tenant_map || group_map || agent_map) ->> value, value);
    END;
    $$;
    """)

    repo.query!("""
    CREATE OR REPLACE FUNCTION pg_temp.bft_hierarchy_jsonb(
      value jsonb,
      tenant_map jsonb,
      group_map jsonb,
      agent_map jsonb
    ) RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE
      result jsonb;
      item jsonb;
      object_key text;
      object_value jsonb;
      rewritten jsonb;
      identity_map jsonb;
      decoded jsonb;
    BEGIN
      CASE jsonb_typeof(value)
        WHEN 'array' THEN
          result := '[]'::jsonb;
          FOR item IN SELECT * FROM jsonb_array_elements(value) LOOP
            result := result || jsonb_build_array(
              pg_temp.bft_hierarchy_jsonb(item, tenant_map, group_map, agent_map)
            );
          END LOOP;
          RETURN result;
        WHEN 'object' THEN
          result := '{}'::jsonb;
          FOR object_key, object_value IN SELECT * FROM jsonb_each(value) LOOP
            identity_map := NULL;

            IF object_key IN ('tenant', 'tenant_id', 'tenant_ids') OR
               object_key ~ '(_tenant_id|_tenant_ids)$' THEN
              identity_map := tenant_map;
            ELSIF object_key IN ('group', 'group_id', 'group_ids', 'agent_group_id') OR
                  object_key ~ '(_group_id|_group_ids)$' OR
                  (object_key = 'product_owner_id' AND value ->> 'product_owner_type' = 'group') THEN
              identity_map := group_map;
            ELSIF object_key <> 'bft_agent_id' AND
                  (object_key IN ('agent_id', 'agent_ids') OR
                   object_key ~ '(_agent_id|_agent_ids)$') THEN
              identity_map := agent_map;
            END IF;

            IF identity_map IS NOT NULL THEN
              rewritten := pg_temp.bft_hierarchy_exact(object_value, identity_map);
            ELSIF object_key = 'db_namespace' AND jsonb_typeof(object_value) = 'string' AND
                  object_value #>> '{}' LIKE 'salix:%' THEN
              rewritten := to_jsonb(
                'salix:' || coalesce(
                  agent_map ->> substring(object_value #>> '{}' from 7),
                  substring(object_value #>> '{}' from 7)
                )
              );
            ELSIF object_key IN ('resource_id', 'correlation_id') AND
                  jsonb_typeof(object_value) = 'string' THEN
              rewritten := to_jsonb(pg_temp.bft_hierarchy_identity_text(
                object_value #>> '{}', tenant_map, group_map, agent_map
              ));
            ELSIF object_key = 'config' AND jsonb_typeof(object_value) = 'string' THEN
              BEGIN
                decoded := (object_value #>> '{}')::jsonb;
                rewritten := to_jsonb(
                  pg_temp.bft_hierarchy_jsonb(decoded, tenant_map, group_map, agent_map)::text
                );
              EXCEPTION WHEN others THEN
                rewritten := object_value;
              END;
            ELSE
              rewritten := pg_temp.bft_hierarchy_jsonb(
                object_value, tenant_map, group_map, agent_map
              );
            END IF;

            result := result || jsonb_build_object(object_key, rewritten);
          END LOOP;
          RETURN result;
        ELSE
          RETURN value;
      END CASE;
    END;
    $$;
    """)
  end

  defp rewrite_jsonb_columns(repo, identity) do
    tenant_map = identity.tenants
    group_map = identity.groups
    agent_map = identity.agents

    Enum.each(@jsonb_columns, fn {table, column} ->
      repo.query!(
        """
        UPDATE #{table}
        SET #{column} = pg_temp.bft_hierarchy_jsonb(#{column}, $1, $2, $3)
        WHERE #{column} IS NOT NULL
        """,
        [tenant_map, group_map, agent_map]
      )
    end)
  end

  defp refresh_payload_sizes(repo) do
    Enum.each(
      [
        {"operation_runs", "evidence", "evidence_size_bytes"},
        {"check_results", "result", "result_size_bytes"},
        {"observability_events", "evidence", "evidence_size_bytes"},
        {"audit_logs", "metadata", "metadata_size_bytes"}
      ],
      fn {table, payload, size} ->
        repo.query!("""
        UPDATE #{table}
        SET #{size} = octet_length(COALESCE(#{payload}, '{}'::jsonb)::text)
        """)
      end
    )
  end

  defp rewrite_embedded_text_columns(repo, identity) do
    Enum.each(@embedded_text_columns, fn {table, column} ->
      repo.query!(
        """
        UPDATE #{table}
        SET #{column} = pg_temp.bft_hierarchy_identity_text(#{column}, $1, $2, $3)
        WHERE #{column} IS NOT NULL
        """,
        [identity.tenants, identity.groups, identity.agents]
      )
    end)
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
