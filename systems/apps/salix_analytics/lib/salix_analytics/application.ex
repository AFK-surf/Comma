defmodule SalixAnalytics.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Per-stream archive counters. Owned by the application master rather than
    # by the worker: a sequence run must survive a worker's crash loop, or every
    # restart would look like a gap to `archive.verify`.
    _ = SalixAnalytics.EventArchive.Sequence.create_table()

    # The buffer needs the same owner as the counters, and for a sharper reason.
    # `Worker.enqueue/2` runs in the agent-loop process, so whichever of the two
    # touches the table first OWNS it. If the worker crashes and an enqueue
    # lands before the supervisor restarts it, the table is created by a
    # transient session actor and dies when that actor does — taking every
    # buffered row from every process with it, silently: `take_buffer/1`
    # rescues the missing table, the size never reaches `max_buffer`, and no
    # telemetry fires. Creating it here means it outlives any worker crash loop.
    _ = SalixAnalytics.EventArchive.Worker.ensure_buffer()
    _ = SalixAnalytics.EventArchive.Recipients.verify_at_boot()

    # Slack mirror writes are no longer buffered in this app. The webhook
    # inserts into a PostgreSQL outbox owned by salix_im; this app only
    # answers the synchronous ClickHouse insert.
    children =
      typed_sink_children() ++
        event_archive_children() ++ SalixAnalytics.SlackSemanticIndex.children()

    opts = [strategy: :one_for_one, name: SalixAnalytics.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp typed_sink_children do
    if Application.get_env(:salix_analytics, :typed_sink_worker, true) do
      [
        SalixAnalytics.TypedSinkWorker,
        {SalixAnalytics.TypedSinkWorker, name: SalixAnalytics.AgentObservabilitySinkWorker}
      ]
    else
      []
    end
  end

  # The encrypted agent event archive's ClickHouse writer. Started only when
  # recipients are configured, so a deployment that has not opted in carries no
  # extra process (docs/observability.md).
  defp event_archive_children do
    case SalixAnalytics.EventArchive.Recipients.get() do
      [] -> []
      _recipients -> [SalixAnalytics.EventArchive.Worker]
    end
  end
end
