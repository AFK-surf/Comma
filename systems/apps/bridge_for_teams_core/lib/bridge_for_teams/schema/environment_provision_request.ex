defmodule BridgeForTeams.Schema.EnvironmentProvisionRequest do
  @moduledoc """
  Pre-attach request for a runner to create a project device.

  The request binds BridgeForTeams org/project intent to the project's Salix
  group before any connector run exists. Once a connector attaches, the live
  connector-run record remains owned by `SalixEnv.Registry`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @statuses ~w(pending preflight preflight_complete starting_connector waiting_for_attach connected stop_requested stopping stopped failed)

  schema "environment_provision_requests" do
    field :salix_group_id, :string
    field :name, :string
    field :env_alias, :string
    field :status, :string, default: "pending"
    field :failure_code, :string
    field :failure_message, :string
    field :connector_run_id, :string
    field :connector_token_hash, :string
    field :spec, :map, default: %{}
    field :progress, :map, default: %{}

    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :project, BridgeForTeams.Schema.Project
    belongs_to :provisioner, BridgeForTeams.Schema.MacMiniProvisioner

    timestamps()
  end

  @doc "Valid provisioning state-machine statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for creating or updating a provisioning request."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :org_id,
      :project_id,
      :provisioner_id,
      :salix_group_id,
      :name,
      :env_alias,
      :status,
      :failure_code,
      :failure_message,
      :connector_run_id,
      :connector_token_hash,
      :spec,
      :progress
    ])
    |> validate_required([
      :org_id,
      :project_id,
      :provisioner_id,
      :salix_group_id,
      :name,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @type t :: %__MODULE__{}
end
