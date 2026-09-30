defmodule Comma.Workers.RecommendationRunTimeout do
  @moduledoc "Settles a generation whose durable request budget has expired."
  use Oban.Worker, queue: :comma_recommendation_control, max_attempts: 5

  alias Comma.Recommendations
  alias Comma.Workers.RecommendationGenerate

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Recommendations.run_context(run_id) do
      {:ok, %{run: %{status: status}}} when status not in ~w(pending running) ->
        :ok

      {:error, :not_found} ->
        :ok

      {:ok, %{run: run}} ->
        case RecommendationGenerate.remaining_ms(run) do
          remaining when remaining > 0 ->
            {:snooze, max(1, ceil(remaining / 1_000))}

          _ ->
            case Recommendations.fail_if_active(run_id, :recommendation_run_timed_out) do
              {:ok, _} -> :ok
              {:error, _} = error -> error
            end
        end
    end
  end
end
