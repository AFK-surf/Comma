defmodule BridgeForTeams.Schema.Project do
  @moduledoc """
  A project (design §5 `projects`). Maps 1:1 onto a Salix **group**
  (`salix_group_id`) within its org's tenant — the group scopes
  the project's agents, OAuth bindings and conversations (design §2).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    # The Project <-> Salix link (design §2): the canonical Salix group id.
    field :salix_group_id, :string
    field :archived_at, :utc_datetime_usec
    # Whether this swarm's agents provision a managed cloud VM (needed for
    # OAuth-backed work — the agent uses credentials via env.exec). Default on.
    field :vm_enabled, :boolean, default: true

    belongs_to :org, BridgeForTeams.Schema.Organization
    # Who created the Agent Swarm; nil for rows predating the column and for
    # system-created projects. Ordinary org members are quota-limited by it.
    belongs_to :created_by_user, BridgeForTeams.Schema.User

    has_many :memberships, BridgeForTeams.Schema.ProjectMembership, foreign_key: :project_id
    has_many :agents, BridgeForTeams.Schema.Agent, foreign_key: :project_id

    timestamps()
  end

  @doc "Changeset for a project. unique(org_id, slug); archiving releases the slug."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :org_id,
      :name,
      :slug,
      :status,
      :salix_group_id,
      :archived_at,
      :created_by_user_id,
      :vm_enabled
    ])
    |> reject_identity_update(attrs, :salix_group_id)
    |> validate_required([:org_id, :name, :salix_group_id])
    |> validate_active_slug()
    # The unique index is (org_id, slug); report violations on :slug so forms
    # surface the error on the field the user actually typed.
    |> unique_constraint(:slug, name: :projects_org_id_slug_index)
    |> unique_constraint(:salix_group_id)
  end

  defp reject_identity_update(%Ecto.Changeset{data: %{id: nil}} = changeset, _attrs, _field),
    do: changeset

  defp reject_identity_update(changeset, attrs, field) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
      add_error(changeset, field, "is immutable")
    else
      changeset
    end
  end

  # Active projects need a slug; archived ones have released theirs (NULL) so
  # the name can be recreated — archiving is one-way, there is no unarchive.
  defp validate_active_slug(changeset) do
    if get_field(changeset, :archived_at) do
      changeset
    else
      validate_required(changeset, [:slug])
    end
  end

  @type t :: %__MODULE__{}
end
