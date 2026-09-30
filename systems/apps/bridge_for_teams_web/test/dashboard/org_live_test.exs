defmodule BridgeForTeamsWeb.Dashboard.OrgLiveTest do
  @moduledoc """
  LiveView tests for the organization list (OrgLive.Index). Uses the
  foundation's login + fixtures helpers and injected OIDC.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  describe "OrgLive.Index /orgs" do
    test "lists the orgs the user belongs to", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

      {:ok, _view, html} = live(conn, ~p"/orgs")

      assert html =~ "Organizations"
      assert html =~ org.name
      assert html =~ "member"
      assert html =~ "Agent Swarm"
    end

    test "shows empty state when the user has no orgs", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/orgs")

      assert html =~ "No organizations yet"
      assert html =~ "Use an invite code"
      refute html =~ "New organization"
      refute html =~ "Create your first organization"
    end
  end
end
