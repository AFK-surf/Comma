defmodule SalixStore.Repo.Migrations.AddDeviceRuntimeLocators do
  use Ecto.Migration

  def change do
    create table(:device_runtime_locators, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:device_runtime_id, :text, primary_key: true)
      add(:device_id, :text, null: false)
    end
  end
end
