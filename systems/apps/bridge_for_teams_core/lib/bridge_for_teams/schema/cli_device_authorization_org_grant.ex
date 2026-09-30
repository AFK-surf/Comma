defmodule BridgeForTeams.Schema.CliDeviceAuthorizationOrgGrant do
  @moduledoc """
  Organization selected for a pending or approved CLI device authorization.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "cli_device_authorization_org_grants" do
    belongs_to(:cli_device_authorization, BridgeForTeams.Schema.CliDeviceAuthorization)
    belongs_to(:org, BridgeForTeams.Schema.Organization)

    timestamps()
  end

  @doc "Changeset for a CLI device authorization org grant."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:cli_device_authorization_id, :org_id])
    |> validate_required([:cli_device_authorization_id, :org_id])
    |> unique_constraint([:cli_device_authorization_id, :org_id])
  end

  @type t :: %__MODULE__{}
end
