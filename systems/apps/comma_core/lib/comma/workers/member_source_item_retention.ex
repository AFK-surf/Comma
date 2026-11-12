defmodule Comma.Workers.MemberSourceItemRetention do
  @moduledoc """
  Hourly, bounded deletion of member source items and open threads past their
  retention periods.
  """

  use Oban.Worker, queue: :comma_external, max_attempts: 3

  alias Comma.{MemberSourceItems, OpenThreads}

  @batch_size 1_000
  @max_batches 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = SystemsClock.utc_now()

    for expire <- [&MemberSourceItems.expire/2, &OpenThreads.expire_all/2] do
      Enum.reduce_while(1..@max_batches, :ok, fn _batch, :ok ->
        if expire.(now, @batch_size) < @batch_size,
          do: {:halt, :ok},
          else: {:cont, :ok}
      end)
    end

    :ok
  end
end
