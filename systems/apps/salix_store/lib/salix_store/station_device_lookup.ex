defmodule SalixStore.StationDeviceLookup do
  @moduledoc "Rebuildable nominations from authenticated Device ownership and a proved Station key."
  use Ecto.Schema
  import Ecto.Query
  alias SalixStore.Repo

  @primary_key false
  schema "station_device_lookup" do
    field(:tenant_id, :string, primary_key: true)
    field(:group_id, :string, primary_key: true)
    field(:device_id, :string, primary_key: true)
    field(:station_id, :string)
    field(:owner_user_id, :string)
  end

  def record(tenant, group, device, station, owner)
      when is_binary(device) and is_binary(owner) and owner != "" do
    Repo.insert_all(
      __MODULE__,
      [
        %{
          tenant_id: tenant,
          group_id: group,
          device_id: device,
          station_id: station,
          owner_user_id: owner
        }
      ],
      on_conflict: {:replace, [:station_id, :owner_user_id]},
      conflict_target: [:tenant_id, :group_id, :device_id]
    )

    :ok
  rescue
    _ -> {:error, :station_lookup_unavailable}
  end

  def record(_, _, _, _, _), do: :ok

  def page(tenant, group, owner, limit) when limit in 1..16 do
    Repo.all(
      from(d in __MODULE__,
        where: d.tenant_id == ^tenant and d.group_id == ^group and d.owner_user_id == ^owner,
        order_by: d.device_id,
        limit: ^limit,
        select: %{station_id: d.station_id, device_id: d.device_id}
      )
    )
  rescue
    _ -> {:error, :station_lookup_unavailable}
  end

  def remove(tenant, group, device) do
    Repo.delete_all(
      from(d in __MODULE__,
        where: d.tenant_id == ^tenant and d.group_id == ^group and d.device_id == ^device
      )
    )

    :ok
  rescue
    _ -> {:error, :station_lookup_unavailable}
  end
end
