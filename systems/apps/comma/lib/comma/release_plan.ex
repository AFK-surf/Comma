defmodule Comma.ReleasePlan do
  @moduledoc false

  @manifest Comma.ReleaseManifestV2.manifest()
  @manifest_steps @manifest["steps"]

  @known_versions %{
    alert_router:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "alert_router" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"]),
    comma:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "comma_core" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"]),
    billing:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "billing_core" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"]),
    bridge:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "bridge_for_teams" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"]),
    salix:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "salix_store" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"])
  }
  @required_versions %{
    alert_router:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "alert_router" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"]),
    comma:
      @manifest_steps
      |> Enum.filter(&(&1["owner"] == "comma_core" and &1["store"] == "postgres"))
      |> Enum.map(& &1["version"]),
    billing:
      @manifest_steps
      |> Enum.filter(
        &(&1["owner"] == "billing_core" and &1["store"] == "postgres" and
            &1["source"] != "historical-ledger-only")
      )
      |> Enum.map(& &1["version"]),
    bridge:
      @manifest_steps
      |> Enum.filter(
        &(&1["owner"] == "bridge_for_teams" and &1["store"] == "postgres" and
            &1["source"] != "historical-ledger-only")
      )
      |> Enum.map(& &1["version"]),
    salix:
      @manifest_steps
      |> Enum.filter(
        &(&1["owner"] == "salix_store" and &1["store"] == "postgres" and
            &1["source"] != "historical-ledger-only")
      )
      |> Enum.map(& &1["version"])
  }
  # Comma/Billing/BFT share one physical `schema_migrations` ledger in the
  # production topology, so each of those owners can legitimately observe the
  # others' versions and their unknown-check runs against the shared union.
  # Salix and Alert Router deliberately isolate their ledgers
  # (`salix_schema_migrations` and `alert_router_schema_migrations`); a foreign
  # owner's version appearing there is contamination and must fail closed, so
  # each validates against its own allowlist only.
  @shared_ecto_versions @known_versions
                        |> Map.take([:comma, :billing, :bridge])
                        |> Map.values()
                        |> List.flatten()
                        |> Enum.uniq()

  @clickhouse_versions @manifest_steps
                       |> Enum.filter(
                         &(&1["owner"] == "analytics" and &1["store"] == "clickhouse")
                       )
                       |> Map.new(fn step ->
                         {step["version"], String.replace_prefix(step["checksum"], "sha256:", "")}
                       end)

  def plan(opts \\ []) do
    facts = Keyword.get(opts, :facts, &facts/0).()

    with :ok <- validate_schema_facts(facts),
         :ok <- validate_clickhouse(facts.clickhouse),
         :ok <- Comma.ReleaseManifestV2.validate() do
      pending_steps =
        @manifest_steps
        |> Enum.filter(&pending?(&1["id"], facts))
        |> Comma.ReleaseManifestV2.order_steps(@manifest)
        |> Enum.reject(&(&1["phase"] == "contract"))

      required_mode =
        cond do
          # TLA: tla/salix/SalixLegacyMigrationRelease.tla::RejectLegacyPlan.
          Enum.any?(pending_steps, &(&1["phase"] == "legacy")) -> "blocked_legacy"
          Enum.any?(pending_steps, &(&1["phase"] == "exclusive")) -> "exclusive"
          true -> "online"
        end

      {:ok,
       %{
         schemaVersion: 2,
         manifestDigest: manifest_digest(),
         requiredMode: required_mode,
         pendingIDs: Enum.map(pending_steps, & &1["id"]),
         pendingSteps: pending_steps,
         providerPendingIDs: provider_pending_ids(facts),
         facts: %{
           catalogDigest: facts.catalog_digest
         }
       }}
    end
  end

  def manifest_digest, do: Comma.ReleaseManifestV2.manifest_digest(@manifest)

  defp facts do
    %{
      comma:
        ecto_status(Comma.Repo, [
          Application.app_dir(:comma_core, "priv/release_migrations")
        ]),
      billing: ecto_status(BillingCore.Repo),
      bridge:
        ecto_status(BridgeForTeams.Repo, [
          Application.app_dir(:bridge_for_teams_core, "priv/release_migrations")
        ]),
      alert_router: alert_router_ecto_status(),
      salix: salix_ecto_status(),
      clickhouse: apply(SalixAnalytics.Migrations, :plan, []),
      catalog_digest: catalog_digest(),
      catalog_current: catalog_current?(),
      require_provider: System.get_env("REQUIRE_PROVIDER", "false") == "true"
    }
  end

  # The salix control repo is foundation-only until its first consumer ships:
  # runtime.exs registers :ecto_repos only when `salix.database.url` is
  # configured. With no repo configured there are no observable versions; the
  # manifest's required-version check still fails the plan if a salix step
  # exists but the database is absent, so this cannot mask a missing store.
  defp salix_ecto_status do
    case Application.get_env(:salix_store, :ecto_repos, []) do
      [] ->
        []

      [repo | _] ->
        ecto_status(repo, [Application.app_dir(:salix_store, "priv/release_migrations")])
    end
  end

  # Alert Router is an optional, separately deployed subsystem. Existing Comma,
  # BFT, and Salix release jobs must not connect to its independent database or
  # schedule its migration unless that subsystem is explicitly selected for
  # the release job.
  defp alert_router_ecto_status do
    if :alert_router in Comma.enabled_subsystems() do
      ecto_status(AlertRouter.Repo)
    else
      :disabled
    end
  end

  defp ecto_status(repo, additional_directories \\ []) do
    directories = [
      apply(Ecto.Migrator, :migrations_path, [repo]) | additional_directories
    ]

    {:ok, migrations, _started} =
      apply(Ecto.Migrator, :with_repo, [
        repo,
        fn started -> apply(Ecto.Migrator, :migrations, [started, directories]) end
      ])

    migrations
  end

  defp catalog_digest do
    catalog = apply(Module.concat([Comma, Billing, PricingV1]), :catalog, [])
    :crypto.hash(:sha256, apply(Jason, :encode!, [catalog])) |> Base.encode16(case: :lower)
  end

  defp catalog_current? do
    catalog = apply(Module.concat([Comma, Billing, PricingV1]), :catalog, [])

    Enum.all?(Application.get_env(:billing_core, :ecto_repos, []), fn repo ->
      {:ok, current, _started} =
        apply(Ecto.Migrator, :with_repo, [
          repo,
          fn started ->
            apply(Module.concat([BillingCommerce]), :pricing_catalog_current?, [
              catalog,
              [repo: started]
            ])
          end
        ])

      current
    end)
  end

  defp validate_schema_facts(facts) do
    with :ok <-
           validate_optional_ecto(
             facts.alert_router,
             Map.fetch!(@known_versions, :alert_router),
             Map.fetch!(@required_versions, :alert_router),
             :alert_router
           ),
         :ok <-
           validate_ecto(
             facts.comma,
             @shared_ecto_versions,
             Map.fetch!(@required_versions, :comma),
             :comma
           ),
         :ok <-
           validate_ecto(
             facts.billing,
             @shared_ecto_versions,
             Map.fetch!(@required_versions, :billing),
             :billing
           ),
         :ok <-
           validate_ecto(
             facts.bridge,
             @shared_ecto_versions,
             Map.fetch!(@required_versions, :bridge),
             :bridge
           ),
         :ok <-
           validate_ecto(
             facts.salix,
             Map.fetch!(@known_versions, :salix),
             Map.fetch!(@required_versions, :salix),
             :salix
           ) do
      :ok
    end
  end

  defp validate_optional_ecto(:disabled, _known, _required, _owner), do: :ok

  defp validate_optional_ecto(actual, known, required, owner) do
    validate_ecto(actual, known, required, owner)
  end

  defp validate_ecto(actual, known, required, owner) do
    versions = Enum.map(actual, fn {_status, version, _name} -> version end)
    unknown = versions -- known
    missing = required -- versions

    cond do
      unknown != [] -> {:error, {:unknown_ecto_versions, owner, unknown}}
      missing != [] -> {:error, {:missing_ecto_versions, owner, missing}}
      true -> :ok
    end
  end

  defp validate_clickhouse({:ok, actual}) do
    cond do
      actual.manifest != @clickhouse_versions ->
        {:error, {:clickhouse_manifest_or_checksum_drift, actual.manifest}}

      actual.pending -- Map.keys(@clickhouse_versions) != [] ->
        {:error,
         {:unknown_clickhouse_pending_versions, actual.pending -- Map.keys(@clickhouse_versions)}}

      true ->
        :ok
    end
  end

  defp validate_clickhouse({:error, reason}), do: {:error, {:clickhouse_plan_failed, reason}}

  defp pending?("comma-local-seed", facts), do: not facts.catalog_current
  defp pending?("alert-router-" <> _version, %{alert_router: :disabled}), do: false
  defp pending?("alert-router-" <> version, facts), do: ecto_pending?(facts.alert_router, version)
  defp pending?("comma-" <> version, facts), do: ecto_pending?(facts.comma, version)
  defp pending?("billing-" <> version, facts), do: ecto_pending?(facts.billing, version)
  defp pending?("bridge-" <> version, facts), do: ecto_pending?(facts.bridge, version)
  defp pending?("salix-" <> version, facts), do: ecto_pending?(facts.salix, version)

  defp pending?("analytics-" <> version, facts) do
    String.to_integer(version) in (facts.clickhouse |> elem(1) |> Map.fetch!(:pending))
  end

  defp pending?(id, _facts) when is_binary(id), do: raise("unsupported V2 release step id: #{id}")

  defp provider_pending_ids(facts) do
    if(facts.require_provider, do: ["billing-provider"], else: [])
    |> Enum.sort()
  end

  defp ecto_pending?(migrations, version) do
    target = String.to_integer(version)
    Enum.any?(migrations, fn {status, actual, _name} -> status == :down and actual == target end)
  end
end
