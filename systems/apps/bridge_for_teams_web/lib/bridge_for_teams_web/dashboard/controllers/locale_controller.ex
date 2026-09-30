defmodule BridgeForTeamsWeb.Dashboard.LocaleController do
  @moduledoc """
  Switches the dashboard locale. A LiveView can't write the session cookie, so
  the switcher links here: this action persists the chosen locale to the session
  (and, for a signed-in user, to `preferred_locale`), then redirects back to the
  page the user came from.

  `GET /locale/:locale?return_to=/some/local/path`
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.Accounts
  alias BridgeForTeamsWeb.Dashboard.Locale
  alias BridgeForTeamsWeb.I18n

  def update(conn, %{"locale" => locale} = params) do
    return_to = return_to(conn, params["return_to"])

    if I18n.supported?(locale) do
      if user = conn.assigns[:current_user] do
        Accounts.update_locale(user, locale)
      end

      conn
      |> put_session(Locale.session_key(), locale)
      |> redirect(to: return_to)
    else
      redirect(conn, to: return_to)
    end
  end

  # Prefer an explicit (local) return_to param, else the Referer's path, else "/".
  defp return_to(conn, param) do
    cond do
      local_path?(param) -> param
      path = referer_path(conn) -> path
      true -> "/"
    end
  end

  defp referer_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{path: "/" <> _ = path} = uri <- URI.parse(referer),
         true <- local_path?(path) do
      if uri.query, do: path <> "?" <> uri.query, else: path
    else
      _ -> nil
    end
  end

  # A local path: starts with a single "/", not "//host" or "/\..." (open redirect).
  defp local_path?("/" <> rest),
    do: rest == "" or binary_part(rest, 0, 1) not in ["/", "\\"]

  defp local_path?(_), do: false
end
