defmodule SalixWeb.Dashboard.EndpointDispatchTest do
  @moduledoc """
  Locks in the same-port architecture: `SalixWeb.Endpoint` (the single Bandit
  plug) hands `/dash/*` to the LiveView `DashboardEndpoint` while every other
  path still reaches the bearer-auth `SalixWeb.Router`.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  import Plug.Test
  import Plug.Conn

  setup do
    prev_api_token = SystemsRuntime.get_env(:salix_web, :api_token)
    SystemsRuntime.put_env(:salix_web, :api_token, "test-token")

    on_exit(fn ->
      if prev_api_token do
        SystemsRuntime.put_env(:salix_web, :api_token, prev_api_token)
      else
        SystemsRuntime.delete_env(:salix_web, :api_token)
      end
    end)

    :ok
  end

  test "/dash/* is served by the dashboard endpoint (no bearer auth)" do
    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _config ->
          SystemsRuntime.Proc.send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    conn = conn(:get, "/dash/login") |> SalixWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "Admin token"

    settle_receive(
      {[:comma_system, :http, :stop], %{duration: duration}, %{route: "/dash/login"}}
    )

    assert duration >= 0
  end

  test "non-dash paths still reach the API router" do
    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _config ->
          SystemsRuntime.Proc.send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    # /health is public on the API router.
    conn = conn(:get, "/health") |> SalixWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "ok"

    settle_receive(
      {[:comma_system, :http, :stop], %{duration: health_duration},
       %{
         endpoint: :salix_api,
         method: "GET",
         route: "/health",
         status: 200
       }}
    )

    assert health_duration >= 0

    unauthorized = conn(:get, "/v1/admin/cluster/stats") |> SalixWeb.Endpoint.call([])
    assert unauthorized.status == 401

    settle_receive(
      {[:comma_system, :http, :stop], %{duration: admin_duration},
       %{
         endpoint: :salix_api,
         method: "GET",
         route: "/v1/admin/cluster/stats",
         status: 401
       }}
    )

    assert admin_duration >= 0
  end

  test "admin API paths accept the bearer admin token" do
    conn =
      conn(:get, "/v1/admin/cluster/stats")
      |> put_req_header("authorization", "Bearer test-token")
      |> SalixWeb.Endpoint.call([])

    assert conn.status == 200
  end
end
