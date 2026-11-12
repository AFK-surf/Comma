defmodule Comma.Repo.Migrations.AddWorkspaceOwnRequestMode do
  use Ecto.Migration

  # How a Workspace takes its owner's own Task requests (sent from a chat app
  # linked to them): each waits for the owner (`review`), or becomes a Task
  # at once (`auto_accept`) as a grant in that mode does. And which chat
  # account a link is, as the person sees it: its email and the chat app's
  # workspace (a Slack workspace's name).
  def change do
    alter table(:comma_provider_user_links) do
      add(:subject_email, :text)
      add(:subject_workspace, :text)
    end

    alter table(:comma_workspaces) do
      add(:own_request_mode, :text, null: false, default: "review")
    end

    create(
      constraint(:comma_workspaces, :comma_workspaces_own_request_mode_check,
        check: "own_request_mode IN ('review', 'auto_accept')"
      )
    )
  end
end
