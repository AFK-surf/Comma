defmodule Comma.Repo.Migrations.AddRecommendationSourceEvidenceRecorded do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_runs) do
      add(:source_evidence_recorded, :boolean, null: false, default: false)
    end
  end
end
