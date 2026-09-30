defmodule BridgeForTeams.Repo.Migrations.CreateTriageFeedback do
  use Ecto.Migration

  def change do
    create table(:triage_feedback, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :reviewer_id, :binary_id, null: false
      add :subject_type, :text, null: false
      add :subject_id, :text, null: false
      add :score, :integer
      add :comment, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(
             :triage_feedback,
             [
               :org_id,
               :project_id,
               :agent_id,
               :subject_type,
               :subject_id,
               "inserted_at DESC",
               "id DESC"
             ], name: :triage_feedback_subject_recent)

    create constraint(:triage_feedback, :triage_feedback_score,
             check: "score IS NULL OR score BETWEEN 1 AND 5"
           )

    create constraint(:triage_feedback, :triage_feedback_content,
             check: "score IS NOT NULL OR length(btrim(comment)) > 0"
           )

    create constraint(:triage_feedback, :triage_feedback_comment_length,
             check: "comment IS NULL OR length(comment) <= 4000"
           )
  end
end
