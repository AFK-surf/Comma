defmodule SalixWeb.Dashboard.LiveBootTest do
  @moduledoc """
  Real-boot verification of the same-port architecture: the dashboard is served
  over the actual Bandit listener (not just ConnTest), and — the load-bearing
  claim — the LiveView websocket upgrade succeeds on that shared listener even
  though `DashboardEndpoint` runs with `server: false`.
  """
  use ExUnit.Case, async: false

  defmodule WsProbe do
    @moduledoc false
    use WebSockex

    def start_link(url, parent), do: WebSockex.start_link(url, __MODULE__, parent)

    @impl true
    def handle_frame(_frame, parent), do: {:ok, parent}
  end

  test "dashboard login is served over the shared Bandit listener" do
    port = SalixWeb.Application.http_port()
    {:ok, resp} = Req.get("http://127.0.0.1:#{port}/dash/login")
    assert resp.status == 200
    assert resp.body =~ "Admin token"
  end

  test "non-dash API path still served on the same listener" do
    port = SalixWeb.Application.http_port()
    {:ok, resp} = Req.get("http://127.0.0.1:#{port}/health")
    assert resp.status == 200
  end

  test "LiveView websocket upgrades on the shared listener (server: false endpoint)" do
    port = SalixWeb.Application.http_port()
    url = "ws://127.0.0.1:#{port}/dash/live/websocket?vsn=2.0.0"

    # WebSockex.start_link returns {:ok, pid} only after the HTTP 101 upgrade
    # completes — so a successful connect proves the upgrade rode the Bandit
    # adapter of the shared listener.
    assert {:ok, pid} = WsProbe.start_link(url, self())
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
  end
end
