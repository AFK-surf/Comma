defmodule Comma.Workers.RecommendationReconcile do
  @moduledoc false
  use Oban.Worker, queue: :comma_recommendation_control, max_attempts: 5, priority: 2

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def backoff(_job), do: 15

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id} = args}) do
    Application.fetch_env!(:comma_core, :recommendation_runtime_mod).reconcile_profile(profile_id,
      retire_renderer: args["retire_renderer"] == true
    )
  end
end
