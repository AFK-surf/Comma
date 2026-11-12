defmodule Comma.Repo.Migrations.AddRecommendationAddedItems do
  use Ecto.Migration

  # The matters a member added to Routine themselves, through their Router.
  # Every envelope read shows them as the briefing's first card.
  def change do
    alter table(:comma_recommendation_profiles) do
      add(:added_items, {:array, :map}, default: [], null: false)
    end
  end
end
