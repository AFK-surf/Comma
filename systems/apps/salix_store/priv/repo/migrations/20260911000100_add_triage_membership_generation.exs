defmodule SalixStore.Repo.Migrations.AddTriageMembershipGeneration do
  use Ecto.Migration

  def change do
    alter table(:triage_bucket_memberships) do
      add(:generation, :text)
    end
  end
end
