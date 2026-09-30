defmodule Comma.Workers.RecommendationSourceRefresh do
  @moduledoc false
  use Oban.Worker, queue: :comma_external, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id, "source_revision" => revision}}) do
    case Application.get_env(:comma_core, :recommendation_runtime_mod) do
      nil -> {:error, :recommendation_runtime_not_configured}
      module -> module.refresh_sources(profile_id, revision)
    end
  end
end
