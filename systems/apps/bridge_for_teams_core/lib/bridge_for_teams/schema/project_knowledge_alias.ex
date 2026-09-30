defmodule BridgeForTeams.Schema.ProjectKnowledgeAlias do
  @moduledoc "A project-scoped sourced alias for a product-owned person or project identity."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "project_knowledge_aliases" do
    field(:entity_kind, :string)
    field(:alias, :string)
    field(:normalized_alias, :string)
    field(:source_type, :string)
    field(:source_ref, :string)

    belongs_to(:project, BridgeForTeams.Schema.Project)
    belongs_to(:user, BridgeForTeams.Schema.User)
    belongs_to(:target_project, BridgeForTeams.Schema.Project)

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :project_id,
      :entity_kind,
      :user_id,
      :target_project_id,
      :alias,
      :normalized_alias,
      :source_type,
      :source_ref
    ])
    |> validate_required([
      :project_id,
      :entity_kind,
      :alias,
      :normalized_alias,
      :source_type,
      :source_ref
    ])
    |> validate_inclusion(:entity_kind, ~w(person project))
    |> validate_length(:alias, max: 200)
    |> validate_length(:source_type, max: 64)
    |> validate_length(:source_ref, max: 1_024)
    |> check_constraint(:entity_kind, name: :project_knowledge_aliases_typed_target)
    |> check_constraint(:normalized_alias, name: :project_knowledge_aliases_normalized)
    |> unique_constraint(:normalized_alias,
      name: :project_knowledge_aliases_person_identity_idx
    )
    |> unique_constraint(:normalized_alias,
      name: :project_knowledge_aliases_project_identity_idx
    )
  end
end
