defmodule BridgeForTeams.Repo.Migrations.DailyBriefFeishuLark do
  use Ecto.Migration

  # The daily brief reads and posts through one IM provider per organization:
  # Slack, Feishu, or Lark. Every existing row is Slack's and stays as it is.
  #
  # Settings name the provider and its connect (`connect_id`); a Slack row
  # keeps `slack_connect_id` too. `connect_id` is backfilled but stays
  # nullable so a Slack setting saved by the release before still inserts.
  #
  # A member is linked per provider: a Slack member keeps its Slack ids, a
  # Feishu or Lark member has the app's open id. An organization that changes
  # provider keeps each provider's links apart.
  def up do
    alter table(:daily_brief_settings) do
      add :provider, :text, null: false, default: "slack"
      add :connect_id, :text
      modify :slack_connect_id, :text, null: true, from: {:text, null: false}
    end

    execute "UPDATE daily_brief_settings SET connect_id = slack_connect_id WHERE connect_id IS NULL"

    create constraint(:daily_brief_settings, :daily_brief_settings_provider,
             check:
               "(provider = 'slack' AND slack_connect_id IS NOT NULL) OR " <>
                 "(provider IN ('feishu', 'lark') AND connect_id IS NOT NULL AND slack_connect_id IS NULL)"
           )

    alter table(:daily_brief_members) do
      add :provider, :text, null: false, default: "slack"
      add :app_id, :text
      add :open_id, :text
      modify :slack_workspace_id, :text, null: true, from: {:text, null: false}
      modify :slack_user_id, :text, null: true, from: {:text, null: false}
    end

    drop unique_index(:daily_brief_members, [:org_id, :user_id])
    create unique_index(:daily_brief_members, [:org_id, :provider, :user_id])

    create unique_index(:daily_brief_members, [:org_id, :provider, :app_id, :open_id],
             name: :daily_brief_members_lark_identity,
             where: "provider IN ('feishu', 'lark')"
           )

    create constraint(:daily_brief_members, :daily_brief_members_provider,
             check:
               "(provider = 'slack' AND slack_workspace_id IS NOT NULL AND slack_user_id IS NOT NULL) OR " <>
                 "(provider IN ('feishu', 'lark') AND app_id IS NOT NULL AND open_id IS NOT NULL)"
           )

    alter table(:daily_brief_runs) do
      add :provider_chat_id, :text
      add :provider_message_id, :text
    end
  end

  def down do
    alter table(:daily_brief_runs) do
      remove :provider_message_id
      remove :provider_chat_id
    end

    execute "DELETE FROM daily_brief_members WHERE provider <> 'slack'"
    drop constraint(:daily_brief_members, :daily_brief_members_provider)

    drop index(:daily_brief_members, [:org_id, :provider, :app_id, :open_id],
           name: :daily_brief_members_lark_identity
         )

    drop unique_index(:daily_brief_members, [:org_id, :provider, :user_id])
    create unique_index(:daily_brief_members, [:org_id, :user_id])

    alter table(:daily_brief_members) do
      modify :slack_user_id, :text, null: false, from: {:text, null: true}
      modify :slack_workspace_id, :text, null: false, from: {:text, null: true}
      remove :open_id
      remove :app_id
      remove :provider
    end

    execute "DELETE FROM daily_brief_settings WHERE provider <> 'slack'"
    drop constraint(:daily_brief_settings, :daily_brief_settings_provider)

    alter table(:daily_brief_settings) do
      modify :slack_connect_id, :text, null: false, from: {:text, null: true}
      remove :connect_id
      remove :provider
    end
  end
end
