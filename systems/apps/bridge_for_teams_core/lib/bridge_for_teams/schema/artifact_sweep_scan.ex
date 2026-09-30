defmodule BridgeForTeams.Schema.ArtifactSweepScan do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "artifact_sweep_scans" do
    field :cursor_agent_id, Ecto.UUID
    field :active_agent_id, Ecto.UUID
    field :directory_cursor, :string
    field :file_cursor, :string
    field :active_document_path, :string
    field :member_cursor_user_id, Ecto.UUID
    field :generation, :integer
    field :lease_token, Ecto.UUID
    field :lease_expires_at, :utc_datetime_usec

    timestamps()
  end
end
