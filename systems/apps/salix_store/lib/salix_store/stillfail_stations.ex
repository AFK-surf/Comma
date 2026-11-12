defmodule SalixStore.StillfailStations do
  @moduledoc """
  The still.fail stations connected to a Group through a Comma connect: a
  device of the Group with `device_kind` `stillfail`, whose station sends the
  Stats index of its still.fail workspace over its Connector run
  (`stats.index`, source `stillfail`). A Comma station's index is held on its
  `SalixStore.Stations.Station`; such a station has none, so its record here
  holds how much of the index Salix keeps (`stats_epoch`, `stats_through`).
  It sends its workspace's chats as a Task index (`task.index`,
  `SalixStore.StationTaskIndex`) too, held here the same way (`index_epoch`,
  `index_through`). Its rows are under `station_id` `"stillfail-" <> device_id`
  (a Router names a Task `station:<station_id>:<thread>`, so the id has no
  colon). Removing the device removes the record and its rows.
  """

  import Ecto.Query

  alias SalixStore.Repo
  alias SalixStore.{StationStatsIndex, StationTaskIndex}

  defmodule Station do
    @moduledoc "A still.fail station of a Group, as the Stats index holds it."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    @timestamps_opts [
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    ]

    schema "salix_stillfail_stations" do
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:device_id, :string)
      field(:stats_epoch, :string)
      field(:stats_through, :integer)
      field(:index_epoch, :string)
      field(:index_through, :integer)

      timestamps()
    end
  end

  @doc "The `station_id` of a still.fail device's index rows."
  def id(device_id) when is_binary(device_id), do: "stillfail-" <> device_id

  @doc "The record of a still.fail device of the Group, made the first time it sends a page."
  def ensure(tenant_id, group_id, device_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(device_id) do
    id = id(device_id)

    Repo.insert_all(
      Station,
      [
        %{
          id: id,
          tenant_id: tenant_id,
          group_id: group_id,
          device_id: device_id,
          inserted_at: SystemsClock.timestamp(:utc_datetime_usec),
          updated_at: SystemsClock.timestamp(:utc_datetime_usec)
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:id]
    )

    case Repo.get(Station, id) do
      %Station{tenant_id: ^tenant_id, group_id: ^group_id} = station -> {:ok, station}
      _ -> {:error, :not_this_group}
    end
  end

  @doc "Locks a still.fail station's record (inside the caller's transaction)."
  def lock(id) when is_binary(id),
    do: Repo.one(from(s in Station, where: s.id == ^id, lock: "FOR UPDATE"))

  @doc "Removes a still.fail device's record and its Stats index and Task index rows."
  def remove(device_id) when is_binary(device_id) do
    id = id(device_id)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(r in StationStatsIndex.Row, where: r.station_id == ^id))
        Repo.delete_all(from(r in StationTaskIndex.Row, where: r.station_id == ^id))
        Repo.delete_all(from(s in Station, where: s.id == ^id))
      end)

    :ok
  end
end
