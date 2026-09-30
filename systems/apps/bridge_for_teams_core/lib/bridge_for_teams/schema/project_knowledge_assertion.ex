defmodule BridgeForTeams.Schema.ProjectKnowledgeAssertion do
  @moduledoc "An append-only project fact or decision with an auditable source."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "project_knowledge_assertions" do
    field(:kind, :string)
    field(:content, :string)
    field(:source_type, :string)
    field(:source_ref, :string)
    field(:observed_at, :utc_datetime_usec)

    belongs_to(:project, BridgeForTeams.Schema.Project)
    belongs_to(:supersedes, __MODULE__)

    has_many(:subjects, BridgeForTeams.Schema.ProjectKnowledgeAssertionSubject,
      foreign_key: :assertion_id
    )

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :project_id,
      :kind,
      :content,
      :source_type,
      :source_ref,
      :observed_at,
      :supersedes_id
    ])
    |> validate_required([:project_id, :kind, :content, :source_type, :source_ref, :observed_at])
    |> validate_inclusion(:kind, ~w(decision fact))
    |> validate_length(:content, max: 8_000)
    |> validate_length(:source_type, max: 64)
    |> validate_length(:source_ref, max: 1_024)
    |> check_constraint(:kind, name: :project_knowledge_assertions_kind)
    |> check_constraint(:content, name: :project_knowledge_assertions_content)
    |> unique_constraint([:project_id, :kind, :source_type, :source_ref],
      name: :project_knowledge_assertions_source_idx
    )
  end
end
