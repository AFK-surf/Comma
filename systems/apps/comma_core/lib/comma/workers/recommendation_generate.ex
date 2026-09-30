defmodule Comma.Workers.RecommendationGenerate do
  @moduledoc "Durable execution owner for one member briefing."
  use Oban.Worker, queue: :comma_recommendations, max_attempts: 3

  alias Comma.{RecommendationBudgets, Recommendations}

  @impl Oban.Worker
  def timeout(_job), do: RecommendationBudgets.run_hard_cap_seconds() * 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Recommendations.run_context(run_id) do
      {:ok, %{run: %{status: status}}} when status not in ~w(pending running) ->
        :ok

      {:error, :not_found} ->
        :ok

      {:ok, %{run: run}} ->
        if remaining_ms(run) <= 0 do
          settle(run_id, :recommendation_run_timed_out)
        else
          case Application.fetch_env!(:comma_core, :recommendation_runtime_mod).generate(run_id) do
            :ok -> :ok
            {:error, reason} -> settle(run_id, reason)
          end
        end
    end
  end

  def remaining_ms(run) do
    RecommendationBudgets.run_hard_cap_seconds() * 1_000 -
      DateTime.diff(DateTime.utc_now(), run.inserted_at, :millisecond)
  end

  defp settle(run_id, reason) do
    case Recommendations.fail_if_active(run_id, reason) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end
end
