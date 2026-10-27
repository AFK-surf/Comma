defmodule Comma.Workers.MiniAppCleanup do
  @moduledoc """
  Bounded Mini App cleanup (`Comma.MiniApps.cleanup/1`). With an `app_id`,
  one app (enqueued at delete; it runs again until the app's objects are
  gone). Without one (hourly cron), up to 50 apps with deleted rows, Versions
  past retention, or failed Versions whose 7 days are over.
  """

  use Oban.Worker, queue: :comma_external, max_attempts: 20

  @batch 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"app_id" => app_id}}) do
    case Comma.MiniApps.cleanup(app_id) do
      :done -> :ok
      :more -> {:snooze, 5}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}) do
    @batch
    |> Comma.MiniApps.cleanup_candidates()
    |> Enum.each(&Comma.MiniApps.cleanup/1)

    :ok
  end
end
