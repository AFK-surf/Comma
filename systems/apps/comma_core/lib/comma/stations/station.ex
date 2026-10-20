defmodule Comma.Stations.Station do
  @moduledoc """
  A still.fail station enrolled in a Comma Workspace (docs/architecture/DOMAIN_CONCEPTS.md,
  "Station"). The id is the station's Ed25519 public key in hex; the station
  proves it on every signed request. `removed_at` set means removed: signed
  requests and the presence socket answer `station_removed`. `enrolled_by` nil
  means the control plane placed it (a Cloud VM's station), not a token.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "comma_stations" do
    field(:workspace_id, :string)
    field(:name, :string)
    field(:version, :string)
    field(:enrolled_by, :string)
    field(:enrolled_at, :utc_datetime_usec)
    field(:removed_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps()
  end
end
