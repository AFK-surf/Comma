defmodule BridgeForTeams.Schema.OrgMembership do
  @moduledoc "Org-level RBAC grant (design §5 `org_memberships`). role: owner|admin|member."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  @roles ~w(owner admin member)

  schema "org_memberships" do
    field :role, :string
    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :user, BridgeForTeams.Schema.User

    timestamps()
  end

  @doc "The valid org roles."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "Changeset for an org membership. unique(org_id, user_id)."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(m, attrs) do
    m
    |> cast(attrs, [:org_id, :user_id, :role])
    |> validate_required([:org_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:org_id, :user_id])
  end

  @type t :: %__MODULE__{}
end
