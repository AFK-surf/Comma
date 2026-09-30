defmodule Comma.Repo.Migrations.AddRecommendationSourceEvidence do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_runs) do
      add(:source_evidence, :map, null: false, default: fragment("'{}'::jsonb"))
    end
  end
end
