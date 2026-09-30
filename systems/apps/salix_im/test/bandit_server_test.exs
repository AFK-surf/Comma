defmodule SalixIM.TestSupport.BanditServerTest do
  use ExUnit.Case, async: false

  alias SalixIM.TestSupport.BanditServer

  defmodule Endpoint do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "test-owned")
  end

  test "skips a listener bound to the exact request address" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, occupied} = :inet.port(socket)
    owner = self()

    port =
      BanditServer.start!(fn candidate ->
        send(owner, {:candidate, candidate})

        requested =
          if Process.get({__MODULE__, :attempted}, false), do: candidate, else: occupied

        Process.put({__MODULE__, :attempted}, true)
        {Bandit, plug: Endpoint, port: requested}
      end)

    assert_receive {:candidate, first}
    assert_receive {:candidate, ^port}
    assert port > first
    assert Req.get!("http://127.0.0.1:#{port}").body == "test-owned"
  end
end
