defmodule CommaWeb.SessionCookie do
  @moduledoc "HttpOnly browser-session transport for Comma user sessions."

  import Plug.Conn

  @cookie_name "comma_session"
  @panel_cookie_name "comma_panel_session"
  @transport_header "x-comma-session-transport"

  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie_name

  @spec panel_cookie_name() :: String.t()
  def panel_cookie_name, do: @panel_cookie_name

  @spec cookie_transport?(Plug.Conn.t()) :: boolean()
  def cookie_transport?(conn) do
    get_req_header(conn, @transport_header) == ["cookie"]
  end

  @spec fetch(Plug.Conn.t()) :: {Plug.Conn.t(), String.t() | nil}
  def fetch(conn) do
    conn = fetch_cookies(conn)
    {conn, normalize_token(conn.req_cookies[@cookie_name])}
  end

  @spec fetch_browser(Plug.Conn.t()) :: {Plug.Conn.t(), String.t() | nil}
  def fetch_browser(conn) do
    conn = fetch_cookies(conn)
    user_token = normalize_token(conn.req_cookies[@cookie_name])
    panel_token = normalize_token(conn.req_cookies[@panel_cookie_name])

    if user_token do
      {assign(conn, :comma_cookie_kind, :user), user_token}
    else
      {assign(conn, :comma_cookie_kind, :panel), panel_token}
    end
  end

  @spec put_session(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_session(conn, %{"token" => token, "expires_at" => expires_at})
      when is_binary(token) and token != "" and is_integer(expires_at) do
    put_resp_cookie(conn, @cookie_name, token,
      http_only: true,
      secure: secure?(),
      same_site: "Lax",
      path: "/",
      max_age: max(expires_at - System.system_time(:second), 0)
    )
  end

  def put_session(conn, _session), do: conn

  @spec put_panel_session(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_panel_session(conn, %{"token" => token, "expires_at" => expires_at})
      when is_binary(token) and token != "" and is_integer(expires_at) do
    put_resp_cookie(conn, @panel_cookie_name, token,
      http_only: true,
      secure: true,
      same_site: "None",
      extra: "Partitioned",
      path: "/",
      max_age: max(expires_at - System.system_time(:second), 0)
    )
  end

  def put_panel_session(conn, _session), do: conn

  @spec clear_user(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_user(conn) do
    delete_resp_cookie(conn, @cookie_name,
      http_only: true,
      secure: secure?(),
      same_site: "Lax",
      path: "/"
    )
  end

  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn) do
    conn
    |> clear_user()
    |> delete_resp_cookie(@panel_cookie_name,
      http_only: true,
      secure: true,
      same_site: "None",
      extra: "Partitioned",
      path: "/"
    )
  end

  defp secure? do
    Application.get_env(:comma_web, :session_cookie, [])[:secure] != false
  end

  defp normalize_token(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_value), do: nil
end
