defmodule BridgeForTeams.Schema.CliSessionOrgGrant do
  @moduledoc """
  Active or revoked organization grant for a BFT CLI session.

  Grants are soft-revoked so dashboard/audit surfaces can show exactly which org
  was removed without destroying the entire CLI session.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "cli_session_org_grants" do
    belongs_to(:auth_session, BridgeForTeams.Schema.AuthSession)
    belongs_to(:org, BridgeForTeams.Schema.Organization)
    belongs_to(:granted_by_user, BridgeForTeams.Schema.User)
    belongs_to(:grant_device_authorization, BridgeForTeams.Schema.CliDeviceAuthorization)
    belongs_to(:revoked_by_user, BridgeForTeams.Schema.User)

    field(:granted_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "Changeset for a CLI session organization grant."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :auth_session_id,
      :org_id,
      :granted_by_user_id,
      :grant_device_authorization_id,
      :granted_at,
      :revoked_by_user_id,
      :revoked_at
    ])
    |> validate_required([:auth_session_id, :org_id, :granted_at])
    |> unique_constraint([:auth_session_id, :org_id])
  end

  @type t :: %__MODULE__{}
end
