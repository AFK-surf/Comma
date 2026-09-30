defmodule SalixAgent.SessionHistory.Supervisor do
  @moduledoc "Search-only pools and maintenance. No Session work runs under this supervisor."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    opts =
      SalixStore.Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size])
      |> Keyword.merge(pool_size: 4, queue_target: 50, queue_interval: 100)

    Supervisor.init(
      [
        {SalixStore.SessionHistoryRepo, opts},
        {Finch, name: SalixAgent.SessionHistory.HTTP, pools: %{default: [size: 2, count: 1]}},
        SalixAgent.SessionHistory.Scheduler,
        SalixAgent.SessionHistory.Worker,
        Supervisor.child_spec({SalixAgent.SessionHistory.Recent, []}, id: :recent_history_a),
        Supervisor.child_spec({SalixAgent.SessionHistory.Recent, []}, id: :recent_history_b),
        Supervisor.child_spec({SalixAgent.SessionHistory.Recent, []}, id: :recent_history_c),
        Supervisor.child_spec({SalixAgent.SessionHistory.Recent, []}, id: :recent_history_d)
      ],
      strategy: :rest_for_one
    )
  end

  def children do
    if Application.get_env(:salix_store, :start_repo, false) and
         Application.get_env(:salix_agent, :session_history_enabled, true),
       do: [Supervisor.child_spec(__MODULE__, restart: :temporary)],
       else: []
  end
end
