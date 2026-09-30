defmodule Comma.Repo.Migrations.AddMemberSourceRules do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_profiles) do
      add(:member_source_rules, :map, default: %{}, null: false)
    end
  end
end
