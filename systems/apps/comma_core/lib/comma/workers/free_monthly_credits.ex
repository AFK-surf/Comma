defmodule Comma.Workers.FreeMonthlyCredits do
  @moduledoc """
  Hourly cron: issues this month's non-LLM credits to free Users
  (`Comma.Billing.FreeMonthlyCredits.converge/0`). A new month, or a Subscription
  that ended, takes effect at the next run.
  """

  use Oban.Worker, queue: :comma_external, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Comma.Billing.FreeMonthlyCredits.converge()
end
