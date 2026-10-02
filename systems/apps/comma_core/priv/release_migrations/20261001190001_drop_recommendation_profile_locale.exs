defmodule Comma.Repo.Migrations.DropRecommendationProfileLocale do
  @moduledoc """
  Retire the Routine profile's client-reported locale. `comma_users.locale`
  (20261001190000) holds the app language and was seeded from this column;
  no runtime after that release reads or writes it.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:comma_recommendation_profiles) do
      remove(:locale)
    end
  end

  def down do
    alter table(:comma_recommendation_profiles) do
      add(:locale, :string)
    end
  end
end
