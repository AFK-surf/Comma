defmodule BridgeForTeamsWeb.Dashboard.ConversationTraceController do
  @moduledoc """
  Authenticated dashboard proxy for a conversation's local Salix session trace.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.{Conversations, Memberships, Orgs, Projects}
  alias BridgeForTeamsWeb.{LimitParams, ResponseSanitizer}

  def show(conn, %{"org" => slug, "id" => project_id, "conversation_id" => conversation_id}) do
    user = conn.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id,
         :ok <- Memberships.authorize(user.id, :read, %{project_id: project.id}),
         {:ok, limit} <- LimitParams.read(conn.params, "limit"),
         {:ok, conversation} <- require_conversation(project, conversation_id),
         {:ok, participants} <-
           Conversations.list_project_conversation_participants(project, conversation_id),
         {:ok, %{agent_id: agent_id, session_id: session_id}} <-
           Conversations.debug_trace_target(Map.put(conversation, "participants", participants),
             participant_id: conn.params["participant"]
           ),
         {:ok, trace} <- require_session_trace(agent_id, session_id, limit) do
      json(conn, ResponseSanitizer.sanitize(trace))
    else
      {:error, :conversation_not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "conversation_not_found"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "forbidden"})

      {:error, :unavailable} ->
        conn |> put_status(503) |> json(%{"error" => "unavailable"})

      {:error, :timeout} ->
        conn |> put_status(504) |> json(%{"error" => "timeout"})

      {:error, {:bad_request, message}} ->
        conn |> put_status(400) |> json(%{"error" => message})

      {:error, :missing_trace_session} ->
        conn |> put_status(404) |> json(%{"error" => "trace_session_not_found"})

      {:error, :trace_participant_required} ->
        conn |> put_status(400) |> json(%{"error" => "trace_participant_required"})

      {:error, :invalid_limit} ->
        conn |> put_status(400) |> json(%{"error" => "invalid_limit"})

      false ->
        conn |> put_status(:not_found) |> json(%{"error" => "not_found"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{"error" => "trace_unavailable"})
    end
  end

  defp require_conversation(project, conversation_id) do
    case Conversations.get_project_conversation(project, conversation_id) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :not_found} -> {:error, :conversation_not_found}
      error -> error
    end
  end

  defp require_session_trace(agent_id, session_id, limit) do
    case Conversations.get_session_trace(agent_id, session_id, limit: limit) do
      {:ok, trace} -> {:ok, trace}
      {:error, :not_found} -> {:error, :missing_trace_session}
      error -> error
    end
  end
end
