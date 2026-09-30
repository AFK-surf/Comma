defmodule Comma.ObanPlugins.OperationLifeline do
  @moduledoc """
  Rescues orphaned durable-operation jobs without consuming their final attempt.

  Oban's standard Lifeline discards an orphan when its current attempt equals
  `max_attempts`. Durable operations own their own retry and terminal state, so
  a process death must leave enough Oban budget for the operation to re-enter
  and make that decision itself.

  Routine jobs use their own eight-minute rescue threshold. A rescued
  generation checks its original deadline before any source or model call.
  Each rescue pass selects at most 1,000 jobs from each class.
  """

  @behaviour Oban.Plugin

  use GenServer

  import Ecto.Query

  alias Oban.{Peer, Repo, Validation}

  defstruct [
    :conf,
    :timer,
    interval: :timer.minutes(1),
    rescue_after: :timer.minutes(60),
    limit: 1_000
  ]

  @impl Oban.Plugin
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, struct!(__MODULE__, opts), name: name)
  end

  @impl Oban.Plugin
  def validate(opts) do
    Validation.validate_schema(opts,
      conf: :any,
      name: :any,
      interval: :pos_integer,
      rescue_after: :pos_integer,
      limit: :pos_integer
    )
  end

  @impl GenServer
  def init(state), do: {:ok, schedule(state)}

  @impl GenServer
  def handle_info(:rescue, state) do
    if Peer.leader?(state.conf) do
      Repo.transaction(
        state.conf,
        fn ->
          rescue_jobs(state.conf, state.rescue_after, state.limit)
          rescue_recommendation_jobs(state.conf, state.limit)
        end,
        on_exhausted: :log
      )
    end

    {:noreply, schedule(state)}
  end

  @doc false
  def rescue_jobs(conf, rescue_after) when is_integer(rescue_after) and rescue_after > 0 do
    rescue_jobs(conf, rescue_after, 1_000)
  end

  @doc false
  def rescue_jobs(conf, rescue_after, limit)
      when is_integer(rescue_after) and rescue_after > 0 and is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -rescue_after, :millisecond)

    candidates =
      from(job in Oban.Job,
        where:
          job.state == "executing" and job.attempted_at < ^cutoff and
            fragment(
              """
              EXISTS (
                SELECT 1
                FROM comma_external_operations AS operation
                WHERE operation.operation_id = ?->>'operation_id'
              )
              """,
              job.args
            ),
        order_by: [asc: job.attempted_at, asc: job.id],
        limit: ^limit,
        select: job.id
      )

    query =
      from(job in Oban.Job,
        join: candidate in subquery(candidates),
        on: candidate.id == job.id,
        update: [
          set: [
            state: "available",
            max_attempts: fragment("GREATEST(?, ? + 1)", job.max_attempts, job.attempt)
          ]
        ],
        select: map(job, [:id, :queue, :state, :max_attempts])
      )

    Repo.update_all(conf, query, [])
  end

  @doc false
  def rescue_recommendation_jobs(conf, limit \\ 1_000) do
    # A process lost with its Pod cannot report an Oban failure. Only after the
    # full run budget can it be rescued without overlapping a valid producer.
    # Its next execution settles the run before any provider/model call.
    cutoff =
      DateTime.add(DateTime.utc_now(), -Comma.RecommendationBudgets.run_hard_cap_seconds(), :second)

    workers =
      Enum.map(
        [
          Comma.Workers.RecommendationGenerate,
          Comma.Workers.RecommendationRunTimeout,
          Comma.Workers.RecommendationReconcile
        ],
        &(Atom.to_string(&1) |> String.replace_prefix("Elixir.", ""))
      )

    candidates =
      from(job in Oban.Job,
        where: job.state == "executing" and job.worker in ^workers and job.attempted_at < ^cutoff,
        order_by: [asc: job.attempted_at, asc: job.id],
        limit: ^limit,
        select: job.id
      )

    query =
      from(job in Oban.Job,
        join: candidate in subquery(candidates),
        on: candidate.id == job.id,
        update: [
          set: [
            state: "available",
            max_attempts: fragment("GREATEST(?, ? + 1)", job.max_attempts, job.attempt)
          ]
        ],
        select: map(job, [:id, :queue, :state, :max_attempts])
      )

    Repo.update_all(conf, query, [])
  end

  defp schedule(state) do
    %{state | timer: Process.send_after(self(), :rescue, state.interval)}
  end
end
