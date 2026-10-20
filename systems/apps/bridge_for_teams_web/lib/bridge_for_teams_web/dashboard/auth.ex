defmodule BridgeForTeamsWeb.Dashboard.Auth do
  @moduledoc """
  Dashboard authentication (design §7): the signed session cookie carries the
  opaque `BridgeForTeams.Auth` session token under `:comma_session`. This module
  provides the `fetch_current_user/2` plug (the `:browser` pipeline), which
  resolves the token via `BridgeForTeams.Auth.Sessions`/`Accounts` and assigns
  `:current_user`, and `require_authenticated/2`, which redirects anonymous
  users to `/login`.

  Login itself is driven by the existing OIDC flow in `BridgeForTeams.Auth` via
  `BridgeForTeamsWeb.Dashboard.AuthController`.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Accounts

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
    put_session(conn, @session_token_key, token)
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

  defp login_path(conn) do
    conn
    |> fetch_query_params()
    |> Map.get(:query_params)
    |> build_login_query(current_return_to(conn))
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
