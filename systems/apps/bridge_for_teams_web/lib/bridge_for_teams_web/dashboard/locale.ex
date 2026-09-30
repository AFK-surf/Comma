defmodule BridgeForTeamsWeb.Dashboard.Locale do
  @moduledoc """
  Resolves the request locale for the dashboard and applies it for the dead
  render (HTTP/plug process).

  Precedence:

    * **Signed-in users:** `?locale=` override → personal `preferred_locale` →
      the org default (`organizations.default_locale`, resolved from the URL's
      org slug, else the user's first org) → `Accept-Language` → default.
    * **Anonymous users** (login/signup): `?locale=` → session `"locale"` (set by
      the switcher) → `Accept-Language` → default.

  The resolved locale is always written back to the session and assigned as
  `@locale` — this is what the connected LiveView reads in the `:set_locale`
  `on_mount` hook (Gettext locale is process-local). For signed-in users the
  session is treated as an output-only handoff (not an input), so a changed
  personal/org preference takes effect immediately rather than being shadowed by
  a stale session value.

  Must run after `:fetch_session` and `fetch_current_user` in the pipeline.
  """
  import Plug.Conn

  alias BridgeForTeams.Orgs
  alias BridgeForTeamsWeb.I18n

  @session_key "locale"

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    locale = resolve(conn, conn.assigns[:current_user])

    Gettext.put_locale(locale)

    conn
    |> maybe_put_locale_session(locale)
    |> assign(:locale, locale)
  end

  # Only write the session when the locale is non-default or the session already
  # carries one. This keeps the LiveView handoff working (a missing session
  # locale resolves to the default in the on_mount hook) while avoiding a
  # gratuitous cookie on plain default-locale requests (e.g. the /dev/login
  # bypass, which must mint no cookie).
  defp maybe_put_locale_session(conn, locale) do
    current = get_session(conn, @session_key)

    if locale == current or (is_nil(current) and locale == I18n.default_locale()) do
      conn
    else
      put_session(conn, @session_key, locale)
    end
  end

  defp resolve(conn, nil) do
    I18n.resolve(conn.params["locale"], [
      get_session(conn, @session_key),
      I18n.negotiate(get_req_header(conn, "accept-language"))
    ])
  end

  defp resolve(conn, user) do
    I18n.resolve(conn.params["locale"], [
      user.preferred_locale,
      org_default_locale(conn, user),
      I18n.negotiate(get_req_header(conn, "accept-language"))
    ])
  end

  # The org default for the org in the URL (`/orgs/:slug/...`) when present,
  # otherwise the default of the user's first org.
  defp org_default_locale(conn, user) do
    with slug when is_binary(slug) <- org_slug(conn),
         {:ok, %{default_locale: locale}} when is_binary(locale) <- Orgs.get_org_by_slug(slug) do
      locale
    else
      _ -> Orgs.default_locale_for_user(user.id)
    end
  end

  # Pages carry the org as the first path segment (`/orgs/:org/...`); the
  # dashboard JSON API nests it (`/dashboard/api/v1/orgs/:org/...`) but routes
  # it to the same `:org` path parameter.
  defp org_slug(conn) do
    case conn.path_params do
      %{"org" => slug} ->
        slug

      _ ->
        case conn.path_info do
          ["orgs", slug | _] -> slug
          _ -> nil
        end
    end
  end

  @doc "The session key under which the resolved locale is stored."
  def session_key, do: @session_key
end
