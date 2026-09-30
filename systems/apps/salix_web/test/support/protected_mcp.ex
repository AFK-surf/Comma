defmodule SalixWeb.TestSupport.ProtectedMCP do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def base_url(pid), do: GenServer.call(pid, :base_url)
  def calls(pid), do: GenServer.call(pid, :calls)
  def release(pid), do: send(pid, :release_paused_call)

  @impl true
  def init(opts) do
    {:ok, bandit} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, self()},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    {:ok,
     %{
       port: port,
       expected_authorization: Keyword.fetch!(opts, :expected_authorization),
       pause_authorized_method: Keyword.get(opts, :pause_authorized_method),
       pause_notify: Keyword.get(opts, :pause_notify),
       calls: []
     }}
  end

  @impl true
  def handle_call(:base_url, _from, state),
    do: {:reply, "http://127.0.0.1:#{state.port}", state}

  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:authorize, authorization, method}, _from, state) do
    authorized = authorization == state.expected_authorization

    state =
      if authorized and method == state.pause_authorized_method do
        send(state.pause_notify, {:protected_mcp_paused, self(), method})

        receive do
          :release_paused_call -> %{state | pause_authorized_method: nil}
        end
      else
        state
      end

    {:reply, authorized,
     %{state | calls: [%{method: method, authorized: authorized} | state.calls]}}
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      authorization = conn |> get_req_header("authorization") |> List.first()

      if GenServer.call(owner, {:authorize, authorization, request["method"]}) do
        respond(conn, request)
      else
        send_resp(conn, 401, "authorization required")
      end
    end

    defp respond(conn, %{"id" => id, "method" => "initialize"}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "Protected Test MCP", "version" => "1.0.0"}
        }
      })
    end

    defp respond(conn, %{"id" => id, "method" => "tools/list"}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "tools" => [
            %{
              "name" => "echo",
              "description" => "Echo a marker.",
              "inputSchema" => %{
                "type" => "object",
                "properties" => %{"marker" => %{"type" => "string"}},
                "required" => ["marker"]
              }
            }
          ]
        }
      })
    end

    defp respond(conn, %{"id" => id, "method" => "tools/call", "params" => params}) do
      marker = get_in(params, ["arguments", "marker"])

      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "content" => [%{"type" => "text", "text" => "MATERIALIZATION_E2E #{marker}"}]
        }
      })
    end

    defp respond(conn, %{"method" => _method}), do: send_resp(conn, 202, "")

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
