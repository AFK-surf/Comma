defmodule CommaWeb.MacAppsPluginTest do
  @moduledoc """
  The Mac apps plugin end to end through Salix: the desktop app installs it with
  its own device, Salix reaches the app's MCP server only through that device's
  Connector (`client_mcp`), and the tools run only for the member whose Mac it is.
  The device's Connector is a fake socket owner that answers like the station and
  Main would.
  """
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias CommaWeb.PluginConnections
  alias SalixEnv.{Bridge, Registry}
  alias SalixStore.Ids

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "mac-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()
    %{user: user, workspace: workspace}
  end

  test "installs on the member's own Mac and runs the tools only for that member", %{
    user: user,
    workspace: w
  } do
    device_id = connect_mac!(w, user["id"])

    assert {:ok, %{"plugin" => %{"installed" => true}}} =
             PluginConnections.install(user, %{}, w["id"], "mac-apps", %{"device_id" => device_id})

    [binding] = SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])
    assert binding["alias"] == "mac"
    assert binding["placement"] == "device"
    assert binding["owner_user_id"] == user["id"]
    assert get_in(binding, ["connection", "status"]) == "running"

    assert get_in(binding, ["connection", "discovered", "tools"]) |> Enum.map(& &1["name"]) ==
             ["calendar_list_events"]

    # Discovery went through client_mcp to the app's server, never over HTTP.
    assert_received {:client_mcp, "mac-apps", %{"method" => "initialize"}}
    assert_received {:client_mcp, "mac-apps", %{"method" => "tools/list"}}

    w = CommaWeb.TestWorkers.with_default_worker!(w)
    agent_id = w["default_worker_agent_id"]

    call = fn ctx ->
      SalixMCP.Provider.call_tool(agent_id, "mac", "calendar_list_events", %{}, ctx)
    end

    assert {:ok, %{"status" => "completed", "content" => content}} = call.(as(user["id"]))
    assert content =~ "calendar_list_events"
    assert_received {:client_mcp, "mac-apps", %{"method" => "tools/call"}}

    # Another member's turn, or work no person asked for, never reaches this Mac.
    assert {:error, refused} = call.(as("another-member"))
    assert refused =~ "another member"
    assert {:error, _} = call.(%{})
    refute_received {:client_mcp, _, %{"method" => "tools/call"}}

    # A tool of an app the user turned off is not listed; the Agent is told to ask
    # the user, not to reconnect.
    assert {:error, off} =
             SalixMCP.Provider.call_tool(agent_id, "mac", "notes_search", %{}, as(user["id"]))

    assert off =~ "turned off"
    refute_received {:client_mcp, _, %{"method" => "tools/call"}}

    assert {:ok, _} = PluginConnections.uninstall(user, %{}, w["id"], "mac-apps")
    assert SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"]) == []
  end

  test "Comma offers the Mac apps only to a Mac app that installs plugins on its device", %{
    user: user,
    workspace: w
  } do
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    path = "/v1/comma/workspaces/#{w["id"]}/plugins"
    capable = {"x-comma-client-capabilities", "device-plugins"}

    listed = fn headers ->
      %{status: 200, resp_body: body} = request(session["token"], :get, path, headers)
      body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["id"])
    end

    # An app from before the headers (the desktop 1.0.7) sends neither.
    assert "github" in listed.([])
    refute "mac-apps" in listed.([])
    refute "mac-apps" in listed.([{"x-comma-client", "electron/macos/1.0.7"}])
    refute "mac-apps" in listed.([{"x-comma-client", "electron/windows/1.0.8"}, capable])
    refute "mac-apps" in listed.([{"x-comma-client", "web/unknown"}, capable])
    assert "mac-apps" in listed.([{"x-comma-client", "electron/macos/1.0.8"}, capable])

    # Nor can an app it is not offered to install it.
    assert %{status: 404} =
             request(session["token"], :post, path <> "/mac-apps/install", [], %{
               "contract" => "unified_v1"
             })
  end

  test "only the Mac's owner runs its tools, whatever a binding to it says", %{
    user: user,
    workspace: w
  } do
    device_id = connect_mac!(w, user["id"])

    assert {:ok, _} =
             PluginConnections.install(user, %{}, w["id"], "mac-apps", %{"device_id" => device_id})

    w = CommaWeb.TestWorkers.with_default_worker!(w)
    agent_id = w["default_worker_agent_id"]
    runtime_id = SalixStore.RuntimeIds.device_runtime_id(device_id, "connector", "default")

    [plugin_binding] =
      SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])

    # An Agent cannot connect the Mac apps itself, nor move or relabel their binding.
    assert {:error, {:bad_request, _}} =
             SalixMCP.Provider.create_binding(agent_id, %{
               "mcp_id" => SalixMCP.Builtins.mac_apps_mcp_id(),
               "alias" => "mine",
               "placement" => "device",
               "device_runtime_id" => runtime_id
             })

    assert {:error, {:bad_request, _}} =
             SalixMCP.Provider.update_binding(agent_id, plugin_binding["binding_id"], %{
               "owner_user_id" => "another-member"
             })

    # A binding to this Mac that names another member as its owner still runs
    # only for the member whose Mac it is.
    {:ok, _} =
      SalixMCP.Gateway.create_binding(w["salix_tenant_id"], w["default_group_id"], %{
        "mcp_id" => SalixMCP.Builtins.mac_apps_mcp_id(),
        "alias" => "elsewhere",
        "target_ref" => "client:mac-apps",
        "placement" => "device",
        "device_runtime_id" => runtime_id,
        "owner_user_id" => "another-member"
      })

    call = fn ctx ->
      SalixMCP.Provider.call_tool(agent_id, "elsewhere", "calendar_list_events", %{}, ctx)
    end

    assert {:error, refused} = call.(as("another-member"))
    assert refused =~ "another member"
    refute_received {:client_mcp, _, %{"method" => "tools/call"}}

    assert {:ok, %{"status" => "completed"}} = call.(as(user["id"]))
    assert_received {:client_mcp, "mac-apps", %{"method" => "tools/call"}}
  end

  test "an Agent cannot reach a Mac through a definition of its own", %{
    user: user,
    workspace: w
  } do
    connect_mac!(w, user["id"])
    w = CommaWeb.TestWorkers.with_default_worker!(w)
    agent_id = w["default_worker_agent_id"]

    # The transport that hands messages to the desktop app is Comma's own.
    assert {:error, {:bad_request, refused}} =
             SalixMCP.Provider.create_definition(agent_id, %{
               "name" => "Mine",
               "server_metadata" => %{
                 "name" => "Mine",
                 "remotes" => [
                   %{
                     "target_ref" => "remote:mine",
                     "transport" => "comma-client",
                     "url" => "comma-client://mac-apps"
                   }
                 ]
               }
             })

    assert refused =~ "comma-client"
    refute_received {:client_mcp, _, _}
  end

  test "a schedule or a Loop runs no tool on the Mac, even one its owner created", %{
    user: user,
    workspace: w
  } do
    device_id = connect_mac!(w, user["id"])

    assert {:ok, _} =
             PluginConnections.install(user, %{}, w["id"], "mac-apps", %{"device_id" => device_id})

    w = CommaWeb.TestWorkers.with_default_worker!(w)
    agent_id = w["default_worker_agent_id"]
    {:ok, principal} = SalixIFC.Codec.encode_principal({:comma_user, user["id"]})

    for provider <- ["schedule", "loop"] do
      ctx = %{trusted_origin: %{"provider" => provider, "ifc" => %{"principal" => principal}}}

      assert {:error, refused} =
               SalixMCP.Provider.call_tool(agent_id, "mac", "calendar_list_events", %{}, ctx)

      assert refused =~ "no person asked for"
    end

    refute_received {:client_mcp, _, %{"method" => "tools/call"}}
  end

  test "installs only from a Mac the member owns", %{user: user, workspace: w} do
    assert {:error, {:bad_request, _}} = PluginConnections.install(user, %{}, w["id"], "mac-apps")

    someone_elses = connect_mac!(w, "another-member")

    assert {:error, :forbidden} =
             PluginConnections.install(user, %{}, w["id"], "mac-apps", %{
               "device_id" => someone_elses
             })

    assert SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"]) == []
  end

  # A request to the Comma API with the session's bearer and `headers`.
  defp request(token, method, path, headers, body \\ nil) do
    conn = if body, do: conn(method, path, Jason.encode!(body)), else: conn(method, path)

    [{"authorization", "Bearer " <> token}, {"content-type", "application/json"} | headers]
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  # The internal chat delivery of a message the member wrote.
  defp as(user_id), do: %{trusted_origin: %{"principal_ref" => %{"subject_id" => user_id}}}

  # A desktop's Connector in the workspace, owned by `owner_user_id`, whose app
  # answers the Mac apps MCP; each message is reported to the test.
  defp connect_mac!(workspace, owner_user_id) do
    transport_id = "mac-transport-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    device_id = Ids.new_device_id()

    {:ok, ^transport_id, _device} =
      Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => workspace["salix_tenant_id"],
          "group_id" => workspace["default_group_id"],
          "device_id" => device_id,
          "connector_id" => "connector-#{SystemsRuntime.Proc.unique_integer([:positive])}",
          "owner_user_id" => owner_user_id,
          "capabilities" => %{"client_mcp" => ["mac-apps"]}
        },
        transport_id: transport_id
      )

    test = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn_link(fn ->
      Bridge.register_owner(transport_id)
      SystemsRuntime.Proc.send(test, {:mac_ready, transport_id})
      answer_client_mcp(test)
    end)

    SystemsRuntime.Proc.receive do
      {:mac_ready, ^transport_id} -> device_id
    end
  end

  defp answer_client_mcp(test) do
    SystemsRuntime.Proc.receive do
      {:env_rpc, ref, from, %{"method" => "client_mcp", "params" => params}} ->
        message = params["message"]
        SystemsRuntime.Proc.send(test, {:client_mcp, params["server"], message})

        SystemsRuntime.Proc.send(
          from,
          {:env_rpc_reply, ref, {:ok, %{"message" => reply(message)}}}
        )

        answer_client_mcp(test)

      {:env_rpc, ref, from, _other} ->
        SystemsRuntime.Proc.send(from, {:env_rpc_reply, ref, {:error, "unexpected method"}})
        answer_client_mcp(test)

      {:env_owner_takeover, _, _} ->
        :ok
    end
  end

  defp reply(%{"id" => id, "method" => method} = message) do
    result =
      case method do
        "initialize" ->
          %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{"listChanged" => false}},
            "serverInfo" => %{"name" => "comma-mac-apps", "version" => "1.0.0"}
          }

        "tools/list" ->
          %{
            "tools" => [
              %{
                "name" => "calendar_list_events",
                "inputSchema" => %{"type" => "object"},
                "annotations" => %{"readOnlyHint" => true}
              }
            ]
          }

        "tools/call" ->
          %{"content" => [%{"type" => "text", "text" => "ran " <> message["params"]["name"]}]}
      end

    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  # A notification needs no answer.
  defp reply(_notification), do: nil
end
