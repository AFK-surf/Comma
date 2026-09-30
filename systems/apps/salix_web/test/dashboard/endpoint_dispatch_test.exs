defmodule SalixWeb.Dashboard.EndpointDispatchTest do
  @moduledoc """
  Locks in the same-port architecture: `SalixWeb.Endpoint` (the single Bandit
  plug) hands `/dash/*` to the LiveView `DashboardEndpoint` while every other
  path still reaches the bearer-auth `SalixWeb.Router`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  setup do
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_web, :api_token, "test-token")

    on_exit(fn ->
      if prev_api_token do
        Application.put_env(:salix_web, :api_token, prev_api_token)
      else
        Application.delete_env(:salix_web, :api_token)
      end
    end)

    :ok
  end

  test "/dash/* is served by the dashboard endpoint (no bearer auth)" do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = conn(:get, "/dash/login") |> SalixWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "Admin token"

    assert_receive {[:comma_system, :http, :stop], %{duration: duration}, %{route: "/dash/login"}}
    assert duration >= 0
  end

  test "non-dash paths still reach the API router" do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # /health is public on the API router.
    conn = conn(:get, "/health") |> SalixWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "ok"

    assert_receive {[:comma_system, :http, :stop], %{duration: health_duration},
                    %{
                      endpoint: :salix_api,
                      method: "GET",
                      route: "/health",
                      status: 200
                    }}

    assert health_duration >= 0

    unauthorized = conn(:get, "/v1/admin/cluster/stats") |> SalixWeb.Endpoint.call([])
    assert unauthorized.status == 401

    assert_receive {[:comma_system, :http, :stop], %{duration: admin_duration},
                    %{
                      endpoint: :salix_api,
                      method: "GET",
                      route: "/v1/admin/cluster/stats",
                      status: 401
                    }}

    assert admin_duration >= 0
  end

  test "admin API paths still require the bearer token (dashboard auth is separate)" do
    conn = conn(:get, "/v1/admin/cluster/stats") |> SalixWeb.Endpoint.call([])
    assert conn.status == 401
  end

  test "admin API paths accept the bearer admin token" do
    conn =
      conn(:get, "/v1/admin/cluster/stats")
      |> put_req_header("authorization", "Bearer test-token")
      |> SalixWeb.Endpoint.call([])

    assert conn.status == 200
  end
end
