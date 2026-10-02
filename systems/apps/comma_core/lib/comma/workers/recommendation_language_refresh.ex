defmodule Comma.Workers.RecommendationLanguageRefresh do
  @moduledoc """
  Regenerates a member's Routines after the account language changes. The
  profile update enqueues it in the same transaction, so the request stays
  bounded and a failed regeneration retries instead of failing the save.
  """
  use Oban.Worker,
    queue: :comma_recommendation_control,
    max_attempts: 5,
    priority: 2,
    unique: [period: 60, fields: [:worker, :args], states: :incomplete]

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Comma.Recommendations.language_changed(user_id)
  end
end
