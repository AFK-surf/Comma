defmodule BridgeForTeams.Repo.Migrations.AddOrgDefaultLocale do
  use Ecto.Migration

  # Org-level default dashboard locale (docs/bridge-for-teams/i18n-design.md).
  # Nullable: NULL means "no org default", so members fall through to
  # Accept-Language negotiation.
  def change do
    alter table(:organizations) do
      add :default_locale, :string
    end
  end
end
