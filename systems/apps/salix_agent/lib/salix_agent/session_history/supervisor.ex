defmodule SalixAgent.SessionHistory.Supervisor do
  @moduledoc "Search-only pools and maintenance. No Session work runs under this supervisor."
  use Supervisor

  def start_link(opts),
    do: SystemsRuntime.Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

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
        SalixAgent.SessionHistory.Worker
      ],
      strategy: :rest_for_one
    )
  end

  # Only the Agent's ring node indexes and archives its Sessions, so this
  # supervisor restarts after a failure. A keeper between it and the
  # application bounds the restarts: a crash loop stops history work on this
  # node and leaves the Agents running.
  @keeper_max_restarts 5
  @keeper_max_seconds 60

  def children do
    if SystemsRuntime.get_env(:salix_store, :start_repo, false) and
         SystemsRuntime.get_env(:salix_agent, :session_history_enabled, true),
       do: [keeper_spec()],
       else: []
  end

  def keeper_spec do
    %{
      id: SalixAgent.SessionHistory.Keeper,
      start:
        {SystemsRuntime.Supervisor, :start_link,
         [
           [__MODULE__],
           [
             strategy: :one_for_one,
             max_restarts: @keeper_max_restarts,
             max_seconds: @keeper_max_seconds,
             name: SalixAgent.SessionHistory.Keeper
           ]
         ]},
      type: :supervisor,
      restart: :temporary
    }
  end
end
