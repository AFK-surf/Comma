defmodule BridgeForTeams.Schema.StorageMeteringScan do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "storage_metering_scans" do
    field :cursor_project_id, Ecto.UUID
    field :generation, :integer
    field :sampled_at, :utc_datetime_usec
    field :lease_token, Ecto.UUID
    field :lease_expires_at, :utc_datetime_usec

    timestamps()
  end
end
