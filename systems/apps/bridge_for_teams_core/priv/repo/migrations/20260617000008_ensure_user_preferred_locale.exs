defmodule BridgeForTeams.Repo.Migrations.EnsureUserPreferredLocale do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add_if_not_exists :preferred_locale, :string
    end
  end

  def down do
    :ok
  end
end
