defmodule Comma.Release do
  @moduledoc """
  Release-time entrypoints for schema migrations and deterministic local seeds.

  Progressive reconciliation belongs to domain workers. External provider sync
  remains an explicit operation and historical Salix migration manifests are
  retained only as offline baseline evidence.
  """

  @doc """
  One bounded Agent handoff page, called by the release runner ONLY after core
  rollout success. Use release RPC on a serving node; no application bootstrap,
  global maintenance or rollback is performed. The cursor is base64 JSON from
  the preceding response. An error leaves prior claims intact for exact retry.
  """
  def transfer_agent_configuration_page(cursor \\ nil) do
    rollout = Module.concat([SalixStore, AgentConfigurationRollout])
    transfer = Module.concat([BridgeForTeams, Agents, ConfigurationTransfer])

    decoded = if cursor, do: apply(Jason, :decode!, [Base.decode64!(cursor)]), else: nil

    result =
      cond do
        is_map(decoded) and decoded["stage"] == "cloudflare_profile" ->
          transfer_cloudflare_profile_page(decoded["source"])

        is_map(decoded) and decoded["stage"] == "group_compute" ->
          transfer_group_compute_page(decoded["source"])

        true ->
          with {:ok, phase} <- apply(rollout, :state, []) do
            if phase == :complete do
              transfer_group_compute_page(nil)
            else
              with :ok <- apply(rollout, :open, []) do
                case apply(transfer, :page, [decoded]) do
                  {:ok, %{next_cursor: nil} = summary} ->
                    {:ok,
                     %{summary | next_cursor: %{"stage" => "group_compute", "source" => nil}}}

                  result ->
                    result
                end
              end
            end
          end
      end

    case result do
      {:ok, summary} ->
        next =
          if summary.next_cursor,
            do: apply(Jason, :encode!, [summary.next_cursor]) |> Base.encode64()

        IO.puts(
          "COMMA_AGENT_TRANSFER_RESULT:" <>
            apply(Jason, :encode!, [%{processed: summary.processed, next_cursor: next}])
        )

        :ok

      {:error, reason} ->
        raise "Configuration/Compute handoff paused; core remains online. Retry this page: #{inspect(reason)}"
    end
  end

  defp transfer_group_compute_page(cursor) do
    migration = Module.concat([SalixStore, ComputeMigration])

    case apply(migration, :transfer_page, [cursor]) do
      {:ok, %{next_cursor: nil} = summary} ->
        {:ok, %{summary | next_cursor: %{"stage" => "cloudflare_profile", "source" => nil}}}

      {:ok, %{next_cursor: next} = summary} ->
        {:ok, %{summary | next_cursor: %{"stage" => "group_compute", "source" => next}}}

      error ->
        error
    end
  end

  defp transfer_cloudflare_profile_page(cursor) do
    migration = Module.concat([SalixStore, CloudflareProfileHandoff])

    case apply(migration, :transfer_page, [cursor]) do
      {:ok, %{next_cursor: next} = summary} ->
        wrapped = if next, do: %{"stage" => "cloudflare_profile", "source" => next}
        {:ok, %{summary | next_cursor: wrapped}}

      error ->
        error
    end
  end

  @doc "Publish the desired Runtime catalog from the successful release's immutable image."
  def publish_runtime_release(release_id, helm_revision) do
    case apply(Module.concat([SalixStore, ComputeRuntimeRelease]), :publish, [
           release_id,
           helm_revision
         ]) do
      :ok -> :ok
      {:error, reason} -> raise "Runtime publication failed: #{inspect(reason)}"
    end
  end

  @doc "Read a bounded page of Runtime update results, independently of core deployment status."
  def runtime_release_status(cursor \\ ""),
    do: apply(Module.concat([SalixStore, ComputeRuntimeRelease]), :status_page, [cursor])

  @doc "Start or inspect one operator-authorized Workload update on a serving node."
  def workload_update(action, attrs)
      when action in ~w(start status retry cancel forward_repair) and is_map(attrs) do
    operation =
      case action do
        "start" -> :start
        "status" -> :status
        "retry" -> :retry
        "cancel" -> :cancel
        "forward_repair" -> :forward_repair
      end

    apply(Module.concat([SalixEnv, ComputeWorkloadUpdate]), operation, [attrs])
  end

  def workload_update(_, _), do: {:error, :invalid_workload_update}

  @synchronicity_default_limit 100
  @synchronicity_max_limit 1_000

  @doc """
  Explicit online format-3 migration after the runtime rollout has completed.
  Run in a dedicated operator process, never in the serving VM. Defaults to a
  read-only inventory; writes require `dry_run: false`.

      bin/comma eval 'Comma.Release.migrate_salix_format3()'
      bin/comma eval 'Comma.Release.migrate_salix_format3(dry_run: false)'
  """
  def migrate_salix_format3(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case apply(Module.concat([SalixAgent, InternalSessionFormat3Cutover]), :run, [opts]) do
      {:ok, summary} ->
        IO.puts("salix format-3 migration: #{inspect(summary)}")
        {:ok, summary}

      {:error, reason} ->
        raise "salix format-3 migration stopped: #{inspect(reason)}"
    end
  end

  @doc "Prune expired, verified format-3 migration backups; defaults to dry-run."
  def prune_salix_format3_backups(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case apply(Module.concat([SalixAgent, SessionFormat3BackupPrune]), :run, [opts]) do
      {:ok, summary} ->
        IO.puts("salix format-3 backup prune: #{inspect(summary)}")
        {:ok, summary}

      {:error, reason} ->
        raise "salix format-3 backup prune stopped: #{inspect(reason)}"
    end
  end

  @doc """
  Release-native Synchronicity provisioning for one Comma Workspace or a bounded
  batch of missing or existing mappings.

      bin/comma rpc 'Comma.Release.provision_synchronicity("wsp_...")'
      bin/comma rpc 'Comma.Release.provision_synchronicity(all_missing: true, limit: 100)'

  The OTP release ships no Mix runtime, so production operators use this entry
  instead of `mix comma.synchronicity.provision`. Batch successes are persisted
  before later rows run. All-missing retries skip rows with both ids. A failed
  provider call raises after printing the bounded summary so the release command
  exits nonzero.
  Use refresh_all: true to include mapped rows. Page with last_workspace_id as
  after_id until processed is zero. Retry failed ids before advancing.
  The control plane enforces enabled browsing and hosting on each refresh.
  """
  @spec provision_synchronicity(String.t() | keyword()) :: {:ok, map()}
  def provision_synchronicity(workspace_id) when is_binary(workspace_id) do
    if workspace_id == "", do: raise("Synchronicity Workspace id must not be empty")

    ensure_comma_core_started!()

    synchronicity = Module.concat([Comma, Synchronicity])

    case apply(synchronicity, :provision_workspace_by_id, [workspace_id]) do
      {:ok, result} ->
        summary = %{
          mode: :workspace,
          workspace_id: workspace_id,
          processed: 1,
          succeeded: 1,
          failed: 0,
          remote_created: result.created
        }

        IO.puts("Synchronicity provisioning: #{inspect(summary)}")
        {:ok, summary}

      {:error, reason} ->
        raise "Synchronicity provisioning failed for #{workspace_id}: #{inspect(reason)}"
    end
  end

  def provision_synchronicity(opts) when is_list(opts) do
    ensure_provision_options!(opts)
    limit = Keyword.get(opts, :limit, @synchronicity_default_limit)
    ensure_synchronicity_limit!(limit)
    ensure_comma_core_started!()

    synchronicity = Module.concat([Comma, Synchronicity])

    mode = if Keyword.get(opts, :refresh_all) == true, do: :refresh_all, else: :all_missing

    result =
      case mode do
        :refresh_all -> apply(synchronicity, :refresh_all, [limit, Keyword.get(opts, :after_id)])
        :all_missing -> apply(synchronicity, :provision_missing, [limit])
      end

    case result do
      {:ok, summary} ->
        summary = Map.put(summary, :mode, mode)
        IO.puts("Synchronicity provisioning: #{inspect(summary)}")
        {:ok, summary}

      {:error, %{failed: failed} = summary} ->
        IO.puts("Synchronicity provisioning: #{inspect(Map.put(summary, :mode, mode))}")
        raise "Synchronicity provisioning left #{failed} Workspace(s) unresolved"

      {:error, reason} ->
        raise "Synchronicity provisioning failed: #{inspect(reason)}"
    end
  end

  def provision_synchronicity(_target) do
    raise ArgumentError,
          "expected a Workspace id, all_missing: true, or refresh_all: true"
  end

  @doc """
  Release-native entry for the archived-schedule sweep (#849): pause the
  agent-receiver schedules of every already-archived agent, once.

      bin/comma eval 'Comma.Release.pause_archived_agent_schedules()'
      bin/comma eval 'Comma.Release.pause_archived_agent_schedules(dry_run: true)'

  Same contract as `mix salix.schedules.pause_archived`: idempotent,
  user-paused rows untouched, raises when any per-agent update failed.
  """
  @spec pause_archived_agent_schedules(keyword()) :: {:ok, map()}
  def pause_archived_agent_schedules(opts \\ []) do
    case Application.ensure_all_started(:salix_store) do
      {:ok, _started} ->
        case apply(Module.concat([SalixAgent, ArchivedScheduleSweep]), :run, [opts]) do
          {:ok, summary} ->
            IO.puts("archived-schedule sweep: #{inspect(summary)}")
            {:ok, summary}

          {:error, reason} ->
            # `bin/comma eval` exits 0 for any returned value — raising is the
            # only way a failed sweep fails the invocation.
            raise "archived-schedule sweep failed: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "could not start salix_store for the archived-schedule sweep: #{inspect(reason)}"
    end
  end

  @doc """
  Release-native entry for the format-1 backup prune (the OTP release ships
  no Mix, so the documented Mix task cannot run in a pod):

      bin/comma eval 'Comma.Release.prune_salix_format1_backups()'
      bin/comma eval 'Comma.Release.prune_salix_format1_backups(dry_run: true)'

  Same contract as `mix salix.session.prune_format1_backups`: refuses inside
  the retention window, verifies the sampled migrated sessions through the
  real window/archive read path, deletes only afterwards.
  """
  @spec prune_salix_format1_backups(keyword()) :: {:ok, map()}
  def prune_salix_format1_backups(opts \\ []) do
    case Application.ensure_all_started(:salix_store) do
      {:ok, _started} ->
        case apply(Module.concat([SalixAgent, SessionFormat1BackupPrune]), :run, [opts]) do
          {:ok, summary} ->
            IO.puts("salix format-1 backup prune: #{inspect(summary)}")
            {:ok, summary}

          {:error, reason} ->
            # `bin/comma eval` exits 0 for any returned value — raising is the
            # only way a failed prune fails the invocation.
            raise "salix format-1 backup prune failed: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "could not start salix_store for the backup prune: #{inspect(reason)}"
    end
  end

  defp ensure_provision_options!(opts) do
    if Keyword.keyword?(opts) do
      allowed = [:all_missing, :refresh_all, :limit, :after_id]
      unknown = Keyword.keys(opts) -- allowed

      cond do
        unknown != [] ->
          raise ArgumentError, "unknown Synchronicity provisioning options: #{inspect(unknown)}"

        {Keyword.get(opts, :all_missing, false), Keyword.get(opts, :refresh_all, false)} not in [
          {true, false},
          {false, true}
        ] ->
          raise ArgumentError,
                "batch Synchronicity provisioning requires all_missing: true or refresh_all: true, not both"

        Keyword.has_key?(opts, :after_id) and
            (Keyword.get(opts, :refresh_all) != true or
               not is_binary(opts[:after_id]) or opts[:after_id] == "") ->
          raise ArgumentError, "after_id requires refresh_all: true and a nonempty Workspace id"

        true ->
          :ok
      end
    else
      raise ArgumentError,
            "expected a Workspace id, all_missing: true, or refresh_all: true"
    end
  end

  defp ensure_synchronicity_limit!(limit)
       when is_integer(limit) and limit in 1..@synchronicity_max_limit,
       do: :ok

  defp ensure_synchronicity_limit!(_limit) do
    raise ArgumentError,
          "Synchronicity provisioning limit must be between 1 and #{@synchronicity_max_limit}"
  end

  defp ensure_comma_core_started! do
    case Application.ensure_all_started(:comma_core) do
      {:ok, _started} ->
        synchronicity = Module.concat([Comma, Synchronicity])

        unless apply(synchronicity, :configured?, []) do
          raise "Synchronicity provisioning is not configured"
        end

        :ok

      {:error, reason} ->
        raise "could not start comma_core for Synchronicity provisioning: #{inspect(reason)}"
    end
  end

  @doc "Run pending schemas and deterministic local seeds."
  @spec migrate() :: :ok
  def migrate do
    enabled = enabled_subsystems()

    if Enum.any?(enabled, &(&1 in [:salix, :comma_product, :bridge_for_teams])) do
      Module.concat([BillingCore, Release])
      |> apply(:migrate, [])
    end

    if enabled?(:alert_router, enabled) do
      migrate_alert_router_schema()
    end

    if enabled?(:comma_product, enabled) do
      migrate_comma_schema()
      sync_billing_catalog(provider_sync: false)
    end

    if enabled?(:bridge_for_teams, enabled) do
      Module.concat([BridgeForTeams, Release])
      |> apply(:migrate, [])
    end

    if enabled?(:salix, enabled) do
      migrate_salix_schema()

      Module.concat([SalixAnalytics, Migrations])
      |> apply(:migrate, [])
    end

    :ok
  end

  @doc "Return the deterministic candidate release plan."
  def plan do
    case Comma.ReleasePlan.plan() do
      {:ok, plan} -> plan
      {:error, reason} -> raise "release plan rejected: #{inspect(reason)}"
    end
  end

  @doc "Return the candidate release plan as one JSON envelope."
  def plan_json, do: apply(Jason, :encode!, [plan()])

  @doc "Execute only the ids authorized by the persisted candidate plan."
  def execute_plan_stage(stage, manifest_digest, allowed_ids)
      when is_binary(stage) and is_binary(manifest_digest) and is_list(allowed_ids) do
    execute_plan_stage(stage, manifest_digest, allowed_ids, [])
  end

  @doc false
  def execute_plan_stage(stage, manifest_digest, allowed_ids, opts)
      when is_binary(stage) and is_binary(manifest_digest) and is_list(allowed_ids) do
    execute_release_stage(
      stage,
      manifest_digest,
      allowed_ids,
      Keyword.put(opts, :legacy_upgrade, false)
    )
  end

  @doc "Execute an audited legacy-upgrade stage outside the normal release path."
  def execute_legacy_upgrade_stage(stage, manifest_digest, allowed_ids)
      when is_binary(stage) and is_binary(manifest_digest) and is_list(allowed_ids) do
    execute_legacy_upgrade_stage(stage, manifest_digest, allowed_ids, [])
  end

  @doc false
  def execute_legacy_upgrade_stage(stage, manifest_digest, allowed_ids, opts)
      when is_binary(stage) and is_binary(manifest_digest) and is_list(allowed_ids) do
    authorized? =
      Keyword.get(opts, :legacy_upgrade_authorized, System.get_env("COMMA_LEGACY_UPGRADE") == "1")

    unless authorized?, do: raise("legacy upgrade execution requires the audited upgrade carrier")
    unless stage in ["online", "cutover"], do: raise("unknown legacy upgrade stage")

    execute_release_stage(
      stage,
      manifest_digest,
      allowed_ids,
      Keyword.put(opts, :legacy_upgrade, true)
    )
  end

  defp execute_release_stage(stage, manifest_digest, allowed_ids, opts) do
    plan_fun = Keyword.get(opts, :plan, &plan/0)
    current = plan_fun.()
    legacy_upgrade? = Keyword.fetch!(opts, :legacy_upgrade)

    if current.manifestDigest != manifest_digest do
      raise "release manifest digest drift"
    end

    # TLA: tla/salix/SalixLegacyMigrationRelease.tla::RejectStageExecution.
    # TLA: tla/salix/SalixLegacyUpgrade.tla::RunMigration.
    if field(current, :requiredMode) == "blocked_legacy" and not legacy_upgrade? do
      raise "release plan mode #{field(current, :requiredMode)} forbids stage execution"
    end

    if legacy_upgrade?, do: ensure_legacy_upgrade_scope!(current, allowed_ids)
    ensure_stage_authorized!(current, stage, allowed_ids, legacy_upgrade?)
    ensure_online_steps_converged!(current, stage, legacy_upgrade?)

    pending =
      stage_pending_ids(current, stage, legacy_upgrade?)
      |> Enum.map(&field(&1, :id))

    # Drift guard. Every pending step must be authorized, in plan order: the
    # authorized ids that are still pending must equal `pending` exactly. An
    # authorized id that is NO LONGER pending was already applied on a prior
    # attempt — the migration ledger (schema_migrations) is the durable
    # completion record — so it is adopted as an idempotent no-op instead of
    # raising drift. This closes the lost-completion / Job-GC recovery wedge
    # without a controller-side adoption protocol: a re-launched exclusive step
    # re-runs harmlessly (Ecto `:already_up`; `TenantApiKeyCutover.run/0` is a
    # marker no-op). The manifest digest is verified above, so every id is a
    # real manifest step, and the executor still rejects ids invalid for the
    # stage. Order-sensitivity for pending work is preserved.
    authorized_pending = Enum.filter(allowed_ids, &(&1 in pending))
    if authorized_pending != pending, do: raise("authorized pending ids drift")

    adopted = allowed_ids -- pending

    if adopted != [] do
      require Logger

      Logger.info(
        "release stage #{stage}: adopting already-applied authorized steps #{inspect(adopted)}"
      )
    end

    result =
      case stage do
        "online" ->
          Keyword.get(opts, :online_executor, &execute_online_steps/1).(allowed_ids)

        "cutover" ->
          Keyword.get(opts, :cutover_executor, fn ids ->
            execute_cutover_steps(ids, manifest_digest: manifest_digest)
          end).(allowed_ids)

        "provider" ->
          Keyword.get(opts, :provider_executor, fn -> run_provider_sequence(allowed_ids) end).()

        _ ->
          raise "unknown release stage"
      end

    if stage in ["online", "cutover"] do
      remaining =
        plan_fun.().pendingSteps
        |> Enum.filter(&(field(&1, :id) in allowed_ids))
        |> Enum.map(&field(&1, :id))
        |> Enum.sort()

      if remaining != [],
        do: raise("authorized release steps did not converge: #{inspect(remaining)}")
    end

    result
  end

  @doc "Sync the shipped Comma billing catalog."
  @spec sync_billing_catalog(keyword()) :: [map()]
  def sync_billing_catalog(opts \\ []) do
    Application.load(:comma_core)

    catalog =
      Module.concat([Comma, Billing, PricingV1])
      |> apply(:catalog, [])

    case Keyword.get(opts, :provider_sync, true) do
      false -> sync_local_billing_catalog(catalog, opts)
      _ -> sync_billing_provider_catalog(catalog, opts)
    end
  end

  @doc """
  Explicitly converge the Comma billing catalog with its external payment provider.

  Keep this out of `migrate/0`: provider API failures must not block deterministic
  schema rollout.
  """
  @spec sync_billing_provider_catalog(map() | keyword()) :: [map()]
  def sync_billing_provider_catalog(catalog_or_opts \\ []) do
    {catalog, opts} =
      if is_map(catalog_or_opts) do
        {catalog_or_opts, []}
      else
        Application.load(:comma_core)

        catalog =
          Module.concat([Comma, Billing, PricingV1])
          |> apply(:catalog, [])

        {catalog, catalog_or_opts}
      end

    Module.concat([BillingStripe, Release])
    |> apply(:sync_catalog, [catalog, opts])
  end

  @spec sync_billing_provider_catalog(map(), keyword()) :: [map()]
  def sync_billing_provider_catalog(catalog, opts) when is_map(catalog) do
    Module.concat([BillingStripe, Release])
    |> apply(:sync_catalog, [catalog, opts])
  end

  @doc "Converge the nondefault Comma portal, or bootstrap it before the first live release."
  def sync_billing_portal(opts \\ []) do
    Application.load(:comma_core)
    catalog = Module.concat([Comma, Billing, PricingV1]) |> apply(:catalog, [])
    Module.concat([BillingStripe, Release]) |> apply(:sync_portal, [catalog, opts])
  end

  defp sync_local_billing_catalog(catalog, opts) do
    load_billing_commerce_apps()
    attrs = opts |> Keyword.delete(:provider_sync) |> Keyword.put_new(:provider_sync, :skipped)

    for repo <- billing_core_repos() do
      {:ok, {:ok, summary}, _started} =
        Module.concat([Ecto, Migrator])
        |> apply(:with_repo, [
          repo,
          fn started_repo ->
            Module.concat([BillingCommerce])
            |> apply(:sync_local_pricing_catalog, [
              catalog,
              Keyword.put(attrs, :repo, started_repo)
            ])
          end
        ])

      %{
        local: summary,
        provider: "stripe",
        provider_prices: [],
        provider_sync: :skipped,
        reason: :release_migration_local_only
      }
    end
  end

  defp billing_core_repos do
    Application.get_env(:billing_core, :ecto_repos, [])
  end

  defp migrate_comma_schema do
    Application.load(:comma_core)
    migrator = Module.concat([Ecto, Migrator])

    for repo <- Application.get_env(:comma_core, :ecto_repos, []) do
      {:ok, _, _} =
        apply(migrator, :with_repo, [
          repo,
          fn started_repo -> apply(migrator, :run, [started_repo, :up, [all: true]]) end
        ])
    end
  end

  defp migrate_alert_router_schema do
    Application.load(:alert_router)
    migrator = Module.concat([Ecto, Migrator])

    for repo <- Application.get_env(:alert_router, :ecto_repos, []) do
      {:ok, _, _} =
        apply(migrator, :with_repo, [
          repo,
          fn started_repo -> apply(migrator, :run, [started_repo, :up, [all: true]]) end
        ])
    end
  end

  # Salix control-plane repo (docs/storage-search.md).
  # `:ecto_repos` is registered by runtime.exs only when `salix.database.url`
  # is configured, so nodes without the control database no-op here.
  defp migrate_salix_schema do
    Application.load(:salix_store)
    migrator = Module.concat([Ecto, Migrator])

    for repo <- Application.get_env(:salix_store, :ecto_repos, []) do
      {:ok, _, _} =
        apply(migrator, :with_repo, [
          repo,
          fn started_repo -> apply(migrator, :run, [started_repo, :up, [all: true]]) end
        ])
    end

    run_salix_cutover_for_dev_compose()
  end

  # `migrate/0` is the dev/compose/test one-shot path (docker-compose comma-migrate
  # and the release adapter tests). Production never calls it: the release
  # controller drives manifest-authorized steps through `execute_plan_stage/3`.
  # Dev/compose would otherwise leave control-plane markers absent or retained
  # nested participant state invisible to the flat-only runtime. Run these
  # cutovers here before the serving `comma` container starts. Normal production
  # and staging releases classify the published incompatible relocation as
  # `legacy` and reject it; crossing that boundary requires a separately audited
  # upgrade. This local path keeps dev/compose on the idempotent pre-serving
  # relocation contract.
  defp run_salix_cutover_for_dev_compose do
    cutovers =
      [
        Module.concat([SalixStore, TenantApiKeyCutover]),
        Module.concat([SalixStore, ProviderCredentialsCutover]),
        Module.concat([SalixStore, TenantConfigsCutover]),
        Module.concat([SalixStore, SchedulesCutover]),
        Module.concat([SalixStore, OAuthAppsCutover])
      ]
      |> Enum.filter(&Code.ensure_loaded?/1)

    if Application.get_env(:salix_store, :start_repo, false) and cutovers != [] do
      # `bin/comma eval` (docker-compose comma-migrate) does not start applications,
      # and the migrator's with_repo only starts/stops the repo. The cutovers
      # need the whole :salix_store app up — the S3 client's Finch pool and
      # storage config — exactly as the production release-migration files do
      # before calling run/0. Without this the eval crashes and the dev stack
      # never boots (worse than the uncertified state PR-A set out to fix).
      case Application.ensure_all_started(:salix_store) do
        {:ok, _started} -> :ok
        {:error, reason} -> raise "could not start salix_store for cutover: #{inspect(reason)}"
      end

      Enum.each(cutovers, fn cutover ->
        case apply(cutover, :run, []) do
          :ok -> :ok
          {:error, reason} -> raise "salix cutover #{inspect(cutover)} failed: #{inspect(reason)}"
        end
      end)

      participant_release = Module.concat([SalixIM, Release])

      apply(participant_release, :migrate_conversation_participant_states, [
        [confirm_no_writers: true]
      ])
    end
  end

  defp load_billing_commerce_apps do
    Application.load(:billing_core)
    Application.load(:billing_commerce)
  end

  defp enabled_subsystems do
    Module.concat([Comma]) |> apply(:enabled_subsystems, [])
  end

  defp enabled?(subsystem, enabled), do: subsystem in enabled

  defp execute_online_steps(ids) do
    execute_authorized_schema_steps(ids, allow_local_seed: true)
  end

  @doc false
  def execute_authorized_schema_steps(ids, opts \\ []) do
    allow_local_seed = Keyword.get(opts, :allow_local_seed, false)

    Enum.each(ids, fn
      "comma-local-seed" when allow_local_seed ->
        sync_billing_catalog(provider_sync: false)

      "alert-router-" <> version ->
        run_ecto_migration(AlertRouter.Repo, :alert_router, version)

      "comma-" <> version ->
        run_ecto_migration(Comma.Repo, :comma_core, version)

      "billing-" <> version ->
        run_ecto_migration(BillingCore.Repo, :billing_core, version)

      "bridge-" <> version ->
        run_ecto_migration(BridgeForTeams.Repo, :bridge_for_teams_core, version)

      "salix-" <> version ->
        run_ecto_migration(SalixStore.Repo, :salix_store, version)

      "analytics-" <> _ ->
        :ok

      id ->
        raise "unsupported schema release step: #{id}"
    end)

    analytics =
      for "analytics-" <> version <- ids,
          do: String.to_integer(version)

    if analytics != [] do
      clickhouse_opts = Application.get_env(:comma, :release_clickhouse_opts, [])

      case apply(SalixAnalytics.Migrations, :migrate_versions, [analytics, clickhouse_opts]) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "analytics migration failed: #{inspect(reason)}"
      end
    end

    :ok
  end

  @doc false
  def execute_cutover_steps(ids, opts \\ []) do
    schema_ids =
      Enum.filter(ids, fn id ->
        Regex.match?(~r/^(alert-router|comma|billing|bridge|salix|analytics)-\d+$/, id)
      end)

    unknown = ids -- schema_ids
    if unknown != [], do: raise("unsupported cutover release steps: #{inspect(unknown)}")

    schema_runner = Keyword.get(opts, :schema_runner, &execute_authorized_schema_steps/1)
    schema_runner.(schema_ids)
    :ok
  end

  defp run_ecto_migration(repo, app, version_text) do
    version = String.to_integer(version_text)
    source = Application.get_env(:comma, :release_ecto_sources, %{}) |> Map.get(app, [])
    repo = Keyword.get(source, :repo, repo)

    # A migration authored in priv/release_migrations (exclusive cutover steps)
    # vs priv/repo/migrations (expand steps) is resolved by locating the version
    # file in whichever directory holds it — the manifest is the authority for
    # which steps exist, and the file's directory is discovered, not hardcoded
    # per version. A `:migration_dir` override (tests) still wins.
    path =
      case Keyword.fetch(source, :migration_dir) do
        {:ok, dir} -> resolve_migration_file(dir, app, version)
        :error -> resolve_migration_file(app, version)
      end

    modules = migration_modules(path)

    unless Enum.all?(modules, &Code.ensure_loaded?/1), do: Code.require_file(path)

    modules = Enum.filter(modules, &function_exported?(&1, :__migration__, 0))

    module =
      case modules do
        [module] -> module
        _ -> raise "migration file must define exactly one Ecto migration: #{path}"
      end

    migrator = Module.concat([Ecto, Migrator])

    {:ok, result, _started} =
      apply(migrator, :with_repo, [
        repo,
        fn started ->
          # The V2 manifest is the execution authority. Comma/Billing/BFT share
          # one physical ledger (salix_store keeps an isolated
          # salix_schema_migrations ledger), and phase-separated exclusive steps
          # can intentionally run below later expand versions. Ecto's global
          # numeric ordering cannot represent that contract; exact manifest IDs,
          # checksums, pending drift, and the declared repair/postcondition
          # contract provide the fail-closed authorization and diagnosis
          # boundary instead.
          apply(migrator, :up, [started, version, module, [strict_version_order: false]])
        end
      ])

    if result not in [:ok, :already_up],
      do: raise("unexpected Ecto migration result: #{inspect(result)}")

    :ok
  end

  @doc false
  # Test hook: the authorized-step file path the real release entrypoint resolves
  # for `app`/`version` (including the `release_ecto_sources` override), or raises
  # exactly as production would. Mirrors run_ecto_migration's resolution without
  # running the migration.
  def authorized_migration_path(app, version) when is_atom(app) and is_integer(version) do
    source = Application.get_env(:comma, :release_ecto_sources, %{}) |> Map.get(app, [])

    case Keyword.fetch(source, :migration_dir) do
      {:ok, dir} -> resolve_migration_file(dir, app, version)
      :error -> resolve_migration_file(app, version)
    end
  end

  @doc false
  # Test hook for the `:migration_dir` override branch (async-safe: no global env).
  def authorized_migration_path(app, version, override_dir)
      when is_atom(app) and is_integer(version) and is_binary(override_dir),
      do: resolve_migration_file(override_dir, app, version)

  # Locate a migration's source file by version across the directories an app can
  # author them in. Expand steps live in priv/repo/migrations (or a
  # `:migration_dir` override redirecting that base); operational compatibility,
  # legacy, and exclusive steps live in priv/release_migrations. Both are searched
  # so a step resolves regardless of phase, and a `:migration_dir` override never
  # hides the app's release-migration directory. Version numbers are unique per app.
  defp resolve_migration_file(app, version) do
    app
    |> candidate_migration_dirs(nil)
    |> find_authorized_migration(app, version)
  end

  defp resolve_migration_file(dir, app, version) do
    app
    |> candidate_migration_dirs(dir)
    |> find_authorized_migration(app, version)
  end

  defp candidate_migration_dirs(app, override) do
    base = override || Application.app_dir(app, "priv/repo/migrations")
    Enum.uniq([base, Application.app_dir(app, "priv/release_migrations")])
  end

  defp find_authorized_migration(dirs, app, version) do
    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "#{version}_*.exs")))
    |> Enum.uniq()
    |> resolve_migration_match(app, version)
  end

  defp resolve_migration_match(paths, app, version) do
    case paths do
      [path] -> path
      [] -> raise "authorized migration file missing: #{app}/#{version}"
      paths -> raise "duplicate authorized migration files: #{inspect(paths)}"
    end
  end

  defp migration_modules(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted(file: path)

    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, _body]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp stage_pending_ids(current, "provider", false),
    do: Enum.map(current.providerPendingIDs, &%{id: &1})

  defp stage_pending_ids(current, stage, legacy_upgrade?) when stage in ["online", "cutover"] do
    current.pendingSteps
    |> Enum.filter(&(stage_for_phase(field(&1, :phase), legacy_upgrade?) == stage))
  end

  defp stage_pending_ids(_current, _stage, _legacy_upgrade?), do: raise("unknown release stage")

  defp ensure_stage_authorized!(current, stage, allowed_ids, legacy_upgrade?)
       when stage in ["online", "cutover"] do
    stage_by_id =
      (Comma.ReleaseManifestV2.manifest()["steps"] ++ field(current, :pendingSteps))
      |> Map.new(fn step ->
        {field(step, :id), stage_for_phase(field(step, :phase), legacy_upgrade?)}
      end)

    unauthorized = Enum.reject(allowed_ids, &(Map.get(stage_by_id, &1) == stage))

    if unauthorized != [] do
      raise "authorized pending ids drift: #{inspect(unauthorized)} are not authorized for #{stage}"
    end
  end

  defp ensure_stage_authorized!(_current, _stage, _allowed_ids, false), do: :ok

  defp ensure_online_steps_converged!(current, "cutover", legacy_upgrade?) do
    pending =
      stage_pending_ids(current, "online", legacy_upgrade?)
      |> Enum.map(&field(&1, :id))

    if pending != [] do
      raise "cutover requires all online release steps to converge: #{inspect(pending)}"
    end
  end

  defp ensure_online_steps_converged!(_current, _stage, _legacy_upgrade?), do: :ok

  defp stage_for_phase(phase, _legacy_upgrade?) when phase in ["expand", "local_seed"],
    do: "online"

  defp stage_for_phase("exclusive", _legacy_upgrade?), do: "cutover"
  defp stage_for_phase("legacy", true), do: "cutover"
  defp stage_for_phase("legacy", false), do: "blocked_legacy"
  defp stage_for_phase("contract", _legacy_upgrade?), do: "deferred"

  defp stage_for_phase(phase, _legacy_upgrade?),
    do: raise("unknown release step phase: #{inspect(phase)}")

  defp ensure_legacy_upgrade_scope!(current, allowed_ids) do
    reserved =
      MapSet.new([
        "salix-20260728000103",
        "salix-20260729000001",
        "salix-20260729000002"
      ])

    legacy_ids =
      (Comma.ReleaseManifestV2.manifest()["steps"] ++ field(current, :pendingSteps))
      |> Enum.filter(&(field(&1, :phase) == "legacy"))
      |> Enum.map(&field(&1, :id))
      |> MapSet.new()

    requested_legacy_ids = Enum.filter(allowed_ids, &MapSet.member?(legacy_ids, &1))

    pending_legacy_ids =
      field(current, :pendingSteps)
      |> Enum.filter(&(field(&1, :phase) == "legacy"))
      |> Enum.map(&field(&1, :id))

    unless Enum.all?(requested_legacy_ids ++ pending_legacy_ids, &MapSet.member?(reserved, &1)) do
      raise "legacy upgrade plan contains an unaudited legacy step"
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp run_provider_sequence(allowed_ids) do
    {:ok, _} = Application.ensure_all_started(:comma_core)

    if "comma-signup-credits" in allowed_ids do
      case apply(Module.concat([Comma, Billing, SignupCredits]), :converge, []) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "Comma registration credits remain unresolved: #{inspect(reason)}"
      end
    end

    if "billing-provider" in allowed_ids, do: run_billing_provider_sequence()
  end

  defp run_billing_provider_sequence do
    require_provider = System.get_env("REQUIRE_PROVIDER", "false") == "true"

    sync_billing_provider_catalog(
      require_provider: require_provider,
      dry_run: true,
      max_attempts: 3
    )

    sync_billing_provider_catalog(require_provider: require_provider, max_attempts: 3)

    sync_billing_provider_catalog(
      require_provider: require_provider,
      dry_run: true,
      verify_local_mapping: true,
      max_attempts: 3
    )

    if require_provider do
      sync_billing_portal(dry_run: true, max_attempts: 3)
      sync_billing_portal(max_attempts: 3)
      sync_billing_portal(dry_run: true, verify: true, max_attempts: 3)
    end
  end
end
