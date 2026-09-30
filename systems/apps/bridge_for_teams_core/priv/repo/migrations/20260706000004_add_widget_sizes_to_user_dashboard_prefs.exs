defmodule BridgeForTeams.Repo.Migrations.AddWidgetSizesToUserDashboardPrefs do
  use Ecto.Migration

  def change do
    alter table(:user_dashboard_prefs) do
      add :widget_sizes, :map, null: false, default: %{}
    end
  end
end
