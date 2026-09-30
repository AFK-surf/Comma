defmodule BridgeForTeams.Schema.AuthSession do
  @moduledoc """
  A login session (design §5 `auth_sessions`). Postgres replaces Redis for
  session storage (design §1, §7). Only `token_hash` is stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "auth_sessions" do
    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:device, :string)
    field(:client_name, :string)

    belongs_to(:user, BridgeForTeams.Schema.User)

    has_many(:cli_org_grants, BridgeForTeams.Schema.CliSessionOrgGrant)
    has_many(:cli_granted_orgs, through: [:cli_org_grants, :org])

    timestamps()
  end

  @doc "Changeset for an auth session."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :token_hash, :expires_at, :last_seen_at, :device, :client_name])
    |> validate_required([:user_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end

  @type t :: %__MODULE__{}
end
