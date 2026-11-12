defmodule BridgeForTeams.Repo.Migrations.DailyBriefAliasChannels do
  use Ecto.Migration

  # A member's main-channel choices are kept as aliases whose term is a
  # channel id: added, added with bot messages, or dropped from the defaults.
  def up do
    drop constraint(:daily_brief_aliases, :daily_brief_aliases_term)

    create constraint(:daily_brief_aliases, :daily_brief_aliases_term,
             check:
               "btrim(term) <> '' AND length(term) <= 128 AND " <>
                 "kind IN ('name', 'handle', 'project', 'channel', 'channel_bots', 'channel_off')"
           )
  end

  def down do
    execute "DELETE FROM daily_brief_aliases WHERE kind IN ('channel', 'channel_bots', 'channel_off')"
    drop constraint(:daily_brief_aliases, :daily_brief_aliases_term)

    create constraint(:daily_brief_aliases, :daily_brief_aliases_term,
             check:
               "btrim(term) <> '' AND length(term) <= 128 AND kind IN ('name', 'handle', 'project')"
           )
  end
end
