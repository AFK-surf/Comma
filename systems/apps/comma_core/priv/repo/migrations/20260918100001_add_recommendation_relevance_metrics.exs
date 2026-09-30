defmodule Comma.Repo.Migrations.AddRecommendationRelevanceMetrics do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_profiles) do
      add(:relevance_mode, :string)
      add(:published_metrics, :map, default: %{}, null: false)
    end

    alter table(:comma_recommendation_runs) do
      add(:metrics, :map, default: %{}, null: false)
    end
  end
end
