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
            ~p"/orgs/#{org.slug}/plugins",
            ~p"/orgs/#{org.slug}/meetings",
            ~p"/orgs/#{org.slug}/meetings/past",
            ~p"/orgs/#{org.slug}/meetings/settings",
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

    test "passes the user's dashboard language to the React app", %{conn: conn, user: user} do
      {:ok, _} = BridgeForTeams.Accounts.update_user(user, %{"preferred_locale" => "zh_Hans"})

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(<html lang="zh-Hans">)
      assert html =~ ~s(<meta name="bft-locale" content="zh_Hans" />)
    end

    test "a flash left by a redirect into the React app is written into the page once",
         %{conn: conn, org: org} do
      missing = ~p"/orgs/#{org.slug}/projects/#{Ecto.UUID.generate()}/plugins"
      conn = get(conn, missing)
      assert redirected_to(conn) == ~p"/orgs/#{org.slug}/projects"

      conn = get(conn, ~p"/orgs/#{org.slug}/projects")
      html = html_response(conn, 200)

      assert html =~
               ~s(<meta name="bft-flash" data-kind="error" content="Agent Swarm not found." />)

      html = conn |> get(~p"/orgs/#{org.slug}/projects") |> html_response(200)
      refute html =~ "bft-flash"
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
