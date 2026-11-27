defmodule BridgeForTeamsWeb.ProjectIMConnectController do
  @moduledoc """
  Project-scoped IM connect API used by BFT CLI clients.

  The controller owns HTTP transport, user/project authorization, JSON shape, and
  redaction. The dashboard LiveView uses `BridgeForTeams.ProjectIMConnects`
  in-process, so both surfaces share the same business context without creating
  a second Slack-connect lifecycle.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.ProjectIMConnects
  alias BridgeForTeams.Schema.Project
  alias BridgeForTeamsWeb.ProjectScope

  def index(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, connects} <- ProjectIMConnects.list_project_connects(org.id, project.id, "slack") do
      send_ok(conn, %{
        "mode" => "project_im_connects_list",
        "provider" => "slack",
        "org" => public_org(org),
        "project" => public_project(project),
        "connects" => Enum.map(connects, &public_connect/1)
      })
    else
      error -> send_project_error(conn, error, "Could not list project Slack connects.")
    end
  end

  def create_slack(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         :ok <- valid_member_scope(params["member_scope"]),
         {:ok, connect} <-
           ProjectIMConnects.create_project_connect(
             org.id,
             project.id,
             "slack",
             slack_attrs(params, project),
             request_audit_opts(conn)
           ) do
      send_ok(conn, %{
        "mode" => "project_im_connect_create",
        "provider" => "slack",
        "org" => public_org(org),
        "project" => public_project(project),
        "connect" => public_connect(connect),
        "oauth_url" => sanitize_url(connect["oauth_url"]),
        "redaction" => %{
          "credential_input" => "request_body",
          "secrets_printed" => false
        }
      })
    else
      {:error, :invalid_member_scope} ->
        send_error(
          conn,
          400,
          "invalid_member_scope",
          "Pass member_scope as organization or external.",
          %{}
        )

      error ->
        send_project_error(conn, error, "Could not create project Slack connect.")
    end
  end

  defp valid_member_scope(scope) when scope in [nil, "organization", "external"], do: :ok
  defp valid_member_scope(_scope), do: {:error, :invalid_member_scope}

  def update_slack(conn, %{"connect_id" => connect_id} = params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, connect} <- update_slack_connect(conn, org, project, connect_id, params) do
      send_ok(conn, %{
        "mode" => "project_im_connect_update",
        "provider" => "slack",
        "org" => public_org(org),
        "project" => public_project(project),
        "connect" => public_connect(connect)
      })
    else
      {:error, :missing_inbound_agent} ->
        send_error(
          conn,
          400,
          "missing_inbound_agent",
          "Pass inbound_agent_id (the Router), inbound_tasks ({\"model\": <model choice or null>}), auto_join_public_channels (true or false) or member_scope (organization or external).",
          %{}
        )

      {:error, :invalid_member_scope} ->
        send_error(
          conn,
          400,
          "invalid_member_scope",
          "Pass member_scope as organization (the workspace's members are the project's people) or external (only people granted by name).",
          %{}
        )

      {:error, :workers_retired} ->
        send_error(
          conn,
          410,
          "workers_retired",
          "Workers are retired. Bind the connection to the Router, or to Tasks with inbound_tasks: each new Slack thread becomes a Task that runs its model, or the project's default Task model.",
          %{}
        )

      error ->
        send_project_error(conn, error, "Could not update project Slack connect.")
    end
  end

  def disable_slack(conn, %{"connect_id" => connect_id} = params),
    do: slack_lifecycle(conn, params, connect_id, :disable)

  def enable_slack(conn, %{"connect_id" => connect_id} = params),
    do: slack_lifecycle(conn, params, connect_id, :enable)

  def delete_slack(conn, %{"connect_id" => connect_id} = params),
    do: slack_lifecycle(conn, params, connect_id, :delete)

  defp slack_lifecycle(conn, params, connect_id, action) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, _result} <-
           call_lifecycle(org, project, connect_id, action, request_audit_opts(conn)),
         {:ok, refreshed} <- ProjectIMConnects.list_project_connects(org.id, project.id, "slack") do
      response = %{
        "mode" => lifecycle_mode(action),
        "provider" => "slack",
        "org" => public_org(org),
        "project" => public_project(project),
        "connect_id" => connect_id,
        "connects" => Enum.map(refreshed, &public_connect/1)
      }

      response =
        case {action, select_connect(refreshed, connect_id)} do
          {:delete, _} -> response
          {_, {:ok, connect}} -> Map.put(response, "connect", public_connect(connect))
          {_, {:error, _}} -> response
        end

      send_ok(conn, response)
    else
      error -> send_project_error(conn, error, "Could not update project Slack connect.")
    end
  end

  defp call_lifecycle(org, project, connect_id, :disable, opts),
    do: ProjectIMConnects.disable_project_connect(org.id, project.id, connect_id, opts)

  defp call_lifecycle(org, project, connect_id, :enable, opts),
    do: ProjectIMConnects.enable_project_connect(org.id, project.id, connect_id, opts)

  defp call_lifecycle(org, project, connect_id, :delete, opts),
    do: ProjectIMConnects.delete_project_connect(org.id, project.id, connect_id, opts)

  defp lifecycle_mode(:disable), do: "project_im_connect_disable"
  defp lifecycle_mode(:enable), do: "project_im_connect_enable"
  defp lifecycle_mode(:delete), do: "project_im_connect_delete"

  defp require_org(ref) do
    ProjectScope.require_org(ref, missing_message: "Pass an org id or slug.")
  end

  defp require_project(conn, org, ref) do
    ProjectScope.require_project_for_conn(conn, org, ref,
      missing_message: "Pass a project id or slug."
    )
  end

  defp select_connect(connects, connect_id) do
    case Enum.find(connects, &(&1["connect_id"] == connect_id)) do
      nil -> {:error, :connect_not_found}
      connect -> {:ok, connect}
    end
  end

  defp slack_attrs(params, %Project{} = project) do
    params
    |> Map.take(
      ~w(app_id client_id client_secret signing_secret app_name inbound_agent_id inbound_tasks member_scope)
    )
    |> Map.put_new("app_name", project.name)
  end

  # An update changes the inbound binding, whether the app joins new public
  # channels by itself (`auto_join_public_channels`), whose people the
  # workspace's people are (`member_scope`), or any of them.
  defp update_slack_connect(conn, org, project, connect_id, params) do
    auto_join = params["auto_join_public_channels"]
    scope = params["member_scope"]

    changes =
      [
        case require_inbound(params) do
          {:ok, inbound} ->
            fn -> update_slack_inbound(conn, org, project, connect_id, inbound) end

          _absent ->
            nil
        end,
        if(is_boolean(auto_join),
          do: fn -> update_slack_auto_join(conn, org, project, connect_id, auto_join) end
        ),
        if(not is_nil(scope),
          do: fn -> update_member_scope(conn, org, project, connect_id, scope) end
        )
      ]
      |> Enum.reject(&is_nil/1)

    case changes do
      [] ->
        require_inbound(params)

      changes ->
        Enum.reduce_while(changes, nil, fn change, _last ->
          case change.() do
            {:ok, _connect} = ok -> {:cont, ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp update_member_scope(conn, org, project, connect_id, scope)
       when scope in ["organization", "external"],
       do:
         ProjectIMConnects.update_project_connect_member_scope(
           org.id,
           project.id,
           connect_id,
           scope,
           request_audit_opts(conn)
         )

  defp update_member_scope(_conn, _org, _project, _connect_id, _scope),
    do: {:error, :invalid_member_scope}

  defp update_slack_inbound(conn, org, project, connect_id, inbound),
    do:
      ProjectIMConnects.update_project_slack_inbound(
        org.id,
        project.id,
        connect_id,
        inbound,
        request_audit_opts(conn)
      )

  defp update_slack_auto_join(conn, org, project, connect_id, enabled),
    do:
      ProjectIMConnects.update_project_slack_auto_join(
        org.id,
        project.id,
        connect_id,
        enabled,
        request_audit_opts(conn)
      )

  # The Router (`inbound_agent_id`) or Tasks (`inbound_tasks`).
  defp require_inbound(%{"inbound_tasks" => %{} = tasks}),
    do: {:ok, %{"inbound_tasks" => tasks}}

  defp require_inbound(%{"inbound_agent_id" => value}) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :missing_inbound_agent}
      value -> {:ok, %{"inbound_agent_id" => value}}
    end
  end

  defp require_inbound(_params), do: {:error, :missing_inbound_agent}

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
