defmodule BridgeForTeamsWeb.Dashboard.SPAController do
  @moduledoc """
  Serves the React dashboard (`clients/apps/bft`) for the pages it owns.

  The build lands in `priv/static/bft/`: hashed assets are served by
  `Plug.Static` under `/bft/`, and this controller returns `index.html` for
  page routes, so the SPA shares the browser session, CSRF token and locale
  with the server-rendered pages. A flash message left by a redirect into the
  SPA is written into the page once, because the SPA has no other way to read
  it. It applies the first-run gate, except on the onboarding wizard itself,
  the pages the wizard links to and the CLI device-login page.
  """
  use BridgeForTeamsWeb.Dashboard, :controller
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Memberships, UserOnboardings}
  alias BridgeForTeamsWeb.I18n

  def index(conn, _params) do
    if UserOnboardings.onboarded?(conn.assigns.current_user.id) do
      send_index(conn)
    else
      redirect(conn, to: ~p"/onboarding")
    end
  end

  @doc """
  Serves a page without the first-run gate. The onboarding integrations step
  links admins to Settings → Integrations (Composio) to configure the org's
  API key, and links to its swarm's Connections page to set up messaging, so
  sending them back to `/onboarding` would block that step. The pages and
  their APIs keep their own owner, admin or swarm-member rules.
  """
  def before_onboarding(conn, _params), do: send_index(conn)

  @doc """
  Serves the first-run onboarding wizard to users who have not finished it;
  anyone else goes to `/`. The Composio Connect round trip may come back with
  `?oauth_error=`, which becomes an error notice.
  """
  def onboarding(conn, params) do
    cond do
      UserOnboardings.onboarded?(conn.assigns.current_user.id) ->
        redirect(conn, to: ~p"/")

      is_binary(params["oauth_error"]) and params["oauth_error"] != "" ->
        conn
        |> put_flash(:error, gettext("We couldn't connect that account. Please try again."))
        |> send_index()

      true ->
        send_index(conn)
    end
  end

  @doc """
  Serves the BFT CLI device-login page. Only owners and admins may approve a
  CLI login; anyone else goes to `/orgs` with an error. The first-run gate does
  not apply, so the `user_code` link from the terminal survives onboarding.
  """
  def cli_device_login(conn, _params) do
    if Memberships.manages_any_org?(conn.assigns.current_user.id) do
      send_index(conn)
    else
      conn
      |> put_flash(:error, gettext("You do not have permission to approve CLI login requests."))
      |> redirect(to: ~p"/orgs")
    end
  end

  @doc """
  The retired session inspector's address (`/tasks/:id/session`) opens the
  task it belonged to.
  """
  def task_session(conn, %{"org" => org, "id" => project, "conversation_id" => task}),
    do: redirect(conn, to: ~p"/orgs/#{org}/projects/#{project}/tasks/#{task}")

  defp send_index(conn) do
    case File.read(index_path()) do
      {:ok, html} ->
        flash = conn.assigns[:flash] || %{}

        conn
        |> clear_flash()
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, inject_request_context(html, conn.assigns[:locale], flash))

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "The dashboard is not built. Run `pnpm --filter @comma/bft build`.")
    end
  end

  # The CSRF token for later writes, the locale resolved by
  # `Dashboard.Locale` (same precedence as the server-rendered pages) for the SPA's
  # string table, and the already translated `:info`/`:error` flash.
  defp inject_request_context(html, locale, flash) do
    locale = I18n.resolve(locale)

    meta =
      ~s(<meta name="csrf-token" content="#{get_csrf_token()}" />) <>
        ~s(<meta name="bft-locale" content="#{locale}" />) <>
        Enum.map_join(~w(info error), &flash_meta(&1, Phoenix.Flash.get(flash, &1)))

    html
    |> String.replace(~s(<html lang="en">), ~s(<html lang="#{I18n.lang_tag(locale)}">),
      global: false
    )
    |> String.replace("</head>", meta <> "</head>", global: false)
  end

  defp flash_meta(kind, message) when is_binary(message) and message != "" do
    content = message |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    ~s(<meta name="bft-flash" data-kind="#{kind}" content="#{content}" />)
  end

  defp flash_meta(_kind, _message), do: ""

  defp index_path do
    SystemsRuntime.get_env(:bridge_for_teams_web, :spa_index_path) ||
      Application.app_dir(:bridge_for_teams_web, "priv/static/bft/index.html")
  end
end
