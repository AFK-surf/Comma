defmodule SalixSignal.GroupCall.SfuTest do
  require SystemsRuntime.Proc

  # The calling-server HTTP client (CRS-14 section 5): TLS trust in the
  # Signal roots only, redirects (section 5.1), and Comma decision D2 (UDP
  # only: a join response without udpAddresses fails the join). The server
  # is a local HTTPS endpoint with a test chain.
  use SystemsClock.Case, async: true

  alias SalixSignal.GroupCall.Sfu
  alias SalixSignal.Test.FakeChat

  @token "fake:token"
  defmodule Server do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      SystemsRuntime.Proc.send(
        test,
        {:sfu_request, conn.method, conn.request_path, get_req_header(conn, "authorization")}
      )

      case String.split(conn.request_path, "/v2/conference/participants") do
        ["/moved", ""] ->
          answer(conn, conn.method, true)

        ["/no-udp", ""] ->
          answer(conn, conn.method, false)

        ["", ""] ->
          redirect(conn, "/moved/v2/conference/participants")

        ["/absolute", ""] ->
          redirect(conn, "https://localhost:#{conn.port}/moved/v2/conference/participants")

        ["/permanent", ""] ->
          conn
          |> put_resp_header("location", "/moved/v2/conference/participants")
          |> send_resp(308, "")

        ["/loop", ""] ->
          redirect(conn, "/loop/v2/conference/participants")

        ["/no-location", ""] ->
          send_resp(conn, 307, "")

        ["/plain-http", ""] ->
          redirect(conn, "http://localhost:#{conn.port}/moved/v2/conference/participants")

        _ ->
          send_resp(conn, 404, "")
      end
    end

    defp redirect(conn, location),
      do: conn |> put_resp_header("location", location) |> send_resp(307, "")

    defp answer(conn, "GET", _udp?) do
      body = JSON.encode!(%{"conferenceId" => "era", "participants" => [%{"demuxId" => 32}]})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end

    defp answer(conn, "PUT", udp?) do
      {:ok, _body, conn} = read_body(conn)

      body =
        JSON.encode!(%{
          "demuxId" => 16,
          "udpAddresses" => if(udp?, do: ["127.0.0.1:10000"], else: []),
          "tcpAddresses" => ["127.0.0.1:10001"],
          "iceUfrag" => "sfuu",
          "icePwd" => "sfupassword0123456789ab",
          "dhePublicKey" => String.duplicate("09", 32),
          "conferenceId" => "era",
          "clientStatus" => "ACTIVE"
        })

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    server =
      start_supervised!(
        {Bandit,
         plug: {Server, SystemsRuntime.Proc.self()},
         scheme: :https,
         ip: :loopback,
         port: 0,
         thousand_island_options: [transport_options: chain.server]}
      )

    %{base: "https://localhost:#{FakeChat.port(server)}", http: [roots: [chain.root]]}
  end

  test "the SFU certificate must chain to the configured Signal roots", ctx do
    # The test chain is not a Signal root: without `roots`, the pinned
    # Signal roots are used and the handshake fails.
    assert {:error, _} = Sfu.peek(ctx.base <> "/moved", @token, [])

    other = FakeChat.chain()
    assert {:error, _} = Sfu.peek(ctx.base <> "/moved", @token, http: [roots: [other.root]])
  end
end
