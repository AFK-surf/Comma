defmodule SalixSignal.Test.FakeChat do
  @moduledoc false
  # A fake Signal chat service for service-client tests, written from CRS-01.
  #
  # It serves TLS 1.3 with an Ed25519 leaf for "localhost" signed by an RSA
  # test root, like the chat hosts in CRS-01 section 3.2. `GET /v1/websocket/`
  # upgrades to a socket whose frames are forwarded to the test process as
  # `{:fake_chat, :frame, socket, decoded}`; the test drives the socket with
  # `send(socket, {:send, bytes})` and `send(socket, {:close, code})`. Other
  # paths answer 200 with the request's Authorization header as the body.

  alias SalixSignalProto.Service.Frame

  @doc "A test root and a server certificate chained to it: `%{root: der, server: [cert:, key:]}`."
  def chain do
    san = [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}, digest: :sha256],
          intermediates: [],
          peer: [key: {:namedCurve, :ed25519}, digest: :sha256, extensions: san]
        },
        client_chain: %{
          root: [key: {:rsa, 2048, 65_537}, digest: :sha256],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}, digest: :sha256]
        }
      })

    cert = data.server_config[:cert]
    [root] = for r <- data.client_config[:cacerts], :public_key.pkix_is_issuer(cert, r), do: r
    %{root: root, server: [cert: cert, key: data.server_config[:key]]}
  end

  @doc """
  Bandit options for a fake chat server. `upgrades` is an Agent that holds
  the queued answers to upgrade requests: `:accept` or `{:reject, status,
  headers}`; an empty queue accepts.
  """
  def bandit_options(test_pid, chain, upgrades, opts \\ []) do
    state = %{
      test: test_pid,
      upgrades: upgrades,
      auto_keepalive: Keyword.get(opts, :auto_keepalive, true),
      upgrade_headers: Keyword.get(opts, :upgrade_headers, [])
    }

    [
      plug: {__MODULE__.Router, state},
      scheme: :https,
      ip: :loopback,
      port: 0,
      thousand_island_options: [transport_options: chain.server ++ [versions: [:"tlsv1.3"]]]
    ]
  end

  def port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(state), do: state

    @impl true
    def call(%{request_path: "/v1/websocket/"} = conn, state) do
      send(state.test, {:fake_chat, :upgrade, conn.req_headers})

      decision =
        Agent.get_and_update(state.upgrades, fn
          [next | rest] -> {next, rest}
          [] -> {:accept, []}
        end)

      case decision do
        :accept ->
          conn
          |> merge_resp_headers([{"x-signal-timestamp", "1758790000000"} | state.upgrade_headers])
          |> WebSockAdapter.upgrade(SalixSignal.Test.FakeChat.Socket, state, [])
          |> halt()

        {:reject, status, headers} ->
          conn |> merge_resp_headers(headers) |> send_resp(status, "") |> halt()
      end
    end

    def call(conn, state) do
      send(state.test, {:fake_chat, :http, conn.method, conn.request_path})

      conn
      |> put_resp_header("x-signal-timestamp", "1758790000000")
      |> send_resp(200, get_req_header(conn, "authorization") |> List.first() |> Kernel.||(""))
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state) do
      send(state.test, {:fake_chat, :connected, self()})
      {:ok, state}
    end

    @impl true
    def handle_in({bytes, opcode: :binary}, state) do
      {:ok, frame} = Frame.decode(bytes)

      case frame do
        %Frame.Request{verb: "GET", path: "/v1/keepalive", id: id} when state.auto_keepalive ->
          send(state.test, {:fake_chat, :keepalive, self()})
          reply = Frame.encode_response(%Frame.Response{id: id, status: 200})
          {:push, {:binary, reply}, state}

        _ ->
          send(state.test, {:fake_chat, :frame, self(), frame})
          {:ok, state}
      end
    end

    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info({:send, bytes}, state), do: {:push, {:binary, bytes}, state}
    def handle_info({:close, code}, state), do: {:stop, :normal, code, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
