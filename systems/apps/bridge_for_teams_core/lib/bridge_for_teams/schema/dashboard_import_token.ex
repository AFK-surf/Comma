defmodule BridgeForTeams.Schema.DashboardImportToken do
  @moduledoc """
  A short-lived, single-use-scope credential for the My Space data-import API.

  Minted by a project admin (or org owner/admin) for a specific
  `(user, org, project)` and expiring after a short TTL. Stored hashed like
  `auth_sessions`/`api_keys` — only `token_hash` is persisted, so a database
  read can never recover a usable token. `revoked_at` soft-revokes; minting a
  new token for the same `(user, project)` revokes the previous active one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "dashboard_import_tokens" do
    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:user, BridgeForTeams.Schema.User)
    belongs_to(:org, BridgeForTeams.Schema.Organization)
    belongs_to(:project, BridgeForTeams.Schema.Project)

    timestamps()
  end

  @doc "Changeset for a dashboard import token."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :org_id, :project_id, :token_hash, :expires_at, :revoked_at])
    |> validate_required([:user_id, :org_id, :project_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end

  @type t :: %__MODULE__{}
end
