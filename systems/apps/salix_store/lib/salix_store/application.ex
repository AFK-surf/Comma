defmodule SalixStore.Application do
  @moduledoc """
  Storage-kernel supervision root.

  Starts the shared `SalixStore.Finch` default pool used by the S3 backend and
  other Salix HTTP paths. The fake backend needs an ETS table owner, which is
  started only when that backend is selected.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Owned by the application master: no separately crashable state holder
    # (the in-flight gauges must survive any worker's crash loop).
    _ = SalixStore.Inflight.create_table()

    children =
      repo_children() ++
        [
          SalixStore.Ids,
          SalixStore.Inflight.Poller,
          # The shared CommaLog JSONL logger is started by the :comma_log application
          # (a dependency), so it is already up before this app boots.
          {Finch,
           name: SalixStore.Finch,
           pools: %{
             default: [size: 50, count: 1]
           }}
        ] ++ fake_children()

    opts = [strategy: :one_for_one, name: SalixStore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The control-plane Postgres repo (docs/storage-search.md).
  # `config/runtime.exs` sets :start_repo only when `salix.database.url` is
  # configured, so nodes without the control database run S3-only as before.
  # The whereis guard covers release-migration contexts where Ecto.Migrator's
  # with_repo already started the repo before this application boots.
  #
  # The readiness probes start right after the repo: they are the signals
  # `Comma.PodLifecycle.ready(:salix)` consults, so the pod stays out of service
  # until each control-metadata cutover marker exists (mirrors how comma_core
  # starts Comma.SchemaReadiness after Comma.Repo). One probe per migrated dataset.
  defp repo_children do
    if Application.get_env(:salix_store, :start_repo, false) and
         is_nil(Process.whereis(SalixStore.Repo)) do
      [
        SalixStore.Repo,
        SalixStore.TenantApiKeyReadiness,
        SalixStore.ProviderCredentialsReadiness,
        SalixStore.TenantConfigsReadiness,
        SalixStore.SchedulesReadiness,
        SalixStore.OAuthAppsReadiness,
        SalixStore.MeetingGroupProjectionReadiness,
        SalixStore.SlackRouterThreadParticipationSweeper,
        {SalixStore.AgentVMMSettlementSweeper,
         interval_ms:
           Application.get_env(:salix_store, :agent_vmm_settlement_sweep_interval_ms, 5_000)}
      ]
    else
      []
    end
  end

  defp fake_children do
    if SalixStore.Config.backend() == SalixStore.S3.Fake do
      [SalixStore.S3.Fake]
    else
      []
    end
  end
end
