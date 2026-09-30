defmodule SalixWeb.Dashboard.LiveDashboardTest do
  @moduledoc """
  Phoenix LiveDashboard is mounted at `/dash/live-dashboard` behind the same
  admin-token gate as the rest of the dashboard: the `:require_admin` HTTP
  pipeline plus the `:ensure_admin` on_mount on its (own) live_session.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  test "anonymous /dash/live-dashboard redirects to login" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/dash/login"}}} = live(conn, "/dash/live-dashboard")
  end

  test "authenticated admin reaches the LiveDashboard home page" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "LiveDashboard"})
    tenant_id = tenant["tenant_id"]

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id})

    # LiveDashboard's index redirects to the node's home page
    # (`/dash/live-dashboard/:node/home`); follow it to land on a live view.
    {:ok, _view, html} = live(conn, "/dash/live-dashboard/home")
    assert html =~ "Dashboard"
  end
end
