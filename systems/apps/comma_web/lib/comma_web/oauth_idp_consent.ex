defmodule CommaWeb.OauthIdpConsent do
  @moduledoc """
  Browser side of the Comma OAuth/OIDC identity provider
  (docs/identity-security.md–§6.4, PR 5/10): `GET /oauth2/authorize`
  renders the consent page, `POST /oauth2/authorize` settles it.

  This is comma_web's first — and only — HTML surface, so its contract is
  deliberately rigid:

    * classic EEx does **not** auto-escape; every dynamic value is
      HTML-escaped in `render_consent/2` / `render_error/2` before it
      reaches a template, and the templates carry the same warning;
    * responses ship a deny-all CSP (`default-src 'none'`) plus
      `X-Frame-Options: DENY` — the page needs no scripts, images, or
      frames, and inline styles cannot exfiltrate with no permitted
      destinations;
    * the consent POST trusts only the one-time server-side handle
      (`Comma.OauthIdp.AuthorizeRequests`): resubmitted query parameters
      are ignored, the CSRF token lives and dies with the handle, and
      the request must present a same-origin `Origin` header;
    * a redirect back to the client happens only through a
      Boruta-validated `redirect_uri` — every other failure renders a
      terminal page with **no** links or fallback redirects (§6.4).

  Session authentication is cookie-only and deliberately does not go
  through the `ClientSurface` origin allowlist: the authorize GET is a
  cross-site top-level navigation (that is the OAuth flow), which
  `SameSite=Lax` permits and which never carries an `Origin` header.
  `CommaWeb.Auth` scopes this exemption to exactly this path.
  """

  import Plug.Conn

  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.ResourceOwner
  alias Comma.OauthIdp.AuthorizeRequests

  require EEx

  @authorize_path "/oauth2/authorize"

  @csp "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"

  @client_name_limit 40

  @external_resource Path.expand("../../priv/oauth_idp/consent.html.eex", __DIR__)
  @external_resource Path.expand("../../priv/oauth_idp/oauth_error.html.eex", __DIR__)

  EEx.function_from_file(
    :defp,
    :consent_template,
    Path.expand("../../priv/oauth_idp/consent.html.eex", __DIR__),
    [:assigns]
  )

  EEx.function_from_file(
    :defp,
    :error_template,
    Path.expand("../../priv/oauth_idp/oauth_error.html.eex", __DIR__),
    [:assigns]
  )

  @spec authorize_path?(String.t()) :: boolean()
  def authorize_path?(path), do: path == @authorize_path

  ## GET /oauth2/authorize

  @spec authorize(Plug.Conn.t()) :: Plug.Conn.t()
  def authorize(conn) do
    case {conn.query_params["resume"], current_user(conn)} do
      {nil, {:ok, user}} -> preauthorize(conn, user)
      {nil, :forbidden_session} -> render_forbidden_session(conn)
      {nil, :error} -> stash_and_redirect_to_login(conn)
      {handle, {:ok, user}} when is_binary(handle) -> resume(conn, user, handle)
      {handle, :forbidden_session} when is_binary(handle) -> render_forbidden_session(conn)
      # Arriving at resume still logged out means the login round trip
      # failed; redirecting to login again would loop, so this is a
      # terminal page (RFC §5).
      {handle, :error} when is_binary(handle) -> render_login_required(conn)
    end
  end

  ## Logged-out path (RFC §5): stash the validated request server-side,
  ## send the browser to the frontend login page with only an opaque
  ## handle, and rebuild the request from storage when the user returns.
  ##
  ## Contract with the frontend login page (PR 7): the login URL is
  ## `{web_cookie_origin}/login?oauth_handle={handle}`; after the
  ## session cookie is established the frontend navigates (top-level
  ## GET) to `{issuer}/oauth2/authorize?resume={handle}`.

  defp stash_and_redirect_to_login(conn) do
    # The full request is validated before anything is stored or any
    # redirect is issued: an invalid client, redirect_uri, scope, nonce,
    # or PKCE parameter must never reach the stash or the login round
    # trip. Boruta orders its checks Client -> ResourceOwner -> Scope ->
    # Nonce -> PKCE, so an unauthenticated (nil-sub) principal would
    # short-circuit before the request-shape checks ran — instead the
    # validation pass runs with a preflight probe principal that cannot
    # match any real user, purely so every check executes. Nothing about
    # the probe is persisted, resolved, or issued: on success the only
    # outcomes are an error settled onto the vouched redirect or a stash
    # of the raw query parameters.
    case Boruta.Oauth.preauthorize(conn, preflight_resource_owner(), __MODULE__) do
      {:preauthorize_success, _authorization} ->
        # The request is fully valid; the user is simply not signed in.
        cond do
          combines_none_prompt?(conn) ->
            settle_vouched_error(
              conn,
              :invalid_request,
              "The prompt parameter must not combine none with other values."
            )

          conn.query_params["prompt"] == "none" ->
            # OIDC Core §3.1.2.1/§3.1.2.6: silent authentication with no
            # signed-in user answers login_required on the vouched
            # redirect — never authentication UI.
            settle_vouched_error(conn, :login_required, "User is not logged in.")

          true ->
            case check_fixed_scope(conn.query_params["scope"]) do
              :ok -> stash_and_redirect(conn)
              :invalid_scope -> reject_scope(conn)
            end
        end

      {:preauthorize_error, %Error{} = error} ->
        # Boruta formatted the error itself: onto the vouched redirect
        # when the client and redirect_uri validated, a terminal page
        # otherwise. Same settlement as the logged-in path.
        settle_oauth_error(conn, error)
    end
  end

  defp stash_and_redirect(conn) do
    request =
      AuthorizeRequests.create!(%{
        user_id: nil,
        client_id: conn.query_params["client_id"],
        redirect_uri: conn.query_params["redirect_uri"],
        scope: conn.query_params["scope"],
        state: conn.query_params["state"],
        nonce: conn.query_params["nonce"],
        code_challenge: conn.query_params["code_challenge"],
        code_challenge_method: conn.query_params["code_challenge_method"]
      })

    conn
    |> CommaWeb.OauthIdpEndpoints.put_outcome(:login_redirect)
    |> redirect_external(login_url(request.id))
  end

  defp login_url(handle) do
    origin = Application.fetch_env!(:comma_web, :web_cookie_origin)
    origin <> "/login?" <> URI.encode_query(%{"oauth_handle" => handle})
  end

  defp resume(conn, user, handle) do
    case AuthorizeRequests.consume_anonymous(handle) do
      {:ok, request} ->
        # Same principle as approve/3: storage is the only input Boruta
        # sees; whatever query string rode along on the resume GET is
        # discarded. response_type is not stored because v1 admits only
        # "code" (enforced by the pre-stash validation).
        params = %{
          "response_type" => "code",
          "client_id" => request.client_id,
          "redirect_uri" => request.redirect_uri,
          "scope" => request.scope,
          "state" => request.state,
          "nonce" => request.nonce,
          "code_challenge" => request.code_challenge,
          "code_challenge_method" => request.code_challenge_method
        }

        # Full revalidation against the live client record: the client
        # may have been disabled or rewritten between stash and resume.
        preauthorize(%{conn | query_params: params}, user)

      :error ->
        render_error(conn, :expired)
    end
  end

  # A principal for the logged-out validation pass whose only job is to
  # let every request-shape check run. The URN can never collide with a
  # real `usr_*` subject; `ResourceOwners.get_by/1` is never called for
  # it (Boruta validates the struct it is handed), `authorized_scopes/1`
  # returns [] for every principal, and preauthorization issues nothing.
  defp preflight_resource_owner do
    %ResourceOwner{sub: "urn:comma:oauth-idp:preflight"}
  end

  # OIDC Core §3.1.2.1: `prompt=none` must not be combined with any
  # other value. Exact "none" never reaches the callers of this check:
  # logged out it becomes Boruta's login_required, logged in it becomes
  # consent_required (v1 always requires consent, D8).
  defp combines_none_prompt?(conn) do
    case conn.query_params["prompt"] do
      prompt when is_binary(prompt) ->
        values = String.split(prompt)
        "none" in values and length(values) > 1

      _absent ->
        false
    end
  end

  # Settles a policy error onto a redirect_uri that Boruta has already
  # vouched for on this request (never onto raw caller input).
  defp settle_vouched_error(conn, error_code, description) do
    settle_oauth_error(conn, %Error{
      status: :bad_request,
      error: error_code,
      error_description: description,
      format: :query,
      redirect_uri: conn.query_params["redirect_uri"],
      state: conn.query_params["state"]
    })
  end

  defp preauthorize(conn, user) do
    case Boruta.Oauth.preauthorize(conn, resource_owner(user), __MODULE__) do
      {:preauthorize_success, authorization} ->
        cond do
          combines_none_prompt?(conn) ->
            settle_vouched_error(
              conn,
              :invalid_request,
              "The prompt parameter must not combine none with other values."
            )

          conn.query_params["prompt"] == "none" ->
            # v1 requires consent on every authorization (decision D8),
            # so a silent request can never be satisfied even for a
            # signed-in user: OIDC Core §3.1.2.1 mandates an error
            # instead of any consent UI.
            settle_vouched_error(
              conn,
              :consent_required,
              "Comma requires consent on every authorization."
            )

          true ->
            case check_fixed_scope(conn.query_params["scope"]) do
              :ok -> store_and_render(conn, user, authorization)
              :invalid_scope -> reject_scope(conn)
            end
        end

      {:preauthorize_error, %Error{} = error} ->
        settle_oauth_error(conn, error)
    end
  end

  defp store_and_render(conn, user, authorization) do
    request =
      AuthorizeRequests.create!(%{
        user_id: user["id"],
        client_id: authorization.client.id,
        redirect_uri: conn.query_params["redirect_uri"],
        scope: authorization.scope,
        state: conn.query_params["state"],
        nonce: conn.query_params["nonce"],
        code_challenge: conn.query_params["code_challenge"],
        code_challenge_method: conn.query_params["code_challenge_method"]
      })

    render_consent(conn, %{
      client_name: client_display_name(authorization.client),
      user: user,
      redirect_uri: request.redirect_uri,
      redirect_host: URI.parse(request.redirect_uri).host,
      handle: request.id,
      csrf_token: request.csrf_token
    })
  end

  # v1 fixes the scope set (RFC §1): order-insensitive equality with
  # exactly {openid, email, profile}. Anything else — missing, subset,
  # superset, or unknown — is invalid_scope. Enforced before any state
  # is stored, and only after Boruta vouched for the redirect_uri, so
  # the spec error can go back to the app.
  @fixed_scope_set MapSet.new(["openid", "email", "profile"])

  defp check_fixed_scope(scope) when is_binary(scope) do
    requested = scope |> String.split(" ", trim: true) |> MapSet.new()
    if MapSet.equal?(requested, @fixed_scope_set), do: :ok, else: :invalid_scope
  end

  defp check_fixed_scope(_missing), do: :invalid_scope

  defp reject_scope(conn) do
    params =
      %{
        "error" => "invalid_scope",
        "error_description" => "This provider requires exactly: openid email profile."
      }
      |> put_state(conn.query_params["state"])

    conn
    |> CommaWeb.OauthIdpEndpoints.put_outcome(:rejected)
    |> redirect_external(merge_query(conn.query_params["redirect_uri"], params))
  end

  @doc false
  def preauthorize_success(_conn, authorization), do: {:preauthorize_success, authorization}
  @doc false
  def preauthorize_error(_conn, error), do: {:preauthorize_error, error}

  ## POST /oauth2/authorize

  @spec decide(Plug.Conn.t()) :: Plug.Conn.t()
  def decide(conn) do
    with {:ok, user} <- current_user(conn),
         :ok <- require_same_origin(conn),
         {:ok, request} <- consume_request(conn, user) do
      case conn.body_params["decision"] do
        "approve" -> approve(conn, user, request)
        _deny -> deny(conn, request)
      end
    else
      :error ->
        render_login_required(conn)

      :forbidden_session ->
        render_forbidden_session(conn)

      :cross_origin ->
        render_error(conn, :invalid)

      :bad_handle ->
        render_error(conn, :expired)

      :bad_csrf ->
        # The handle is already burned by the consume; a wrong token is
        # either an attack or a corrupted form — never redirect.
        render_error(conn, :invalid)
    end
  end

  defp consume_request(conn, user) do
    handle = conn.body_params["handle"]
    csrf = conn.body_params["_csrf_token"]

    with true <- is_binary(handle) and is_binary(csrf),
         {:ok, request} <- AuthorizeRequests.consume(handle, user["id"]) do
      if Plug.Crypto.secure_compare(csrf, request.csrf_token) do
        {:ok, request}
      else
        :bad_csrf
      end
    else
      _missing_or_consumed -> :bad_handle
    end
  end

  defp approve(conn, user, request) do
    # The stored, validated parameters are the only input Boruta sees;
    # whatever query string rode along on the POST is discarded.
    authorize_conn = %{
      conn
      | query_params: %{
          "response_type" => "code",
          "client_id" => request.client_id,
          "redirect_uri" => request.redirect_uri,
          "scope" => request.scope,
          "state" => request.state,
          "nonce" => request.nonce,
          "code_challenge" => request.code_challenge,
          "code_challenge_method" => request.code_challenge_method
        }
    }

    case Boruta.Oauth.authorize(authorize_conn, resource_owner(user), __MODULE__) do
      {:authorize_success, %AuthorizeResponse{} = response} ->
        conn
        |> CommaWeb.OauthIdpEndpoints.put_outcome(:ok)
        |> redirect_external(AuthorizeResponse.redirect_to_url(response))

      {:authorize_error, %Error{} = error} ->
        settle_oauth_error(conn, error)
    end
  end

  @doc false
  def authorize_success(_conn, response), do: {:authorize_success, response}
  @doc false
  def authorize_error(_conn, error), do: {:authorize_error, error}

  defp deny(conn, request) do
    params =
      %{"error" => "access_denied", "error_description" => "The user denied the request."}
      |> put_state(request.state)

    conn
    |> CommaWeb.OauthIdpEndpoints.put_outcome(:rejected)
    |> redirect_external(merge_query(request.redirect_uri, params))
  end

  ## Error settlement: redirect only when Boruta vouched for the URI

  defp settle_oauth_error(conn, %Error{format: format, redirect_uri: redirect_uri} = error)
       when format in [:query, :fragment] and is_binary(redirect_uri) do
    params =
      %{"error" => to_string(error.error), "error_description" => error.error_description}
      |> put_state(error.state)

    url =
      case format do
        :query -> merge_query(redirect_uri, params)
        :fragment -> redirect_uri <> "#" <> URI.encode_query(params)
      end

    conn
    |> CommaWeb.OauthIdpEndpoints.put_outcome(:rejected)
    |> redirect_external(url)
  end

  defp settle_oauth_error(conn, %Error{} = error) do
    # No trustworthy redirect target (unknown client, tampered
    # redirect_uri, ...): terminal page, no links (§6.4). The client
    # name is never rendered on this path.
    render_error(conn, :invalid, error_code: to_string(error.error))
  end

  defp put_state(params, nil), do: params
  defp put_state(params, state), do: Map.put(params, "state", state)

  defp merge_query(url, params) do
    uri = URI.parse(url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(params)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  defp redirect_external(conn, url) do
    conn
    |> put_security_headers()
    |> put_resp_header("location", url)
    |> send_resp(302, "")
  end

  ## Session (cookie-only; see moduledoc for why no origin allowlist)

  defp current_user(conn) do
    {_conn, token} = CommaWeb.SessionCookie.fetch(conn)

    with true <- is_binary(token),
         {:ok, user, session} <- Comma.Accounts.validate_session(token) do
      # Issuing an external identity assertion is a first-person act.
      # Restricted support sessions are resource/interaction-scoped
      # capabilities, and ops-issued sessions act on a user's behalf —
      # neither may sign the user's identity over to a third party, so
      # only ordinary user_login sessions qualify (stricter than the
      # bare restricted check on purpose).
      # A guest has only a placeholder email, so it has no identity to assert.
      if session["restricted"] == true or session["session_source"] != "user_login" or
           user["kind"] == "guest" do
        :forbidden_session
      else
        {:ok, user}
      end
    else
      _missing_or_invalid -> :error
    end
  end

  defp require_same_origin(conn) do
    origin_ok? =
      case get_req_header(conn, "origin") do
        [origin] -> origin == issuer_origin()
        _missing_or_multiple -> false
      end

    fetch_site_ok? =
      case get_req_header(conn, "sec-fetch-site") do
        [] -> true
        ["same-origin"] -> true
        _cross_site -> false
      end

    if origin_ok? and fetch_site_ok?, do: :ok, else: :cross_origin
  end

  defp issuer_origin, do: Boruta.Config.issuer()

  defp resource_owner(user) do
    %ResourceOwner{sub: user["id"], username: user["email"]}
  end

  ## Rendering — the escape boundary

  defp render_consent(conn, assigns) do
    user = assigns.user
    client_name = assigns.client_name

    html =
      consent_template(%{
        client_name: escape(client_name),
        client_initial: escape(initial(client_name)),
        user_name: escape(user["name"] || "Comma user"),
        user_initial: escape(initial(user["name"] || user["email"] || "?")),
        user_email: escape(user["email"] || ""),
        redirect_host: escape(assigns.redirect_host || ""),
        handle: escape(assigns.handle),
        csrf_token: escape(assigns.csrf_token)
      })

    send_html(conn, 200, html, consent_csp(assigns.redirect_uri))
  end

  defp render_forbidden_session(conn) do
    render_error(conn, :invalid,
      title: "This session can’t authorize apps",
      body:
        "Signing in to another app requires a regular Comma login session. Sign in to Comma yourself, then start again from the app.",
      error_code: "restricted_session",
      status: 403
    )
  end

  defp render_login_required(conn) do
    render_error(conn, :error,
      title: "Sign in to Comma first",
      body:
        "You need an active Comma session to continue. Open the Comma app, sign in, then start again from the app you came from.",
      error_code: "login_required",
      status: 401
    )
  end

  @doc false
  def render_error(conn, kind, overrides \\ []) do
    copy = error_copy(kind)

    html =
      error_template(%{
        icon: kind,
        title: escape(Keyword.get(overrides, :title, copy.title)),
        body: escape(Keyword.get(overrides, :body, copy.body)),
        error_code: escape(Keyword.get(overrides, :error_code, copy.error_code))
      })

    send_html(conn, Keyword.get(overrides, :status, copy.status), html)
  end

  defp error_copy(:expired) do
    %{
      title: "This sign-in request expired",
      body:
        "Sign-in requests only stay valid for a few minutes. Go back to the app and start signing in again.",
      error_code: "authorization_request_expired",
      status: 400
    }
  end

  defp error_copy(:invalid) do
    %{
      title: "This sign-in request isn’t valid",
      body:
        "The app sent an invalid sign-in request. Go back and try again — if this keeps happening, contact the app’s developer.",
      error_code: "invalid_request",
      status: 400
    }
  end

  defp error_copy(:denied) do
    %{
      title: "Sign-in canceled",
      body: "Nothing was shared. You can close this tab.",
      error_code: "access_denied",
      status: 200
    }
  end

  defp error_copy(:error) do
    %{
      title: "Something went wrong",
      body: "Comma couldn’t process this sign-in. Go back to the app and try again in a moment.",
      error_code: "server_error",
      status: 500
    }
  end

  defp send_html(conn, status, html, csp \\ @csp) do
    conn
    |> put_security_headers(csp)
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  # The consent page's CSP must list the client's registered redirect_uri
  # origin in form-action, not just 'self'. Chrome enforces form-action on
  # every hop of the redirect chain a form submission follows, and approving
  # consent IS a cross-origin redirect: the POST answers 302 to the client's
  # redirect_uri carrying the authorization code. Under a bare
  # `form-action 'self'` the browser submits the form, the server consumes
  # the one-shot handle and issues the code — and then the browser refuses
  # the redirect, so the user stays on the consent page and the client never
  # receives the code. (Found on staging the moment the Origin:null bug
  # stopped masking it; a second click then answers
  # authorization_request_expired, because the first click really was
  # accepted.) The origin comes from the Boruta-validated stored request,
  # never from caller input, and anything unexpected falls back to the
  # strict policy rather than widening it.
  defp consent_csp(redirect_uri) do
    case form_action_origin(redirect_uri) do
      nil -> @csp
      origin -> String.replace(@csp, "form-action 'self'", "form-action 'self' " <> origin)
    end
  end

  defp form_action_origin(redirect_uri) when is_binary(redirect_uri) do
    uri = URI.parse(redirect_uri)

    with true <- uri.scheme in ["http", "https"],
         host when is_binary(host) <- uri.host,
         csp_host when is_binary(csp_host) <- csp_host(host) do
      if uri.port == URI.default_port(uri.scheme) do
        "#{uri.scheme}://#{csp_host}"
      else
        "#{uri.scheme}://#{csp_host}:#{uri.port}"
      end
    else
      _unexpected -> nil
    end
  end

  defp form_action_origin(_other), do: nil

  # Serializes a host for a CSP source expression, restricted so a stored
  # value can never smuggle CSP syntax (spaces, semicolons) into the header.
  # Registered names and IPv4 literals pass the charset guard as-is. An
  # IPv6 literal must be re-bracketed: `URI.parse/1` strips the brackets
  # (`http://[::1]:8765` parses to host `::1`), while a CSP host-source
  # requires them — and the v1 contract explicitly admits `http://[::1]`
  # (RFC §7.2, `ClientAdmin.loopback_host?/1`). The literal is validated as
  # an actual IPv6 address, not by charset.
  defp csp_host(host) do
    cond do
      host =~ ~r/^[A-Za-z0-9][A-Za-z0-9.-]*$/ ->
        host

      String.contains?(host, ":") ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, addr} when tuple_size(addr) == 8 -> "[" <> host <> "]"
          _not_ipv6 -> nil
        end

      true ->
        nil
    end
  end

  defp put_security_headers(conn, csp \\ @csp) do
    conn
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_header("x-frame-options", "DENY")
    # Load-bearing: must NOT be `no-referrer`. Under `no-referrer` the Fetch
    # spec has the browser serialize the Origin header of a navigation
    # request — the consent form POST is one — as the literal string "null",
    # which `require_same_origin/1` then rejects: the page's own header would
    # make every real browser fail its own same-origin check (no synthetic
    # test catches it, since those set `origin` by hand). `same-origin` keeps
    # the property that motivated `no-referrer` — a cross-origin navigation,
    # including the final hop to the client's redirect_uri, still sends no
    # referrer at all, so the consent URL and its OAuth parameters never
    # reach the relying party — while restoring a real Origin on the
    # same-origin POST back to this endpoint.
    |> put_resp_header("referrer-policy", "same-origin")
  end

  defp escape(value), do: Plug.HTML.html_escape(to_string(value))

  defp initial(name) do
    case String.first(String.trim(to_string(name))) do
      nil -> "?"
      grapheme -> String.upcase(grapheme)
    end
  end

  defp client_display_name(client) do
    name = String.trim(to_string(client.name || ""))

    cond do
      name == "" -> "This app"
      String.length(name) > @client_name_limit -> String.slice(name, 0, @client_name_limit) <> "…"
      true -> name
    end
  end
end
