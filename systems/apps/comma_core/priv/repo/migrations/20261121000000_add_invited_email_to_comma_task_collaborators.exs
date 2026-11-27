defmodule Comma.Repo.Migrations.AddInvitedEmailToCommaTaskCollaborators do
  use Ecto.Migration

  # Someone not yet on Comma is invited to a Collaborative Task by email
  # (`invited_email`, no `user_id`): the account that signs in with that
  # address takes the seat.
  def change do
    execute(
      "ALTER TABLE comma_task_collaborators ALTER COLUMN user_id DROP NOT NULL",
      "ALTER TABLE comma_task_collaborators ALTER COLUMN user_id SET NOT NULL"
    )

    alter table(:comma_task_collaborators) do
      add(:invited_email, :text)
    end

    create(
      unique_index(:comma_task_collaborators, [:conversation_id, :invited_email],
        where: "invited_email IS NOT NULL",
        name: :comma_task_collaborators_task_invited_email_index
      )
    )

    create(index(:comma_task_collaborators, [:invited_email], where: "user_id IS NULL"))

    # A host's seats by email (their daily room) and their rows when they go.
    create(index(:comma_task_collaborators, [:host_user_id]))

    create(
      constraint(:comma_task_collaborators, :comma_task_collaborators_seat_check,
        check: "user_id IS NOT NULL OR invited_email IS NOT NULL"
      )
    )
  end
end
