defmodule Comma.Repo.Migrations.AddPluginAccountConfirmation do
  use Ecto.Migration

  def change do
    alter table(:comma_plugin_install_attempts) do
      add(:operation_kind, :string)
      add(:initiator_user_id, :string)
      add(:operation_data, :map)
      add(:expires_at, :utc_datetime_usec)
    end
  end
end
