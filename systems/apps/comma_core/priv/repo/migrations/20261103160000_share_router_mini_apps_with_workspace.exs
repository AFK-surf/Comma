defmodule Comma.Repo.Migrations.ShareRouterMiniAppsWithWorkspace do
  use Ecto.Migration

  # An app the Router made was `private` with no creator, which meant every
  # member saw it. It is now `workspace`, which says the same: visibility alone
  # decides who sees an app, and `created_by` only names who made it.
  def up do
    execute("""
    UPDATE comma_mini_apps SET visibility = 'workspace'
    WHERE visibility = 'private' AND created_by IS NULL
    """)
  end

  def down, do: :ok
end
