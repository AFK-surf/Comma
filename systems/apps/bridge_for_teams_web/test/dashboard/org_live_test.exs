defmodule BridgeForTeamsWeb.Dashboard.OrgLiveTest do
  @moduledoc """
  LiveView tests for the orgs-shell slice: OrgLive.Index (list) and HomeLive
  (workspace overview). Uses the foundation's login + fixtures helpers and injected OIDC.
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

  describe "HomeLive /orgs/:org" do
    test "renders the canonical workspace overview", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}")

      assert html =~ org.name
      assert html =~ "Agent Swarms"
      assert html =~ "Agent Swarm activity"
      assert html =~ "Tasks"
      assert html =~ "Token usage"
      assert html =~ ~s(href="/orgs/#{org.slug}/operations")
      assert has_element?(view, "a[aria-current='page'][href='/orgs/#{org.slug}']", "Overview")
    end

    test "redirects to /orgs for an org the user does not belong to", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      other = org_fixture()

      assert {:error, {:live_redirect, %{to: "/orgs"}}} = live(conn, ~p"/orgs/#{other.slug}")
    end
  end
end
