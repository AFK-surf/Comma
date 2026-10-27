defmodule SalixStore.Repo.Migrations.StationDeviceLookup do
  use Ecto.Migration

  def change do
    create table(:station_device_lookup, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:device_id, :text, primary_key: true)
      add(:station_id, :text, null: false)
      add(:owner_user_id, :text, null: false)
    end

    create(
      index(:station_device_lookup, [:tenant_id, :group_id, :owner_user_id, :device_id],
        name: :station_device_lookup_group_owner_device_idx
      )
    )
  end
end
