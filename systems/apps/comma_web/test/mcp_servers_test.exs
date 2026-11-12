defmodule CommaWeb.McpServersTest do
  use Comma.DataCase, async: false

  alias CommaWeb.McpServers
  alias Salix.Control.RemoteMCPOAuth

  defmodule Remote do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/down"} = conn, _opts), do: send_resp(conn, 500, "down")

    # The MCP endpoint asks for the OAuth sign-in the way a real server does.
    def call(%{request_path: "/v1/local-oauth/mcp/resource"} = conn, _opts) do
      case get_req_header(conn, "authorization") do
        [] ->
          conn
          |> put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> send_resp(401, "sign in")

        _authorized ->
          SalixWeb.LocalOAuthMock.call(conn, [])
      end
    end

    def call(conn, _opts), do: SalixWeb.LocalOAuthMock.call(conn, [])
  end

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    keys = [
      {:salix_web, :local_oauth_mock},
      {:salix_web, :public_base_url},
      {:salix_mcp, :private_http_target_allowlist},
      {:salix_mcp, :credential_resolver_mod}
    ]

    previous = Enum.map(keys, fn {app, key} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    bandit =
      start_supervised!({Bandit, plug: Remote, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"
    resource = base <> "/v1/local-oauth/mcp/resource"
    down = base <> "/down"
    SystemsRuntime.put_env(:salix_web, :public_base_url, base)
    SystemsRuntime.put_env(:salix_web, :local_oauth_mock, true)
    SystemsRuntime.put_env(:salix_mcp, :private_http_target_allowlist, [resource, down])
    SystemsRuntime.put_env(:salix_mcp, :credential_resolver_mod, Salix.Bindings.MCPCredentials)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, value} -> SystemsRuntime.put_env(app, key, value)
      end)

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    user = new_user()
    %{user: user, workspace: create_ready_workspace!(user), resource: resource, down: down}
  end

  test "a server with OAuth is added, signed in to, removed and added again", %{
    user: user,
    workspace: %{"id" => id},
    resource: resource
  } do
    attrs = %{"name" => "Shengcai", "url" => resource}
    assert {:ok, added} = McpServers.add(user, %{}, id, attrs)
    assert added["authorizationUrl"] =~ "/mcp/authorize"

    assert [%{"name" => "Shengcai", "status" => "needs_authorization", "tools" => 0} = server] =
             added["servers"]

    assert server["url"] == resource

    RemoteMCPOAuth.handle_callback(%{"state" => state(added), "code" => "test"})

    assert {:ok, %{"servers" => [connected]}} = McpServers.list(user, %{}, id)
    assert connected["status"] == "connected"
    assert connected["tools"] > 0

    assert {:ok, again} = McpServers.connect(user, %{}, id, server["id"])
    refute Map.has_key?(again, "authorizationUrl")
    assert [%{"status" => "connected"}] = again["servers"]

    assert {:error, {:bad_request, "mcp_server_exists"}} = McpServers.add(user, %{}, id, attrs)

    assert {:ok, %{"servers" => []}} = McpServers.remove(user, %{}, id, server["id"])
    assert {:ok, readded} = McpServers.add(user, %{}, id, attrs)
    assert readded["authorizationUrl"] =~ "/mcp/authorize"
    [%{"id" => new_id}] = readded["servers"]
    assert new_id != server["id"]
  end

  test "a server that answers neither transport leaves nothing behind", %{
    user: user,
    workspace: %{"id" => id},
    down: down
  } do
    assert {:error, {:bad_request, "mcp_server_unreachable"}} =
             McpServers.add(user, %{}, id, %{"name" => "Down", "url" => down})

    assert {:ok, %{"servers" => []}} = McpServers.list(user, %{}, id)

    assert {:error, {:bad_request, "invalid_mcp_url"}} =
             McpServers.add(user, %{}, id, %{"url" => "ftp://example.com"})
  end

  test "only the workspace's owner reaches its servers, and a plugin's stay the plugin's", %{
    user: user,
    workspace: workspace,
    resource: resource
  } do
    id = workspace["id"]
    {:ok, added} = McpServers.add(user, %{}, id, %{"name" => "Mine", "url" => resource})
    [%{"id" => server}] = added["servers"]

    stranger = new_user()
    assert {:error, :forbidden} = McpServers.list(stranger, %{}, id)
    assert {:error, :forbidden} = McpServers.remove(stranger, %{}, id, server)

    {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()
    [system | _] = Enum.filter(SalixMCP.Store.list_definitions(), &(&1["scope"] == "system"))

    {:ok, plugin_binding} =
      SalixMCP.Store.create_binding(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        %{
          "mcp_id" => system["mcp_id"],
          "alias" => "from-plugin",
          "target_ref" => hd(system["server_metadata"]["remotes"])["target_ref"],
          "placement" => "server"
        }
      )

    assert {:ok, %{"servers" => [%{"id" => ^server}]}} = McpServers.list(user, %{}, id)

    assert {:error, :not_found} =
             McpServers.remove(user, %{}, id, plugin_binding["binding_id"])
  end

  defp new_user do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "mcp-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    user
  end

  defp state(%{"authorizationUrl" => url}),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
end
