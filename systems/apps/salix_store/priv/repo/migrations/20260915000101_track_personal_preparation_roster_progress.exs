defmodule SalixStore.Repo.Migrations.TrackPersonalPreparationRosterProgress do
  use Ecto.Migration

  def change do
    alter table(:meeting_personal_preparations) do
      add(:resolved_count, :integer, null: false, default: 0)
    end
  end
end
