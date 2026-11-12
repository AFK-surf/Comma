defmodule CommaWeb.BlenderPluginTest do
  @moduledoc """
  The Blender plugin through Salix: the desktop app installs it with its own
  device, Salix reaches the app's Blender MCP only through that device's
  Connector (`client_mcp`), and a render's end is waited for inside one tool
  call. The device's Connector is a fake socket owner that answers like the
  station and Main would; Main holds a `job` wait 20 s while the render runs.
  """
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias CommaWeb.PluginConnections
  alias SalixEnv.{Bridge, Registry}
  alias SalixStore.Ids

  # A real render (Blender 4.2, Cycles), made small: the picture a `job` wait gives.
  @render File.read!(Path.expand("fixtures/blender-render.jpg", __DIR__))
  @jpeg Base.encode64(@render)

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "blender-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()
    %{user: user, workspace: workspace}
  end

  test "a render's wait holds one tool call and the model gets the picture", %{
    user: user,
    workspace: w
  } do
    agent_id = install!(user, w, waits_before_done: 2)
    ctx = Map.merge(as(user["id"]), %{agent_id: agent_id, group_id: w["default_group_id"]})

    # The Agent's own tool, as a round dispatches it.
    assert {content, [event]} =
             SalixAgent.Tools.MCP.call_dynamic_operation(
               "mcp.blender.job",
               %{"op" => "wait", "job_id" => "job-1"},
               ctx
             )

    # Three holds of the app, one tool call: the model was not asked in between.
    for _ <- 1..3, do: assert_received({:client_mcp, "blender", %{"method" => "tools/call"}})
    refute_received {:client_mcp, _, %{"method" => "tools/call"}}

    assert [%{"type" => "text", "text" => text}, %{"type" => "image"} = image] =
             Jason.decode!(content)

    assert %{"state" => "done"} = Jason.decode!(text)
    assert %{"file_ref" => %{"environment_id" => "vfs", "path" => "/artifacts/mcp-" <> _}} = image
    refute content =~ @jpeg

    {:ok, _} = SalixAgent.AgentWorkspace.seed_operation(agent_id, "render", %{}, [event])

    # The next model request carries the render as an image.
    session =
      SalixVerifiedKernel.Session.new(agent_id, "render")
      |> SalixVerifiedKernel.Session.export()
      |> Map.put(:messages, [
        %{id: 1, role: "user", content: "Render the scene"},
        %{
          id: 2,
          role: "assistant",
          content: "",
          tool_calls: [%{"id" => "wait", "name" => "mcp.blender.job", "args" => %{}}]
        },
        %{
          id: 3,
          role: "tool",
          tool_name: "mcp.blender.job",
          tool_call_id: "wait",
          content: content
        }
      ])
      |> SalixVerifiedKernel.Session.open()

    {protocol, cfg} =
      SalixLlm.Provider.request_config(%{"protocol" => "chat", "model" => "image-model"})

    assert {:ok, body, _} =
             SalixVerifiedKernel.Session.query(
               session,
               :round_request,
               %{
                 "role" => "worker",
                 "canonical_router" => false,
                 "protocol" => protocol,
                 "cfg" => cfg,
                 "tools" => [],
                 "mode" => "complete"
               },
               SalixAgent.ImageRefs.reader(%{agent_id: agent_id, model_supports_images: true})
             )

    assert body =~ "data:image/jpeg;base64,"
    assert body =~ String.slice(@jpeg, 0, 64)
  end

  test "a wait the app answered at once is not asked again", %{user: user, workspace: w} do
    agent_id = install!(user, w, waits_before_done: 2, hold_ms: 0)

    assert {:ok, %{"raw" => %{"structuredContent" => %{"state" => "running"}}}} =
             SalixMCP.Provider.call_tool(
               agent_id,
               "blender",
               "job",
               %{"op" => "wait", "job_id" => "job-1"},
               as(user["id"])
             )

    assert_received {:client_mcp, "blender", %{"method" => "tools/call"}}
    refute_received {:client_mcp, _, %{"method" => "tools/call"}}
  end

  test "Comma offers Blender to a desktop app on macOS or Windows that installs plugins", %{
    user: user,
    workspace: w
  } do
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    path = "/v1/comma/workspaces/#{w["id"]}/plugins"
    capable = {"x-comma-client-capabilities", "device-plugins,blender-plugin"}

    listed = fn headers ->
      %{status: 200, resp_body: body} = request(session["token"], :get, path, headers)
      body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["id"])
    end

    refute "blender" in listed.([])
    refute "blender" in listed.([{"x-comma-client", "web/unknown"}, capable])
    refute "blender" in listed.([{"x-comma-client", "electron/macos/1.0.8"}])

    # A desktop app from before Blender installs plugins on its device, but not this one.
    refute "blender" in listed.([
             {"x-comma-client", "electron/macos/1.0.8"},
             {"x-comma-client-capabilities", "device-plugins"}
           ])

    assert "blender" in listed.([{"x-comma-client", "electron/macos/1.0.8"}, capable])
    assert "blender" in listed.([{"x-comma-client", "electron/windows/1.0.8"}, capable])
  end

  defp install!(user, w, behavior) do
    device_id = connect_desktop!(w, user["id"], behavior)

    assert {:ok, %{"plugin" => %{"installed" => true}}} =
             PluginConnections.install(user, %{}, w["id"], "blender", %{"device_id" => device_id})

    [binding] = SalixMCP.Store.list_group_bindings(w["salix_tenant_id"], w["default_group_id"])
    assert binding["alias"] == "blender"
    assert get_in(binding, ["connection", "status"]) == "running"
    assert_received {:client_mcp, "blender", %{"method" => "initialize"}}
    assert_received {:client_mcp, "blender", %{"method" => "tools/list"}}

    CommaWeb.TestWorkers.with_default_worker!(w)["default_worker_agent_id"]
  end

  defp request(token, method, path, headers) do
    [{"authorization", "Bearer " <> token}, {"content-type", "application/json"} | headers]
    |> Enum.reduce(conn(method, path), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp as(user_id), do: %{trusted_origin: %{"principal_ref" => %{"subject_id" => user_id}}}

  # A desktop's Connector whose app serves the Blender MCP; each message is
  # reported to the test. A `job` wait answers `running` the first
  # `waits_before_done` times, each after holding `hold_ms`, then `done`.
  defp connect_desktop!(workspace, owner_user_id, behavior) do
    transport_id = "blender-transport-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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
          "capabilities" => %{"client_mcp" => ["mac-apps", "blender"]}
        },
        transport_id: transport_id
      )

    test = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn_link(fn ->
      Bridge.register_owner(transport_id)
      SystemsRuntime.Proc.send(test, {:desktop_ready, transport_id})

      answer(test, %{
        running: Keyword.fetch!(behavior, :waits_before_done),
        hold_ms: Keyword.get(behavior, :hold_ms, 20_000)
      })
    end)

    SystemsRuntime.Proc.receive do
      {:desktop_ready, ^transport_id} -> device_id
    end
  end

  defp answer(test, state) do
    SystemsRuntime.Proc.receive do
      {:env_rpc, ref, from, %{"method" => "client_mcp", "params" => params}} ->
        message = params["message"]
        SystemsRuntime.Proc.send(test, {:client_mcp, params["server"], message})
        {reply, state} = reply(message, state)
        SystemsRuntime.Proc.send(from, {:env_rpc_reply, ref, {:ok, %{"message" => reply}}})
        answer(test, state)

      {:env_rpc, ref, from, _other} ->
        SystemsRuntime.Proc.send(from, {:env_rpc_reply, ref, {:error, "unexpected method"}})
        answer(test, state)

      {:env_owner_takeover, _, _} ->
        :ok
    end
  end

  defp reply(%{"id" => id, "method" => "initialize"}, state),
    do:
      {rpc(id, %{
         "protocolVersion" => "2025-06-18",
         "capabilities" => %{"tools" => %{"listChanged" => false}},
         "serverInfo" => %{"name" => "comma-blender", "version" => "1"}
       }), state}

  defp reply(%{"id" => id, "method" => "tools/list"}, state),
    do:
      {rpc(id, %{
         "tools" => [
           %{"name" => "job", "inputSchema" => %{"type" => "object"}},
           %{"name" => "render", "inputSchema" => %{"type" => "object"}}
         ]
       }), state}

  defp reply(%{"id" => id, "method" => "tools/call"}, %{running: running} = state)
       when running > 0 do
    if state.hold_ms > 0, do: SystemsClock.sleep(state.hold_ms)
    job = %{"job_id" => "job-1", "state" => "running"}

    {rpc(id, %{
       "content" => [%{"type" => "text", "text" => Jason.encode!(job)}],
       "structuredContent" => job
     }), %{state | running: running - 1}}
  end

  defp reply(%{"id" => id, "method" => "tools/call"}, state) do
    job = %{"job_id" => "job-1", "state" => "done"}

    {rpc(id, %{
       "content" => [
         %{"type" => "text", "text" => Jason.encode!(job)},
         %{"type" => "image", "data" => @jpeg, "mimeType" => "image/jpeg"}
       ],
       "structuredContent" => job
     }), state}
  end

  defp reply(_notification, state), do: {nil, state}

  defp rpc(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end
