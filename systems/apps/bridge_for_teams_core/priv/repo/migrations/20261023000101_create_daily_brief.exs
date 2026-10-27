defmodule BridgeForTeams.Repo.Migrations.CreateDailyBrief do
  use Ecto.Migration

  def change do
    create table(:daily_brief_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :slack_connect_id, :text, null: false
      add :enabled, :boolean, null: false, default: false
      add :retention_days, :integer, null: false, default: 90
      add :team_names, :text, null: false, default: "hidden"
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:daily_brief_settings, [:org_id])

    create constraint(:daily_brief_settings, :daily_brief_settings_retention_days,
             check: "retention_days BETWEEN 1 AND 90"
           )

    create constraint(:daily_brief_settings, :daily_brief_settings_team_names,
             check: "team_names IN ('hidden', 'shown')"
           )

    create table(:daily_brief_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :slack_workspace_id, :text, null: false
      add :slack_user_id, :text, null: false
      add :timezone, :text, null: false, default: "Etc/UTC"
      add :deliver_at, :time, null: false, default: "09:00:00"
      add :enabled, :boolean, null: false, default: true
      add :dm_status, :text, null: false, default: "off"
      add :dm_declined_at, :utc_datetime_usec
      add :oauth_connection_id, :text
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:daily_brief_members, [:org_id, :user_id])

    create unique_index(:daily_brief_members, [:org_id, :slack_workspace_id, :slack_user_id],
             name: :daily_brief_members_slack_identity
           )

    create constraint(:daily_brief_members, :daily_brief_members_dm_status,
             check: """
             (dm_status = 'off' AND oauth_connection_id IS NULL) OR
             (dm_status = 'on' AND oauth_connection_id IS NOT NULL) OR
             (dm_status = 'declined' AND oauth_connection_id IS NULL AND dm_declined_at IS NOT NULL)
             """
           )

    create table(:daily_brief_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :member_id, references(:daily_brief_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :term, :text, null: false
      add :kind, :text, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:daily_brief_aliases, ["member_id", "lower(term)"],
             name: :daily_brief_aliases_member_term
           )

    create constraint(:daily_brief_aliases, :daily_brief_aliases_term,
             check:
               "btrim(term) <> '' AND length(term) <= 128 AND kind IN ('name', 'handle', 'project')"
           )

    # Shared rows reference a message whose text stays in the Salix mirror.
    # Personal rows hold the only copy, sealed, and belong to one member.
    create table(:daily_brief_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope, :text, null: false

      add :owner_member_id,
          references(:daily_brief_members, type: :binary_id, on_delete: :delete_all)

      add :source, :text, null: false
      add :workspace_id, :text, null: false
      add :conversation_id, :text, null: false
      add :conversation_kind, :text, null: false
      add :ts, :text, null: false
      add :thread_ts, :text
      add :author_ref, :text
      add :is_bot, :boolean, null: false, default: false
      add :payload_ciphertext, :text
      add :key_version, :integer
      add :edited_ts, :text
      add :deleted, :boolean, null: false, default: false
      add :permalink, :text
      add :observed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:daily_brief_events, :daily_brief_events_scope,
             check: """
             (scope = 'shared' AND owner_member_id IS NULL AND payload_ciphertext IS NULL AND
              key_version IS NULL AND conversation_kind IN ('public', 'meeting')) OR
             (scope = 'personal' AND owner_member_id IS NOT NULL AND
              payload_ciphertext IS NOT NULL AND key_version IS NOT NULL AND
              conversation_kind IN ('public', 'private', 'im', 'mpim'))
             """
           )

    create constraint(:daily_brief_events, :daily_brief_events_source,
             check: "source IN ('slack', 'meeting')"
           )

    create unique_index(
             :daily_brief_events,
             [:project_id, :source, :workspace_id, :conversation_id, :ts],
             where: "scope = 'shared'",
             name: :daily_brief_events_shared_identity
           )

    create unique_index(
             :daily_brief_events,
             [:owner_member_id, :source, :workspace_id, :conversation_id, :ts],
             where: "scope = 'personal'",
             name: :daily_brief_events_personal_identity
           )

    create index(:daily_brief_events, [:observed_at])

    create table(:daily_brief_followups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope, :text, null: false

      add :scope_member_id,
          references(:daily_brief_members, type: :binary_id, on_delete: :delete_all)

      add :kind, :text, null: false
      add :payload_ciphertext, :text, null: false
      add :key_version, :integer, null: false
      add :owner_slack_id, :text

      add :owner_member_id,
          references(:daily_brief_members, type: :binary_id, on_delete: :nilify_all)

      add :waiting_on_slack_id, :text

      add :waiting_on_member_id,
          references(:daily_brief_members, type: :binary_id, on_delete: :nilify_all)

      add :status, :text, null: false, default: "open"
      add :level, :text, null: false, default: "normal"
      add :due_at, :utc_datetime_usec
      add :reversible, :boolean, null: false, default: true
      add :confidence, :text, null: false
      add :origin, :text, null: false

      add :source_event_id,
          references(:daily_brief_events, type: :binary_id, on_delete: :nilify_all)

      add :source_permalink, :text
      add :meeting_ref, :text
      add :evidence_kind, :text

      add :evidence_event_id,
          references(:daily_brief_events, type: :binary_id, on_delete: :nilify_all)

      add :evidence_permalink, :text

      add :closed_by_member_id,
          references(:daily_brief_members, type: :binary_id, on_delete: :nilify_all)

      add :snoozed_until, :utc_datetime_usec
      add :opened_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:daily_brief_followups, :daily_brief_followups_scope,
             check: """
             (scope = 'shared' AND scope_member_id IS NULL) OR
             (scope = 'personal' AND scope_member_id IS NOT NULL)
             """
           )

    create constraint(:daily_brief_followups, :daily_brief_followups_values,
             check: """
             kind IN ('commitment', 'question', 'decision', 'awaiting_reply', 'risk') AND
             status IN ('open', 'in_progress', 'waiting', 'done', 'dropped') AND
             level IN ('critical', 'high', 'normal', 'low') AND
             confidence IN ('high', 'medium', 'low') AND
             origin IN ('human', 'bot_relay', 'transcript_inferred')
             """
           )

    # A follow-up closes only with evidence: a message link that outlives the
    # retained text, or the member's own confirmation.
    create constraint(:daily_brief_followups, :daily_brief_followups_evidence,
             check: """
             (status IN ('open', 'in_progress', 'waiting') AND closed_at IS NULL AND
              evidence_kind IS NULL) OR
             (status IN ('done', 'dropped') AND closed_at IS NOT NULL AND (
               (evidence_kind = 'event' AND evidence_permalink IS NOT NULL) OR
               (evidence_kind = 'member_confirmed' AND closed_by_member_id IS NOT NULL)))
             """
           )

    create index(:daily_brief_followups, [:scope_member_id, :status], where: "scope = 'personal'")

    create index(:daily_brief_followups, [:project_id, :status], where: "scope = 'shared'")
    create index(:daily_brief_followups, [:closed_at], where: "closed_at IS NOT NULL")

    create unique_index(:daily_brief_followups, [:project_id, :meeting_ref],
             where: "meeting_ref IS NOT NULL",
             name: :daily_brief_followups_meeting_ref
           )
  end
end
