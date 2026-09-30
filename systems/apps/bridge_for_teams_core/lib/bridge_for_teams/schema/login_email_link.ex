defmodule BridgeForTeams.Schema.LoginEmailLink do
  @moduledoc """
  One-time email magic-link login token, self-served from the login page for
  orgs without an SSO connection (`BridgeForTeams.LoginLinks`). The raw token
  is emailed once; only `token_hash` is persisted. The link is bound to the
  org it was requested for so redemption can re-check that the org still has
  no SSO connection.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "login_email_links" do
    field :token_hash, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :user, BridgeForTeams.Schema.User
    belongs_to :org, BridgeForTeams.Schema.Organization

    timestamps()
  end

  @doc "Changeset for one-time login email links."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:user_id, :org_id, :token_hash, :expires_at, :used_at])
    |> validate_required([:user_id, :org_id, :token_hash, :expires_at])
    |> validate_length(:token_hash, min: 1)
    |> unique_constraint(:token_hash)
  end

  @type t :: %__MODULE__{}
end
