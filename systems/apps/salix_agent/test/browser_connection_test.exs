defmodule SalixAgent.BrowserConnectionTest do
  use SystemsClock.Case, async: true
  alias SalixAgent.Browser.Connection

  defmodule Socket do
    def init(owner), do: {:ok, owner}

    def handle_in({data, _}, owner) do
      SystemsRuntime.Proc.send(owner, {:command, SystemsRuntime.Proc.self(), Jason.decode!(data)})
      {:ok, owner}
    end

    def handle_info({:reply, value}, owner), do: {:push, {:text, Jason.encode!(value)}, owner}
    def handle_info(:disconnect, owner), do: {:stop, :normal, owner}
  end

  defmodule Endpoint do
    def init(owner), do: owner
    def call(conn, owner), do: WebSockAdapter.upgrade(conn, Socket, owner, [])
  end

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {Endpoint, SystemsRuntime.Proc.self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    conn =
      start_supervised!(
        {Connection, owner: SystemsRuntime.Proc.self(), url: "ws://127.0.0.1:#{port}/cdp"}
      )

    ready = SystemsRuntime.Task.async(fn -> Connection.command(conn, "Browser.getVersion") end)
    assert_receive {:command, socket, %{"id" => id, "method" => "Browser.getVersion"}}
    SystemsRuntime.Proc.send(socket, {:reply, %{"id" => id, "result" => %{}}})
    assert SystemsRuntime.Task.await(ready, :infinity) == {:ok, %{}}
    %{conn: conn}
  end

  test "correlates replies while keeping provider errors out of results", %{conn: conn} do
    first = SystemsRuntime.Task.async(fn -> Connection.command(conn, "Target.getTargets") end)
    assert_receive {:command, socket, %{"id" => first_id}}

    second =
      SystemsRuntime.Task.async(fn ->
        Connection.command(conn, "Page.navigate", %{url: "https://example.com"}, "tab")
      end)

    assert_receive {:command, ^socket, %{"id" => second_id, "sessionId" => "tab"}}

    SystemsRuntime.Proc.send(
      socket,
      {:reply, %{"id" => second_id, "error" => %{"message" => "wss://private?token=secret"}}}
    )

    SystemsRuntime.Proc.send(
      socket,
      {:reply, %{"id" => first_id, "result" => %{"targetInfos" => []}}}
    )

    assert SystemsRuntime.Task.await(second, :infinity) == {:error, "browser_operation_failed"}
    assert SystemsRuntime.Task.await(first, :infinity) == {:ok, %{"targetInfos" => []}}
  end

  test "disconnect settles a pending action as unknown without replay", %{conn: conn} do
    pending =
      SystemsRuntime.Task.async(fn ->
        Connection.command(conn, "Input.insertText", %{text: "once"}, "tab")
      end)

    assert_receive {:command, socket, %{"method" => "Input.insertText"}}
    monitor = SystemsRuntime.Proc.monitor(conn)
    SystemsRuntime.Proc.send(socket, :disconnect)
    assert SystemsRuntime.Task.await(pending, :infinity) == {:error, :browser_outcome_unknown}
    assert_receive {:DOWN, ^monitor, :process, ^conn, :normal}
    refute_receive {:command, _, _}, 100
  end
end
