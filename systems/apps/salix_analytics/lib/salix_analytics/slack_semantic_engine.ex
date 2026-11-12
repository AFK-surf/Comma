defmodule SalixAnalytics.SlackSemanticEngine do
  @moduledoc """
  Oban Basic storage with bounded queue discovery and priority at dispatch.
  Delayed work stays durable without taking an executor merely to yield.
  """
  @behaviour Oban.Engine
  import Ecto.Query
  alias Oban.{Job, Repo}

  Code.ensure_loaded!(Oban.Engines.Basic)

  # Keep Oban's insertion, settlement, fencing and recovery paths.
  for {name, arity} <- Oban.Engine.behaviour_info(:callbacks),
      {name, arity} not in [fetch_jobs: 3, check_available: 1],
      function_exported?(Oban.Engines.Basic, name, arity) do
    args = Macro.generate_arguments(arity, __MODULE__)
    defdelegate unquote(name)(unquote_splicing(args)), to: Oban.Engines.Basic
  end

  def check_available(conf) do
    queues =
      for queue <- ~w(semantic_text semantic_files),
          Repo.exists?(conf, from(j in Job, where: j.state == "available" and j.queue == ^queue)),
          do: queue

    {:ok, queues}
  end

  def fetch_jobs(_conf, %{paused: true} = meta, _running), do: {:ok, {meta, []}}

  def fetch_jobs(_conf, %{limit: limit} = meta, running) when map_size(running) >= limit,
    do: {:ok, {meta, []}}

  def fetch_jobs(conf, meta, running) do
    # Live text also preempts historical media on the shared GPU. A delayed
    # file retry never holds the text lane. These are indexed existence probes.
    lanes =
      if meta.queue == "semantic_files", do: ~w(semantic_text semantic_files), else: [meta.queue]

    live =
      from(j in Job,
        where: j.queue in ^lanes and j.priority == 0 and j.state in ["available", "executing"],
        select: 1,
        limit: 1
      )

    Repo.transaction(conf, fn ->
      # Choose an indexed lane before claiming. A per-row OR/NOT EXISTS filter
      # would still walk the historical backlog when live work holds the lane.
      subset =
        from(j in Job,
          where: j.state == "available" and j.queue == ^meta.queue,
          order_by: [asc: j.priority, asc: j.scheduled_at, asc: j.id],
          limit: ^(meta.limit - map_size(running)),
          lock: "FOR UPDATE SKIP LOCKED",
          select: [:id]
        )

      source_live = SalixStore.SlackSearchSources.live_pending?()

      subset =
        if source_live or Repo.exists?(conf, live),
          do: where(subset, [j], j.priority == 0),
          else: subset

      query =
        Job
        |> with_cte("subset", materialized: true, as: ^subset)
        |> join(:inner, [j], s in fragment("\"subset\""), on: j.id == s.id)
        |> where([j], j.attempt < j.max_attempts)
        |> select([j], j)

      {_, jobs} =
        Repo.update_all(conf, query,
          set: [
            state: "executing",
            attempted_at: SystemsClock.utc_now(),
            attempted_by: [meta.node, meta.uuid]
          ],
          inc: [attempt: 1]
        )

      {meta, jobs}
    end)
  end
end
