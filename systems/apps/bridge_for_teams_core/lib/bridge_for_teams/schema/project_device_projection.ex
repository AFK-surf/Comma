defmodule BridgeForTeams.Schema.ProjectDeviceProjection do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "project_device_projections" do
    belongs_to :project, BridgeForTeams.Schema.Project, primary_key: true
    field :device_id, :string, primary_key: true
    field :connector_run_id, :string
    field :connector_id, :string
    field :name, :string
    field :status, :string
    field :source_updated_at, :integer
    field :runtime_inventory, :map, default: %{"items" => []}
    field :observed_generation, :integer

    timestamps()
  end

  def changeset(projection, attrs) do
    projection
    |> cast(attrs, [
      :project_id,
      :device_id,
      :connector_run_id,
      :connector_id,
      :name,
      :status,
      :source_updated_at,
      :runtime_inventory,
      :observed_generation
    ])
    |> validate_required([:project_id, :device_id, :status, :observed_generation])
  end
end
