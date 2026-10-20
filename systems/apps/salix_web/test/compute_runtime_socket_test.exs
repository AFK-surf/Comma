defmodule SalixWeb.ComputeRuntimeSocketTest do
  use SystemsClock.Case, async: true

  import Plug.Test

  alias SalixWeb.ComputeRuntimeSocket

  test "runtime carrier upgrade stays open while an agent is idle" do
    conn =
      "GET"
      |> conn("http://localhost/v1/compute/runtime/socket")
      |> then(&%{&1 | req_headers: [{"host", "localhost"} | &1.req_headers]})
      |> Plug.Conn.put_req_header("connection", "Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("sec-websocket-version", "13")
      |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> Plug.Conn.put_req_header("authorization", "Bearer test-token")
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert conn.state == :upgraded

    assert_receive {_ref, :upgrade,
                    {:websocket, {SalixWeb.ComputeRuntimeSocket, %{token: "test-token"}, opts}}}

    assert opts[:timeout] == :infinity
  end
end
