defmodule Comma.Workers.MemberSourceItemRetention do
  @moduledoc "Hourly, bounded deletion of member source items past their retention period."

  use Oban.Worker, queue: :comma_external, max_attempts: 3

  alias Comma.MemberSourceItems

  @batch_size 1_000
  @max_batches 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Enum.reduce_while(1..@max_batches, :ok, fn _batch, :ok ->
      if MemberSourceItems.expire(now, @batch_size) < @batch_size,
        do: {:halt, :ok},
        else: {:cont, :ok}
    end)
  end
end
