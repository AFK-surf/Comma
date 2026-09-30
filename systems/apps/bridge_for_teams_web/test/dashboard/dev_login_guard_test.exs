defmodule BridgeForTeamsWeb.Dashboard.DevLoginGuardTest do
  @moduledoc """
  The /dev/login e2e bypass must be inert unless explicitly enabled. In the test
  env the `:dev_login` flag is unset, so the route must 404 (and never mint a
  session). The flag is only ever set for non-prod e2e via config.json.
  """
  use BridgeForTeamsWeb.DashboardCase, async: true

  test "GET /dev/login returns 404 when the dev_login flag is off", %{conn: conn} do
    refute Application.get_env(:bridge_for_teams_web, :dev_login, false)

    conn = get(conn, "/dev/login?email=nobody@example.com")

    assert conn.status == 404
    # No session cookie was set.
    assert conn.resp_cookies == %{}
  end
end
