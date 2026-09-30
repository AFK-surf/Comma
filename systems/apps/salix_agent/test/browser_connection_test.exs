defmodule SalixAgent.BrowserConnectionTest do
  use ExUnit.Case, async: true
  alias SalixAgent.Browser.Connection

  defmodule Socket do
    def init(owner), do: {:ok, owner}

    def handle_in({data, _}, owner) do
      send(owner, {:command, self(), Jason.decode!(data)})
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
        {Bandit, plug: {Endpoint, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    conn = start_supervised!({Connection, owner: self(), url: "ws://127.0.0.1:#{port}/cdp"})
    ready = Task.async(fn -> Connection.command(conn, "Browser.getVersion") end)
    assert_receive {:command, socket, %{"id" => id, "method" => "Browser.getVersion"}}, 2000
    send(socket, {:reply, %{"id" => id, "result" => %{}}})
    assert Task.await(ready) == {:ok, %{}}
    %{conn: conn}
  end

  test "correlates replies while keeping provider errors out of results", %{conn: conn} do
    first = Task.async(fn -> Connection.command(conn, "Target.getTargets") end)
    assert_receive {:command, socket, %{"id" => first_id}}, 2000

    second =
      Task.async(fn ->
        Connection.command(conn, "Page.navigate", %{url: "https://example.com"}, "tab")
      end)

    assert_receive {:command, ^socket, %{"id" => second_id, "sessionId" => "tab"}}, 2000

    send(
      socket,
      {:reply, %{"id" => second_id, "error" => %{"message" => "wss://private?token=secret"}}}
    )

    send(socket, {:reply, %{"id" => first_id, "result" => %{"targetInfos" => []}}})
    assert Task.await(second) == {:error, "browser_operation_failed"}
    assert Task.await(first) == {:ok, %{"targetInfos" => []}}
  end

  test "disconnect settles a pending action as unknown without replay", %{conn: conn} do
    pending =
      Task.async(fn -> Connection.command(conn, "Input.insertText", %{text: "once"}, "tab") end)

    assert_receive {:command, socket, %{"method" => "Input.insertText"}}, 2000
    monitor = Process.monitor(conn)
    send(socket, :disconnect)
    assert Task.await(pending) == {:error, :browser_outcome_unknown}
    assert_receive {:DOWN, ^monitor, :process, ^conn, :normal}
    refute_receive {:command, _, _}, 100
  end

  test "CDP timeout closes the connection and never retries", %{conn: conn} do
    pending = Task.async(fn -> Connection.command(conn, "Page.navigate", %{}, "tab", 500) end)
    assert_receive {:command, _, %{"method" => "Page.navigate"}}, 2000
    assert Task.await(pending) == {:error, :browser_outcome_unknown}
    refute_receive {:command, _, _}, 100
  end
end
