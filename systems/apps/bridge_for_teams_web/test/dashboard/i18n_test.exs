defmodule BridgeForTeamsWeb.Dashboard.I18nTest do
  @moduledoc """
  Dashboard internationalization: `I18n` negotiation/resolution, the locale
  resolution plug + `:set_locale` on_mount (Chinese renders for a user whose
  preferred_locale is zh_Hans), the org-level default, and the `/locale/:locale`
  switcher (session + preferred_locale persistence, open-redirect safety).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Accounts, Orgs}
  alias BridgeForTeamsWeb.I18n

  describe "I18n" do
    test "supported?/lang_tag/options" do
      assert I18n.supported?("en")
      assert I18n.supported?("zh_Hans")
      refute I18n.supported?("fr")
      assert I18n.default_locale() == "en"
      assert I18n.lang_tag("zh_Hans") == "zh-Hans"
      assert I18n.lang_tag("bogus") == "en"
      assert {"中文（简体）", "zh_Hans"} in I18n.options()
    end

    test "negotiate/1 maps Accept-Language to a supported locale" do
      assert I18n.negotiate("zh-CN,zh;q=0.9,en;q=0.8") == "zh_Hans"
      assert I18n.negotiate("zh-Hans") == "zh_Hans"
      assert I18n.negotiate("en-US,en;q=0.9") == "en"
      assert I18n.negotiate("fr-FR,fr;q=0.9") == "en"
      assert I18n.negotiate(["zh-CN"]) == "zh_Hans"
      assert I18n.negotiate(nil) == "en"
    end

    test "resolve/2 returns the first supported value, else default" do
      assert I18n.resolve("zh_Hans", []) == "zh_Hans"
      assert I18n.resolve(nil, ["bogus", "zh_Hans"]) == "zh_Hans"
      assert I18n.resolve(nil, [nil, "fr"]) == "en"
    end
  end

  describe "locale rendering" do
    test "renders Chinese when the user prefers zh_Hans", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

      {:ok, _view, html} = live(conn, swarm_page(org))

      assert html =~ "会议"
      # Sidebar nav is translated too.
      assert html =~ "概览"
      assert html =~ "工作区"
      refute html =~ "Workspace"
    end

    test "renders English by default", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

      {:ok, _view, html} = live(conn, swarm_page(org))

      assert html =~ "Workspace"
      refute html =~ "工作区"
    end

    test "falls back to the org default locale when the user has no preference", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
      {:ok, _org} = Orgs.update_org(org, %{"default_locale" => "zh_Hans"})

      {:ok, _view, html} = live(conn, swarm_page(org))

      assert html =~ "成员"
    end
  end

  # Org pages are the React dashboard; the LiveView shell renders on an Agent
  # Swarm page.
  defp swarm_page(org) do
    project = bare_project_fixture(org)
    ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins"
  end

  describe "GET /locale/:locale" do
    test "persists the locale to the session and the user, then redirects", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, "/locale/zh_Hans")

      assert redirected_to(conn) == "/"
      assert get_session(conn, "locale") == "zh_Hans"
      assert {:ok, %{preferred_locale: "zh_Hans"}} = Accounts.get_user(user.id)
    end

    test "honors a local return_to and ignores an unsupported locale", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, "/locale/zh_Hans?return_to=/orgs")
      assert redirected_to(conn) == "/orgs"

      conn = get(build_conn(), "/locale/klingon")
      # Unsupported: redirect without setting a locale.
      assert redirected_to(conn) == "/"
      refute get_session(conn, "locale") == "klingon"
    end

    test "rejects a non-local return_to (open redirect)", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, "/locale/zh_Hans?return_to=//evil.example.com")
      assert redirected_to(conn) == "/"
    end
  end
end
