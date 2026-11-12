defmodule Comma.Workers.AccountDeletionSweep do
  @moduledoc """
  Hourly cron: deletes the accounts whose seven days after a confirmed
  deletion are over (`Comma.AccountDeletion.delete_due/0`).
  """

  use Oban.Worker, queue: :comma_external, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Comma.AccountDeletion.delete_due()
    :ok
  end
end
