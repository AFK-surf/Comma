defmodule Comma.Repo.Migrations.AllowOwnTaskRequests do
  use Ecto.Migration

  # A Workspace owner's request to their own Workspace, sent through a chat
  # account linked to them, has no grant: owning the Workspace is the
  # authority. Every other request still names its grant.
  def change do
    alter table(:comma_task_requests) do
      modify(:grant_id, :string, null: true, from: {:string, null: false})
    end
  end
end
