defmodule BridgeForTeams.Schema.ProjectKnowledgeAssertionSubject do
  @moduledoc "A typed product identity referenced by one project knowledge assertion."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "project_knowledge_assertion_subjects" do
    belongs_to(:assertion, BridgeForTeams.Schema.ProjectKnowledgeAssertion)
    belongs_to(:user, BridgeForTeams.Schema.User)
    belongs_to(:target_project, BridgeForTeams.Schema.Project)

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:assertion_id, :user_id, :target_project_id])
    |> validate_required([:assertion_id])
    |> check_constraint(:user_id, name: :project_knowledge_assertion_subjects_typed_target)
  end
end
