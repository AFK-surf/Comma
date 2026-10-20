defmodule BridgeForTeamsWeb.Dashboard.I18nTest do
  @moduledoc """
  Dashboard internationalization: `I18n` negotiation/resolution, the locale
  resolution plug (the React app and the JSON API speak Chinese for a user
  whose preferred_locale is zh_Hans), the org-level default, and the
  `/locale/:locale` switcher (session + preferred_locale persistence,
  open-redirect safety).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Accounts, Orgs}
  alias BridgeForTeamsWeb.I18n

  describe "I18n" do
  end

  describe "locale rendering" do
    test "renders Chinese when the user prefers zh_Hans", %{conn: conn} do
      %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
      {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

      html = conn |> get(~p"/orgs/#{org.slug}") |> html_response(200)
      assert html =~ ~s(<html lang="zh-Hans">)
      assert html =~ ~s(<meta name="bft-locale" content="zh_Hans" />)

      # Server-side messages of the JSON API are translated too.
      assert missing_task_message(conn, org) == "未找到任务。"
    end
  end

  defp missing_task_message(conn, org) do
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Locale",
        "slug" => "locale-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

    conn
    |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/tasks/missing")
    |> json_response(404)
    |> get_in(["error", "message"])
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
