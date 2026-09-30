defmodule Comma.Repo.Migrations.FenceMemberRecommendations do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_runs) do
      add(:relevance_mode, :string, default: "generic", null: false)
      add(:member_subjects, :map, default: %{}, null: false)
    end

    alter table(:comma_recommendation_profiles) do
      add(:published_member_subjects, :map, default: %{}, null: false)
    end
  end
end
