defmodule BridgeForTeamsWeb.Dashboard.SPAControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  test "anonymous visitors are sent to the login page", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() =~ "/login"
  end

  describe "signed-in users" do
    setup :register_and_log_in_user

    test "the dashboard pages serve the React app with the CSRF token",
         %{conn: conn, org: org} do
      for path <- [~p"/", ~p"/orgs/#{org.slug}"] do
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
  end

  test "users who have not finished onboarding are sent there first", %{conn: conn} do
    %{user: user} = org_with_owner_fixture()
    conn = log_in_user(conn, user, onboarded: false)

    assert conn |> get(~p"/") |> redirected_to() == "/onboarding"
  end
end
