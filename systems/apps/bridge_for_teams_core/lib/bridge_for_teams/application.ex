defmodule BridgeForTeams.Application do
  @moduledoc """
  Supervision tree for the `bridge_for_teams_core` OTP app (design §3).

  Children:
    * `BridgeForTeams.Repo` — Postgres system of record.
    * `BridgeForTeams.Cache` — node-local ETS read cache.
    * `BridgeForTeams.RateLimit` — Redis-owned global magic-link limiter.
    * `BridgeForTeams.Salix.ReadCache` — node-local read-through cache for
      Salix `:erpc` reads on dashboard render paths.
    * `BridgeForTeams.Salix.TenantConfigChecker` — asynchronously ensures
      BFT-owned Salix tenant config without blocking startup or requests.
    * `BridgeForTeams.Salix.Reconciler` — drains `reconcile_outbox` to Salix
      (Postgres → S3 control-plane), at-least-once / idempotent.
    * `BridgeForTeams.EnvironmentProvisioning.Reconciler` — reconciles runner-backed
      provision requests against live Salix env attach state and timeout policy.
    * `BridgeForTeams.Observability.Pruner` — runs the shared Operations
      retention pruning boundary on a schedule.
    * `BridgeForTeams.DashboardProjection.Reconciler` — refreshes per-project
      dashboard snapshots outside request and LiveView processes.
    * `BridgeForTeams.SlackHistoryOnboarding.Reconciler` — when explicitly
      enabled, advances one persisted bounded Slack-history import transition
      at a time; PostgreSQL run/receipt/lease state remains the correctness
      owner.

  Reconcile/event consumers run in this core app alongside the domain contexts.
  """
  use Application

  @impl true
  def start(_type, _args) do
    configure_salix_im_diagnostic_sink()
    configure_salix_schedule_diagnostic_sink()
    SalixStore.StationMembers.register(BridgeForTeams.StationMembers)

    children =
      [
        BridgeForTeams.Repo,
        {SystemsRuntime.TaskSupervisor, name: BridgeForTeams.TaskSupervisor},
        BridgeForTeams.Cache,
        BridgeForTeams.RateLimit,
        BridgeForTeams.Salix.ReadCache
      ]
      |> maybe_add(
        tenant_config_checker_enabled?(),
        BridgeForTeams.Salix.TenantConfigChecker
      )
      |> Kernel.++([
        BridgeForTeams.Salix.Reconciler,
        BridgeForTeams.DashboardProjection.Reconciler,
        BridgeForTeams.EnvironmentProvisioning.Reconciler,
        BridgeForTeams.Observability.Pruner
      ])
      |> maybe_add(
        SystemsRuntime.get_env(:bridge_for_teams_core, :storage_metering, [])
        |> Keyword.get(:enabled, false),
        BridgeForTeams.StorageMetering.Reconciler
      )
      |> maybe_add(
        slack_history_reconciler_enabled?(),
        BridgeForTeams.SlackHistoryOnboarding.Reconciler
      )
      |> maybe_add(
        SystemsRuntime.get_env(:bridge_for_teams_core, BridgeForTeams.DailyBrief.Retention, [])
        |> Keyword.get(:enabled, true),
        BridgeForTeams.DailyBrief.Retention
      )
      |> maybe_add(
        SystemsRuntime.get_env(:bridge_for_teams_core, BridgeForTeams.ContextLifecycle.Worker, [])
        |> Keyword.get(:enabled, true),
        BridgeForTeams.ContextLifecycle.Worker
      )
      |> maybe_add(
        SystemsRuntime.get_env(
          :bridge_for_teams_core,
          BridgeForTeams.DailyBrief.DeliveryWorker,
          []
        )
        |> Keyword.get(:enabled, true),
        BridgeForTeams.DailyBrief.DeliveryWorker
      )

    opts = [strategy: :one_for_one, name: BridgeForTeams.Supervisor]
    SystemsRuntime.Supervisor.start_link(children, opts)
  end

  defp maybe_add(children, true, child), do: children ++ [child]
  defp maybe_add(children, _enabled, _child), do: children

  defp tenant_config_checker_enabled? do
    :bridge_for_teams_core
    |> SystemsRuntime.get_env(BridgeForTeams.Salix.TenantConfigChecker, [])
    |> Keyword.get(:enabled, true)
  end

  defp slack_history_reconciler_enabled? do
    :bridge_for_teams_core
    |> SystemsRuntime.get_env(BridgeForTeams.SlackHistoryOnboarding.Reconciler, [])
    |> Keyword.get(:enabled, false)
  end

  defp configure_salix_im_diagnostic_sink do
    sink =
      SystemsRuntime.get_env(
        :salix_im,
        :diagnostic_sink,
        BridgeForTeams.Observability.SalixIMSink
      )

    SystemsRuntime.put_env(:salix_im, :diagnostic_sink, sink)
  end

  defp configure_salix_schedule_diagnostic_sink do
    sink =
      SystemsRuntime.get_env(
        :salix_cluster,
        :schedule_diagnostic_sink,
        BridgeForTeams.Observability.SalixScheduleSink
      )

    SystemsRuntime.put_env(:salix_cluster, :schedule_diagnostic_sink, sink)
  end
end
