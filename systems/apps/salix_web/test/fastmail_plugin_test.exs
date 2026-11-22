defmodule Salix.Control.FastmailPluginTest do
  use SystemsClock.Case, async: false

  alias Salix.Control.{Groups, Plugins, Tenants}
  alias SalixMCP.{Config, Gateway}
  alias SalixMCP.Store, as: MCPStore

  # These are fixture tools, not a claim about Fastmail's live tool schema.
  defmodule MockMCP do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def url(pid), do: GenServer.call(pid, :url)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(opts) do
      {:ok, listener} =
        Bandit.start_link(
          plug: {__MODULE__.Plug, SystemsRuntime.Proc.self()},
          port: 0,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      {:ok, %{port: port, mode: Keyword.get(opts, :mode, :ok), calls: []}}
    end

    @impl true
    def handle_call(:url, _from, state),
      do: {:reply, "http://127.0.0.1:#{state.port}/mcp", state}

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:request, authorization, method}, _from, state) do
      authorized = authorization == "Bearer fastmail-fixture-token"
      outcome = if authorized, do: state.mode, else: :unauthorized
      call = %{method: method, authorized: authorized}
      {:reply, outcome, %{state | calls: [call | state.calls]}}
    end

    defmodule Plug do
      @behaviour Elixir.Plug
      import Elixir.Plug.Conn

      @impl true
      def init(owner), do: owner

      @impl true
      def call(conn, owner) do
        {:ok, body, conn} = read_body(conn)
        request = Jason.decode!(body)
        authorization = conn |> get_req_header("authorization") |> List.first()

        case GenServer.call(owner, {:request, authorization, request["method"]}) do
          :ok -> respond(conn, request)
          :unauthorized -> send_resp(conn, 401, "authorization required")
          :rate_limited -> send_resp(conn, 429, "rate limited")
        end
      end

      defp respond(conn, %{"id" => id, "method" => "initialize"}) do
        json(conn, id, %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "Fixture MCP", "version" => "1"}
        })
      end

      defp respond(conn, %{"id" => id, "method" => "tools/list"}) do
        json(conn, id, %{
          "tools" => [
            %{
              "name" => "fixture_search",
              "description" => "Read a fixture message.",
              "inputSchema" => %{"type" => "object", "properties" => %{}},
              "annotations" => %{"readOnlyHint" => true}
            }
          ]
        })
      end

      defp respond(conn, %{"id" => id, "method" => "tools/call"}) do
        # A malicious/buggy remote response must not expose the stored token.
        json(conn, id, %{
          "content" => [%{"type" => "text", "text" => "Fixture mail fastmail-fixture-token"}]
        })
      end

      defp respond(conn, %{"method" => _}), do: send_resp(conn, 202, "")

      defp json(conn, id, result) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
      end
    end
  end

  setup do
    keys = [:s3_backend]
    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:salix_store, &1)})
    previous_private = SystemsRuntime.get_env(:salix_mcp, :allow_private_http_targets)
    previous_overrides = SystemsRuntime.get_env(:salix_mcp, :remote_target_overrides)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_mcp, :allow_private_http_targets, true)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(:salix_store, key, value) end)
      restore(:salix_mcp, :allow_private_http_targets, previous_private)
      restore(:salix_mcp, :remote_target_overrides, previous_overrides)
    end)

    assert {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()
    {:ok, tenant} = Tenants.create(%{"name" => "Fastmail test"})
    {:ok, group} = Groups.create(%{"name" => "Mail"}, tenant["tenant_id"])
    %{tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "install discovers tools with the supplied bearer token and keeps it private", context do
    mock = mock_server()
    refute enabled?(context)

    assert :ok = configure(context, "fastmail-fixture-token")
    [binding] = fastmail_bindings(context)

    assert {:ok, stored, definition, connection} =
             MCPStore.get_binding_with_definition(
               context.tenant_id,
               context.group_id,
               binding["binding_id"]
             )

    assert connection["status"] == "running"
    assert "fastmail-fixture-token" in Config.redaction_values(definition, stored)
    refute inspect(MCPStore.public_binding(stored)) =~ "fastmail-fixture-token"

    assert {:ok, result} =
             Gateway.call_tool(
               context.tenant_id,
               context.group_id,
               binding["binding_id"],
               "fixture_search",
               %{}
             )

    assert result["status"] == "completed"
    assert result["content"] =~ "Fixture mail"
    refute inspect(result) =~ "fastmail-fixture-token"
    assert Enum.all?(MockMCP.calls(mock), & &1.authorized)
    assert Enum.any?(MockMCP.calls(mock), &(&1.method == "tools/list"))
    assert Enum.any?(MockMCP.calls(mock), &(&1.method == "tools/call"))

    assert {:ok, _} = Plugins.enable_group(context.tenant_id, context.group_id, "fastmail")
    assert enabled?(context)
    assert {:ok, _} = Plugins.disable_group(context.tenant_id, context.group_id, "fastmail")
    refute enabled?(context)

    assert :ok =
             Plugins.disconnect_group_credentials(
               context.tenant_id,
               context.group_id,
               "fastmail",
               "fastmail-api-key"
             )

    assert fastmail_bindings(context) == []
  end

  test "blank, missing and wrong credential fields fail before any remote call", context do
    mock = mock_server()

    for values <- [%{}, %{"FASTMAIL_MCP_TOKEN" => " "}, %{"JMAP_TOKEN" => "wrong-kind"}] do
      assert {:error, {:bad_request, _}} =
               Plugins.configure_group_credentials(
                 context.tenant_id,
                 context.group_id,
                 "fastmail",
                 "fastmail-api-key",
                 values
               )
    end

    assert MockMCP.calls(mock) == []
    assert fastmail_bindings(context) == []
  end

  test "the server rejects an invalid or revoked token without enabling the plugin", context do
    mock = mock_server()
    assert {:error, :plugin_credential_rejected} = configure(context, "revoked-fixture-token")
    refute enabled?(context)
    assert Enum.any?(MockMCP.calls(mock), &(not &1.authorized))

    for binding <- fastmail_bindings(context) do
      refute inspect(MCPStore.public_binding_with_connection(binding)) =~ "revoked-fixture-token"
    end
  end

  test "rate limits are connection failures, not invalid credential claims", context do
    mock_server(mode: :rate_limited)
    assert {:error, :plugin_connection_unavailable} = configure(context, "fastmail-fixture-token")
    refute enabled?(context)
  end

  test "a group's stored token and enabled tools are not shared with another group", context do
    mock_server()
    assert :ok = configure(context, "fastmail-fixture-token")
    [binding] = fastmail_bindings(context)
    {:ok, other} = Groups.create(%{"name" => "Other mail"}, context.tenant_id)

    assert {:error, :not_found} =
             MCPStore.get_binding(context.tenant_id, other["group_id"], binding["binding_id"])

    assert MCPStore.list_group_bindings(context.tenant_id, other["group_id"]) == []
    refute enabled?(%{context | group_id: other["group_id"]})
  end

  defp mock_server(opts \\ []) do
    mock = start_supervised!({MockMCP, opts})
    SystemsRuntime.put_env(:salix_mcp, :remote_target_overrides, %{
      "remote:fastmail" => MockMCP.url(mock)
    })

    mock
  end

  defp configure(context, token) do
    Plugins.configure_group_credentials(
      context.tenant_id,
      context.group_id,
      "fastmail",
      "fastmail-api-key",
      %{"FASTMAIL_MCP_TOKEN" => token}
    )
  end

  defp fastmail_bindings(context) do
    MCPStore.list_group_bindings(context.tenant_id, context.group_id)
    |> Enum.filter(&(&1["alias"] == "fastmail"))
  end

  defp enabled?(context) do
    assert {:ok, projection} =
             Plugins.runtime_projection(%{
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id
             })

    "mcp.fastmail." in projection["allowed_tool_prefixes"]
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
