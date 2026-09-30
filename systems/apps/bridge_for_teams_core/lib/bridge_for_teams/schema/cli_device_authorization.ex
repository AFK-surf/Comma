defmodule BridgeForTeams.Schema.CliDeviceAuthorization do
  @moduledoc """
  Pending CLI device login request.

  This is not an authenticated session. It is the short-lived authorization
  object created by `bft auth login` and confirmed or cancelled in the dashboard.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @statuses ~w(pending approved cancelled consumed expired)
  @purposes ~w(login session_org_grant)

  schema "cli_device_authorizations" do
    field(:user_code, :string)
    field(:device_code_hash, :string)
    field(:status, :string, default: "pending")
    field(:purpose, :string, default: "login")
    field(:client_name, :string)
    field(:created_by_ip, :string)
    field(:approved_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:last_polled_at, :utc_datetime_usec)

    belongs_to(:approved_by_user, BridgeForTeams.Schema.User)
    belongs_to(:cancelled_by_user, BridgeForTeams.Schema.User)
    belongs_to(:auth_session, BridgeForTeams.Schema.AuthSession)

    has_many(:org_grants, BridgeForTeams.Schema.CliDeviceAuthorizationOrgGrant)
    has_many(:granted_orgs, through: [:org_grants, :org])

    timestamps()
  end

  @doc "Changeset for a CLI device authorization."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(auth, attrs) do
    auth
    |> cast(attrs, [
      :user_code,
      :device_code_hash,
      :status,
      :purpose,
      :auth_session_id,
      :client_name,
      :created_by_ip,
      :approved_by_user_id,
      :cancelled_by_user_id,
      :approved_at,
      :cancelled_at,
      :consumed_at,
      :expires_at,
      :last_polled_at
    ])
    |> validate_required([:user_code, :device_code_hash, :status, :purpose, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:purpose, @purposes)
    |> unique_constraint(:user_code)
    |> unique_constraint(:device_code_hash)
  end

  @type t :: %__MODULE__{}
end
