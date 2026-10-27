defmodule BridgeForTeams.Repo.Migrations.CreateDailyBriefPersonalSync do
  use Ecto.Migration

  # Per-conversation cursors and watched threads of one member's personal
  # stream. Both belong to the member and go with the member's personal data.
  def change do
    create table(:daily_brief_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id, :text, null: false
      add :kind, :text, null: false
      add :name, :text
      add :covered_by_bot, :boolean, null: false, default: false
      add :cursor_ts, :text
      add :last_synced_at, :utc_datetime_usec
      add :last_error, :text
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:daily_brief_conversations, [:member_id, :conversation_id])

    create constraint(:daily_brief_conversations, :daily_brief_conversations_kind,
             check: "kind IN ('im', 'mpim', 'private', 'public')"
           )

    create table(:daily_brief_threads_watched, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id, :text, null: false
      add :thread_ts, :text, null: false
      add :last_reply_ts, :text
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:daily_brief_threads_watched, [:member_id, :conversation_id, :thread_ts])

    alter table(:daily_brief_members) do
      add :personal_synced_at, :utc_datetime_usec
      add :personal_rescanned_at, :utc_datetime_usec
    end

    create index(:daily_brief_members, [:personal_synced_at], where: "dm_status = 'on'")
  end
end
