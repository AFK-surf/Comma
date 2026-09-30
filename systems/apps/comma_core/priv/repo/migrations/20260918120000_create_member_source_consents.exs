defmodule Comma.Repo.Migrations.CreateMemberSourceConsents do
  use Ecto.Migration

  def change do
    create table(:comma_member_source_consents, primary_key: false) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:toolkit, :string, null: false, primary_key: true)
      add(:connection_id, :string, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
