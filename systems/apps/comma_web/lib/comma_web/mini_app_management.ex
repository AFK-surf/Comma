defmodule CommaWeb.MiniAppManagement do
  @moduledoc """
  The Workspace Router's Mini App actions use the existing product operations.
  The current Workspace binding supplies authority, never tool parameters.
  Member-private apps remain outside the shared Router's scope.
  """

  alias Comma.Data.Workspace
  alias Comma.MiniApps
  alias Comma.Repo
  alias CommaWeb.{MiniAppPort, MiniAppPublishing}

  def call(%{tenant_id: tenant, group_id: group, agent_id: router}, action, params) do
    with %Workspace{
           status: "active",
           kind: "standard",
           salix_tenant_id: ^tenant,
           salix_router_agent_id: ^router
         } = workspace <-
           Repo.get_by(Workspace, salix_group_id: group) || {:error, :not_found},
         {:ok, user} <- owner(workspace),
         {:ok, _, _} <- MiniApps.member(user, caller(workspace), workspace.id, access(action)),
         :ok <- visible(workspace, action, params) do
      run(workspace, user, action, params)
    else
      %Workspace{} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def call(_scope, _action, _params), do: {:error, :not_found}

  defp owner(workspace) do
    case Comma.Accounts.get_user(workspace.owner_user_id) do
      {:ok, %{"status" => "active"} = user} ->
        if user["kind"] == "guest", do: {:error, :forbidden}, else: {:ok, user}

      _ ->
        {:error, :forbidden}
    end
  end

  defp caller(workspace), do: {:router, workspace.salix_router_agent_id}

  defp access("link.get"), do: :read
  defp access("report"), do: :read
  defp access(_action), do: :write

  defp visible(_workspace, action, _params) when action in ["install", "remix"], do: :ok

  defp visible(workspace, "report", %{"app_id" => id}) do
    case MiniApps.get_app(id) do
      %{workspace_id: ws, visibility: "link"} when ws != workspace.id -> :ok
      _ -> visible(workspace, "get", %{"app_id" => id})
    end
  end

  defp visible(workspace, _action, %{"app_id" => id}) do
    with {:ok, _app} <- MiniApps.router_app(workspace, id), do: :ok
  end

  defp visible(_workspace, _action, _params), do: {:error, {:bad_request, "app_id is required"}}

  defp run(ws, user, "publish", %{"app_id" => id, "version" => number} = params)
       when is_integer(number) and number > 0 do
    with {:ok, _, app} <- MiniApps.owner_app(user, caller(ws), ws.id, id),
         {:ok, version} <- MiniApps.ready_version(app, number),
         {:ok, task} <-
           SalixIM.Conversations.get_group_conversation(
             ws.salix_group_id,
             version.conversation_id
           ) do
      body =
        Map.merge(params, %{
          "group_id" => ws.salix_group_id,
          "conversation_id" => version.conversation_id,
          "review_version" => task["updated_at"]
        })

      MiniAppPublishing.publish(user, caller(ws), ws.id, id, body, initiator_kind: "agent")
    end
  end

  defp run(ws, user, "update", params),
    do: MiniApps.update(user, caller(ws), ws.id, params["app_id"], params)

  defp run(ws, user, "rollback", params),
    do: MiniApps.rollback(user, caller(ws), ws.id, params["app_id"], params["version"])

  defp run(ws, user, "disable", params),
    do: MiniApps.disable(user, caller(ws), ws.id, params["app_id"])

  defp run(ws, user, "enable", params),
    do: MiniApps.enable(user, caller(ws), ws.id, params["app_id"])

  defp run(ws, user, "delete", params) do
    with {:ok, :ok} <- MiniApps.delete(user, caller(ws), ws.id, params["app_id"]),
         do: {:ok, %{"status" => "deleted"}}
  end

  defp run(ws, user, "link.get", params),
    do: link(MiniApps.get_link(user, caller(ws), ws.id, params["app_id"]))

  defp run(ws, user, "link.create", params),
    do: link(MiniApps.put_link(user, caller(ws), ws.id, params["app_id"]))

  defp run(ws, user, "link.reset", params),
    do: link(MiniApps.reset_link(user, caller(ws), ws.id, params["app_id"]))

  defp run(ws, user, "link.revoke", params) do
    with :ok <- MiniApps.revoke_link(user, caller(ws), ws.id, params["app_id"]),
         do: {:ok, %{"link" => nil}}
  end

  defp run(ws, user, "grants.set", params),
    do: MiniApps.put_grants(user, caller(ws), ws.id, params["app_id"], params["grants"])

  defp run(ws, user, "secrets.set", params),
    do:
      MiniApps.put_secret(
        user,
        caller(ws),
        ws.id,
        params["app_id"],
        params["name"],
        params["value"]
      )

  defp run(ws, user, "secrets.delete", params),
    do: MiniApps.delete_secret(user, caller(ws), ws.id, params["app_id"], params["name"])

  defp run(ws, user, "install", params),
    do: MiniApps.install(user, caller(ws), ws.id, params["token"], params["pinned_version"])

  defp run(ws, user, "uninstall", params) do
    with :ok <- MiniApps.uninstall(user, caller(ws), ws.id, params["app_id"]),
         do: {:ok, %{"status" => "removed"}}
  end

  defp run(ws, user, "remix", params),
    do: MiniAppPort.remix(user, caller(ws), ws.id, params["token"], initiator_kind: "agent")

  defp run(ws, user, "report", params) do
    with :ok <- MiniApps.report(user, caller(ws), ws.id, params["app_id"], params["reason"]),
         do: {:ok, %{"status" => "reported"}}
  end

  defp run(_ws, _user, _action, _params),
    do: {:error, {:bad_request, "invalid Mini App operation"}}

  defp link({:ok, nil}), do: {:ok, %{"link" => nil}}
  defp link({:ok, link}), do: {:ok, MiniApps.link_view(link)}
  defp link(error), do: error
end
