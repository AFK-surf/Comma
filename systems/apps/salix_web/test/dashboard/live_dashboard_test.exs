defmodule SalixWeb.Dashboard.LiveDashboardTest do
  @moduledoc """
  Phoenix LiveDashboard is mounted at `/dash/live-dashboard` behind the same
  admin-token gate as the rest of the dashboard: the `:require_admin` HTTP
  pipeline plus the `:ensure_admin` on_mount on its (own) live_session.
  """
  use SystemsClock.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  test "anonymous /dash/live-dashboard redirects to login" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/dash/login"}}} = live(conn, "/dash/live-dashboard")
  end
end
