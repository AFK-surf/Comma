defmodule BridgeForTeamsWeb.ProjectAgentController do
  @moduledoc """
  Project-scoped agent API used by BFT CLI clients.

  This is the same project agent inventory the dashboard relies on, exposed as
  a product API so operators can read agent ids and configure the Router.

  Workers are retired. A Worker made before stays listed as history. Creating
  one, moving one to a station (`…/runtime`) or changing one answers 410 Gone
  (`workers_retired`): Tasks run at the project's default place and model,
  which the project's Settings set, or at the place and model a Task names.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.Agents
  alias BridgeForTeams.Schema.Project
  alias BridgeForTeamsWeb.{LimitParams, ProjectScope}

  @workers_retired "Workers are retired. Tasks run at the project's default place and model (set them in the project's Settings), or at the place and model a Task names."

  def create(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, agent} <- create_agent(project, params, request_audit_opts(conn)) do
      send_ok(
        conn,
        %{
          "mode" => "project_agent_create",
          "org" => public_org(org),
          "project" => public_project(project),
          "agent" => public_agent(agent)
        },
        201
      )
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, 422, "validation_failed", "Could not create project agent.", %{
          "errors" => changeset_errors(changeset)
        })

      {:error, :workers_retired} ->
        send_error(conn, 410, "workers_retired", @workers_retired, %{})

      error ->
        send_project_error(conn, error, "Could not create project agent.")
    end
  end

  def index(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, limit} <- read_limit(params),
         {:ok, role} <- read_role(params),
         {:ok, page} <-
           Agents.page_agents(project,
             role: role,
             filter: params["filter"],
             limit: limit,
             cursor: params["cursor"]
           ) do
      agents = page.items

      response =
        %{
          "mode" => "project_agents_list",
          "org" => public_org(org),
          "project" => public_project(project),
          "agents" => Enum.map(agents, &public_agent/1),
          "limit" => limit,
          "next_cursor" => page.next_cursor
        }
        |> maybe_put("role", role)
        |> maybe_put("filter", trim(params["filter"]))

      send_ok(conn, response)
    else
      {:error, :invalid_role} ->
        send_error(conn, 400, "invalid_role", "Role must be router or worker.", %{})

      {:error, :invalid_limit} ->
        send_error(conn, 400, "invalid_limit", "Limit must be a positive integer.", %{})

      error ->
        send_project_error(conn, error, "Could not list project agents.")
    end
  end

  def update(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, agent} <- require_project_agent(project, params["agent"]),
         {:ok, agent} <-
           Agents.update_agent(agent, update_agent_attrs(params), request_audit_opts(conn)) do
      send_ok(
        conn,
        %{
          "mode" => "project_agent_update",
          "org" => public_org(org),
          "project" => public_project(project),
          "agent" => public_agent(agent)
        }
      )
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, 422, "validation_failed", "Could not update project agent.", %{
          "errors" => changeset_errors(changeset)
        })

      {:error, :workers_retired} ->
        send_error(conn, 410, "workers_retired", @workers_retired, %{})

      error ->
        send_project_error(conn, error, "Could not update project agent.")
    end
  end

  def rebind_runtime(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write) do
      send_error(conn, 410, "workers_retired", @workers_retired, %{})
    else
      error -> send_project_error(conn, error, "Could not rebind project agent runtime.")
    end
  end

  defp require_org(ref) do
    ProjectScope.require_org(ref, missing_message: "Pass an org id or slug.")
  end

  defp require_project(conn, org, ref) do
    ProjectScope.require_project_for_conn(conn, org, ref,
      missing_message: "Pass a project id or slug."
    )
  end

  defp require_project_agent(%Project{id: project_id}, ref) do
    Agents.get_project_agent(project_id, ref)
  end

  defp read_limit(params), do: LimitParams.read(params, "limit", 100)

  defp create_agent(_project, %{"station_target" => _target}, _opts),
    do: {:error, :workers_retired}

  defp create_agent(_project, %{"external_target" => _target}, _opts),
    do: {:error, :workers_retired}

  defp create_agent(_project, %{"runtime_config" => _config}, _opts),
    do: {:error, :raw_runtime_config_forbidden}

  defp create_agent(project, params, opts),
    do: Agents.create_agent(project.id, Map.take(params, ~w(name role)), opts)

  defp update_agent_attrs(params) do
    Map.take(params, ~w(name role))
  end

  defp read_role(params) do
    case trim(params["role"]) do
      "" -> {:ok, nil}
      role when role in ["router", "worker"] -> {:ok, role}
      _other -> {:error, :invalid_role}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_audit_opts(conn) do
    user = current_user(conn)

    [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: List.first(get_req_header(conn, "x-request-id")) || SystemsRuntime.Proc.uuid()
    ]
  end

  defp actor_label(user) do
    cond do
      present?(Map.get(user, :email)) -> String.trim(user.email)
      present?(Map.get(user, :name)) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp current_user(conn), do: ProjectScope.current_user(conn)

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(safe_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
