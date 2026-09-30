defmodule SalixStore.Repo.Migrations.CreateSlackRouterThreadParticipations do
  use Ecto.Migration

  def change do
    create table(:slack_router_thread_participations, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:bot_user_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:thread_ts, :text, primary_key: true)
      add(:last_active_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(
      index(
        :slack_router_thread_participations,
        [
          :expires_at,
          :group_id,
          :connect_id,
          :workspace_id,
          :bot_user_id,
          :channel_id,
          :thread_ts
        ],
        name: :slack_router_thread_participations_expiry_idx
      )
    )

    create(
      constraint(
        :slack_router_thread_participations,
        :slack_router_thread_participations_nonempty_identity,
        check:
          "btrim(group_id) <> '' AND btrim(connect_id) <> '' AND " <>
            "btrim(workspace_id) <> '' AND btrim(bot_user_id) <> '' AND " <>
            "btrim(channel_id) <> '' AND btrim(thread_ts) <> ''"
      )
    )
  end
end
