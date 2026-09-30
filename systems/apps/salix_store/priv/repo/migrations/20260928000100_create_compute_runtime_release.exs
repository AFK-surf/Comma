defmodule SalixStore.Repo.Migrations.CreateComputeRuntimeRelease do
  use Ecto.Migration

  def change do
    # A release-owned desired catalog projection. Workload operations retain
    # their own phase and target across subsequent releases.
    create table(:compute_runtime_release, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:helm_revision, :bigint, null: false)
      add(:release_id, :text, null: false)
      add(:templates, :map, null: false)
      add(:published_at, :utc_datetime_usec, null: false)
    end

    create(constraint(:compute_runtime_release, :singleton, check: "id = 1"))
  end
end
