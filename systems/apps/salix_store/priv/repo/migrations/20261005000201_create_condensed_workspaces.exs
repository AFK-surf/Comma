defmodule SalixStore.Repo.Migrations.CreateCondensedWorkspaces do
  use Ecto.Migration

  # A new opt-in Group feature (docs/agent-runtime.md#condensed-workspace).
  # No existing row or serving path changes, so there is no data cutover.
  def change do
    create table(:condensed_workspaces, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:revision, :bigint, null: false)
      add(:value, :map, null: false)
      add(:updated_by, :map, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end
