defmodule BridgeForTeamsWeb.DashboardImportController do
  @moduledoc """
  Import mock/demo My Space board data.

  External tools generate a `bft.myspace.import` JSON document and POST it here
  to seed a user's "My Space" board with cards, task-chat transcripts, an
  assistant-rail transcript, and a layout. See
  `BridgeForTeams.WorkspaceImports` for the document contract and the
  `mock_import` semantics.

  ## Auth

  The `:dashboard_import_api` pipeline authenticates the bearer token two ways
  (import token first, CLI session as a fallback):

    * **Import token** — a temporary token minted from the Agent Swarm dashboard
      by a project admin (`BridgeForTeams.Auth.create_import_token/4`). It is
      scoped to one `(user, org, project)`; the path org/project must match that
      scope exactly, and no CLI org-grant is consulted.
    * **CLI session** — a `bft auth login` session, scoped by the CLI org-grant
      and project RBAC (`ProjectScope`), exactly as before.

  `user_email` (importing into another member's board) stays org owner/admin
  gated in both modes.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.WorkspaceImports
  alias BridgeForTeamsWeb.ProjectScope

  def create(conn, params) do
    with {:ok, org, project} <- resolve_and_authorize(conn, params),
         {:ok, target_user} <- resolve_target_user(conn, org, params["user_email"]),
         {:ok, summary} <-
           WorkspaceImports.import_document(
             ProjectScope.current_user(conn),
             target_user,
             org,
             project,
             import_document(params),
             request_id: request_id(conn)
           ) do
      send_ok(conn, %{
        "mode" => "dashboard_import",
        "created" => summary.created,
        "updated" => summary.updated,
        "archived" => summary.archived,
        "messages_appended" => summary.messages_appended,
        "messages_skipped" => summary.messages_skipped,
        "items" => Enum.map(summary.items, &public_item/1)
      })
    else
      {:error, {:validation, errors}} ->
        send_error(conn, 422, "validation_failed", "Import document is invalid.", %{
          "errors" => Enum.map(errors, &public_error/1)
        })

      {:error, :forbidden} ->
        send_error(conn, 403, "forbidden", "You may not import into that user's board.", %{})

      {:error, :not_found} ->
        send_error(conn, 404, "user_not_found", "No matching org member for that email.", %{})

      error ->
        send_project_error(conn, error, "Could not import dashboard data.")
    end
  end

  # Import-token requests are already scoped to a single (user, org, project):
  # require the path to match that scope exactly and skip the CLI org-grant /
  # project RBAC checks (project write access was re-verified at auth time).
  # CLI-session requests keep the existing org-grant + project-write ordering
  # (org authorization decides before the project is resolved).
  defp resolve_and_authorize(conn, params) do
    case conn.assigns do
      %{import_token_org_id: token_org_id, import_token_project_id: token_project_id} ->
        with {:ok, org} <- require_org(params["org"]),
             {:ok, project} <- require_project(conn, org, params["project"]),
             :ok <- match_import_scope(org, project, token_org_id, token_project_id) do
          {:ok, org, project}
        end

      _cli_session ->
        with {:ok, org} <- require_org(params["org"]),
             :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
             {:ok, project} <- require_project(conn, org, params["project"]),
             :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write) do
          {:ok, org, project}
        end
    end
  end

  defp match_import_scope(org, project, token_org_id, token_project_id) do
    if org.id == token_org_id and project.id == token_project_id do
      :ok
    else
      error(403, "forbidden", "This import token is not scoped to that Agent Swarm.")
    end
  end

  defp error(status, code, message, details \\ %{}), do: {:error, status, code, message, details}

  # The request body IS the import document; the org/project come from the path.
  defp import_document(params), do: Map.drop(params, ["org", "project"])

  defp resolve_target_user(conn, org, email) do
    WorkspaceImports.resolve_target_user(ProjectScope.current_user(conn), org, email)
  end

  defp public_item(%{external_id: external_id, conversation_id: conversation_id}) do
    %{"external_id" => external_id, "conversation_id" => conversation_id}
  end

  defp public_error(%{index: index, external_id: external_id, errors: errors}) do
    %{"index" => index, "external_id" => external_id, "errors" => errors}
  end

  defp require_org(ref) do
    ProjectScope.require_org(ref, missing_message: "Pass an org id or slug.")
  end

  defp require_project(conn, org, ref) do
    ProjectScope.require_project_for_conn(conn, org, ref,
      missing_message: "Pass a project id or slug."
    )
  end

  defp request_id(conn) do
    List.first(get_req_header(conn, "x-request-id")) || Ecto.UUID.generate()
  end
end
