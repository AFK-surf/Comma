defmodule CommaWeb.Coding.EndpointsTest do
  use SystemsClock.Case, async: false

  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.Ids

  defmodule GitHub do
    @moduledoc false
    def token(_tenant, _group), do: {:ok, %{token: "ghu_x", expires_at: nil}}

    def repos("ghu_x", page),
      do:
        {:ok,
         [
           %{
             owner: "acme",
             name: "api",
             default_branch: "main",
             private: true,
             pushed_at: "p#{page}"
           }
         ]}

    def branches("ghu_x", "acme", "api", 1), do: {:ok, ["main", "release/2.1"]}
    def branches("ghu_x", _owner, _name, _page), do: {:error, :not_found}
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    SystemsRuntime.put_env(:salix_web, :coding_github, GitHub)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :coding_github)
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

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
      base: "http://127.0.0.1:#{port}/v1/comma/workspaces/#{workspace.id}/coding",
      owner: owner_session,
      viewer: viewer_session
    }
  end

  test "a member reads a page of the connected GitHub account's repositories and a repository's branches",
       ctx do
    assert %{status: 200, body: %{"repos" => [repo]}} =
             get(ctx.base <> "/repos?page=2", ctx.owner)

    assert repo == %{
             "owner" => "acme",
             "name" => "api",
             "default_branch" => "main",
             "private" => true,
             "pushed_at" => "p2"
           }

    assert %{status: 200, body: %{"branches" => ["main", "release/2.1"]}} =
             get(ctx.base <> "/repos/acme/api/branches", ctx.viewer)

    assert %{status: 404} = get(ctx.base <> "/repos/acme/other/branches", ctx.owner)
    assert %{status: 401} = Req.get!(ctx.base <> "/repos", retry: false)
  end

  test "a read-only member starts no session, and a start needs its words and request id", ctx do
    body = %{
      "text" => "fix it",
      "client_request_id" => "k1",
      "repo" => %{"owner" => "acme", "name" => "api"}
    }

    assert %{status: 403} = post(ctx.base <> "/sessions", ctx.viewer, body)

    assert %{status: 400, body: %{"message" => "text is required"}} =
             post(ctx.base <> "/sessions", ctx.owner, Map.put(body, "text", " "))

    assert %{status: 400, body: %{"message" => "client_request_id is required"}} =
             post(ctx.base <> "/sessions", ctx.owner, Map.delete(body, "client_request_id"))

    assert %{status: 400} =
             post(
               ctx.base <> "/sessions",
               ctx.owner,
               Map.put(body, "model", %{"provider" => "gemini"})
             )
  end

  test "a Task that is no coding session of the Workspace is not found", ctx do
    assert %{status: 404} = get(ctx.base <> "/sessions/cnv_missing", ctx.owner)
    assert %{status: 404} = get(ctx.base <> "/sessions/cnv_missing/changes", ctx.owner)
    assert %{status: 404} = get(ctx.base <> "/sessions/cnv_missing/history", ctx.owner)
    assert %{status: 404} = post(ctx.base <> "/sessions/cnv_missing/terminal", ctx.owner, %{})

    assert %{status: 403} =
             post(ctx.base <> "/sessions/cnv_missing/pull-request", ctx.viewer, %{})
  end

  defp user! do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "coding-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
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
        id: "wsp_coding_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "coding-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "coding-test",
        name: "Coding team",
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
  defp get(url, session), do: Req.get!(url, headers: auth(session), retry: false)

  defp post(url, session, body),
    do: Req.post!(url, json: body, headers: auth(session), retry: false)
end
