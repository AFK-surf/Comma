defmodule BridgeForTeams.Schema.SearchGrant do
  @moduledoc """
  One cross-Swarm conversation search rule within a CFT `Organization`.

  `subject_kind` is `"department"` or `"project"`. `target_kind` is
  `"department"`, `"project"`, or `"all_departments"` (with `target_id == org_id`,
  dynamically matching all active Projects assigned to any department in the
  organization). Mutations compile all rules of the organization into flat Salix
  `search_group_ids` lists per active `Project` and enqueue `update_group`
  outbox entries in the same Ecto transaction.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  @subject_kinds ~w(department project)
  @target_kinds ~w(department project all_departments)

  schema "search_grants" do
    field :subject_kind, :string
    field :subject_id, :binary_id
    field :target_kind, :string
    field :target_id, :binary_id

    belongs_to :org, BridgeForTeams.Schema.Organization

    timestamps()
  end

  @spec kinds() :: [String.t()]
  def kinds, do: @subject_kinds

  @spec target_kinds() :: [String.t()]
  def target_kinds, do: @target_kinds

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:org_id, :subject_kind, :subject_id, :target_kind, :target_id])
    |> validate_required([:org_id, :subject_kind, :subject_id, :target_kind, :target_id])
    |> validate_inclusion(:subject_kind, @subject_kinds)
    |> validate_inclusion(:target_kind, @target_kinds)
    |> validate_all_departments_target_id()
    |> unique_constraint(:target_id, name: :search_grants_unique_rule_index)
  end

  defp validate_all_departments_target_id(changeset) do
    if get_field(changeset, :target_kind) == "all_departments" and
         get_field(changeset, :target_id) != get_field(changeset, :org_id) do
      add_error(changeset, :target_id, "must match org_id when target_kind is all_departments")
    else
      changeset
    end
  end

  @type t :: %__MODULE__{}
end
