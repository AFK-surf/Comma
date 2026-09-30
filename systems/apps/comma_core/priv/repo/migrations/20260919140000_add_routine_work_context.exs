defmodule Comma.Repo.Migrations.AddRoutineWorkContext do
  use Ecto.Migration

  def change do
    alter table(:comma_recommendation_profiles) do
      add(:work_context, :text, default: "", null: false)
    end
  end
end
