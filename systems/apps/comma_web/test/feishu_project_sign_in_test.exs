defmodule CommaWeb.FeishuProjectSignInTest do
  @moduledoc """
  Feishu Project and Meegle run every tool call as the person who asked
  (`SalixMCP.HostedServices`, docs/tools-integrations.md): enabling needs no
  credential, a person who is not signed in gets a device-flow link and the
  call waits for it, each call carries only its requester's token, and turns
  with no person are refused. A scripted server stands in for the real MCP
  and OAuth endpoints.
  """

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma", "Elixir.SalixMCP"]
  import Comma.WorkspaceTestSupport

  alias Salix.Control.{OAuthBindings, Plugins}
  alias SalixAgent.CapabilityRequests
  alias SalixAgent.Tools.MCP
  alias SalixStore.Ids

  @tool "get_workitem_brief"

  defmodule Server do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)
    def set(key, value), do: GenServer.call(__MODULE__, {:set, key, value}, :infinity)
    def device(code, status), do: GenServer.call(__MODULE__, {:device, code, status}, :infinity)
    def revoke(token), do: GenServer.call(__MODULE__, {:revoke, token}, :infinity)
    def requests, do: GenServer.call(__MODULE__, :requests, :infinity)
    def handle(request), do: GenServer.call(__MODULE__, {:handle, request}, :infinity)

    @impl true
    def init(owner) do
      {:ok,
       %{
         owner: owner,
         base: nil,
         wrapped: false,
         expires_in: 1800,
         devices: %{},
         tokens: MapSet.new(),
         codes: 0,
         sessions: 0,
         requests: []
       }}
    end

    @impl true
    def handle_call({:set, key, value}, _from, state),
      do: {:reply, :ok, Map.put(state, key, value)}

    def handle_call({:device, code, status}, _from, state),
      do: {:reply, :ok, put_in(state.devices[code], status)}

    def handle_call({:revoke, token}, _from, state),
      do: {:reply, :ok, %{state | tokens: MapSet.delete(state.tokens, token)}}

    def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

    def handle_call({:handle, request}, _from, state) do
      state = %{state | requests: [request | state.requests]}
      {reply, state} = respond(request, state)
      {:reply, reply, state}
    end

    defp respond(%{path: "/.well-known/oauth-protected-resource"}, state) do
      {{200,
        %{
          "resource" => state.base <> "/mcp_server/v1",
          "authorization_servers" => [state.base]
        }, []}, state}
    end

    defp respond(%{path: "/.well-known/oauth-authorization-server"}, state) do
      base = state.base

      {{200,
        %{
          "issuer" => base,
          "authorization_endpoint" => base <> "/b/auth/mcp",
          "registration_endpoint" => base <> "/mcp_server/oauth/register",
          "token_endpoint" => base <> "/mcp_server/oauth/token",
          "device_authorization_endpoint" => base <> "/goapi/v5/mcp_server/oauth/device_code",
          "grant_types_supported" => [
            "authorization_code",
            "refresh_token",
            "urn:ietf:params:oauth:grant-type:device_code"
          ],
          "code_challenge_methods_supported" => ["S256"]
        }, []}, state}
    end

    defp respond(%{path: "/mcp_server/oauth/register"}, state),
      do: {{200, wrap(state, %{"client_id" => "cli_test", "client_secret" => "s"}), []}, state}

    defp respond(%{path: "/goapi/v5/mcp_server/oauth/device_code"}, state) do
      n = state.codes + 1
      code = "dc-#{n}"

      body = %{
        "device_code" => code,
        "user_code" => "UC-#{n}",
        "verification_uri" => state.base <> "/b/auth/mcp",
        "verification_uri_complete" => state.base <> "/b/auth/mcp?mode=device&user_code=UC-#{n}",
        "expires_in" => state.expires_in,
        "interval" => 5
      }

      {{200, wrap(state, body), []},
       %{state | codes: n, devices: Map.put(state.devices, code, :pending)}}
    end

    defp respond(%{path: "/mcp_server/oauth/token", form: form}, state) do
      code = form["device_code"]

      case state.devices[code] do
        {:granted, token} ->
          body = %{
            "access_token" => token,
            "refresh_token" => "refresh-" <> token,
            "token_type" => "Bearer",
            "expires_in" => 7200
          }

          {{200, wrap(state, body), []},
           %{
             state
             | tokens: MapSet.put(state.tokens, token),
               devices: Map.put(state.devices, code, :used)
           }}

        :slow_down ->
          {{400, %{"error" => "slow_down"}, []}, put_in(state.devices[code], :pending)}

        :denied ->
          {{400, %{"error" => "access_denied"}, []}, state}

        _pending ->
          {{400, %{"error" => "authorization_pending"}, []}, state}
      end
    end

    defp respond(
           %{path: "/mcp_server/v1", body: %{"method" => "tools/call"} = rpc} = request,
           state
         ) do
      token =
        case request.authorization do
          "Bearer " <> token -> token
          _ -> nil
        end

      if token && MapSet.member?(state.tokens, token) do
        {{200,
          %{
            "jsonrpc" => "2.0",
            "id" => rpc["id"],
            "result" => %{"content" => [%{"type" => "text", "text" => "brief for " <> token}]}
          }, []}, state}
      else
        challenge =
          "Bearer resource_metadata=\"#{state.base}/.well-known/oauth-protected-resource\""

        {{401, %{"error" => "unauthorized"}, [{"www-authenticate", challenge}]}, state}
      end
    end

    defp respond(%{path: "/mcp_server/v1", body: %{"method" => "initialize", "id" => id}}, state) do
      n = state.sessions + 1

      {{200,
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "Meego MCP Server", "version" => "1"}
          }
        }, [{"mcp-session-id", "session-#{n}"}]}, %{state | sessions: n}}
    end

    defp respond(%{path: "/mcp_server/v1", body: %{"method" => "tools/list", "id" => id}}, state) do
      {{200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools()}}, []}, state}
    end

    defp respond(%{path: "/mcp_server/v1"}, state), do: {{202, nil, []}, state}
    defp respond(_request, state), do: {{404, %{"error" => "not_found"}, []}, state}

    defp wrap(%{wrapped: true}, body), do: %{"code" => 0, "data" => body, "msg" => ""}
    defp wrap(_state, body), do: body

    # Two tools of the real list (feishu-project-tools.json), trimmed.
    defp tools do
      [
        %{
          "name" => "get_workitem_brief",
          "description" => "按ID/名称查询工作项概况。",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "project_key" => %{"type" => "string"},
              "work_item_id" => %{"type" => "string"}
            }
          },
          "annotations" => %{"destructiveHint" => true, "openWorldHint" => true}
        },
        %{
          "name" => "list_workitem_types",
          "description" => "获取空间下的所有工作项类型列表",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"project_key" => %{"type" => "string"}}
          },
          "annotations" => %{"destructiveHint" => true, "openWorldHint" => true}
        }
      ]
    end
  end

  defmodule Plug do
    @moduledoc false
    import Elixir.Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      {body, form} =
        case get_req_header(conn, "content-type") do
          ["application/x-www-form-urlencoded" <> _] -> {nil, URI.decode_query(raw)}
          _ -> {(raw != "" && Jason.decode!(raw)) || nil, %{}}
        end

      {status, reply, headers} =
        Server.handle(%{
          path: conn.request_path,
          body: body,
          form: form,
          authorization: conn |> get_req_header("authorization") |> List.first(),
          session: conn |> get_req_header("mcp-session-id") |> List.first()
        })

      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn ->
          put_resp_header(conn, name, value)
        end)

      if is_nil(reply),
        do: send_resp(conn, status, ""),
        else:
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(reply))
    end
  end

  setup_all do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    billing = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    keys = [
      {:salix_store, :s3_backend},
      {:salix_mcp, :allow_private_http_targets},
      {:salix_mcp, :remote_target_overrides}
    ]

    previous = for {app, key} <- keys, do: {app, key, SystemsRuntime.get_env(app, key)}

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing)

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    {:ok, _seeded} = SalixMCP.Builtins.seed_builtin_definitions()

    start_supervised!({Server, SystemsRuntime.Proc.self()})

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: Plug, port: port} end)

    base = "http://127.0.0.1:#{port}"
    :ok = Server.set(:base, base)

    SystemsRuntime.put_env(:salix_mcp, :allow_private_http_targets, true)

    SystemsRuntime.put_env(:salix_mcp, :remote_target_overrides, %{
      "remote:feishu-project" => base <> "/mcp_server/v1",
      "remote:meegle" => base <> "/mcp_server/v1"
    })

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "project-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user, %{"name" => "Project Test"})

    %{user: user, workspace: workspace, base: base}
  end

  test "enabling either plugin gives a running binding with the server's tools and no sign-in",
       c do
    # Comma installs through its Plugins page; Comma for Teams enables the Group's plugin.
    assert {:ok, %{"plugin" => %{"installed" => true}, "authorization" => nil}} =
             CommaWeb.PluginConnections.install(c.user, %{}, c.workspace["id"], "feishu-project")

    assert {:ok, _enabled} = Plugins.enable_group(tenant(c), group(c), "meegle")

    for plugin <- ["feishu-project", "meegle"] do
      assert {:ok, binding} = SalixMCP.Store.find_binding_by_alias(tenant(c), group(c), plugin)
      assert get_in(binding, ["connection", "status"]) == "running"

      assert Enum.map(get_in(binding, ["connection", "discovered", "tools"]), & &1["name"]) ==
               ["get_workitem_brief", "list_workitem_types"]

      assert {:ok, definitions} = Plugins.list_definitions(tenant(c), group(c))
      definition = Enum.find(definitions, &(&1["plugin_id"] == plugin))

      assert [%{"state" => "connected"}] = definition["setup_status"]["connections"]
      assert [%{"state" => "running"}] = definition["setup_status"]["mcps"]
    end

    assert OAuthBindings.list_records(group(c)) == []
    refute Enum.any?(Server.requests(), &(&1.path =~ "oauth"))
  end

  test "a person signs in with the link, the waiting call ends, and their next call carries their token",
       c do
    :ok = Server.set(:wrapped, true)
    enable!(c, "feishu-project")
    alice = person(c.user["id"])

    assert {content, events} = call(c, alice, "call-1")
    pending = Jason.decode!(content)
    assert pending["status"] == "sign_in_required"
    assert pending["link_url"] == c.base <> "/b/auth/mcp?mode=device&user_code=UC-1"
    assert pending["instructions"] =~ "Post link_url"

    assert [%{"type" => "async_tool_call_started", "completion_mode" => "external_callback"} | _] =
             events

    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    assert request["request_type"] == "account_link"

    # Asked again while it waits: the same link, no second device code.
    assert {again, _events} = call(c, alice, "call-2")
    assert Jason.decode!(again)["link_url"] == pending["link_url"]
    assert Enum.count(Server.requests(), &(&1.path =~ "device_code")) == 1

    :ok = Server.device("dc-1", {:granted, "token-alice"})
    ended = settle_until(fn -> finished(c, request["request_id"]) end)
    assert ended["status"] == "completed"
    assert ended["response_payload"] == %{"status" => "signed_in"}

    assert "brief for token-alice" == call(c, alice, "call-3")
    assert [%{authorization: "Bearer token-alice"}] = tool_calls()
  end

  test "two people: each call carries its own token, and one signing in signs only them in", c do
    :ok = Server.set(:wrapped, false)
    enable!(c, "meegle")
    alice = person(c.user["id"])

    bob = %{
      "provider" => "slack",
      "principal_ref" => %{"connect_id" => "connect-1", "subject_id" => "U-BOB"}
    }

    {_content, _events} = call(c, alice, "alice-1", "meegle")
    {:ok, [alice_request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    :ok = Server.device("dc-1", {:granted, "token-alice"})
    settle_until(fn -> finished(c, alice_request["request_id"]) end)

    # Alice is signed in; Bob still gets his own link.
    assert {content, _events} = call(c, bob, "bob-1", "meegle")
    assert Jason.decode!(content)["link_url"] =~ "UC-2"

    {:ok, [bob_request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    :ok = Server.device("dc-2", {:granted, "token-bob"})
    settle_until(fn -> finished(c, bob_request["request_id"]) end)

    assert "brief for token-alice" == call(c, alice, "alice-2", "meegle")
    assert "brief for token-bob" == call(c, bob, "bob-2", "meegle")

    assert [alice_call, bob_call] = tool_calls()
    assert alice_call.authorization == "Bearer token-alice"
    assert bob_call.authorization == "Bearer token-bob"
    assert alice_call.session != bob_call.session

    # The server refuses Alice's token: Alice gets a new link, Bob goes on.
    :ok = Server.revoke("token-alice")
    assert {content, _events} = call(c, alice, "alice-3", "meegle")
    assert Jason.decode!(content)["status"] == "sign_in_required"
    assert "brief for token-bob" == call(c, bob, "bob-3", "meegle")
  end

  test "a turn with no person is refused and asks the server for nothing", c do
    enable!(c, "feishu-project")
    before = Server.requests()

    for origin <- [
          %{"provider" => "schedule"},
          %{"provider" => "loop"},
          %{"provider" => "internal"}
        ] do
      assert_raise RuntimeError, ~r/runs only as the person who asked/, fn ->
        call(c, origin, "unattended")
      end
    end

    assert Server.requests() == before
    assert {:ok, []} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
  end

  test "an unused link ends the call as expired; a refusal ends it as denied", c do
    :ok = Server.set(:expires_in, 12)
    enable!(c, "feishu-project")
    alice = person(c.user["id"])

    {_content, _events} = call(c, alice, "expire-1")
    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    :ok = Server.device("dc-1", :slow_down)
    expired = settle_until(fn -> finished(c, request["request_id"]) end)
    assert expired["status"] == "expired"
    assert expired["result"]["error_class"] == "sign_in_expired"
    # One poll at 5 s; slowed down by 5 s, the next would come after the expiry at 12 s.
    assert Enum.count(Server.requests(), &(&1.path =~ "oauth/token")) == 1

    {_content, _events} = call(c, alice, "deny-1")
    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    :ok = Server.device("dc-2", :denied)
    denied = settle_until(fn -> finished(c, request["request_id"]) end)
    assert denied["status"] == "failed"
    assert denied["result"]["error_class"] == "sign_in_denied"
    assert OAuthBindings.list_records(group(c)) == []
  end

  test "removing the plugin removes every person's sign-in", c do
    assert {:ok, _installed} =
             CommaWeb.PluginConnections.install(c.user, %{}, c.workspace["id"], "feishu-project")

    alice = person(c.user["id"])

    {_content, _events} = call(c, alice, "remove-1")
    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    :ok = Server.device("dc-1", {:granted, "token-alice"})
    settle_until(fn -> finished(c, request["request_id"]) end)

    assert [sign_in] = OAuthBindings.list_records(group(c))
    assert {:ok, _connection} = SalixStore.OAuth.get(sign_in["connection_id"])

    assert {:ok, %{"installed" => false}} =
             CommaWeb.PluginConnections.uninstall(
               c.user,
               %{},
               c.workspace["id"],
               "feishu-project"
             )

    assert OAuthBindings.list_records(group(c)) == []
    assert {:error, :not_found} = SalixStore.OAuth.get(sign_in["connection_id"])

    assert {:error, :not_found} =
             SalixMCP.Store.find_binding_by_alias(tenant(c), group(c), "feishu-project")

    # Comma for Teams disconnects the Group's connection the same way.
    enable!(c, "meegle")
    assert {:ok, _binding} = SalixMCP.Store.find_binding_by_alias(tenant(c), group(c), "meegle")

    assert :ok =
             Plugins.disconnect_group_credentials(
               tenant(c),
               group(c),
               "meegle",
               "meegle-requester"
             )

    assert {:error, :not_found} =
             SalixMCP.Store.find_binding_by_alias(tenant(c), group(c), "meegle")
  end

  defp enable!(c, plugin) do
    assert {:ok, _enabled} = Plugins.enable_group(tenant(c), group(c), plugin)
  end

  defp call(c, origin, tool_call_id, plugin \\ "feishu-project") do
    MCP.call_dynamic_operation(
      "mcp.#{plugin}.#{@tool}",
      %{"project_key" => "demo", "work_item_id" => "1"},
      %{
        agent_id: c.workspace["router_agent_id"],
        session_id: session_id(tool_call_id),
        tool_call_id: tool_call_id,
        group_id: group(c),
        tenant_id: tenant(c),
        trusted_origin: origin
      }
    )
  end

  # One Session per call id.
  defp session_id(tool_call_id) do
    Process.get({:session, tool_call_id}) ||
      tap(Ids.new_session_id(), &Process.put({:session, tool_call_id}, &1))
  end

  defp person(user_id),
    do: %{
      "provider" => "internal",
      "principal_ref" => %{"namespace" => "comma_user", "subject_id" => user_id}
    }

  defp tool_calls do
    for %{path: "/mcp_server/v1", body: %{"method" => "tools/call"}} = request <-
          Server.requests(),
        do: request
  end

  defp finished(c, request_id) do
    case CapabilityRequests.get(group(c), request_id, tenant(c)) do
      {:ok, %{"status" => "pending"}} -> nil
      {:ok, request} -> request
    end
  end

  defp group(c), do: c.workspace["default_group_id"]
  defp tenant(c), do: c.workspace["salix_tenant_id"]
end
