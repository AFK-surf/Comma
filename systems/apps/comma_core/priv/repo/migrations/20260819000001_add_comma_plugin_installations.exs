defmodule Comma.Repo.Migrations.AddCommaPluginInstallations do
  use Ecto.Migration

  def change do
    create table(:comma_plugin_installations, primary_key: false) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:plugin_id, :string, null: false, primary_key: true)
      add(:connected_observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
