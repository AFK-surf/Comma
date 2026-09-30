defmodule BridgeForTeams.Schema.OrgCreationInvite do
  @moduledoc """
  One-time invite code that permits anonymous creation of a BridgeForTeams
  organization and its first owner account.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "org_creation_invites" do
    field :code_hash, :string
    field :org_name, :string
    field :org_slug, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :note, :string

    belongs_to :used_by_user, BridgeForTeams.Schema.User
    belongs_to :used_org, BridgeForTeams.Schema.Organization

    timestamps()
  end

  @doc "Changeset for one-time org creation invite codes."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :code_hash,
      :org_name,
      :org_slug,
      :expires_at,
      :used_at,
      :used_by_user_id,
      :used_org_id,
      :note
    ])
    |> validate_required([:code_hash, :org_name, :org_slug])
    |> validate_length(:code_hash, min: 1)
    |> validate_length(:org_name, min: 1)
    |> validate_length(:org_slug, min: 1)
    |> unique_constraint(:code_hash)
  end

  @type t :: %__MODULE__{}
end
