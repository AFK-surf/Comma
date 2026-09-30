defmodule Comma.Repo.Migrations.AddCommaPluginInstallAttempts do
  use Ecto.Migration

  def change do
    create table(:comma_plugin_install_attempts, primary_key: false) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:plugin_id, :string, null: false, primary_key: true)
      add(:generation, :bigint, null: false, default: 0)
      add(:authorization_state, :string)
      add(:provider_state, :string)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
