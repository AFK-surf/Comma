defmodule Comma.Analytics.ProfileSweep do
  @moduledoc """
  One recurring Oban job across Comma pods. Its args retain the accepted page cursor.

  Cron admits a job only when no incomplete sweep exists. Each execution exports
  100 Users, then snoozes for 30 seconds. A complete scan waits 24 hours.
  At 10,000 Users a scan takes about 50 minutes plus request time, regardless of pods.
  Failed pages retain their cursor. Pod loss can replay the last uncheckpointed page,
  but a restart does not restart the scan. Profiles never emit registration events.
  """
  use Oban.Worker,
    queue: :comma_analytics,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  import Ecto.Query
  alias Comma.{Analytics, Repo}

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    wait = (job.args["next_at"] || 0) - SystemsClock.system_time(:second)

    cond do
      not Analytics.configured?() ->
        :ok

      wait > 0 ->
        {:snooze, wait}

      true ->
        case Analytics.Export.attempt(fn -> export_page(job) end) do
          {:snooze, _} = result -> result
          _ -> {:snooze, 60}
        end
    end
  end

  defp export_page(job) do
    case Analytics.Export.page(job.args["after"] || "") do
      {:ok, cursor} ->
        delay = if(is_nil(cursor), do: 86_400, else: 30)
        # Keep the due time with the cursor, including a crash before Oban acknowledges snooze.
        args = %{"after" => cursor || "", "next_at" => SystemsClock.system_time(:second) + delay}
        job |> Ecto.Changeset.change(args: args) |> Repo.update!()
        {:snooze, delay}

      {:error, _} ->
        {:snooze, 60}
    end
  end

  # Only this short, observational job is rescued. Other workers retain their policies.
  # The one-minute cutoff exceeds its 30-second execution budget.
  def rescue_jobs(conf) do
    cutoff = DateTime.add(SystemsClock.utc_now(), -60, :second)

    candidates =
      from(job in Oban.Job,
        where:
          job.worker == "Comma.Analytics.ProfileSweep" and job.state == "executing" and
            job.attempted_at < ^cutoff,
        order_by: job.id,
        limit: 1,
        select: job.id
      )

    query =
      from(job in Oban.Job,
        where: job.id in subquery(candidates),
        update: [
          set: [
            state: "available",
            max_attempts: fragment("GREATEST(?, ? + 1)", job.max_attempts, job.attempt)
          ]
        ]
      )

    Oban.Repo.update_all(conf, query, [])
  end
end
