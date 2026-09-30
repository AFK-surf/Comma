defmodule BridgeForTeamsWeb.Dashboard.ConversationAttachmentController do
  @moduledoc "Authenticated downloads of files an Agent sent to a project Conversation."
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.{Conversations, Memberships, Orgs, Projects}

  def show(conn, %{
        "org" => slug,
        "id" => project_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "index" => index
      }) do
    # Authorization is fresh for every click; a link is not a durable grant.
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id,
         :ok <-
           Memberships.authorize(conn.assigns.current_user.id, :read, %{project_id: project.id}),
         {index, ""} when index >= 0 <- Integer.parse(index),
         {:ok, %{filename: filename, body: body}} <-
           Conversations.get_project_conversation_attachment(
             project,
             conversation_id,
             message_id,
             index
           ) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:binary, body},
        filename: filename,
        content_type: "application/octet-stream"
      )
    else
      {:error, :forbidden} -> error(conn, 403, "forbidden")
      {:error, :too_large} -> error(conn, 413, "attachment_exceeds_10_mb")
      {:error, :not_found} -> error(conn, 404, "attachment_not_found")
      {:error, {:bad_request, _}} -> error(conn, 404, "attachment_not_found")
      {:error, :timeout} -> error(conn, 504, "attachment_unavailable")
      {:error, _reason} -> error(conn, 503, "attachment_unavailable")
      _ -> error(conn, 404, "attachment_not_found")
    end
  end

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{"error" => reason})
end
