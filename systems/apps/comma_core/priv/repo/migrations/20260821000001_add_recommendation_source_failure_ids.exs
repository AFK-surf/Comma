defmodule Comma.Repo.Migrations.AddRecommendationSourceFailureIds do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_runs) do
      add(:source_failure_ids, {:array, :text}, null: false, default: [])
    end
  end
end
