defmodule BridgeForTeams.Schema.ProjectDeviceProjectionScan do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "project_device_projection_scans" do
    field :cursor_project_id, Ecto.UUID
    field :active_project_id, Ecto.UUID
    field :device_cursor, :string
    field :project_generation, :integer
    field :generation, :integer
    field :lease_token, Ecto.UUID
    field :lease_expires_at, :utc_datetime_usec
    field :last_error, :string

    timestamps()
  end
end
