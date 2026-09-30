defmodule Comma.Repo.Migrations.RetainNativeRecommendationPreferences do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_profiles) do
      add(:native_source_preferences, :map, default: %{}, null: false)
    end
  end
end
