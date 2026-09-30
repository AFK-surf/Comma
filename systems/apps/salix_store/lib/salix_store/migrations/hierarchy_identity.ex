defmodule SalixStore.Migrations.HierarchyIdentity do
  @moduledoc """
  One-shot tenant/group/agent identity migration for Salix S3 data.

  The complete identity map is durably reserved before any owner key moves.
  Object moves are create-once and content-checked, so an interrupted release
  resumes with the same canonical targets.

  The skill-catalog target-repair and move recovery protocol is modeled in
  `tla/salix/SkillCatalogIdentityMigration.tla`.
  """

  require Logger

  alias SalixStore.{Codec, Crypto, HierarchyIdMigration, Ids, Keys, RuntimeIds, S3, Timers}

  @tenant_key ~r|^ctl/tenants/([^/]+)\.json$|
  @group_key ~r|^ctl/groups/([^/]+)\.json$|
  @agent_key ~r|^ctl/agents/([^/]+)\.json$|
  @worker_source ~r/^agent-tool-([0-9a-f]{24})$/
  @max_concurrency 32

  @type stats :: %{migrated: non_neg_integer(), unchanged: non_neg_integer()}

  def run(opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    try do
      seed = load_seed!(Keyword.fetch!(opts, :identity_seed))

      case HierarchyIdMigration.phase_complete?(:s3, seed) do
        {:ok, true} ->
          stats = %{migrated: 0, unchanged: 0}
          CommaLog.log("migrate_salix_hierarchy_identity_already_complete", stats)
          {:ok, stats}

        {:ok, false} ->
          migrate_pending(seed)

        {:error, reason} ->
          abort({:read_s3_completion_failed, reason})
      end
    catch
      {:hierarchy_identity_abort, reason} ->
        {:error, {:hierarchy_identity_migration_failed, reason}}
    end
  end

  defp migrate_pending(seed) do
    Logger.info("Salix hierarchy identity inventory started")
    started_at = System.monotonic_time(:millisecond)
    inventory = build_inventory!()

    Logger.info(
      "Salix hierarchy identity inventory completed " <>
        "objects=#{:ets.info(inventory, :size)} " <>
        "elapsed_ms=#{System.monotonic_time(:millisecond) - started_at}"
    )

    try do
      migrate_pending(seed, inventory)
    after
      :ets.delete(inventory)
    end
  end

  defp migrate_pending(seed, inventory) do
    context = collect_identity!(seed, inventory)

    identity =
      case HierarchyIdMigration.reserve(context.identity) do
        {:ok, identity} -> identity
        {:error, reason} -> abort({:reserve_complete_identity_map_failed, reason})
      end

    context = %{context | identity: identity}

    stats =
      %{migrated: 0, unchanged: 0}
      |> migrate_phase(:worker_reservations, &migrate_worker_reservations(&1, context))
      |> migrate_phase(:tenants, &migrate_tenants(&1, context))
      |> migrate_phase(:groups, &migrate_groups(&1, context))
      |> migrate_phase(:agents, &migrate_agents(&1, context))
      |> migrate_phase(:timers, &migrate_timer_keys(&1, context))
      |> migrate_phase(:rewrite_ctl, &rewrite_prefix(&1, "ctl/", context))
      |> migrate_phase(:rewrite_meet, &rewrite_prefix(&1, "meet/", context))
      |> migrate_phase(:rewrite_comma, &rewrite_prefix(&1, "comma/", context))

    refresh_inventory!(inventory)

    migrate_phase(stats, :verification, fn current ->
      verify_migration!(context)
      current
    end)

    case HierarchyIdMigration.mark_phase_complete(:s3, identity) do
      :ok -> :ok
      {:error, reason} -> abort({:mark_s3_completion_failed, reason})
    end

    CommaLog.log("migrate_salix_hierarchy_identity", stats)
    {:ok, stats}
  end

  defp load_seed!(:s3_only) do
    case HierarchyIdMigration.read() do
      {:ok, identity} -> identity
      {:error, :not_found} -> HierarchyIdMigration.empty()
      {:error, reason} -> abort({:read_identity_map_failed, reason})
    end
  end

  defp load_seed!(identity) when is_map(identity) do
    case HierarchyIdMigration.reserve(identity) do
      {:ok, reserved} -> reserved
      {:error, reason} -> abort({:reserve_bft_identity_seed_failed, reason})
    end
  end

  defp load_seed!(source), do: abort({:invalid_identity_seed, source})

  defp collect_identity!(seed, inventory) do
    comma_workspaces = collect_comma_workspaces!(inventory)
    group_owner_hints = collect_group_owner_hints!(inventory)
    tenants = collect_tenants!(seed.tenants, comma_workspaces, group_owner_hints, inventory)

    groups =
      collect_groups!(tenants, seed.groups, comma_workspaces, group_owner_hints, inventory)

    agents = collect_agents!(tenants, groups, seed.agents, comma_workspaces, inventory)

    %{
      identity: %{tenants: tenants.mappings, groups: groups.mappings, agents: agents.mappings},
      agent_records: agents.records,
      inventory: inventory
    }
  end

  defp collect_group_owner_hints!(inventory) do
    list_keys!("ctl/", inventory)
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> parallel_flat_map(fn key ->
      value = key |> S3.get() |> read_json_value!(key)

      if is_map(value) do
        tenant_id = trim(map_field(value, "tenant_id"))
        group_id = trim(map_field(value, "group_id"))

        if tenant_id != "" and group_id != "" do
          [%{key: key, tenant_id: tenant_id, group_id: group_id}]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp collect_comma_workspaces!(inventory) do
    list_keys!("comma/workspaces/", inventory)
    |> parallel_map(fn key ->
      record = key |> S3.get() |> read_json_object!(key)

      tenant_id = trim(record["salix_tenant_id"])
      group_id = trim(record["default_group_id"])
      agent_id = trim(record["default_agent_id"])

      require!(tenant_id != "", {:comma_workspace_tenant_missing, key})
      require!(group_id != "", {:comma_workspace_group_missing, key})
      require!(agent_id != "", {:comma_workspace_agent_missing, key})

      %{key: key, tenant_id: tenant_id, group_id: group_id, agent_id: agent_id}
    end)
  end

  defp collect_tenants!(mappings, comma_workspaces, group_owner_hints, inventory) do
    state = mapping_state(mappings)

    result =
      list_keys!(Keys.ctl_tenants_prefix(), inventory)
      |> Enum.flat_map(&parse_key(&1, @tenant_key))
      |> Enum.reduce(%{state: state, records: %{}}, fn source, acc ->
        record = read_json!(Keys.ctl_tenant(source))
        require!(record["tenant_id"] == source, {:tenant_record_identity_mismatch, source})

        {target, state} =
          canonical_id(acc.state, source, &Ids.valid_tenant_id?/1, &Ids.new_tenant_id/0)

        %{state: state, records: Map.put(acc.records, source, %{record: record, target: target})}
      end)

    result =
      Enum.reduce(comma_workspaces, result, fn workspace, acc ->
        {_, state} =
          canonical_id(
            acc.state,
            workspace.tenant_id,
            &Ids.valid_tenant_id?/1,
            &Ids.new_tenant_id/0
          )

        %{acc | state: state}
      end)

    group_owner_hints
    |> Enum.reduce(result, fn hint, acc ->
      {_, state} =
        canonical_id(
          acc.state,
          hint.tenant_id,
          &Ids.valid_tenant_id?/1,
          &Ids.new_tenant_id/0
        )

      %{acc | state: state}
    end)
    |> then(&%{mappings: &1.state.mappings, records: &1.records, targets: &1.state.targets})
  end

  defp collect_groups!(tenants, mappings, comma_workspaces, group_owner_hints, inventory) do
    state = mapping_state(mappings)

    result =
      list_keys!(Keys.ctl_groups_prefix(), inventory)
      |> Enum.flat_map(&parse_key(&1, @group_key))
      |> Enum.reduce(%{state: state, records: %{}}, fn source, acc ->
        record = read_json!(Keys.ctl_group(source))
        require!(record["group_id"] == source, {:group_record_identity_mismatch, source})
        source_tenant = trim(record["tenant_id"])

        target_tenant =
          canonical_parent!(source_tenant, tenants.mappings, &Ids.valid_tenant_id?/1)

        {target, state} =
          canonical_id(
            acc.state,
            source,
            &Ids.valid_group_id_for_tenant?(&1, target_tenant),
            fn -> Ids.new_group_id(target_tenant) end
          )

        entry = %{
          record: record,
          target: target,
          source_tenant: source_tenant,
          target_tenant: target_tenant
        }

        %{state: state, records: Map.put(acc.records, source, entry)}
      end)

    result =
      Enum.reduce(comma_workspaces, result, fn workspace, acc ->
        collect_group_identity!(acc, workspace.tenant_id, workspace.group_id, tenants)
      end)

    group_owner_hints
    |> Enum.reduce(result, fn hint, acc ->
      collect_group_identity!(acc, hint.tenant_id, hint.group_id, tenants)
    end)
    |> then(&%{mappings: &1.state.mappings, records: &1.records, targets: &1.state.targets})
  end

  defp collect_group_identity!(acc, source_tenant, source_group, tenants) do
    target_tenant =
      canonical_parent!(source_tenant, tenants.mappings, &Ids.valid_tenant_id?/1)

    {_, state} =
      canonical_id(
        acc.state,
        source_group,
        &Ids.valid_group_id_for_tenant?(&1, target_tenant),
        fn -> Ids.new_group_id(target_tenant) end
      )

    %{acc | state: state}
  end

  defp collect_agents!(tenants, groups, mappings, comma_workspaces, inventory) do
    state = mapping_state(mappings)

    result =
      list_keys!(Keys.ctl_agents_prefix(), inventory)
      |> Enum.flat_map(&parse_key(&1, @agent_key))
      |> Enum.reduce(%{state: state, records: %{}}, fn source, acc ->
        record = read_json!(Keys.ctl_agent(source))
        require!(record["agent_id"] == source, {:agent_record_identity_mismatch, source})

        source_tenant = trim(record["tenant_id"])
        source_group = trim(record["group_id"])

        target_tenant =
          canonical_parent!(source_tenant, tenants.mappings, &Ids.valid_tenant_id?/1)

        target_group =
          canonical_parent!(
            source_group,
            groups.mappings,
            &Ids.valid_group_id_for_tenant?(&1, target_tenant)
          )

        group_record = Map.get(groups.records, source_group)

        if group_record do
          require!(
            group_record.target == target_group and group_record.target_tenant == target_tenant,
            {:agent_group_parent_mismatch, source, source_group}
          )
        end

        {target, state} =
          canonical_id(
            acc.state,
            source,
            &Ids.valid_agent_id_for_group?(&1, target_group),
            fn -> Ids.new_agent_id(target_group) end
          )

        entry = %{
          record: record,
          target: target,
          source_tenant: source_tenant,
          target_tenant: target_tenant,
          source_group: source_group,
          target_group: target_group
        }

        %{state: state, records: Map.put(acc.records, source, entry)}
      end)

    comma_workspaces
    |> Enum.reduce(result, fn workspace, acc ->
      target_tenant =
        canonical_parent!(workspace.tenant_id, tenants.mappings, &Ids.valid_tenant_id?/1)

      target_group =
        canonical_parent!(
          workspace.group_id,
          groups.mappings,
          &Ids.valid_group_id_for_tenant?(&1, target_tenant)
        )

      {_, state} =
        canonical_id(
          acc.state,
          workspace.agent_id,
          &Ids.valid_agent_id_for_group?(&1, target_group),
          fn -> Ids.new_agent_id(target_group) end
        )

      %{acc | state: state}
    end)
    |> then(&%{mappings: &1.state.mappings, records: &1.records, targets: &1.state.targets})
  end

  defp mapping_state(mappings) do
    %{mappings: mappings, targets: MapSet.new(Map.values(mappings))}
  end

  defp canonical_id(state, source, valid?, generate) do
    case Map.fetch(state.mappings, source) do
      {:ok, target} ->
        require!(valid?.(target), {:reserved_identity_parent_mismatch, source, target})
        {target, state}

      :error ->
        cond do
          MapSet.member?(state.targets, source) ->
            require!(valid?.(source), {:reserved_identity_target_invalid, source})
            {source, state}

          valid?.(source) ->
            {source,
             %{
               mappings: Map.put(state.mappings, source, source),
               targets: MapSet.put(state.targets, source)
             }}

          true ->
            target = fresh_target(state.targets, generate)

            {target,
             %{
               mappings: Map.put(state.mappings, source, target),
               targets: MapSet.put(state.targets, target)
             }}
        end
    end
  end

  defp fresh_target(targets, generate) do
    target = generate.()
    if MapSet.member?(targets, target), do: fresh_target(targets, generate), else: target
  end

  defp canonical_parent!(source, mappings, valid?) do
    target = Map.get(mappings, source, source)
    require!(source != "" and valid?.(target), {:invalid_parent_identity, source, target})
    target
  end

  defp migrate_worker_reservations(stats, context) do
    Enum.reduce(context.agent_records, stats, fn {source, entry}, acc ->
      case Regex.run(@worker_source, source) do
        [_, identity_hash] ->
          migrate_worker_reservation(acc, source, entry, identity_hash, context)

        _ ->
          acc
      end
    end)
  end

  defp migrate_worker_reservation(stats, source, entry, identity_hash, context) do
    worker_type = worker_type!(entry.record, source)
    key = Keys.ctl_agent_worker_tool_idempotency(entry.target_group, identity_hash)

    reservation = %{
      "agent_id" => entry.target,
      "group_id" => entry.target_group,
      "worker_type" => worker_type,
      "idempotency_hash" => identity_hash,
      "created_at" => entry.record["created_at"] || System.system_time(:second)
    }

    stats = put_create_once_json(stats, key, reservation, context.inventory)
    put_agent_provenance(stats, source, entry.target, identity_hash)
  end

  defp worker_type!(%{"role" => "worker", "runtime_config" => %{"kind" => "internal"}}, _source),
    do: "internal"

  defp worker_type!(
         %{
           "role" => "worker",
           "runtime_config" => %{"kind" => "external", "provider" => "codex"}
         },
         _source
       ),
       do: "external"

  defp worker_type!(record, source) do
    runtime = record["runtime_config"] || %{"kind" => "internal"}

    if record["role"] == "worker" and runtime["kind"] == "internal" do
      "internal"
    else
      abort({:invalid_tool_created_worker, source})
    end
  end

  defp put_agent_provenance(stats, source, target, identity_hash) do
    [Keys.ctl_agent(source), Keys.ctl_agent(target)]
    |> Enum.uniq()
    |> Enum.find_value(fn key ->
      case S3.get(key) do
        {:ok, object} -> {key, object}
        {:error, :not_found} -> nil
        {:error, reason} -> abort({:read_worker_provenance_failed, key, reason})
      end
    end)
    |> case do
      nil ->
        abort({:worker_control_record_missing, source, target})

      {key, %{body: body, etag: etag}} ->
        record = decode_json!(key, body)

        case record["source_worker_tool_idempotency_hash"] do
          ^identity_hash ->
            unchanged(stats)

          value when value in [nil, ""] ->
            put_json(
              stats,
              key,
              Map.put(record, "source_worker_tool_idempotency_hash", identity_hash),
              etag
            )

          other ->
            abort({:worker_provenance_conflict, source, other, identity_hash})
        end
    end
  end

  defp migrate_tenants(stats, context) do
    parallel_stats(context.identity.tenants, stats, fn {source, target} ->
      zero_stats()
      |> move(Keys.ctl_tenant(source), Keys.ctl_tenant(target), context)
      |> move_prefix("ctl/initial_agents/#{source}/", "ctl/initial_agents/#{target}/", context)
      |> move_prefix("ctl/tenant_api_keys/#{source}/", "ctl/tenant_api_keys/#{target}/", context)
      |> move_prefix("ctl/tenant_configs/#{source}/", "ctl/tenant_configs/#{target}/", context)
      |> move_prefix("ctl/tenants/#{source}/", "ctl/tenants/#{target}/", context)
      |> move_prefix(
        "ctl/oauth/provider_apps/#{source}/",
        "ctl/oauth/provider_apps/#{target}/",
        context
      )
      |> move(
        "ctl/feishu/tenant_apps/#{source}.json",
        "ctl/feishu/tenant_apps/#{target}.json",
        context
      )
      |> move(
        "ctl/composio/tenants/#{source}.json",
        "ctl/composio/tenants/#{target}.json",
        context
      )
      |> move_skill_catalog(:tenant, source, target, context)
      |> move_prefix("ctl/bridge/#{source}/", "ctl/bridge/#{target}/", context)
      |> move_prefix("ctl/bridge/cursors/#{source}/", "ctl/bridge/cursors/#{target}/", context)
    end)
  end

  defp migrate_groups(stats, context) do
    stats =
      parallel_stats(context.identity.groups, stats, fn {source, target} ->
        zero_stats()
        |> move_group_record(source, target, context)
        |> move_prefix("ctl/im_connects/#{source}/", "ctl/im_connects/#{target}/", context)
        |> move_prefix(
          "ctl/oauth/group_bindings/#{source}/",
          "ctl/oauth/group_bindings/#{target}/",
          context
        )
        |> move_prefix(
          "ctl/group_conversations/#{source}/",
          "ctl/group_conversations/#{target}/",
          context
        )
        |> move_prefix(
          "ctl/group_conversation_list/#{source}/",
          "ctl/group_conversation_list/#{target}/",
          context
        )
        |> move_prefix(
          "ctl/group_conversation_delivery_wakeups/#{source}/",
          "ctl/group_conversation_delivery_wakeups/#{target}/",
          context
        )
        |> move_prefix(
          "ctl/conversation_pins/#{Crypto.hex(source)}/",
          "ctl/conversation_pins/#{Crypto.hex(target)}/",
          context
        )
        |> move_prefix(
          "ctl/capability_requests/#{source}/",
          "ctl/capability_requests/#{target}/",
          context
        )
        |> move_prefix("ctl/envs_by_group/#{source}/", "ctl/envs_by_group/#{target}/", context)
        |> move_prefix(
          "ctl/agent_worker_tool_idempotency/#{source}/",
          "ctl/agent_worker_tool_idempotency/#{target}/",
          context
        )
        |> move_vm_record(source, target, context)
        |> move("ctl/sprites/#{source}.json", "ctl/sprites/#{target}.json", context)
        |> move("ctl/meeting_agents/#{source}.json", "ctl/meeting_agents/#{target}.json", context)
        |> move_prefix("meet/sources/slack/#{source}/", "meet/sources/slack/#{target}/", context)
        |> move_skill_catalog(:group, source, target, context)
      end)

    parallel_stats(context.identity.groups, stats, fn {source, target} ->
      target_tenant = target_tenant_from_group!(target)
      old_prefix = "ctl/tenants/#{target_tenant}/groups/#{source}/"
      new_prefix = "ctl/tenants/#{target_tenant}/groups/#{target}/"
      move_prefix(zero_stats(), old_prefix, new_prefix, context)
    end)
  end

  defp migrate_agents(stats, context) do
    stats =
      context.identity.agents
      |> Enum.flat_map(fn {source, target} ->
        source_prefix = "agents/#{source}/"

        list_keys!(source_prefix, context.inventory)
        |> Enum.map(fn key ->
          {key, String.replace_prefix(key, source_prefix, "agents/#{target}/")}
        end)
      end)
      |> parallel_stats(stats, fn {source, target} ->
        move(zero_stats(), source, target, context)
      end)

    parallel_stats(context.identity.agents, stats, fn {source, target} ->
      zero_stats()
      |> move_agent_record(source, target, context)
      |> move(
        "sitedocs/#{source}/ns.json",
        "sitedocs/#{target}/ns.json",
        context
      )
      |> move_prefix_raw(
        "sitedocs/#{source}/sites/",
        "sitedocs/#{target}/sites/",
        context
      )
      |> move_prefix(
        "ctl/site_llm_billing/#{source}/",
        "ctl/site_llm_billing/#{target}/",
        context
      )
      |> move(
        "ctl/agent_billing_state/#{source}.json",
        "ctl/agent_billing_state/#{target}.json",
        context
      )
      |> move_skill_catalog(:agent, source, target, context)
      # Historical staged-protocol layout (retired from Keys, A2 §3.4): this
      # migration transforms pre-cutover buckets, so it keeps the literal.
      |> move(legacy_queue_marker(source), legacy_queue_marker(target), context)
      |> move(
        "ctl/schedule_heartbeats/#{source}.json",
        "ctl/schedule_heartbeats/#{target}.json",
        context
      )
      |> move_suffixes("ctl/recent/", source, target, context)
      |> move_suffixes("ctl/leases/", source, target, context)
    end)
  end

  defp legacy_queue_marker(agent_id),
    do: "ctl/queue/#{Crypto.shard(agent_id)}/#{agent_id}"

  defp move_group_record(stats, source_group_id, target_group_id, context) do
    source = Keys.ctl_group(source_group_id)
    target = Keys.ctl_group(target_group_id)

    move_enriched_json(stats, source, target, context, fn record ->
      # Conversation aggregate identity owns this deterministic legacy value;
      # hierarchy migration only preserves the pre-existing router conversation.
      put_nonblank(record, "router_conversation_id", "router-" <> source_group_id)
    end)
  end

  defp move_agent_record(stats, source_agent_id, target_agent_id, context) do
    source = Keys.ctl_agent(source_agent_id)
    target = Keys.ctl_agent(target_agent_id)

    move_enriched_json(stats, source, target, context, fn record ->
      record
      |> put_nonblank("heartbeat_schedule_id", "heartbeat-" <> source_agent_id)
      |> maybe_put_legacy_router_session(source_agent_id)
    end)
  end

  defp maybe_put_legacy_router_session(
         %{"role" => "router", "group_id" => source_group_id} = record,
         source_agent_id
       ) do
    put_nonblank(
      record,
      "router_session_id",
      legacy_router_session_id(source_agent_id, source_group_id)
    )
  end

  defp maybe_put_legacy_router_session(record, _source_agent_id), do: record

  defp legacy_router_session_id(router_agent_id, group_id) do
    # This value exists only to let the following session_identity migration
    # inventory and rewrite the historical router session deterministically.
    joined =
      ["router-session-v1", String.trim(router_agent_id), String.trim(group_id)]
      |> Enum.join(<<0>>)

    digest = :crypto.hash(:sha256, joined) |> Base.encode16(case: :lower)
    "router-" <> binary_part(digest, 0, 32)
  end

  defp move_enriched_json(stats, source, target, context, enrich) do
    case S3.get(source) do
      {:ok, %{body: body, etag: etag}} ->
        record = source |> decode_json!(body) |> enrich.() |> rewrite_term(context.identity)

        move_or_rewrite_loaded(
          stats,
          source,
          target,
          body,
          encode_json(record),
          etag,
          context.inventory
        )

      {:error, :not_found} ->
        unchanged(stats)

      {:error, reason} ->
        abort({:read_owner_record_failed, source, reason})
    end
  end

  defp move_vm_record(stats, source_group_id, target_group_id, context) do
    source = Keys.ctl_vm(source_group_id)
    target = Keys.ctl_vm(target_group_id)

    case S3.get(source) do
      {:ok, %{body: body, etag: etag}} ->
        record = decode_json!(source, body)

        record =
          record
          |> put_nonblank("env_id", RuntimeIds.cloud_vm_env_id(source_group_id))
          |> put_nonblank("device_id", RuntimeIds.cloud_vm_device_id(source_group_id))
          |> put_nonblank("connector_id", RuntimeIds.cloud_vm_connector_id(source_group_id))
          |> put_nonblank(
            "provider_resource_name",
            RuntimeIds.cloud_vm_provider_resource_name(source_group_id)
          )
          |> put_nonblank(
            "provider_resource_id",
            RuntimeIds.cloud_vm_provider_resource_name(source_group_id)
          )
          |> rewrite_term(context.identity)

        move_or_rewrite_loaded(
          stats,
          source,
          target,
          body,
          encode_json(record),
          etag,
          context.inventory
        )

      {:error, :not_found} ->
        unchanged(stats)

      {:error, reason} ->
        abort({:read_vm_record_failed, source, reason})
    end
  end

  defp migrate_timer_keys(stats, context) do
    list_keys!("ctl/timers/", context.inventory)
    |> parallel_stats(stats, fn key ->
      case S3.get(key) do
        {:ok, %{body: body, etag: etag}} ->
          record = decode_json!(key, body)
          rewritten = rewrite_term(record, context.identity)

          with %{
                 "agent_id" => agent_id,
                 "session_id" => session_id,
                 "timer_id" => timer_id,
                 "deadline_ms" => deadline_ms
               }
               when is_binary(agent_id) and is_binary(session_id) and is_binary(timer_id) and
                      is_integer(deadline_ms) <- rewritten do
            target = Keys.timer(agent_id, session_id, timer_id, Timers.minute_bucket(deadline_ms))

            move_or_rewrite_loaded(
              zero_stats(),
              key,
              target,
              body,
              encode_json(rewritten),
              etag,
              context.inventory
            )
          else
            _ -> abort({:invalid_timer_record, key})
          end

        {:error, :not_found} ->
          unchanged(zero_stats())

        {:error, reason} ->
          abort({:read_timer_failed, key, reason})
      end
    end)
  end

  defp move_prefix(stats, source_prefix, target_prefix, context) do
    list_keys!(source_prefix, context.inventory)
    |> Enum.reduce(stats, fn key, acc ->
      target = String.replace_prefix(key, source_prefix, target_prefix)
      move(acc, key, target, context)
    end)
  end

  defp move_prefix_raw(stats, source_prefix, target_prefix, context) do
    list_keys!(source_prefix, context.inventory)
    |> Enum.reduce(stats, fn key, acc ->
      target = String.replace_prefix(key, source_prefix, target_prefix)
      move_raw(acc, key, target, context)
    end)
  end

  defp move_suffixes(stats, prefix, source, target, context) do
    list_keys!(prefix, context.inventory)
    |> Enum.reduce(stats, fn key, acc ->
      if String.ends_with?(key, "/" <> source) do
        move(acc, key, String.replace_suffix(key, "/" <> source, "/" <> target), context)
      else
        acc
      end
    end)
  end

  defp rewrite_prefix(stats, prefix, context) do
    list_keys!(prefix, context.inventory)
    |> parallel_stats(stats, fn key -> move(zero_stats(), key, key, context) end)
  end

  defp verify_migration!(context) do
    verify_tenant_records!(context)
    verify_group_records!(context)
    verify_agent_records!(context)
    verify_vm_records!(context)
    verify_comma_workspaces!(context)
    verify_site_doc_namespaces!(context)

    Enum.each(["ctl/", "meet/", "comma/", "agents/"], fn prefix ->
      verify_rewritten_prefix!(prefix, context)
    end)
  end

  defp verify_tenant_records!(context) do
    list_keys!(Keys.ctl_tenants_prefix(), context.inventory)
    |> Enum.flat_map(&parse_key(&1, @tenant_key))
    |> parallel_each(fn tenant_id ->
      record = read_json!(Keys.ctl_tenant(tenant_id))

      require!(
        Ids.valid_tenant_id?(tenant_id) and record["tenant_id"] == tenant_id,
        {:invalid_canonical_tenant_record, tenant_id}
      )
    end)
  end

  defp verify_group_records!(context) do
    list_keys!(Keys.ctl_groups_prefix(), context.inventory)
    |> Enum.flat_map(&parse_key(&1, @group_key))
    |> parallel_each(fn group_id ->
      record = read_json!(Keys.ctl_group(group_id))
      tenant_id = trim(record["tenant_id"])

      require!(
        record["group_id"] == group_id and
          Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
          nonblank?(record["router_conversation_id"]),
        {:invalid_canonical_group_record, group_id, tenant_id}
      )
    end)
  end

  defp verify_agent_records!(context) do
    list_keys!(Keys.ctl_agents_prefix(), context.inventory)
    |> Enum.flat_map(&parse_key(&1, @agent_key))
    |> parallel_each(fn agent_id ->
      record = read_json!(Keys.ctl_agent(agent_id))
      tenant_id = trim(record["tenant_id"])
      group_id = trim(record["group_id"])

      require!(
        record["agent_id"] == agent_id and
          Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
          Ids.valid_agent_id_for_group?(agent_id, group_id) and
          nonblank?(record["heartbeat_schedule_id"]) and
          (record["role"] != "router" or nonblank?(record["router_session_id"])),
        {:invalid_canonical_agent_record, agent_id, tenant_id, group_id}
      )
    end)
  end

  defp verify_vm_records!(context) do
    list_keys!(Keys.ctl_vms_prefix(), context.inventory)
    |> parallel_each(fn key ->
      record = read_json!(key)
      group_id = trim(record["group_id"])

      require!(
        key == Keys.ctl_vm(group_id) and
          Ids.valid_group_id?(group_id) and
          Enum.all?(
            [
              "env_id",
              "device_id",
              "connector_id",
              "provider_resource_name",
              "provider_resource_id"
            ],
            &nonblank?(record[&1])
          ),
        {:invalid_canonical_vm_record, key, group_id}
      )
    end)
  end

  defp verify_comma_workspaces!(context) do
    collect_comma_workspaces!(context.inventory)
    |> parallel_each(fn workspace ->
      require!(
        Ids.valid_tenant_id?(workspace.tenant_id),
        {:legacy_comma_tenant_remains, workspace.key}
      )

      require!(
        Ids.valid_group_id_for_tenant?(workspace.group_id, workspace.tenant_id),
        {:legacy_comma_group_remains, workspace.key}
      )

      require!(
        Ids.valid_agent_id_for_group?(workspace.agent_id, workspace.group_id),
        {:legacy_comma_agent_remains, workspace.key}
      )
    end)
  end

  defp verify_site_doc_namespaces!(context) do
    list_keys!("sitedocs/", context.inventory)
    |> Enum.filter(&String.ends_with?(&1, "/ns.json"))
    |> parallel_each(fn key ->
      case S3.get(key) do
        {:ok, %{body: body}} ->
          require!(
            equivalent_body?(key, rewrite_body(key, body, context.identity), body),
            {:legacy_site_doc_namespace_remains, key}
          )

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          abort({:verify_read_failed, key, reason})
      end
    end)
  end

  defp verify_rewritten_prefix!(prefix, context) do
    list_keys!(prefix, context.inventory)
    |> parallel_each(fn key ->
      case S3.get(key) do
        {:ok, %{body: body}} ->
          require!(
            equivalent_body?(key, rewrite_body(key, body, context.identity), body),
            {:legacy_identity_reference_remains, key}
          )

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          abort({:verify_read_failed, key, reason})
      end
    end)
  end

  defp move(stats, source, target, context) do
    case S3.get(source) do
      {:ok, %{body: body, etag: etag}} ->
        move_or_rewrite_loaded(
          stats,
          source,
          target,
          body,
          rewrite_body(source, body, context.identity),
          etag,
          context.inventory
        )

      {:error, :not_found} ->
        unchanged(stats)

      {:error, reason} ->
        abort({:read_source_failed, source, reason})
    end
  end

  # An interrupted older migration may have written the destination snapshot
  # with a legacy payload scope while retaining the source object. Repair the
  # destination first so the subsequent create-once move can compare equal and
  # safely finish the conditional source delete.
  defp move_skill_catalog(stats, layer, source, target, context) do
    source_key = skill_catalog_key(layer, source)
    target_key = skill_catalog_key(layer, target)

    stats
    |> move(target_key, target_key, context)
    |> move(source_key, target_key, context)
  end

  defp skill_catalog_key(:tenant, id), do: Keys.ctl_skill_scope_tenant(id)
  defp skill_catalog_key(:group, id), do: Keys.ctl_skill_scope_group(id)
  defp skill_catalog_key(:agent, id), do: Keys.ctl_skill_scope_agent(id)

  defp move_raw(stats, source, target, context) do
    case S3.get(source) do
      {:ok, %{body: body, etag: etag}} ->
        move_or_rewrite_loaded(stats, source, target, body, body, etag, context.inventory)

      {:error, :not_found} ->
        unchanged(stats)

      {:error, reason} ->
        abort({:read_source_failed, source, reason})
    end
  end

  defp move_or_rewrite_loaded(stats, key, key, current, rewritten, etag, _inventory) do
    if equivalent_body?(key, current, rewritten),
      do: unchanged(stats),
      else: put_body(stats, key, rewritten, etag)
  end

  defp move_or_rewrite_loaded(
         stats,
         source,
         target,
         _current,
         body,
         source_etag,
         inventory
       ) do
    case S3.put(target, body, if_none_match: "*") do
      {:ok, _} ->
        delete_source(stats, source, target, source_etag, inventory)

      {:error, :precondition_failed} ->
        case S3.get(target) do
          {:ok, %{body: ^body}} ->
            delete_source(stats, source, target, source_etag, inventory)

          {:ok, %{body: current}} ->
            if equivalent_body?(target, current, body),
              do: delete_source(stats, source, target, source_etag, inventory),
              else: abort({:migration_target_collision, source, target})

          {:error, reason} ->
            abort({:read_target_failed, target, reason})
        end

      {:error, {:ambiguous, _}} ->
        case S3.get(target) do
          {:ok, %{body: ^body}} ->
            delete_source(stats, source, target, source_etag, inventory)

          {:ok, %{body: current}} ->
            if equivalent_body?(target, current, body),
              do: delete_source(stats, source, target, source_etag, inventory),
              else: abort({:migration_target_collision, source, target})

          {:error, reason} ->
            abort({:ambiguous_target_write, target, reason})
        end

      {:error, reason} ->
        abort({:write_target_failed, target, reason})
    end
  end

  defp delete_source(stats, source, target, etag, inventory) do
    case S3.delete(source, if_match: etag) do
      :ok ->
        move_inventory(stats, inventory, source, target)

      {:error, :not_found} ->
        move_inventory(stats, inventory, source, target)

      {:error, {:ambiguous, _}} ->
        case S3.get(source) do
          {:error, :not_found} -> move_inventory(stats, inventory, source, target)
          {:ok, _} -> abort({:ambiguous_source_delete, source, target})
          {:error, reason} -> abort({:verify_source_delete_failed, source, target, reason})
        end

      {:error, reason} ->
        abort({:delete_source_failed, source, target, reason})
    end
  end

  defp put_create_once_json(stats, key, record, inventory) do
    body = encode_json(record)

    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} ->
        add_inventory(stats, inventory, key, :migrated)

      {:error, :precondition_failed} ->
        case S3.get(key) do
          {:ok, %{body: ^body}} -> add_inventory(stats, inventory, key, :unchanged)
          {:ok, _} -> abort({:migration_target_collision, key})
          {:error, reason} -> abort({:read_target_failed, key, reason})
        end

      {:error, {:ambiguous, _}} ->
        case S3.get(key) do
          {:ok, %{body: ^body}} -> add_inventory(stats, inventory, key, :migrated)
          {:ok, _} -> abort({:migration_target_collision, key})
          {:error, reason} -> abort({:ambiguous_target_write, key, reason})
        end

      {:error, reason} ->
        abort({:write_target_failed, key, reason})
    end
  end

  defp put_json(stats, key, record, etag), do: put_body(stats, key, encode_json(record), etag)

  defp put_body(stats, key, body, etag) do
    case S3.put(key, body, if_match: etag) do
      {:ok, _} ->
        migrated(stats)

      {:error, {:ambiguous, _}} ->
        case S3.get(key) do
          {:ok, %{body: ^body}} -> migrated(stats)
          {:ok, _} -> abort({:ambiguous_rewrite_mismatch, key})
          {:error, reason} -> abort({:ambiguous_rewrite_failed, key, reason})
        end

      {:error, reason} ->
        abort({:rewrite_failed, key, reason})
    end
  end

  defp rewrite_body(key, body, identity) do
    cond do
      String.starts_with?(key, "comma/") ->
        case Jason.decode(body) do
          {:ok, value} -> value |> rewrite_term(identity) |> encode_json()
          {:error, reason} -> abort({:decode_failed, key, reason})
        end

      String.ends_with?(key, ".json") ->
        key |> decode_json_value!(body) |> rewrite_term(identity) |> encode_json()

      String.ends_with?(key, ".jsonl") ->
        body
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.map(fn {line, line_number} ->
          case Jason.decode(line) do
            {:ok, value} -> value |> rewrite_term(identity) |> encode_json()
            {:error, reason} -> abort({:decode_failed, key, {:jsonl, line_number}, reason})
          end
        end)
        |> Enum.join("\n")

      String.ends_with?(key, ".etf.zst") ->
        try do
          body
          |> Codec.decode_snapshot()
          |> rewrite_term(identity)
          |> rewrite_skill_catalog_scope(key, identity)
          |> Codec.encode_snapshot()
        rescue
          error -> abort({:decode_failed, key, :snapshot, Exception.message(error)})
        end

      true ->
        body
    end
  end

  defp equivalent_body?(_key, left, right) when left == right, do: true

  defp equivalent_body?(key, left, right) do
    cond do
      String.starts_with?(key, "comma/") or String.ends_with?(key, ".json") ->
        decoded_json(left) == decoded_json(right)

      String.ends_with?(key, ".jsonl") ->
        decoded_jsonl(left) == decoded_jsonl(right)

      String.ends_with?(key, ".etf.zst") ->
        decoded_snapshot(left) == decoded_snapshot(right)

      true ->
        false
    end
  end

  defp decoded_json(body) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp decoded_jsonl(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  defp decoded_snapshot(body) do
    {:ok, Codec.decode_snapshot(body)}
  rescue
    _error -> :error
  end

  # Skill catalog snapshots redundantly persist their owner scope. The owner
  # key supplies the missing semantic context for the nested field named only
  # `id`; the generic field rewriter must not guess that every `id` is a
  # tenant/group/agent identity.
  defp rewrite_skill_catalog_scope(snapshot, key, identity) do
    case String.split(key, "/") do
      ["ctl", "skills", "global", "state.etf.zst"] ->
        put_snapshot_scope(snapshot, %{"layer" => "global"})

      ["ctl", "skills", "tenants", id, "state.etf.zst"] ->
        put_snapshot_scope(snapshot, %{
          "layer" => "tenant",
          "id" => Map.get(identity.tenants, id, id)
        })

      ["ctl", "skills", "groups", id, "state.etf.zst"] ->
        put_snapshot_scope(snapshot, %{
          "layer" => "group",
          "id" => Map.get(identity.groups, id, id)
        })

      ["ctl", "skills", "agents", id, "state.etf.zst"] ->
        put_snapshot_scope(snapshot, %{
          "layer" => "agent",
          "id" => Map.get(identity.agents, id, id)
        })

      _ ->
        snapshot
    end
  end

  defp put_snapshot_scope(%{__struct__: _module} = snapshot, scope),
    do: Map.put(snapshot, :scope, scope)

  defp put_snapshot_scope(%{"scope" => _current} = snapshot, scope),
    do: Map.put(snapshot, "scope", scope)

  defp put_snapshot_scope(%{scope: _current} = snapshot, scope),
    do: Map.put(snapshot, :scope, scope)

  defp put_snapshot_scope(snapshot, scope) when is_map(snapshot),
    do: Map.put(snapshot, "scope", scope)

  defp put_snapshot_scope(snapshot, _scope), do: snapshot

  defp rewrite_term(%MapSet{} = value, _identity), do: value

  defp rewrite_term(%{__struct__: module} = value, identity) do
    fields = value |> Map.from_struct() |> rewrite_term(identity)
    Map.put(fields, :__struct__, module)
  end

  defp rewrite_term(value, identity) when is_map(value) do
    Map.new(value, fn {key, field_value} ->
      key_name = to_string(key)
      rewritten = rewrite_field(key_name, field_value, value, identity)
      {key, rewritten}
    end)
  end

  defp rewrite_term(value, identity) when is_list(value),
    do: Enum.map(value, &rewrite_term(&1, identity))

  defp rewrite_term(value, identity) when is_tuple(value),
    do: value |> Tuple.to_list() |> rewrite_term(identity) |> List.to_tuple()

  defp rewrite_term(value, _identity), do: value

  defp rewrite_field(key, value, record, identity) do
    cond do
      tenant_field?(key) ->
        rewrite_identity_value(value, identity.tenants, identity)

      group_field?(key) ->
        rewrite_identity_value(value, identity.groups, identity)

      key == "product_owner_id" and trim(map_field(record, "product_owner_type")) == "group" ->
        rewrite_identity_value(value, identity.groups, identity)

      agent_field?(key) ->
        rewrite_identity_value(value, identity.agents, identity)

      key == "db_namespace" ->
        rewrite_db_namespace(value, identity.agents)

      key == "doc_namespace" ->
        rewrite_doc_namespace(value, identity.agents)

      key == "config" ->
        rewrite_config(value, identity)

      key in ["resource_id", "correlation_id"] ->
        rewrite_embedded(value, identity)

      true ->
        rewrite_term(value, identity)
    end
  end

  defp rewrite_doc_namespace(value, agents) when is_binary(value) do
    Enum.reduce(agents, value, fn {source, target}, current ->
      String.replace_prefix(current, "site_#{source}_", "site_#{target}_")
    end)
  end

  defp rewrite_doc_namespace(value, _agents), do: value

  defp tenant_field?(key),
    do:
      key in ["tenant", "tenant_id", "tenant_ids"] or String.ends_with?(key, "_tenant_id") or
        String.ends_with?(key, "_tenant_ids")

  defp group_field?(key),
    do:
      key in ["group", "group_id", "group_ids", "agent_group_id"] or
        String.ends_with?(key, "_group_id") or String.ends_with?(key, "_group_ids")

  defp agent_field?(key),
    do:
      key != "bft_agent_id" and
        (key in ["agent_id", "agent_ids"] or String.ends_with?(key, "_agent_id") or
           String.ends_with?(key, "_agent_ids"))

  defp rewrite_identity_value(value, mappings, _identity) when is_binary(value),
    do: Map.get(mappings, value, value)

  defp rewrite_identity_value(values, mappings, identity) when is_list(values),
    do: Enum.map(values, &rewrite_identity_value(&1, mappings, identity))

  defp rewrite_identity_value(%MapSet{} = values, mappings, identity),
    do: values |> Enum.map(&rewrite_identity_value(&1, mappings, identity)) |> MapSet.new()

  defp rewrite_identity_value(values, mappings, identity) when is_map(values) do
    Enum.reduce(values, %{}, fn {key, value}, acc ->
      next_key = rewrite_identity_value(key, mappings, identity)
      next_value = rewrite_identity_value(value, mappings, identity)

      case Map.fetch(acc, next_key) do
        :error -> Map.put(acc, next_key, next_value)
        {:ok, ^next_value} -> acc
        {:ok, other} -> abort({:rewritten_map_key_collision, key, next_key, other, next_value})
      end
    end)
  end

  defp rewrite_identity_value(values, mappings, identity) when is_tuple(values),
    do:
      values
      |> Tuple.to_list()
      |> Enum.map(&rewrite_identity_value(&1, mappings, identity))
      |> List.to_tuple()

  defp rewrite_identity_value(value, _mappings, identity), do: rewrite_term(value, identity)

  defp rewrite_db_namespace("salix:" <> source, mappings),
    do: "salix:" <> Map.get(mappings, source, source)

  defp rewrite_db_namespace(value, _mappings), do: value

  defp rewrite_config(value, identity) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        decoded |> rewrite_term(identity) |> encode_json()

      _ ->
        value
    end
  end

  defp rewrite_config(value, identity), do: rewrite_term(value, identity)

  defp rewrite_embedded(value, identity) when is_binary(value) do
    identity.tenants
    |> Map.merge(identity.groups)
    |> Map.merge(identity.agents)
    |> Map.get(value, value)
  end

  defp rewrite_embedded(value, identity), do: rewrite_term(value, identity)

  defp read_json!(key), do: key |> S3.get() |> read_json_object!(key)

  defp read_json_value!({:ok, %{body: body}}, key), do: decode_json_value!(key, body)
  defp read_json_value!({:error, reason}, key), do: abort({:read_record_failed, key, reason})

  defp read_json_object!({:ok, %{body: body}}, key), do: decode_json!(key, body)
  defp read_json_object!({:error, reason}, key), do: abort({:read_record_failed, key, reason})

  defp decode_json!(key, body) do
    case decode_json_value(key, body) do
      {:ok, value} when is_map(value) -> value
      {:ok, _value} -> abort({:decode_failed, key, :expected_object})
      {:error, reason} -> abort(reason)
    end
  end

  defp decode_json_value!(key, body) do
    case decode_json_value(key, body) do
      {:ok, value} -> value
      {:error, reason} -> abort(reason)
    end
  end

  defp decode_json_value(key, body) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:decode_failed, key, reason}}
    end
  end

  defp encode_json(value), do: Jason.encode!(value)

  defp parallel_stats(items, stats, fun) do
    items
    |> parallel_map(fun)
    |> Enum.reduce(stats, &merge_stats/2)
  end

  defp parallel_flat_map(items, fun), do: items |> parallel_map(fun) |> List.flatten()

  defp parallel_each(items, fun) do
    items
    |> parallel_map(fn item ->
      fun.(item)
      :ok
    end)

    :ok
  end

  defp parallel_map(items, fun) do
    items
    |> Task.async_stream(
      fn item ->
        try do
          {:ok, fun.(item)}
        catch
          {:hierarchy_identity_abort, reason} -> {:error, reason}
        end
      end,
      max_concurrency: @max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, {:ok, value}} -> value
      {:ok, {:error, reason}} -> abort(reason)
      {:exit, reason} -> abort({:parallel_task_failed, reason})
    end)
  end

  defp merge_stats(next, acc) do
    %{
      migrated: acc.migrated + next.migrated,
      unchanged: acc.unchanged + next.unchanged
    }
  end

  defp zero_stats, do: %{migrated: 0, unchanged: 0}

  defp migrate_phase(stats, phase, run) do
    Logger.info("Salix hierarchy identity phase started phase=#{phase}")
    started_at = System.monotonic_time(:millisecond)
    result = run.(stats)

    Logger.info(
      "Salix hierarchy identity phase completed " <>
        "phase=#{phase} elapsed_ms=#{System.monotonic_time(:millisecond) - started_at}"
    )

    result
  end

  defp build_inventory! do
    inventory =
      :ets.new(:hierarchy_identity_inventory, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    case S3.list_all("") do
      {:ok, objects} ->
        :ets.insert(inventory, Enum.map(objects, &{&1.key}))
        inventory

      {:error, reason} ->
        :ets.delete(inventory)
        abort({:list_failed, "", reason})
    end
  end

  defp refresh_inventory!(inventory) do
    case S3.list_all("") do
      {:ok, objects} ->
        :ets.delete_all_objects(inventory)
        :ets.insert(inventory, Enum.map(objects, &{&1.key}))
        :ok

      {:error, reason} ->
        abort({:list_failed, "", reason})
    end
  end

  defp list_keys!(prefix, inventory) do
    :ets.foldl(
      fn {key}, acc ->
        if String.starts_with?(key, prefix), do: [key | acc], else: acc
      end,
      [],
      inventory
    )
    |> Enum.sort()
  end

  defp move_inventory(stats, inventory, source, target) do
    :ets.delete(inventory, source)
    :ets.insert(inventory, {target})
    migrated(stats)
  end

  defp add_inventory(stats, inventory, key, result) do
    :ets.insert(inventory, {key})

    case result do
      :migrated -> migrated(stats)
      :unchanged -> unchanged(stats)
    end
  end

  defp parse_key(key, regex) do
    case Regex.run(regex, key) do
      [_, id] -> [id]
      _ -> []
    end
  end

  defp target_tenant_from_group!(group_id) do
    case String.split(group_id, "_") do
      ["grp1", tenant_body, _group_body] -> "ten1_" <> tenant_body
      _ -> abort({:invalid_canonical_group_id, group_id})
    end
  end

  defp map_field(map, field), do: Map.get(map, field) || Map.get(map, String.to_atom(field))

  defp put_nonblank(map, key, value) do
    if trim(map[key]) == "", do: Map.put(map, key, value), else: map
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp nonblank?(value), do: trim(value) != ""

  defp require!(true, _reason), do: :ok
  defp require!(false, reason), do: abort(reason)

  defp abort(reason), do: throw({:hierarchy_identity_abort, reason})
  defp migrated(stats), do: %{stats | migrated: stats.migrated + 1}
  defp unchanged(stats), do: %{stats | unchanged: stats.unchanged + 1}
end
