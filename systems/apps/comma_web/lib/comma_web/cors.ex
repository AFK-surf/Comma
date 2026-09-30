defmodule CommaWeb.CORS do
  @moduledoc "Explicit-origin CORS policy for Comma browser sessions and bearer clients."

  import Plug.Conn

  @allowed_headers "authorization,content-type,if-none-match,x-comma-session-transport,x-comma-session-lifecycle-version,x-comma-expected-auth-session-id"
  @allowed_methods "GET,POST,PATCH,PUT,DELETE,OPTIONS"
  @exposed_headers "etag"

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      # Public IdP endpoints are never cookie-authenticated, so they get
      # wildcard CORS and skip the first-party origin policy entirely
      # (docs/identity-security.md). Preflights are answered inside.
      CommaWeb.OauthIdpEndpoints.public_path?(conn.request_path) ->
        CommaWeb.OauthIdpEndpoints.put_public_cors(conn)

      # Public Task Share reads take no credentials, so the same holds.
      CommaWeb.TaskShareEndpoints.public_path?(conn.request_path) ->
        CommaWeb.TaskShareEndpoints.put_public_cors(conn)

      true ->
        first_party_call(conn)
    end
  end

  defp first_party_call(conn) do
    {origin, origin_present?} = request_origin(conn)
    allowed? = allowed_origin?(origin)
    web_cookie_origin? = CommaWeb.ClientSurface.web_cookie_origin?(origin)
    admin_cookie_origin? = CommaWeb.ClientSurface.admin_cookie_origin?(origin)
    cookie_mutation? = cookie_mutation?(conn)

    conn =
      if allowed? do
        conn
        |> CommaWeb.ClientSurface.assign_trusted_surface(origin)
        |> put_allowed_headers(origin)
      else
        conn
      end

    cond do
      origin_present? and allowed? and
          CommaWeb.ClientSurface.origin_scope_violation?(origin, conn.request_path) ->
        reject(conn, :origin_path_not_allowed)

      origin_present? and allowed? and not web_cookie_origin? and not admin_cookie_origin? and
          web_cookie_authority_request?(conn) ->
        reject(conn, :web_cookie_origin_not_allowed)

      cookie_mutation? and not allowed? ->
        reject(conn, :origin_not_allowed)

      cookie_mutation? and cross_site?(conn) ->
        reject(conn, :cross_site_request)

      v1_request?(conn) and origin_present? and not allowed? ->
        reject(conn, :origin_not_allowed)

      conn.method == "OPTIONS" and String.starts_with?(conn.request_path, "/v1/") ->
        conn
        |> put_resp_header("access-control-allow-methods", @allowed_methods)
        |> put_resp_header("access-control-allow-headers", @allowed_headers)
        |> put_resp_header("access-control-max-age", "600")
        |> send_resp(204, "")
        |> halt()

      true ->
        conn
    end
  end

  @spec allowed_origin?(String.t() | nil) :: boolean()
  def allowed_origin?(origin), do: CommaWeb.ClientSurface.allowed_web_origin?(origin)

  defp put_allowed_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-expose-headers", @exposed_headers)
    |> put_resp_header("vary", "origin")
  end

  defp v1_request?(conn), do: String.starts_with?(conn.request_path, "/v1/")

  defp request_origin(conn) do
    case get_req_header(conn, "origin") do
      [] -> {nil, false}
      [origin] -> {origin, true}
      _headers -> {nil, true}
    end
  end

  defp cookie_mutation?(conn) do
    v1_request?(conn) and conn.method in ["POST", "PUT", "PATCH", "DELETE"] and
      (CommaWeb.SessionCookie.cookie_transport?(conn) or session_cookie_presented?(conn))
  end

  defp session_cookie_presented?(conn) do
    conn = fetch_cookies(conn)

    is_binary(conn.req_cookies[CommaWeb.SessionCookie.cookie_name()]) or
      is_binary(conn.req_cookies[CommaWeb.SessionCookie.panel_cookie_name()])
  end

  defp web_cookie_authority_request?(conn) do
    get_req_header(conn, "x-comma-session-transport") != [] or
      session_cookie_presented?(conn) or
      requested_header?(conn, "x-comma-session-transport")
  end

  defp requested_header?(conn, expected) do
    conn
    |> get_req_header("access-control-request-headers")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(&(String.downcase(String.trim(&1)) == expected))
  end

  defp cross_site?(conn) do
    case get_req_header(conn, "sec-fetch-site") do
      [] -> false
      [site] -> site not in ["same-origin", "same-site"]
      _headers -> true
    end
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: reason}))
    |> halt()
  end
end
