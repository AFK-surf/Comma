defmodule BridgeForTeamsWeb.Dashboard.SPAController do
  @moduledoc """
  Serves the React dashboard (`clients/apps/bft`) for the pages it owns.

  The build lands in `priv/static/bft/`: hashed assets are served by
  `Plug.Static` under `/bft/`, and this controller returns `index.html` for
  page routes, so the SPA shares the browser session, CSRF token and locale
  with the LiveView pages. It applies the same first-run gate as the LiveView
  pages.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.UserOnboardings
  alias BridgeForTeamsWeb.I18n

  def index(conn, _params) do
    if UserOnboardings.onboarded?(conn.assigns.current_user.id) do
      send_index(conn)
    else
      redirect(conn, to: ~p"/onboarding")
    end
  end

  defp send_index(conn) do
    case File.read(index_path()) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, inject_request_context(html, conn.assigns[:locale]))

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "The dashboard is not built. Run `pnpm --filter @comma/bft build`.")
    end
  end

  # The CSRF token for later writes, and the locale resolved by
  # `Dashboard.Locale` (same precedence as the LiveView pages) for the SPA's
  # string table.
  defp inject_request_context(html, locale) do
    locale = I18n.resolve(locale)

    meta =
      ~s(<meta name="csrf-token" content="#{get_csrf_token()}" />) <>
        ~s(<meta name="bft-locale" content="#{locale}" />)

    html
    |> String.replace(~s(<html lang="en">), ~s(<html lang="#{I18n.lang_tag(locale)}">),
      global: false
    )
    |> String.replace("</head>", meta <> "</head>", global: false)
  end

  defp index_path do
    Application.get_env(:bridge_for_teams_web, :spa_index_path) ||
      Application.app_dir(:bridge_for_teams_web, "priv/static/bft/index.html")
  end
end
