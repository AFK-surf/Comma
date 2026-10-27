defmodule Comma.Repo.Migrations.AddRecommendationDismissedItems do
  use Ecto.Migration

  # The source items a member dismissed from Routine, as digests of their
  # source and URL with the dismissal time. Routine and proactive attention
  # leave them out.
  def change do
    alter table(:comma_recommendation_profiles) do
      add(:dismissed_items, :map, default: %{}, null: false)
    end
  end
end
