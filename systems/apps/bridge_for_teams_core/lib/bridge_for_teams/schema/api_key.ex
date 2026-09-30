defmodule BridgeForTeams.Schema.ApiKey do
  @moduledoc """
  Programmatic org access key (design §5 `api_keys`, §7). Stored hashed like
  Salix tenant keys. `revoked_at` soft-revokes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "api_keys" do
    field :name, :string
    field :key_hash, :string
    field :scopes, {:array, :string}, default: []
    field :revoked_at, :utc_datetime_usec

    belongs_to :org, BridgeForTeams.Schema.Organization

    timestamps()
  end

  @doc "Changeset for an API key."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:org_id, :name, :key_hash, :scopes, :revoked_at])
    |> validate_required([:org_id, :key_hash])
    |> unique_constraint(:key_hash)
  end

  @type t :: %__MODULE__{}
end
