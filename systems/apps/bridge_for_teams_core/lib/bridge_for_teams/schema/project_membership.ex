defmodule BridgeForTeams.Schema.ProjectMembership do
  @moduledoc """
  Optional per-project RBAC grant atop the org role (design §5
  `project_memberships`). role: admin|user.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  @roles ~w(admin user)

  schema "project_memberships" do
    field :role, :string
    belongs_to :project, BridgeForTeams.Schema.Project
    belongs_to :user, BridgeForTeams.Schema.User

    timestamps()
  end

  @doc "The valid project roles."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "Changeset for a project membership. unique(project_id, user_id)."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(m, attrs) do
    m
    |> cast(attrs, [:project_id, :user_id, :role])
    |> validate_required([:project_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:project_id, :user_id])
  end

  @type t :: %__MODULE__{}
end
