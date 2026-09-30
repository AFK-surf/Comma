defmodule SalixStore.Repo.Migrations.CreateTaskLabelCatalogs do
  use Ecto.Migration

  # This catalog is introduced by the same unreleased feature. Existing
  # Conversations remain untouched; there is no serving-data cutover.
  def change do
    create table(:task_label_catalogs, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:value, :map, null: false)
    end
  end
end
