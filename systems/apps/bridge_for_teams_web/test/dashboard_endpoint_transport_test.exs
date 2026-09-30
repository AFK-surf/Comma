defmodule BridgeForTeamsWeb.DashboardEndpointTransportTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  alias BridgeForTeamsWeb.DashboardEndpoint

  test "LiveView long-poll responses containing a transport token are not cacheable" do
    assert [{"/live", Phoenix.LiveView.Socket, socket_opts}] = DashboardEndpoint.__sockets__()
    assert Keyword.get(socket_opts, :longpoll)

    conn =
      :get
      |> conn("/live/longpoll?vsn=2.0.0")
      |> DashboardEndpoint.call(DashboardEndpoint.init([]))

    assert conn.halted
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert %{"token" => token} = Phoenix.json_library().decode!(conn.resp_body)
    assert is_binary(token) and token != ""
  end
end
