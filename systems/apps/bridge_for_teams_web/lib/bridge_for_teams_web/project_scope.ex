defmodule BridgeForTeamsWeb.ProjectScope do
  @moduledoc """
  Shared org/project resolution and RBAC checks for dashboard-owned HTTP
  surfaces.

  LiveView pages and CLI/API controllers may enter through different transports,
  but project-scoped product operations must resolve the same org/project refs
  and enforce the same membership rules before calling core contexts.
  """

  alias BridgeForTeams.{CLI.Login, Memberships, Orgs, Projects}
  alias BridgeForTeams.Schema.{Organization, Project, User}

  @type error_tuple :: {:error, non_neg_integer(), String.t(), String.t(), map()}

  @spec require_org(String.t() | nil, keyword()) :: {:ok, Organization.t()} | error_tuple()
  def require_org(ref, opts \\ []) do
    missing_message = Keyword.get(opts, :missing_message, "Pass an org id or slug.")

    cond do
      blank?(ref) ->
        error(400, "missing_org", missing_message)

      uuid?(ref) ->
        case Orgs.get_org(ref) do
          {:ok, org} -> {:ok, org}
          {:error, :not_found} -> error(404, "org_not_found", "Org not found.")
        end

      true ->
        case Orgs.get_org_by_slug(ref) do
          {:ok, org} -> {:ok, org}
          {:error, :not_found} -> error(404, "org_not_found", "Org not found.")
        end
    end
  end

  @spec require_project(User.t(), Organization.t(), String.t() | nil, keyword()) ::
          {:ok, Project.t()} | error_tuple()
  def require_project(%User{} = user, %Organization{} = org, ref, opts \\ []) do
    missing_message = Keyword.get(opts, :missing_message, "Pass a project id or slug.")

    cond do
      blank?(ref) ->
        error(400, "missing_project", missing_message)

      true ->
        org.id
        |> Projects.list_projects_for_user(user.id)
        |> Enum.find(&project_matches?(&1, ref))
        |> case do
          %Project{} = project -> {:ok, project}
          nil -> error(404, "project_not_found", "Project not found.")
        end
    end
  end

  def require_project_for_conn(conn, %Organization{} = org, ref, opts \\ []) do
    require_project(current_user(conn), org, ref, opts)
  end

  @spec authorize_org(User.t(), Organization.t(), String.t()) :: :ok | error_tuple()
  def authorize_org(%User{} = user, %Organization{} = org, min_role) do
    case Memberships.authorize(user.id, :read, %{org_id: org.id, min_org_role: min_role}) do
      :ok ->
        :ok

      {:error, :forbidden} ->
        error(403, "forbidden", "You do not have access to this organization.")
    end
  end

  def authorize_org_for_conn(conn, %Organization{} = org, min_role) do
    with :ok <- authorize_cli_org_grant(conn, org),
         :ok <- authorize_org(current_user(conn), org, min_role) do
      :ok
    end
  end

  @spec authorize_project(User.t(), Project.t(), atom()) :: :ok | error_tuple()
  def authorize_project(%User{} = user, %Project{} = project, action) do
    case Memberships.authorize(user.id, action, %{project_id: project.id}) do
      :ok ->
        :ok

      {:error, :forbidden} ->
        error(403, "forbidden", "You do not have access to this Agent Swarm.")
    end
  end

  def authorize_project_for_conn(conn, %Project{} = project, action) do
    with :ok <- authorize_cli_org_grant(conn, project.org_id),
         :ok <- authorize_project(current_user(conn), project, action) do
      :ok
    end
  end

  def current_user(conn), do: Map.fetch!(conn.assigns, :current_user)

  defp authorize_cli_org_grant(conn, %Organization{} = org),
    do: authorize_cli_org_grant(conn, org.id)

  defp authorize_cli_org_grant(conn, org_id) do
    case Login.authorize_cli_session_org(Map.get(conn.assigns, :current_cli_session), org_id) do
      :ok ->
        :ok

      {:error, :cli_org_grant_required} ->
        error(403, "forbidden", "CLI session is not authorized for this organization.")
    end
  end

  defp project_matches?(%Project{} = project, ref) do
    ref in [project.id, project.slug]
  end

  defp error(status, code, message, details \\ %{}), do: {:error, status, code, message, details}

  defp blank?(value), do: !present?(value)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
