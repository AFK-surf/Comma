defmodule SalixStore.Stations.Station do
  @moduledoc """
  A still.fail station of a Salix Group (`SalixStore.Stations`). The id is the
  station's Ed25519 public key in hex; the station proves it on every signed
  request. `removed_at` set means removed. `kind` is `device` for a station
  enrolled from someone's machine and `cloud_vm` for the station the control
  plane placed on the Group's Cloud VM. `enrolled_by` is the enrolling
  product user's id, opaque to Salix; nil for a placed station.
  `index_epoch` and `index_through` say how much of the station's Task index
  Salix holds (`SalixStore.StationTaskIndex`).
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "salix_stations" do
    field(:tenant_id, :string)
    field(:group_id, :string)
    field(:name, :string)
    field(:version, :string)
    field(:kind, :string)
    field(:enrolled_by, :string)
    field(:enrolled_at, :utc_datetime_usec)
    field(:removed_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:index_epoch, :string)
    field(:index_through, :integer)

    timestamps()
  end
end
