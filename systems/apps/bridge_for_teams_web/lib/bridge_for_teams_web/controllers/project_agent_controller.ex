defmodule BridgeForTeamsWeb.ProjectAgentController do
  @moduledoc """
  Project-scoped agent API used by BFT CLI clients.

  This is the same project agent inventory and create path the dashboard relies
  on, exposed as a product API so operators can create external workers and bind
  Slack connects without guessing Salix ids.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.{Agents, Environments}
  alias BridgeForTeams.Schema.Project
  alias BridgeForTeamsWeb.{LimitParams, ProjectScope}

  def create(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, agent} <- create_agent(project, params, request_audit_opts(conn)) do
      {environments, runtime_lookup_error} = project_environments(project)

      response =
        %{
          "mode" => "project_agent_create",
          "org" => public_org(org),
          "project" => public_project(project),
          "agent" => public_agent(agent, environments)
        }
        |> maybe_put("runtime_lookup_error", runtime_lookup_error)

      send_ok(conn, response, 201)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, 422, "validation_failed", "Could not create project agent.", %{
          "errors" => changeset_errors(changeset)
        })

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
      {environments, runtime_lookup_error} = project_environments(project)

      agents = page.items

      response =
        %{
          "mode" => "project_agents_list",
          "org" => public_org(org),
          "project" => public_project(project),
          "agents" => Enum.map(agents, &public_agent(&1, environments)),
          "limit" => limit,
          "next_cursor" => page.next_cursor
        }
        |> maybe_put("role", role)
        |> maybe_put("filter", trim(params["filter"]))
        |> maybe_put("runtime_lookup_error", runtime_lookup_error)

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

  def runtimes(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, runtimes} <- Agents.list_external_runtimes(project.id) do
      send_ok(conn, %{
        "mode" => "project_agent_runtimes_list",
        "org" => public_org(org),
        "project" => public_project(project),
        "runtimes" => runtimes
      })
    else
      error ->
        send_project_error(conn, error, "Could not list project agent runtimes.")
    end
  end

  def workloads(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, provider} <- read_workload_provider(params),
         {:ok, limit} <- LimitParams.read(params, "limit", 50),
         {:ok, include_unavailable} <- read_include_unavailable(params),
         {:ok, page} <-
           Agents.page_external_worker_targets(project, provider,
             cursor: trim_nil(params["cursor"]),
             query: trim_nil(params["query"]),
             node_id: trim_nil(params["node_id"]),
             limit: min(limit, 50),
             include_unavailable: include_unavailable
           ) do
      send_ok(conn, %{
        "mode" => "project_agent_workloads_page",
        "org" => public_org(org),
        "project" => public_project(project),
        "provider" => provider,
        "page" => page
      })
    else
      {:error, :invalid_limit} ->
        send_error(conn, 400, "invalid_limit", "Limit must be a positive integer.", %{})

      {:error, :invalid_include_unavailable} ->
        send_error(
          conn,
          400,
          "invalid_include_unavailable",
          "include_unavailable must be true or false.",
          %{}
        )

      error ->
        send_project_error(conn, error, "Could not list project agent Workloads.")
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
      {environments, runtime_lookup_error} = project_environments(project)

      response =
        %{
          "mode" => "project_agent_update",
          "org" => public_org(org),
          "project" => public_project(project),
          "agent" => public_agent(agent, environments)
        }
        |> maybe_put("runtime_lookup_error", runtime_lookup_error)

      send_ok(conn, response)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, 422, "validation_failed", "Could not update project agent.", %{
          "errors" => changeset_errors(changeset)
        })

      error ->
        send_project_error(conn, error, "Could not update project agent.")
    end
  end

  def rebind_runtime(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, agent} <- require_project_agent(project, params["agent"]),
         {:ok, expected_revision} <- read_expected_binding_revision(params),
         {:ok, agent} <-
           Agents.rebind_external_target(
             project,
             agent,
             external_target(params),
             expected_revision,
             request_audit_opts(conn)
           ) do
      {environments, runtime_lookup_error} = project_environments(project)

      response =
        %{
          "mode" => "project_agent_runtime_rebind",
          "org" => public_org(org),
          "project" => public_project(project),
          "agent" => public_agent(agent, environments)
        }
        |> maybe_put("runtime_lookup_error", runtime_lookup_error)

      send_ok(conn, response)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, 422, "validation_failed", "Could not rebind project agent runtime.", %{
          "errors" => changeset_errors(changeset)
        })

      error ->
        send_project_error(conn, error, "Could not rebind project agent runtime.")
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

  defp create_agent(project, %{"external_target" => target} = params, opts)
       when is_map(target) do
    Agents.create_external_agent(project, Map.take(params, ~w(name)), target, opts)
  end

  defp create_agent(_project, %{"external_target" => _target}, _opts),
    do: {:error, :invalid_external_target}

  defp create_agent(_project, %{"runtime_config" => _config}, _opts),
    do: {:error, :raw_runtime_config_forbidden}

  defp create_agent(project, params, opts),
    do: Agents.create_agent(project.id, Map.take(params, ~w(name role vm)), opts)

  defp update_agent_attrs(params) do
    Map.take(params, ~w(name role vm))
  end

  defp external_target(%{"external_target" => target}) when is_map(target), do: target
  defp external_target(_params), do: %{}

  defp read_expected_binding_revision(params) do
    case params["expected_binding_revision"] do
      revision when is_integer(revision) and revision >= 0 ->
        {:ok, revision}

      revision when is_binary(revision) ->
        case Integer.parse(revision) do
          {value, ""} when value >= 0 -> {:ok, value}
          _ -> {:error, :invalid_expected_binding_revision}
        end

      _ ->
        {:error, :invalid_expected_binding_revision}
    end
  end

  defp read_workload_provider(params) do
    case trim(params["provider"]) do
      provider when provider in ["codex", "pi", "claude"] -> {:ok, provider}
      _ -> {:error, :provider_unsupported}
    end
  end

  defp read_include_unavailable(params) do
    case params["include_unavailable"] do
      nil -> {:ok, false}
      value when value in [true, "true"] -> {:ok, true}
      value when value in [false, "false"] -> {:ok, false}
      _ -> {:error, :invalid_include_unavailable}
    end
  end

  defp trim_nil(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp read_role(params) do
    case trim(params["role"]) do
      "" -> {:ok, nil}
      role when role in ["router", "worker"] -> {:ok, role}
      _other -> {:error, :invalid_role}
    end
  end

  defp project_environments(%Project{} = project) do
    {:ok, environments} = Environments.list_projected_environments(project.id)
    {environments, nil}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_audit_opts(conn) do
    user = current_user(conn)

    [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: List.first(get_req_header(conn, "x-request-id")) || Ecto.UUID.generate()
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
