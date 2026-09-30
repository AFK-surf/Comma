defmodule BridgeForTeams.Repo.Migrations.AddUserPreferredLocale do
  use Ecto.Migration

  # Dashboard i18n (docs/bridge-for-teams/i18n-design.md). Nullable: NULL means
  # "no explicit choice", so locale resolution falls through to Accept-Language.
  def change do
    alter table(:users) do
      add :preferred_locale, :string
    end
  end
end
