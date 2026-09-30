defmodule CommaWeb.Auth do
  @moduledoc """
  Comma product cookie/bearer auth plus path-scoped human and ops Admin actors.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {conn, credential} = presented(conn)

    cond do
      conn.request_path in ["/live", "/ready", "/health"] ->
        conn

      # OAuth IdP machine endpoints authenticate inside Boruta (client
      # credentials/PKCE at the token endpoint, bearer access tokens at
      # userinfo) — never via Comma sessions. Checked before the cookie
      # surface so a stray product cookie can never authorize them.
      CommaWeb.OauthIdpEndpoints.public_path?(conn.request_path) ->
        conn

      # The authorize page resolves its own cookie session: its GET is a
      # cross-site top-level navigation (no Origin header), so the
      # ClientSurface origin allowlist cannot apply; the POST enforces
      # same-origin + CSRF inside CommaWeb.OauthIdpConsent.
      CommaWeb.OauthIdpConsent.authorize_path?(conn.request_path) ->
        conn

      telegram_public_path?(conn.request_path) ->
        conn

      # A public Task Share link is its own authority. Checked before the
      # cookie surface so no session is resolved or required.
      CommaWeb.TaskShareEndpoints.public_path?(conn.request_path) ->
        conn

      CommaWeb.ClientSurface.cookie?(conn) ->
        authenticate_cookie_session(conn, credential)

      CommaWeb.ClientSurface.public_auth_path?(conn.request_path) or
          public_billing_path?(conn.request_path) ->
        conn

      credential == :ambiguous ->
        deny(conn)

      CommaWeb.ClientSurface.admin_product_path?(conn.request_path) ->
        if match?({:bearer, token} when is_binary(token), credential) and
             admin_token?(elem(credential, 1)) do
          assign_admin(conn, elem(credential, 1))
        else
          deny(conn)
        end

      true ->
        authenticate_comma_session(conn, credential)
    end
  end

  defp public_billing_path?("/v1/comma/billing/stripe/webhook"), do: true
  defp public_billing_path?("/v1/comma/billing/stripe/checkout/return"), do: true
  defp public_billing_path?("/v1/comma/billing/stripe/checkout/cancel"), do: true
  defp public_billing_path?(_path), do: false

  defp telegram_public_path?("/v1/comma/integrations/telegram/connect/callback"), do: true
  defp telegram_public_path?("/v1/comma/integrations/telegram/webhook"), do: true
  defp telegram_public_path?(_path), do: false

  defp presented(conn) do
    bearer = bearer_token(conn)
    {conn, cookie} = CommaWeb.SessionCookie.fetch_browser(conn)

    credential =
      case {bearer, cookie} do
        {token, nil} when is_binary(token) -> {:bearer, token}
        {nil, token} when is_binary(token) -> {:cookie, token}
        {nil, nil} -> :missing
        {_bearer, _cookie} -> :ambiguous
      end

    {conn, credential}
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> normalize_token(token)
      [token] -> normalize_token(token)
      _headers -> nil
    end
  end

  defp authenticate_comma_session(conn, {:bearer, token})
       when is_binary(token) and token != "" do
    case Comma.Accounts.validate_session(token) do
      {:ok, _user, %{"session_source" => "channel_task_panel"}} ->
        deny(conn)

      {:ok, user, session} ->
        conn
        |> assign(:auth_role, :comma_user)
        |> assign(:auth_transport, :bearer)
        |> assign(:auth_token, token)
        |> assign(:comma_user, user)
        |> assign(:comma_session, session)

      {:error, _reason} ->
        deny(conn)
    end
  end

  defp authenticate_comma_session(conn, _credential), do: deny(conn)

  defp authenticate_cookie_session(conn, credential) do
    cond do
      get_req_header(conn, "authorization") != [] ->
        deny_web(conn)

      credential == :ambiguous or match?({:bearer, _token}, credential) ->
        deny_web(conn)

      conn.request_path == "/v1/comma/auth/telegram-miniapp" ->
        conn

      CommaWeb.ClientSurface.public_auth_path?(conn.request_path) ->
        authorize_web_auth_request(conn, credential)

      true ->
        authorize_web_protected_request(conn, credential)
    end
  end

  defp authorize_web_auth_request(conn, credential) do
    case resolve_web_cookie(credential) do
      {:ok, _token, _user, %{"session_source" => "channel_task_panel"}} ->
        CommaWeb.SessionCookie.clear(conn)

      {:ok, _token, _user, _session} ->
        session_changed(conn)

      {:error, _reason} ->
        conn
    end
  end

  defp authorize_web_protected_request(conn, credential) do
    expectation = conn.assigns[:comma_session_lifecycle_expectation]

    case {expectation, resolve_web_cookie(credential)} do
      {:unknown, {:ok, token, user, session}} ->
        accept_web_session(conn, token, user, session)

      {:unknown, {:error, _reason}} ->
        deny_web(conn, clear_invalid_cookie?(conn, credential))

      {:none, {:ok, _token, _user, _session}} ->
        session_changed(conn)

      {:none, {:error, _reason}} ->
        deny_web(conn, clear_invalid_cookie?(conn, credential))

      {{:session_id, expected_id}, {:ok, token, user, %{"id" => expected_id} = session}} ->
        accept_web_session(conn, token, user, session)

      {{:session_id, _expected_id}, {:ok, _token, _user, _session}} ->
        session_changed(conn)

      {{:session_id, _expected_id}, {:error, _reason}} ->
        deny_web(conn, clear_invalid_cookie?(conn, credential))

      {_expectation, _resolution} ->
        deny_web(conn)
    end
  end

  defp resolve_web_cookie({:cookie, token}) when is_binary(token) and token != "" do
    case Comma.Accounts.resolve_session(token) do
      {:ok, user, session} -> {:ok, token, user, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_web_cookie(_credential), do: {:error, :not_found}

  defp accept_web_session(conn, token, user, session) do
    if conn.assigns[:comma_cookie_kind] == :panel and
         session["session_source"] != "channel_task_panel" do
      deny_web(conn, clear_invalid_cookie?(conn, {:cookie, token}))
    else
      case CommaWeb.TelegramMiniAppAuth.authorize_panel_request(conn, user, session) do
        :ok -> accept_authorized_web_session(conn, token, user, session)
        {:error, _reason} -> deny_web(conn, clear_invalid_cookie?(conn, {:cookie, token}))
      end
    end
  end

  defp accept_authorized_web_session(conn, token, user, session) do
    :ok = Comma.Accounts.touch_session(session)

    conn =
      conn
      |> assign(:auth_role, :comma_user)
      |> assign(:auth_transport, :cookie)
      |> assign(:auth_token, token)
      |> assign(:comma_user, user)
      |> assign(:comma_session, session)

    if CommaWeb.ClientSurface.admin_cookie?(conn) and Comma.Admin.admin_user?(user) and
         session["restricted"] != true do
      assign(conn, :admin_actor, :comma_user)
    else
      conn
    end
  end

  defp clear_invalid_cookie?(conn, {:cookie, _token}) do
    conn.request_path in ["/v1/comma/auth/session", "/v1/comma/auth/logout"]
  end

  defp clear_invalid_cookie?(_conn, _credential), do: false

  defp assign_admin(conn, token) do
    conn
    |> assign(:auth_role, :admin)
    |> assign(:auth_token, token)
    |> assign(:admin_actor, :ops)
  end

  defp admin_token?(token) when is_binary(token) and token != "" do
    case admin_token() do
      configured when is_binary(configured) and configured != "" ->
        Plug.Crypto.secure_compare(
          :crypto.hash(:sha256, token),
          :crypto.hash(:sha256, configured)
        )

      _ ->
        false
    end
  end

  defp admin_token?(_token), do: false

  defp normalize_token(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_value), do: nil

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end

  defp deny_web(conn, clear_cookie? \\ false)

  defp deny_web(conn, true), do: conn |> CommaWeb.SessionCookie.clear() |> deny_web(false)

  defp deny_web(conn, false) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> deny()
  end

  defp session_changed(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(409, Jason.encode!(%{error: "session_changed"}))
    |> halt()
  end

  defp admin_token do
    Application.get_env(:comma_web, :api_token) ||
      Application.get_env(:salix_web, :api_token) ||
      config_json_admin_token()
  end

  defp config_json_admin_token do
    with path when is_binary(path) and path != "" <- System.get_env("SALIX_CONFIG_PATH"),
         {:ok, config} <- SalixStore.ConfigJson.load(path) do
      SalixStore.ConfigJson.string(config, ~w(web api_token))
    else
      _ -> nil
    end
  end
end
