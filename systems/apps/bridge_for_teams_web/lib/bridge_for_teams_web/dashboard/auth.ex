defmodule BridgeForTeamsWeb.Dashboard.Auth do
  @moduledoc """
  Dashboard authentication (design §7): the signed session cookie carries the
  opaque `BridgeForTeams.Auth` session token under `:comma_session`. This module
  provides both:

    * a `fetch_current_user/2` plug (the `:browser` pipeline) that resolves the
      token via `BridgeForTeams.Auth.Sessions`/`Accounts` and assigns
      `:current_user`; and
    * `on_mount/4` hooks for `live_session` — `:ensure_authenticated` (redirects
      anonymous users to `/login`) and `:mount_current_user` (best-effort).

  Login itself is driven by the existing OIDC flow in `BridgeForTeams.Auth` via
  `BridgeForTeamsWeb.Dashboard.AuthController`.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Accounts
  alias Phoenix.LiveView

  @session_token_key "comma_session"

  # ---- Plug (browser pipeline) ----

  @doc "Plug: resolve the session token from the signed cookie into :current_user."
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    user =
      with token when is_binary(token) <- get_session(conn, @session_token_key),
           {:ok, %{user_id: user_id}} <- Sessions.fetch(token),
           {:ok, user} <- Accounts.get_user(user_id) do
        user
      else
        _ -> nil
      end

    conn
    |> assign(:current_user, user)
    |> assign(:current_session_token, get_session(conn, @session_token_key))
  end

  @doc "Plug: redirect to /login unless a current_user is assigned."
  @spec require_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(
        :error,
        Gettext.gettext(BridgeForTeamsWeb.Gettext, "You must log in to continue.")
      )
      |> redirect(to: login_path(conn))
      |> halt()
    end
  end

  @doc "Store the opaque session token in the signed cookie (called after OIDC login)."
  @spec put_token_in_session(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_token_in_session(conn, token) do
    conn
    |> put_session(@session_token_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  @doc "The session key under which the opaque BridgeForTeams.Auth token is stored."
  def session_token_key, do: @session_token_key

  @doc """
  Return a dashboard-local redirect target, or nil for external/ambiguous input.

  Auth return paths are intentionally path-only. Device login approval links use
  this to survive the dashboard login round trip without opening an external
  redirect path.
  """
  @spec local_return_to(term()) :: String.t() | nil
  def local_return_to(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "/") and
         not String.starts_with?(trimmed, "//") and
         not String.contains?(trimmed, ["\\", "\r", "\n"]) do
      trimmed
    end
  end

  def local_return_to(_value), do: nil

  # ---- LiveView on_mount hooks ----

  @doc """
  on_mount hooks for `live_session`:

    * `:mount_current_user` — assigns `:current_user` (may be nil).
    * `:ensure_authenticated` — assigns `:current_user`, redirecting to `/login`
      if anonymous.
    * `:require_onboarded` — redirects users who have not finished the first-run
      onboarding flow to `/onboarding`.
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> LiveView.put_flash(
          :error,
          Gettext.gettext(BridgeForTeamsWeb.Gettext, "You must log in to continue.")
        )
        |> LiveView.redirect(to: login_path(params))

      {:halt, socket}
    end
  end

  # on_mount `:require_onboarded` — sends users who have not finished the
  # first-run onboarding flow to `/onboarding` before any dashboard surface.
  # (The React pages that skip it, CLI device login and Settings → Composio,
  # are served by `SPAController`.)
  def on_mount(:require_onboarded, _params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:cont, socket}

      BridgeForTeams.UserOnboardings.onboarded?(socket.assigns.current_user.id) ->
        {:cont, socket}

      true ->
        {:halt, LiveView.redirect(socket, to: "/onboarding")}
    end
  end

  # on_mount `:set_locale` — re-applies the locale resolved by the request plug
  # (stored in the session) inside the LiveView process, since Gettext locale is
  # process-local. Also assigns `@locale` for any in-LiveView use.
  def on_mount(:set_locale, _params, session, socket) do
    locale =
      BridgeForTeamsWeb.I18n.resolve(session[BridgeForTeamsWeb.Dashboard.Locale.session_key()])

    Gettext.put_locale(BridgeForTeamsWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      with token when is_binary(token) <- session[@session_token_key],
           {:ok, %{user_id: user_id}} <- Sessions.fetch(token),
           {:ok, user} <- Accounts.get_user(user_id) do
        user
      else
        _ -> nil
      end
    end)
  end

  defp login_path(%Plug.Conn{} = conn) do
    conn
    |> fetch_query_params()
    |> Map.get(:query_params)
    |> build_login_query(current_return_to(conn))
    |> build_login_path()
  end

  defp login_path(params) do
    params
    |> build_login_query(nil)
    |> build_login_path()
  end

  defp build_login_query(params, return_to) do
    params
    |> Map.take(["o"])
    |> maybe_put("return_to", local_return_to(return_to))
  end

  defp build_login_path(query) when map_size(query) == 0, do: "/login"
  defp build_login_path(query), do: "/login?" <> URI.encode_query(query)

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Map.put(query, key, value)

  defp current_return_to(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query_string -> conn.request_path <> "?" <> query_string
    end
  end
end
