defmodule BridgeForTeams.StorageMetering.Reconciler do
  @moduledoc """
  Periodic Bridge-owned storage metering for SalixStore prefixes.

  Bridge is the product owner source of truth, so this worker derives storage
  metering scopes from a durable, bounded project keyset scan. One shared
  expiring claim owns each generation; its stable source keys make billing
  replay safe after a process dies between charge and checkpoint acknowledgement.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{Agent, Organization, Project, StorageMeteringScan}
  alias BridgeForTeams.Telemetry

  @scan_id "bridge-storage-metering"
  @default_interval_ms 3_600_000
  @default_limit 10
  @default_lease_ttl_ms 900_000
  @default_max_objects 25_000

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def run_once(opts \\ []) do
    started = System.monotonic_time()

    try do
      repo = opts[:repo] || Repo
      billing_repo = opts[:billing_repo] || Application.fetch_env!(:billing_core, :repo)
      sql = opts[:sql_runner] || Ecto.Adapters.SQL
      now_ms = opts[:now_ms] || System.system_time(:millisecond)

      sample_window_seconds =
        opts[:sample_window_seconds] || config(:sample_window_seconds, 3_600)

      case claim_scan(repo, now_ms, opts) do
        {:ok, claim} ->
          run_claimed_scan(
            claim,
            repo,
            billing_repo,
            sql,
            sample_window_seconds,
            opts
          )

        :busy ->
          %{sampled: 0, failed: 0, scopes_seen: 0, claimed: false}
      end
    rescue
      exception ->
        Telemetry.emit_operation(:storage_sweep, "error", System.monotonic_time() - started)
        reraise exception, __STACKTRACE__
    end
  end

  defp run_claimed_scan(claim, repo, billing_repo, sql, sample_window_seconds, opts) do
    started = System.monotonic_time()

    try do
      projects = project_page(repo, claim.cursor_project_id, opts[:limit] || @default_limit)
      scopes = scopes(repo, projects)
      now_ms = DateTime.to_unix(claim.sampled_at, :millisecond)

      summary =
        Enum.reduce(scopes, %{sampled: 0, failed: 0, scopes_seen: 0}, fn scope, acc ->
          case sample_scope(scope, billing_repo, sql, now_ms, sample_window_seconds, claim, opts) do
            :ok -> %{acc | sampled: acc.sampled + 1, scopes_seen: acc.scopes_seen + 1}
            {:error, _reason} -> %{acc | failed: acc.failed + 1, scopes_seen: acc.scopes_seen + 1}
          end
        end)

      if summary.failed == 0 do
        :ok = acknowledge_scan(repo, claim, List.last(projects))
      else
        :ok = release_scan(repo, claim)
      end

      outcome = if summary.failed == 0, do: "ok", else: "error"
      Telemetry.emit_operation(:storage_sweep, outcome, System.monotonic_time() - started)

      :telemetry.execute(
        [:bridge_for_teams, :sweeper, :stop],
        %{value: summary.scopes_seen},
        %{operation: "storage_sweep", outcome: outcome}
      )

      Map.put(summary, :claimed, true)
    rescue
      exception ->
        _ = release_scan(repo, claim)
        Telemetry.emit_operation(:storage_sweep, "error", System.monotonic_time() - started)
        reraise exception, __STACKTRACE__
    end
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, config(:enabled, false)),
      interval_ms: Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms)),
      limit: Keyword.get(opts, :limit, config(:limit, @default_limit)),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, config(:lease_ttl_ms, @default_lease_ttl_ms))
    }

    if state.enabled, do: send(self(), :run)
    {:ok, state}
  end

  @impl true
  def handle_info(:run, state) do
    _ = run_safely(state)
    if state.enabled, do: Process.send_after(self(), :run, state.interval_ms)
    {:noreply, state}
  end

  defp run_safely(state) do
    case run_once(limit: state.limit, lease_ttl_ms: state.lease_ttl_ms) do
      %{sampled: sampled, failed: failed} = summary ->
        if sampled > 0 or failed > 0 do
          Logger.info("bridge storage metering completed #{inspect(summary)}")
        end

        :ok

      other ->
        Logger.warning("bridge storage metering returned reason=#{reason_class(other)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("bridge storage metering crashed reason=#{reason_class(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("bridge storage metering failed reason=#{reason_class({kind, reason})}")
      :ok
  end

  defp project_page(repo, cursor, limit) do
    query =
      from p in Project,
        join: o in Organization,
        on: o.id == p.org_id,
        where: p.status == "active" and is_nil(p.archived_at),
        where: not is_nil(o.billing_account_id) and o.billing_account_id != "",
        where: not is_nil(p.salix_group_id) and p.salix_group_id != "",
        order_by: [asc: p.id],
        limit: ^limit,
        select: %{
          org_id: o.id,
          billing_account_id: o.billing_account_id,
          salix_tenant_id: o.salix_tenant_id,
          project_id: p.id,
          salix_group_id: p.salix_group_id
        }

    rows =
      query
      |> maybe_after_project(cursor)
      |> repo.all()

    if rows == [] and is_binary(cursor) do
      repo.all(query)
    else
      rows
    end
  end

  defp maybe_after_project(query, cursor) when is_binary(cursor),
    do: where(query, [p, _o], p.id > ^cursor)

  defp maybe_after_project(query, _cursor), do: query

  defp scopes(_repo, []), do: []

  defp scopes(repo, projects) do
    project_ids = Enum.map(projects, & &1.project_id)

    router_agents =
      from(agent in Agent,
        where: agent.project_id in ^project_ids and agent.role == "router",
        order_by: [asc: agent.id],
        select: {agent.project_id, agent.salix_agent_id}
      )
      |> repo.all()
      |> Enum.reduce(%{}, fn {project_id, salix_agent_id}, acc ->
        Map.put_new(acc, project_id, salix_agent_id)
      end)

    Enum.flat_map(projects, fn project ->
      project
      |> Map.put(:router_agent_id, router_agents[project.project_id])
      |> scope_prefixes()
    end)
  end

  defp scope_prefixes(row) do
    owner = %{
      "billing_account_id" => row.billing_account_id,
      "surface" => "bridge",
      "product_owner_type" => "organization",
      "product_owner_id" => row.org_id,
      "project_id" => row.project_id,
      "salix_tenant_id" => row.salix_tenant_id,
      "salix_group_id" => row.salix_group_id,
      "router_agent_id" => row.router_agent_id,
      "charge_policy" => "platform_paid"
    }

    group_prefixes = [
      {"group-conversations", "ctl/group_conversations/#{row.salix_group_id}/"},
      {"group-conversation-list", "ctl/group_conversation_list/#{row.salix_group_id}/"},
      {"capability-requests", "ctl/capability_requests/#{row.salix_group_id}/"},
      {"im-connects", "ctl/im_connects/#{row.salix_group_id}/"},
      {"oauth-bindings", "ctl/oauth/group_bindings/#{row.salix_group_id}/"}
    ]

    agent_prefixes =
      if present?(row.router_agent_id) do
        [
          {"agent", "agents/#{row.router_agent_id}/"},
          {"sitedocs", "sitedocs/#{row.router_agent_id}/"}
        ]
      else
        []
      end

    Enum.map(group_prefixes ++ agent_prefixes, fn {kind, prefix} ->
      %{
        id: "bridge:#{row.project_id}:#{kind}",
        provider: config(:provider, "gcs"),
        sku: config(:sku, "regional"),
        storage_tier: config(:storage_tier, "regional"),
        bucket: SalixStore.Config.get().bucket,
        prefix: prefix,
        owner_snapshot: owner
      }
    end)
  end

  defp sample_scope(scope, billing_repo, sql, now_ms, default_window, claim, opts) do
    ensure_scope!(billing_repo, sql, scope)
    checkpoint = checkpoint(billing_repo, sql, scope.id)

    if checkpoint_covers_generation?(checkpoint, claim.sampled_at) do
      :ok
    else
      sample_window_seconds = checkpoint_window(checkpoint, now_ms, default_window)
      source_key = "storage:#{scope.id}:#{claim.generation}"

      case sample_and_meter(
             scope,
             source_key,
             billing_repo,
             sql,
             now_ms,
             sample_window_seconds,
             opts
           ) do
        {:ok, fact} ->
          upsert_checkpoint!(
            billing_repo,
            sql,
            scope.id,
            fact.metered_at,
            fact.object_count,
            fact.bytes
          )

          :ok

        {:error, reason} ->
          Logger.warning("storage scope #{scope.id} failed reason=#{reason_class(reason)}")
          {:error, reason}
      end
    end
  end

  defp reason_class({:exception, _detail}), do: "exception"
  defp reason_class({:error, reason}), do: reason_class(reason)
  defp reason_class({reason, _detail}) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(reason) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(%{__struct__: module}) when is_atom(module), do: safe_atom(module)
  defp reason_class(_reason), do: "external_error"

  defp safe_atom(atom), do: atom |> Atom.to_string() |> String.slice(0, 128)

  defp sample_and_meter(
         scope,
         source_key,
         billing_repo,
         sql,
         now_ms,
         sample_window_seconds,
         opts
       ) do
    max_objects = opts[:max_objects] || config(:max_objects, @default_max_objects)
    list_fun = opts[:list_fun] || (&SalixStore.S3.list_all/2)

    with {:ok, objects} <- list_fun.(scope.prefix, max_keys: max_objects + 1) do
      sampled = Enum.take(objects, max_objects)
      truncated? = length(objects) > max_objects
      bytes = Enum.reduce(sampled, 0, &(Map.fetch!(&1, :size) + &2))

      fact = %{
        source: "bridge_for_teams.storage_metering",
        source_key: source_key,
        entrypoint: "storage_snapshot",
        actor_type: "system",
        provider: scope.provider,
        sku: scope.sku,
        storage_tier: scope.storage_tier,
        tier_source: "provided",
        tier_cache_hit: false,
        bucket: scope.bucket,
        prefix: scope.prefix,
        owner_snapshot: scope.owner_snapshot,
        sample_window_seconds: sample_window_seconds,
        bytes: bytes,
        object_count: length(sampled),
        byte_seconds: bytes * sample_window_seconds,
        quantity: bytes * sample_window_seconds,
        metered_at: DateTime.from_unix!(now_ms, :millisecond),
        quality: if(truncated?, do: ["truncated_object_list"], else: []),
        repo: billing_repo,
        sql_runner: sql
      }

      metering_fun =
        opts[:metering_fun] || (&BillingCore.ResourceMetering.meter_storage_sample/1)

      case metering_fun.(fact) do
        {:error, reason} -> {:error, {:metering_failed, reason}}
        _accepted -> {:ok, fact}
      end
    end
  rescue
    exception -> {:error, {:sample_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp claim_scan(repo, now_ms, opts) do
    now = DateTime.from_unix!(now_ms * 1_000, :microsecond)
    lease_ttl_ms = opts[:lease_ttl_ms] || config(:lease_ttl_ms, @default_lease_ttl_ms)
    lease_expires_at = DateTime.add(now, lease_ttl_ms, :millisecond)
    token = Ecto.UUID.generate()

    repo.insert_all(
      StorageMeteringScan,
      [
        %{
          id: @scan_id,
          generation: 1,
          created_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    query =
      from(scan in StorageMeteringScan,
        where:
          scan.id == @scan_id and
            (is_nil(scan.lease_token) or is_nil(scan.lease_expires_at) or
               scan.lease_expires_at <= ^now),
        update: [
          set: [
            lease_token: ^token,
            lease_expires_at: ^lease_expires_at,
            sampled_at: fragment("COALESCE(?, ?)", scan.sampled_at, ^now),
            updated_at: ^now
          ]
        ],
        select: scan
      )

    case repo.update_all(query, []) do
      {1, [scan]} -> {:ok, scan}
      {0, []} -> :busy
    end
  end

  defp acknowledge_scan(repo, claim, last_project) do
    cursor_project_id = last_project && last_project.project_id
    now = DateTime.utc_now()

    {updated, _} =
      repo.update_all(
        from(scan in StorageMeteringScan,
          where: scan.id == @scan_id and scan.lease_token == ^claim.lease_token
        ),
        set: [
          cursor_project_id: cursor_project_id,
          generation: claim.generation + 1,
          sampled_at: nil,
          lease_token: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

    if updated == 1, do: :ok, else: {:error, :storage_metering_lease_lost}
  end

  defp release_scan(repo, claim) do
    now = DateTime.utc_now()

    repo.update_all(
      from(scan in StorageMeteringScan,
        where: scan.id == @scan_id and scan.lease_token == ^claim.lease_token
      ),
      set: [lease_token: nil, lease_expires_at: nil, updated_at: now]
    )

    :ok
  end

  defp ensure_scope!(repo, sql, scope) do
    sql.query!(
      repo,
      """
      INSERT INTO storage_metering_scopes (
        id, billing_account_id, provider, bucket, prefix, owner_snapshot, inserted_at
      ) VALUES ($1, $2, $3, $4, $5, $6::jsonb, now())
      ON CONFLICT (id) DO UPDATE
      SET billing_account_id = EXCLUDED.billing_account_id,
          provider = EXCLUDED.provider,
          bucket = EXCLUDED.bucket,
          prefix = EXCLUDED.prefix,
          owner_snapshot = EXCLUDED.owner_snapshot
      """,
      [
        scope.id,
        scope.owner_snapshot["billing_account_id"],
        scope.provider,
        scope.bucket,
        scope.prefix,
        Jason.encode!(scope.owner_snapshot)
      ]
    )
  end

  defp checkpoint(repo, sql, scope_id) do
    result =
      sql.query!(
        repo,
        """
        SELECT sampled_at, object_count, bytes
        FROM storage_metering_checkpoints
        WHERE scope_id = $1
        """,
        [scope_id]
      )

    case result.rows do
      [[sampled_at, object_count, bytes] | _] ->
        %{sampled_at: sampled_at, object_count: object_count, bytes: bytes}

      [] ->
        nil
    end
  end

  defp upsert_checkpoint!(repo, sql, scope_id, sampled_at, object_count, bytes) do
    sql.query!(
      repo,
      """
      INSERT INTO storage_metering_checkpoints (scope_id, sampled_at, object_count, bytes)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (scope_id) DO UPDATE
      SET sampled_at = EXCLUDED.sampled_at,
          object_count = EXCLUDED.object_count,
          bytes = EXCLUDED.bytes
      """,
      [scope_id, sampled_at, object_count, bytes]
    )
  end

  defp checkpoint_window(nil, _now_ms, default_window), do: default_window

  defp checkpoint_window(%{sampled_at: %DateTime{} = sampled_at}, now_ms, default_window) do
    now = DateTime.from_unix!(now_ms, :millisecond)

    max(DateTime.diff(now, sampled_at, :second), 1)
    |> min(default_window)
  end

  defp checkpoint_window(%{sampled_at: %NaiveDateTime{} = sampled_at}, now_ms, default_window) do
    sampled_at = DateTime.from_naive!(sampled_at, "Etc/UTC")
    checkpoint_window(%{sampled_at: sampled_at}, now_ms, default_window)
  end

  defp checkpoint_window(_checkpoint, _now_ms, default_window), do: default_window

  defp checkpoint_covers_generation?(%{sampled_at: %DateTime{} = sampled_at}, generation_at),
    do: DateTime.compare(sampled_at, generation_at) in [:eq, :gt]

  defp checkpoint_covers_generation?(
         %{sampled_at: %NaiveDateTime{} = sampled_at},
         generation_at
       ) do
    sampled_at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.compare(generation_at)
    |> then(&(&1 in [:eq, :gt]))
  end

  defp checkpoint_covers_generation?(_checkpoint, _generation_at), do: false

  defp config(key, default) do
    :bridge_for_teams_core
    |> Application.get_env(:storage_metering, [])
    |> Keyword.get(key, default)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
