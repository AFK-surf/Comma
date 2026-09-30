defmodule Comma.Repo.Migrations.CreateTaskShares do
  use Ecto.Migration

  def change do
    create table(:comma_task_shares, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token, :text, null: false)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:group_id, :text, null: false)
      add(:conversation_id, :text, null: false)

      add(:created_by, references(:comma_users, type: :string, on_delete: :delete_all), null: false)

      add(:through_seq, :bigint, null: false)
      add(:snapshot, :map, null: false, default: %{})
      add(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_task_shares, [:token]))

    create(
      unique_index(:comma_task_shares, [:conversation_id],
        where: "revoked_at IS NULL",
        name: :comma_task_shares_active_conversation_index
      )
    )

    create(index(:comma_task_shares, [:workspace_id]))

    create(
      constraint(:comma_task_shares, :comma_task_shares_through_seq_check, check: "through_seq >= 0")
    )
  end
end
