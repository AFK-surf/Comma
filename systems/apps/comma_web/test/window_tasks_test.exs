defmodule CommaWeb.WindowTasksTest do
  use SystemsClock.Case, async: false

  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.Ids

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)

    {owner_user, owner_session} = user!()
    {viewer, viewer_session} = user!()
    workspace = workspace!(owner_user)
    member!(workspace, viewer, "viewer")

    server =
      start_supervised!(
        {Bandit, plug: CommaWeb.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      url: "http://127.0.0.1:#{port}/v1/comma/workspaces/#{workspace.id}/tasks",
      owner: owner_session,
      viewer: viewer_session
    }
  end

  test "a read-only member starts no Task, and a start needs its words, request id and model",
       ctx do
    body = %{
      "text" => "fix the build",
      "client_request_id" => "k1",
      "model" => %{"id" => "claude-opus-5-5"}
    }

    assert %{status: 401} = Req.post!(ctx.url, json: body, retry: false)
    assert %{status: 403} = post(ctx.url, ctx.viewer, body)

    assert %{status: 400, body: %{"message" => "text is required"}} =
             post(ctx.url, ctx.owner, Map.put(body, "text", " "))

    assert %{status: 400, body: %{"message" => "client_request_id is required"}} =
             post(ctx.url, ctx.owner, Map.delete(body, "client_request_id"))

    assert %{status: 400, body: %{"message" => "model must name a catalog model id"}} =
             post(ctx.url, ctx.owner, Map.delete(body, "model"))

    assert %{status: 400} =
             post(
               ctx.url,
               ctx.owner,
               Map.put(body, "model", %{"id" => "claude-opus-5-5", "effort" => 3})
             )
  end

  defp user! do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "window-task-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    {user, session}
  end

  defp workspace!(user) do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_window_task_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "window-task-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "window-task-test",
        name: "Window team",
        status: "active"
      })

    member!(workspace, user, "owner")
    workspace
  end

  defp member!(workspace, user, role) do
    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: role,
      status: "active"
    })
  end

  defp auth(session), do: [{"authorization", "Bearer " <> session["token"]}]

  defp post(url, session, body),
    do: Req.post!(url, json: body, headers: auth(session), retry: false)
end
