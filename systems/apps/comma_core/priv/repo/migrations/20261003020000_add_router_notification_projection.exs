defmodule Comma.Repo.Migrations.AddRouterNotificationProjection do
  use Ecto.Migration

  def change do
    alter table(:comma_workspaces) do
      add(:router_notification_state, :map, null: false, default: %{})
    end

    # An ordinal projection of unread canonical Messages. Reading removes
    # these rows, but preserves the Message and the owner's read position.
    create table(:comma_router_notification_messages, primary_key: false) do
      add(:workspace_id, references(:comma_workspaces, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:seq, :bigint, primary_key: true)
      add(:message_id, :text, null: false)
      add(:ordinal, :bigint, null: false)
    end

    create(unique_index(:comma_router_notification_messages, [:workspace_id, :message_id]))

    create(
      constraint(:comma_router_notification_messages, :router_notification_position,
        check: "seq > 0 AND ordinal > 0"
      )
    )
  end
end
