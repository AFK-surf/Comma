defmodule BridgeForTeamsWeb.Dashboard.SPAControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  test "anonymous visitors are sent to the login page", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() =~ "/login"
  end

  describe "signed-in users" do
    setup :register_and_log_in_user

    test "the dashboard pages serve the React app with the CSRF token",
         %{conn: conn, org: org} do
      project = bare_project_fixture(org)

      for path <- [
            ~p"/",
            ~p"/orgs",
            ~p"/orgs/#{org.slug}",
            ~p"/orgs/#{org.slug}/projects",
            ~p"/orgs/#{org.slug}/projects/#{project.id}",
            ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins",
            ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins/linear",
            ~p"/orgs/#{org.slug}/projects/#{project.id}/skills",
            ~p"/orgs/#{org.slug}/projects/#{project.id}/connections",
            ~p"/orgs/#{org.slug}/projects/#{project.id}/integrations",
            ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/cnv1_task",
            ~p"/orgs/#{org.slug}/plugins",
            ~p"/orgs/#{org.slug}/meetings",
            ~p"/orgs/#{org.slug}/meetings/past",
            ~p"/orgs/#{org.slug}/meetings/settings",
            ~p"/orgs/#{org.slug}/daily-brief",
            ~p"/orgs/#{org.slug}/information-flow",
            ~p"/orgs/#{org.slug}/operations",
            ~p"/orgs/#{org.slug}/operations/events",
            ~p"/orgs/#{org.slug}/members",
            ~p"/orgs/#{org.slug}/fin",
            ~p"/orgs/#{org.slug}/settings",
            ~p"/orgs/#{org.slug}/settings/models",
            ~p"/orgs/#{org.slug}/settings/models/templates",
            ~p"/orgs/#{org.slug}/settings/subscriptions",
            ~p"/orgs/#{org.slug}/settings/sso",
            ~p"/orgs/#{org.slug}/settings/integrations",
            ~p"/orgs/#{org.slug}/settings/oauth",
            ~p"/orgs/#{org.slug}/settings/composio",
            ~p"/orgs/#{org.slug}/settings/signal",
            ~p"/orgs/#{org.slug}/settings/feishu",
            ~p"/cli/device-login",
            ~p"/cli/device-login/ABCD2345"
          ] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(<div id="root"></div>)
        assert html =~ ~s(<meta name="csrf-token" content=")
        assert html =~ ~s(<meta name="bft-locale" content="en" />)
      end
    end

    test "escapes the flash message", %{conn: conn} do
      html =
        conn
        |> init_test_session(%{"phoenix_flash" => %{"info" => ~s(Agent Swarm "<b>" archived.)}})
        |> get(~p"/")
        |> html_response(200)

      assert html =~
               ~s(<meta name="bft-flash" data-kind="info" content="Agent Swarm &quot;&lt;b&gt;&quot; archived." />)
    end
  end

  test "users who have not finished onboarding are sent there first", %{conn: conn} do
    %{user: user} = org_with_owner_fixture()
    conn = log_in_user(conn, user, onboarded: false)

    assert conn |> get(~p"/") |> redirected_to() == "/onboarding"
  end
end
