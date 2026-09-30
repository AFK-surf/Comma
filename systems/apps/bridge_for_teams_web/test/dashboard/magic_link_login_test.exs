defmodule BridgeForTeamsWeb.Dashboard.MagicLinkLoginTest do
  @moduledoc """
  Email magic-link login fallback (`/auth/email*`): orgs WITHOUT an SSO
  connection fall back from `POST /auth/start` to the email form; the emailed
  one-time link signs the user in with the same signed session cookie as SSO.
  Delivery goes through `BridgeForTeams.LoginLinks.Delivery.Fake` (process
  dictionary — ConnTest dispatches in the test process).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.LoginLinks.Delivery.Fake, as: FakeDelivery
  alias BridgeForTeams.Memberships
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  defp sso_less_org_with_member do
    org = org_fixture()
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    %{org: org, user: user}
  end

  test "the full flow: request form, emailed link, session cookie", %{conn: conn} do
    %{org: org, user: user} = sso_less_org_with_member()

    conn = get(conn, "/auth/email", %{"o" => org.slug})
    html = html_response(conn, 200)
    assert html =~ "Sign in with email"
    assert html =~ org.slug

    conn =
      conn
      |> recycle()
      |> post("/auth/email/send", %{"org_slug" => org.slug, "email" => user.email})

    assert redirected_to(conn) == "/auth/email?" <> URI.encode_query(%{"o" => org.slug})

    assert [%{email: delivered_to, url: url}] = FakeDelivery.deliveries()
    assert delivered_to == user.email
    # The link is absolute, built on the request host in tests (no configured
    # public base URL).
    assert url =~ "/auth/email/verify?token=bft_login_"

    %{"token" => token} = URI.decode_query(URI.parse(url).query)

    conn = conn |> recycle() |> get("/auth/email/verify", %{"token" => token})
    assert redirected_to(conn) == "/"

    session_token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: user_id}} = Sessions.fetch(session_token)
    assert user_id == user.id

    # The link is single-use.
    conn = conn |> recycle() |> get("/auth/email/verify", %{"token" => token})
    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid, expired, or already used"
  end

  test "sending shows the same neutral message whether or not anything matched", %{conn: conn} do
    %{org: org} = sso_less_org_with_member()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/email/send", %{"org_slug" => org.slug, "email" => "no@match.test"})

    assert redirected_to(conn) == "/auth/email?" <> URI.encode_query(%{"o" => org.slug})
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "we sent a sign-in link"
    assert FakeDelivery.deliveries() == []
  end

  test "an invalid token flashes an error and returns to login", %{conn: conn} do
    conn = get(conn, "/auth/email/verify", %{"token" => "bft_login_bogus"})

    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid, expired, or already used"
  end

  test "the fallback stays on the historical error when delivery is unconfigured", %{conn: conn} do
    %{org: org} = sso_less_org_with_member()
    prev = Application.get_env(:bridge_for_teams_core, :login_link_delivery)

    # The default Postmark delivery reports unconfigured without a server
    # token, so LoginLinks.enabled?/0 is false.
    Application.delete_env(:bridge_for_teams_core, :login_link_delivery)
    on_exit(fn -> Application.put_env(:bridge_for_teams_core, :login_link_delivery, prev) end)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    assert redirected_to(conn) == "/login"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Unknown organization or SSO not configured"

    conn = conn |> recycle() |> get("/auth/email", %{"o" => org.slug})
    assert redirected_to(conn) == "/login"
  end

  test "a signed-in user is bounced away from the email form", %{conn: conn} do
    %{user: user} = sso_less_org_with_member()

    conn = conn |> log_in_user(user) |> get("/auth/email", %{"o" => "whatever"})

    assert redirected_to(conn) == "/"
  end
end
