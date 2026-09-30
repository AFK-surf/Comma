defmodule Comma.Repo.Migrations.AddWorkspaceVmAndSessionBudgetConsumptions do
  use Ecto.Migration

  def change do
    alter table(:comma_workspaces) do
      add(:vm, :map)
    end

    create table(:comma_session_budget_consumptions, primary_key: false) do
      add(
        :session_id,
        references(:comma_sessions, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:operation_id, :string, primary_key: true, null: false)
      add(:consumed_at, :utc_datetime_usec, null: false)
    end
  end
end
