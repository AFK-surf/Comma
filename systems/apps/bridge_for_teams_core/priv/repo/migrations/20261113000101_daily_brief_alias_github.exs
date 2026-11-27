defmodule BridgeForTeams.Repo.Migrations.DailyBriefAliasGitHub do
  use Ecto.Migration

  # A member's GitHub login is kept as an alias of kind "github", so their
  # brief can look up the pull requests they merged or closed.
  def up do
    drop constraint(:daily_brief_aliases, :daily_brief_aliases_term)

    create constraint(:daily_brief_aliases, :daily_brief_aliases_term,
             check:
               "btrim(term) <> '' AND length(term) <= 128 AND " <>
                 "kind IN ('name', 'handle', 'project', 'channel', 'channel_bots', 'channel_off', 'github')"
           )
  end

  def down do
    execute "DELETE FROM daily_brief_aliases WHERE kind = 'github'"
    drop constraint(:daily_brief_aliases, :daily_brief_aliases_term)

    create constraint(:daily_brief_aliases, :daily_brief_aliases_term,
             check:
               "btrim(term) <> '' AND length(term) <= 128 AND " <>
                 "kind IN ('name', 'handle', 'project', 'channel', 'channel_bots', 'channel_off')"
           )
  end
end
