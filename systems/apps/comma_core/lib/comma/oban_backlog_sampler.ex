defmodule Comma.ObanBacklogSampler do
  @moduledoc """
  Periodically exports bounded queue depth and oldest-age facts for Comma-owned
  Oban queues. It never enumerates jobs or exports job/operation identifiers.
  """

  use SystemsRuntime.Server

  import Ecto.Query

  require Logger

  @queues ~w(comma_external comma_recommendations comma_recommendation_control)
  @backlog_states ~w(available scheduled retryable executing)
  @default_interval_ms 10_000

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          SystemsRuntime.get_env(
            :comma_core,
            :oban_backlog_sample_interval_ms,
            @default_interval_ms
          )
        )
    }

    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :sample)
    {:ok, state}
  end

  @doc false
  def sample(repo \\ Comma.Repo, now \\ SystemsClock.utc_now()) do
    rows =
      from(job in Oban.Job,
        where: job.queue in ^@queues and job.state in ^@backlog_states,
        group_by: job.queue,
        select: {job.queue, count(job.id), min(job.scheduled_at)}
      )
      |> repo.all()
      |> Map.new(fn {queue, depth, oldest_at} -> {queue, {depth, oldest_at}} end)

    Enum.each(@queues, fn queue ->
      {depth, oldest_at} = Map.get(rows, queue, {0, nil})

      oldest_age_seconds =
        case oldest_at do
          %DateTime{} = timestamp ->
            max(DateTime.diff(now, timestamp, :second), 0)

          %NaiveDateTime{} = timestamp ->
            max(NaiveDateTime.diff(DateTime.to_naive(now), timestamp), 0)

          nil ->
            0
        end

      CommaProduct.Telemetry.emit_backlog_sample(queue, depth, oldest_age_seconds)
    end)

    :ok
  end

  @impl true
  def handle_info(:sample, state) do
    try do
      sample()
    rescue
      error ->
        Logger.warning("comma_oban_backlog_sample_failed error=#{Exception.message(error)}")
    end

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :sample, state.interval_ms)
    {:noreply, state}
  end
end
