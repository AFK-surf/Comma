defmodule BridgeForTeams.Schema.TriageFeedback do
  @moduledoc "Internal human review, separate from Triage context and task authorization."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "triage_feedback" do
    field :org_id, :binary_id
    field :project_id, :binary_id
    field :agent_id, :binary_id
    field :reviewer_id, :binary_id
    field :subject_type, :string
    field :subject_id, :string
    field :score, :integer
    field :comment, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [
      :org_id,
      :project_id,
      :agent_id,
      :reviewer_id,
      :subject_type,
      :subject_id,
      :score,
      :comment
    ])
    |> validate_required([
      :org_id,
      :project_id,
      :agent_id,
      :reviewer_id,
      :subject_type,
      :subject_id
    ])
    |> validate_inclusion(:subject_type, ["outcome", "follow_up"])
    |> validate_number(:score, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_length(:subject_id, max: 256)
    |> validate_length(:comment, max: 4000)
    |> require_content()
  end

  defp require_content(changeset) do
    if is_nil(get_field(changeset, :score)) and is_nil(get_field(changeset, :comment)),
      do: add_error(changeset, :comment, "enter a score or comment"),
      else: changeset
  end
end
