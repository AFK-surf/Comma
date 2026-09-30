defmodule BridgeForTeamsWeb.Dashboard.AuthController do
  @moduledoc """
  Dashboard auth actions driving the existing OIDC SSO flow (design §7) via
  `BridgeForTeams.Auth`. These actions do browser redirects and set the SIGNED
  dashboard session cookie with the opaque `BridgeForTeams.Auth` session token.

  Flow:

    * `GET  /login`               — render the login page (enter an org slug).
    * `POST /auth/:org_slug/start`— build the IdP authorization-code+PKCE redirect,
                                     stash state/verifier in the session, redirect.
    * `GET  /auth/callback`       — exchange the code, provision, create a session,
                                     store the token in the signed cookie, redirect /.
    * `GET  /auth/recovery`       — redeem a system-admin-generated one-time link,
                                     create a session, redirect /.
    * `GET  /auth/email`          — email magic-link form (fallback for orgs
                                     without an SSO connection).
    * `POST /auth/email/send`     — issue + email the one-time sign-in link
                                     (always the same neutral response).
    * `GET  /auth/email/verify`   — redeem the emailed link, create a session,
                                     store the token in the signed cookie, redirect /.
    * `DELETE /logout`            — revoke the session and clear the cookie.

  Tests/dev never need a live IdP: the OIDC Fake is injected, and the
  `BridgeForTeamsWeb.Dashboard.LiveCase` login helper creates a real session
  directly via `BridgeForTeams.Auth.Sessions`.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.{AccountRecovery, Accounts, Auth, LoginLinks, OrgCreationInvites, Orgs}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  @doc """
  GET /dev/login — dev/e2e-ONLY login bypass. Creates a real session for an
  existing user (by email) without driving an external IdP, so the Playwright
  suite can authenticate. Disabled by default: returns 404 unless the
  `:dev_login` flag is set (non-prod + config.json
  `bridge_for_teams.dashboard.dev_login=true`, wired in config/runtime.exs).
  Never enabled in prod.
  """
  def dev_login(conn, params) do
    if Application.get_env(:bridge_for_teams_web, :dev_login, false) do
      email = params["email"] || "e2e@example.com"

      with {:ok, user} <- Accounts.get_user_by_email(email),
           {:ok, %{token: token}} <- Sessions.create(user, []) do
        conn
        |> DashAuth.put_token_in_session(token)
        |> redirect(
          to:
            DashAuth.local_return_to(params["to"]) ||
              DashAuth.local_return_to(params["return_to"]) || "/"
        )
      else
        _ -> conn |> send_resp(404, "not found") |> halt()
      end
    else
      conn |> send_resp(404, "not found") |> halt()
    end
  end

  @doc "GET /login — show the login form (org slug -> OIDC)."
  def login(conn, params) do
    return_to = DashAuth.local_return_to(params["return_to"])

    if conn.assigns[:current_user] do
      redirect(conn, to: return_to || "/")
    else
      org = login_org(params)

      render(conn, :login,
        error: Phoenix.Flash.get(conn.assigns.flash, :error),
        layout: false,
        org: org,
        org_slug: params["o"],
        shortcuts_disabled: login_shortcuts_disabled?(params),
        return_to: return_to
      )
    end
  end

  @doc "GET /signup — show the invite-code org/account creation form."
  def signup(conn, params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render_signup(conn, params)
    end
  end

  @doc "POST /signup — redeem an invite code, create org + owner account, and log in."
  def create_from_invite(conn, params) do
    signup = params["signup"] || params

    with {:ok, %{user: user}} <-
           OrgCreationInvites.redeem_invite_code(signup["invite_code"], signup,
             audit: true,
             request_id: request_id(conn)
           ),
         {:ok, %{token: token}} <- Sessions.create(user, []) do
      conn
      |> DashAuth.put_token_in_session(token)
      |> put_flash(:info, Gettext.gettext(BridgeForTeamsWeb.Gettext, "Organization created."))
      |> redirect(to: "/")
    else
      _ ->
        conn
        |> render_signup(
          signup,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Invite code or signup details could not be used."
          )
        )
    end
  end

  @doc "POST /auth/:org_slug/start — kick off the OIDC authorization-code+PKCE flow."
  def start(conn, %{"org_slug" => slug}) do
    request_id = request_id(conn)
    return_to = DashAuth.local_return_to(conn.params["return_to"])

    case Orgs.get_org_by_slug(slug) do
      {:ok, org} ->
        case Auth.authorize_url(org.id, redirect_uri: redirect_uri(conn)) do
          {:ok, %{url: url, state: state, code_verifier: verifier}} ->
            conn
            |> put_session(:oidc_org_id, org.id)
            |> put_session(:oidc_state, state)
            |> put_session(:oidc_code_verifier, verifier)
            |> put_oidc_return_to(return_to)
            |> redirect(external: url)

          {:error, reason} ->
            Auth.record_sso_login_failure(org.id, reason,
              request_id: request_id,
              stage: "authorize"
            )

            case reason do
              :no_sso_connection -> email_login_fallback(conn, slug, return_to)
              _other -> sso_not_configured(conn)
            end
        end

      {:error, _reason} ->
        # Unknown slug takes the same fallback as a known SSO-less org, so the
        # response still does not reveal whether the org exists; the magic-link
        # endpoint only sends mail for real SSO-less org members.
        email_login_fallback(conn, slug, return_to)
    end
  end

  # SSO-less orgs fall back to the email magic link when delivery is
  # configured; otherwise keep the historical ambiguous error.
  defp email_login_fallback(conn, slug, return_to) do
    if LoginLinks.enabled?() do
      query =
        %{"o" => slug}
        |> maybe_put_query("return_to", return_to)
        |> URI.encode_query()

      redirect(conn, to: "/auth/email?" <> query)
    else
      sso_not_configured(conn)
    end
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  @doc "GET /auth/email — show the magic-link email form (SSO-less orgs)."
  def email_login(conn, params) do
    cond do
      conn.assigns[:current_user] ->
        redirect(conn, to: DashAuth.local_return_to(params["return_to"]) || "/")

      not LoginLinks.enabled?() ->
        sso_not_configured(conn)

      true ->
        render(conn, :email_login,
          layout: false,
          error: Phoenix.Flash.get(conn.assigns.flash, :error),
          info: Phoenix.Flash.get(conn.assigns.flash, :info),
          org_slug: String.trim(to_string(params["o"] || "")),
          return_to: DashAuth.local_return_to(params["return_to"])
        )
    end
  end

  @doc """
  POST /auth/email/send — issue the magic link. Always answers with the same
  neutral message, whatever matched; `BridgeForTeams.LoginLinks` only mails
  active members of a real org without SSO.
  """
  def send_login_link(conn, params) do
    slug = String.trim(to_string(params["org_slug"] || ""))
    email = String.trim(to_string(params["email"] || ""))
    return_to = DashAuth.local_return_to(params["return_to"])

    :ok =
      LoginLinks.request_login_link(slug, email,
        base_url: public_base_url(conn),
        remote_ip: remote_ip(conn),
        request_id: request_id(conn)
      )

    query = %{"o" => slug} |> maybe_put_query("return_to", return_to) |> URI.encode_query()

    conn
    |> put_flash(
      :info,
      Gettext.gettext(
        BridgeForTeamsWeb.Gettext,
        "If that email matches a member of this organization, we sent a sign-in link. It expires in 15 minutes."
      )
    )
    |> redirect(to: "/auth/email?" <> query)
  end

  @doc "GET /auth/email/verify — redeem a one-time emailed sign-in link."
  def verify_login_link(conn, params) do
    with token when is_binary(token) and token != "" <- params["token"],
         {:ok, %{token: session_token}} <-
           LoginLinks.redeem_login_token_for_session(token, request_id: request_id(conn)) do
      conn
      |> DashAuth.put_token_in_session(session_token)
      |> redirect(to: "/")
    else
      _ ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Sign-in link is invalid, expired, or already used."
          )
        )
        |> redirect(to: "/login")
    end
  end

  @doc "GET /auth/callback — exchange the code, provision, set the session cookie."
  def callback(conn, params) do
    org_id = get_session(conn, :oidc_org_id)
    verifier = get_session(conn, :oidc_code_verifier)
    expected_state = get_session(conn, :oidc_state)
    return_to = DashAuth.local_return_to(get_session(conn, :oidc_return_to))
    request_id = request_id(conn)
    state_result = verify_oidc_state(expected_state, params["state"] || params[:state])

    cond do
      not is_binary(org_id) ->
        sign_in_failed(conn)

      match?({:error, _reason}, state_result) ->
        {:error, reason} = state_result

        Auth.record_sso_login_failure(org_id, reason,
          request_id: request_id,
          stage: "state"
        )

        sign_in_failed(conn)

      true ->
        case Auth.callback(org_id, params,
               code_verifier: verifier,
               redirect_uri: redirect_uri(conn),
               request_id: request_id
             ) do
          {:ok, %{token: token, user: user}} ->
            finish_login(conn, token, user, org_id, return_to)

          {:error, _reason} ->
            sign_in_failed(conn)
        end
    end
  end

  @doc "GET /auth/recovery — redeem a one-time shell-generated recovery link."
  def recover(conn, params) do
    with token when is_binary(token) and token != "" <- params["token"],
         {:ok, %{token: session_token}} <-
           AccountRecovery.redeem_recovery_token_for_session(token) do
      conn
      |> DashAuth.put_token_in_session(session_token)
      |> put_flash(
        :info,
        Gettext.gettext(BridgeForTeamsWeb.Gettext, "Signed in with recovery link.")
      )
      |> redirect(to: "/")
    else
      _ ->
        conn
        |> put_flash(
          :error,
          Gettext.gettext(
            BridgeForTeamsWeb.Gettext,
            "Recovery link is invalid, expired, or already used."
          )
        )
        |> redirect(to: "/login")
    end
  end

  defp verify_oidc_state(expected, returned) when is_binary(expected) and is_binary(returned) do
    if byte_size(expected) == byte_size(returned) and
         Plug.Crypto.secure_compare(expected, returned) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp verify_oidc_state(_expected, _returned), do: {:error, :invalid_state}

  defp clear_oidc_session(conn) do
    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_code_verifier)
    |> delete_session(:oidc_org_id)
    |> delete_session(:oidc_return_to)
  end

  defp put_oidc_return_to(conn, nil), do: delete_session(conn, :oidc_return_to)
  defp put_oidc_return_to(conn, return_to), do: put_session(conn, :oidc_return_to, return_to)

  defp sign_in_failed(conn) do
    conn
    |> clear_oidc_session()
    |> put_flash(
      :error,
      Gettext.gettext(BridgeForTeamsWeb.Gettext, "Sign-in failed. Please try again.")
    )
    |> redirect(to: "/login")
  end

  defp sso_not_configured(conn) do
    conn
    |> put_flash(
      :error,
      Gettext.gettext(
        BridgeForTeamsWeb.Gettext,
        "Unknown organization or SSO not configured."
      )
    )
    |> redirect(to: "/login")
  end

  @doc "DELETE /logout — revoke the session and clear the cookie."
  def logout(conn, _params) do
    if token = get_session(conn, DashAuth.session_token_key()), do: Auth.logout(token)

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  defp redirect_uri(conn), do: public_base_url(conn) <> "/auth/callback"

  # Configured public base URL when available; falling back to the request
  # host keeps dev/e2e working but is why config should win in production
  # (emailed links must not trust the Host header).
  defp public_base_url(conn) do
    case Application.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/")
      _ -> "#{conn.scheme}://#{conn.host}:#{conn.port}"
    end
  end

  defp remote_ip(conn) do
    case :inet.ntoa(conn.remote_ip) do
      {:error, _} -> ""
      chars -> to_string(chars)
    end
  end

  defp request_id(_conn) do
    case Logger.metadata()[:request_id] do
      value when is_binary(value) and value != "" -> value
      _ -> Ecto.UUID.generate()
    end
  end

  defp login_org(%{"o" => slug}) when is_binary(slug) and slug != "" do
    case Orgs.get_org_by_slug(slug) do
      {:ok, org} -> org
      {:error, :not_found} -> nil
    end
  end

  defp login_org(_params), do: nil

  defp login_shortcuts_disabled?(%{"o" => slug}) when is_binary(slug),
    do: String.trim(slug) != ""

  defp login_shortcuts_disabled?(_params), do: false

  defp finish_login(conn, token, _user, _org_id, return_to) when is_binary(return_to) do
    conn
    |> clear_oidc_session()
    |> DashAuth.put_token_in_session(token)
    |> redirect(to: return_to)
  end

  defp finish_login(conn, token, user, org_id, _return_to) do
    conn =
      conn
      |> clear_oidc_session()
      |> DashAuth.put_token_in_session(token)

    case login_orgs(user, org_id) do
      [_ | _] = orgs -> render(conn, :remember_orgs, layout: false, orgs: orgs, next: "/")
      {:error, :not_found} -> redirect(conn, to: "/")
    end
  end

  defp login_orgs(%{id: user_id}, fallback_org_id) when is_binary(user_id) do
    case Orgs.list_orgs_with_sso_for_user(user_id) do
      [_ | _] = orgs -> orgs |> prioritize_org(fallback_org_id) |> Enum.map(&login_org_json/1)
      [] -> fallback_login_orgs(fallback_org_id)
    end
  end

  defp login_orgs(_user, fallback_org_id), do: fallback_login_orgs(fallback_org_id)

  defp fallback_login_orgs(org_id) do
    case Orgs.get_org(org_id) do
      {:ok, org} -> [login_org_json(org)]
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp prioritize_org(orgs, org_id) do
    Enum.sort_by(orgs, fn org ->
      if org.id == org_id, do: {0, org.name, org.slug}, else: {1, org.name, org.slug}
    end)
  end

  defp login_org_json(org) do
    %{slug: org.slug, name: org.name}
    |> maybe_put_org_icon(org.icon)
  end

  defp maybe_put_org_icon(payload, icon) when is_binary(icon) and icon != "",
    do: Map.put(payload, :icon, icon)

  defp maybe_put_org_icon(payload, _icon), do: payload

  defp render_signup(conn, params, error \\ nil) do
    signup = signup_attrs(params)

    render(conn, :signup,
      error: error,
      layout: false,
      signup: signup
    )
  end

  defp signup_attrs(params) do
    invite_code = params["invite_code"] || params["code"]
    invite = invite_for_signup(invite_code)

    %{
      "invite_code" => invite_code,
      "email" => params["email"],
      "name" => params["name"],
      "org_name" => invite && invite.org_name,
      "org_slug" => invite && invite.org_slug
    }
  end

  defp invite_for_signup(code) when is_binary(code) and code != "" do
    case OrgCreationInvites.get_redeemable_invite(code) do
      {:ok, invite} -> invite
      {:error, _reason} -> nil
    end
  end

  defp invite_for_signup(_code), do: nil
end
