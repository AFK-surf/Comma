defmodule SystemsObservability.HTTPPlugTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @reporter Module.concat(__MODULE__, Reporter)

  defmodule BanditTestPlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn =
        SystemsObservability.HTTPPlug.call(conn,
          endpoint: :comma_product_api,
          route: "/health"
        )

      case conn.request_path do
        "/no-content" -> Plug.Conn.send_resp(conn, 204, "")
        "/error" -> raise "secret-http-exception"
      end
    end
  end

  defmodule PhoenixRouter do
    use Phoenix.Router

    get("/phoenix/:id", __MODULE__, :show)
    def show(conn, _params), do: conn
  end

  def fallback_route(_conn), do: "/v1/runtime/:id"

  setup do
    http_counter =
      Enum.find(SystemsObservability.Telemetry.metrics(), fn metric ->
        metric.name == [:comma, :system, :http, :requests, :total]
      end)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: [http_counter], start_async: false}
    )

    :ok
  end

  test "request completion emits a bounded stop event and preserves the response" do
    handler = {__MODULE__, make_ref()}
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _ -> send(test, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = conn(:get, "/health")
    conn = SystemsObservability.HTTPPlug.call(conn, endpoint: :comma_product_api, route: "/health")
    conn = send_resp(conn, 200, "ok")

    assert conn.status == 200
    assert conn.resp_body == "ok"

    assert_receive {[:comma_system, :http, :stop], %{duration: duration},
                    %{
                      endpoint: :comma_product_api,
                      route: "/health",
                      method: "GET",
                      status: 200
                    }}

    assert duration >= 0
  end

  test "route extraction uses explicit, Plug, Phoenix, then resolver fallback precedence" do
    handler = {__MODULE__, make_ref()}
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn _event, _measurements, metadata, _ -> send(test, {:route, metadata.route}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    resolver = {__MODULE__, :fallback_route}

    cases = [
      {conn(:get, "/raw") |> put_private(:plug_route, {"/plug/:id", nil}),
       [endpoint: :salix_api, route: "/health", route_resolver: resolver], "/health"},
      {conn(:get, "/raw") |> put_private(:plug_route, {"/v1/im/:id", nil}),
       [endpoint: :salix_api, route_resolver: resolver], "/v1/im/:id"},
      {conn(:get, "/phoenix/secret") |> put_private(:phoenix_router, PhoenixRouter),
       [endpoint: :salix_api, route_resolver: resolver], "/phoenix/:id"},
      {conn(:get, "/raw"), [endpoint: :salix_api, route_resolver: resolver], "/v1/runtime/:id"},
      {conn(:get, "/raw"), [endpoint: :salix_api], "unmatched"}
    ]

    for {request, opts, expected} <- cases do
      request
      |> SystemsObservability.HTTPPlug.call(opts)
      |> send_resp(200, "ok")

      assert_receive {:route, ^expected}
    end
  end

  test "real Bandit 204 and exception 500 increment their HTTP metric once each" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: BanditTestPlug,
         scheme: :http,
         ip: :loopback,
         port: 0,
         startup_log: false,
         http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    assert request(port, "/no-content") =~ " 204 "
    assert request(port, "/error") =~ " 500 "

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(comma_system_http_requests_total{endpoint="comma_product_api",method="GET",route="/health",status_class="2xx"} 1)

    assert scrape =~
             ~s(comma_system_http_requests_total{endpoint="comma_product_api",method="GET",route="/health",status_class="5xx"} 1)
  end

  test "invalid exception status falls back to one bounded 500 completion" do
    handler = {__MODULE__, make_ref()}
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _ -> send(test, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    :get
    |> conn("/health")
    |> SystemsObservability.HTTPPlug.call(endpoint: :comma_product_api, route: "/health")

    assert :ok ==
             SystemsObservability.HTTPPlug.complete_exception(%{plug_status: :invalid_status})

    assert_receive {[:comma_system, :http, :stop], %{duration: duration},
                    %{endpoint: :comma_product_api, route: "/health", method: "GET", status: 500}}

    assert duration >= 0
    assert :ok == SystemsObservability.HTTPPlug.complete(204)
    refute_receive {[:comma_system, :http, :stop], _, _}, 10
  end

  defp request(port, path) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 1_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"
      )

    receive_response(socket, [])
  end

  defp receive_response(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> receive_response(socket, [chunk | chunks])
      {:error, :closed} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
