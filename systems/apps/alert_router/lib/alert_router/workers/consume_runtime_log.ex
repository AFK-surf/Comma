defmodule AlertRouter.Workers.ConsumeRuntimeLog do
  @moduledoc "Bounded, durable continuation of an authenticated storage notification."
  use Oban.Worker,
    queue: :runtime_log,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:notification_id],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"object" => object}}) do
    case AlertRouter.RuntimeLog.consume(object) do
      {:ok, :done} -> :ok
      {:error, reason} -> {:error, reason}
      :ignored -> :ok
    end
  end
end
