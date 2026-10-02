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
    * `BridgeForTeams.EnvironmentRuntimeObserver` — asynchronously projects
      device runtime changes into agent runtime Operations events.
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

    children =
      [
        BridgeForTeams.Repo,
        {Task.Supervisor, name: BridgeForTeams.TaskSupervisor},
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
        BridgeForTeams.EnvironmentRuntimeObserver,
        BridgeForTeams.Observability.Pruner
      ])
      |> maybe_add(
        Application.get_env(:bridge_for_teams_core, :storage_metering, [])
        |> Keyword.get(:enabled, false),
        BridgeForTeams.StorageMetering.Reconciler
      )
      |> maybe_add(
        slack_history_reconciler_enabled?(),
        BridgeForTeams.SlackHistoryOnboarding.Reconciler
      )

    opts = [strategy: :one_for_one, name: BridgeForTeams.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add(children, true, child), do: children ++ [child]
  defp maybe_add(children, _enabled, _child), do: children

  defp tenant_config_checker_enabled? do
    :bridge_for_teams_core
    |> Application.get_env(BridgeForTeams.Salix.TenantConfigChecker, [])
    |> Keyword.get(:enabled, true)
  end

  defp slack_history_reconciler_enabled? do
    :bridge_for_teams_core
    |> Application.get_env(BridgeForTeams.SlackHistoryOnboarding.Reconciler, [])
    |> Keyword.get(:enabled, false)
  end

  defp configure_salix_im_diagnostic_sink do
    sink =
      Application.get_env(
        :salix_im,
        :diagnostic_sink,
        BridgeForTeams.Observability.SalixIMSink
      )

    Application.put_env(:salix_im, :diagnostic_sink, sink)
  end

  defp configure_salix_schedule_diagnostic_sink do
    sink =
      Application.get_env(
        :salix_cluster,
        :schedule_diagnostic_sink,
        BridgeForTeams.Observability.SalixScheduleSink
      )

    Application.put_env(:salix_cluster, :schedule_diagnostic_sink, sink)
  end
end
