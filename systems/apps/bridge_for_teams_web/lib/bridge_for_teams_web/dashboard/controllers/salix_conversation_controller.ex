defmodule BridgeForTeamsWeb.Dashboard.SalixConversationController do
  @moduledoc """
  Resolve task link identities to the BFT task page.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.{Conversations, Memberships, Orgs, Projects}

  def show(conn, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "conversation_id" => conversation_id
      }) do
    user = conn.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_salix_tenant_id(tenant_id),
         {:ok, project} <- Projects.get_project_by_salix_group(group_id),
         true <- project.org_id == org.id,
         :ok <- Memberships.authorize(user.id, :read, %{project_id: project.id}),
         {:ok, _conversation} <- Conversations.get_project_conversation(project, conversation_id) do
      redirect(conn,
        to: ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation_id}"
      )
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Task not found")
    end
  end
end
