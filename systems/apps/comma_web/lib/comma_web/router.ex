defmodule CommaWeb.Router do
  require Logger

  @moduledoc """
  Comma product HTTP API. Salix remains the shared runtime substrate.
  """

  use Plug.Router

  @local_recommendation_mock_compiled Application.compile_env(
                                        :comma_web,
                                        :local_recommendation_mock_compiled,
                                        false
                                      )

  @default_comma_sse_wait_ms 1_000
  @max_comma_sse_wait_ms 30_000
  @default_comma_sse_heartbeat_ms 15_000
  @conversation_unavailable_reasons [
    :invalid_conversation_binding,
    :invalid_salix_conversation,
    :invalid_salix_conversation_id,
    :invalid_salix_conversation_identity,
    :invalid_salix_conversation_pin,
    :invalid_salix_conversation_list,
    :invalid_salix_message_identity,
    :invalid_salix_participant_list,
    :invalid_salix_participant_page,
    :invalid_salix_router_participant,
    :projection_missing,
    :salix_conversation_projection_conflict,
    :salix_conversation_read_not_supported,
    :salix_conversation_write_not_supported,
    :salix_conversation_subscription_not_supported,
    :salix_participant_read_not_supported,
    :salix_participant_validation_incomplete,
    :salix_user_participant_not_supported
  ]
  @conversation_public_error_reasons [
    :not_found,
    :forbidden,
    :budget_exhausted,
    :invalid_conversation_title,
    :invalid_review_version,
    :tool_not_allowed,
    :exists,
    :unsupported_for_kind
  ]
  @conversation_public_billing_reasons ~w(
    account_inactive
    insufficient_credits
    missing_account
  )

  # Before :match, so routing and every check below see the canonical path.
  plug(CommaWeb.LegacyPaths)
  plug(:match)
  plug(:auth_response_policy)
  plug(:oauth_idp_telemetry)
  plug(SystemsObservability.HTTPPlug, endpoint: :comma_product_api)
  plug(CommaWeb.CORS)
  plug(SystemsObservability.PodDrainGate)
  plug(CommaWeb.SessionLifecycleProtocol)
  plug(CommaWeb.Auth)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json, {:multipart, length: 11_000_000}],
    json_decoder: Jason,
    pass: ["application/json", "audio/mp4"],
    body_reader: {__MODULE__, :cache_body, []}
  )

  plug(:dispatch)

  defp oauth_idp_telemetry(conn, _opts) do
    CommaWeb.OauthIdpEndpoints.register_telemetry(conn)
  end

  defp auth_response_policy(conn, _opts) do
    cond do
      # The consent page is comma_web's only HTML surface, and HTML is what
      # content-rewriting intermediaries act on. `no-transform` (RFC 9111
      # §5.2.2.6) forbids them from rewriting the payload, on top of
      # `no-store` forbidding them to keep it.
      #
      # This is load-bearing, not hardening. On staging, Cloudflare's Email
      # Address Obfuscation rewrote the signed-in user's address into a
      # `[email protected]` placeholder and injected a decoder script
      # to restore it — which this page's own `default-src 'none'` CSP then
      # blocked, leaving the address permanently unreadable on the one
      # screen whose entire job is showing *which account* is about to be
      # handed to a third party. Cloudflare documents `no-transform` as an
      # opt-out, and because the directive is standard it also covers
      # proxies and CDNs we do not operate — which a per-zone dashboard rule
      # would not.
      #
      # Scoped to this path on purpose: /oauth2/token and /oauth2/userinfo
      # are JSON, which rewriting does not target, and RFC 6749 §5.1 pins
      # the token response's Cache-Control to `no-store`.
      CommaWeb.OauthIdpConsent.authorize_path?(conn.request_path) ->
        register_before_send(
          conn,
          &put_resp_header(&1, "cache-control", "no-store, no-transform")
        )

      String.starts_with?(conn.request_path, "/v1/comma/auth/") or
        String.starts_with?(conn.request_path, "/v1/comma/integrations/telegram/") or
          String.starts_with?(conn.request_path, "/oauth2/") ->
        register_before_send(conn, &put_resp_header(&1, "cache-control", "no-store"))

      true ->
        conn
    end
  end

  get "/v1/comma/workspaces/:workspace_id/browsers" do
    CommaWeb.BrowserEndpoints.list(conn, workspace_id)
  end

  post "/v1/comma/workspaces/:workspace_id/browsers/clear-storage" do
    CommaWeb.BrowserEndpoints.clear_storage(conn, workspace_id)
  end

  post "/v1/comma/workspaces/:workspace_id/browsers/:agent_id/:session_id" do
    CommaWeb.BrowserEndpoints.command(conn, workspace_id, agent_id, session_id)
  end

  get "/v1/comma/workspaces/:workspace_id/browsers/:agent_id/:session_id/events" do
    CommaWeb.BrowserEndpoints.stream(conn, workspace_id, agent_id, session_id)
  end

  get "/live" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/ready" do
    send_lifecycle_readiness(conn, :comma_product)
  end

  get "/health" do
    send_lifecycle_readiness(conn, :comma_product)
  end

  # Public Task Share reads. CommaWeb.Auth admits these paths without a session.
  get "/v1/comma/public/shares/:token" do
    CommaWeb.TaskShareEndpoints.summary(conn, token)
  end

  get "/v1/comma/public/shares/:token/messages" do
    CommaWeb.TaskShareEndpoints.messages(conn, token)
  end

  get "/v1/comma/public/shares/:token/attachments/:seq/:index" do
    CommaWeb.TaskShareEndpoints.attachment(conn, token, seq, index)
  end

  if @local_recommendation_mock_compiled do
    get "/v1/debug/recommendation-mock" do
      with_user(conn, fn _user, _session ->
        send_json(conn, 200, SalixWeb.LocalOAuthMock.status())
      end)
    end

    patch "/v1/debug/recommendation-mock" do
      with_user(conn, fn user, session ->
        case conn.body_params do
          %{"enabled" => enabled} when is_boolean(enabled) ->
            case SalixWeb.LocalOAuthMock.set_enabled(enabled) do
              {:ok, status} ->
                sync_error =
                  case conn.body_params["workspaceId"] do
                    workspace_id when is_binary(workspace_id) and workspace_id != "" ->
                      with {:ok, workspace} <-
                             Comma.Workspaces.authorize(user, session, workspace_id),
                           :ok <-
                             CommaWeb.RecommendationRuntime.reset_for_mode_change(
                               user,
                               session,
                               workspace
                             ) do
                        false
                      else
                        _ -> true
                      end

                    _ ->
                      false
                  end

                send_json(conn, 200, Map.put(status, :syncError, sync_error))

              {:error, reason} ->
                comma_error(conn, reason)
            end

          _params ->
            send_error(conn, 400, :invalid_recommendation_mock_setting)
        end
      end)
    end
  end

  defp send_lifecycle_readiness(conn, surface) do
    lifecycle = Module.concat([Comma, PodLifecycle])

    case apply(lifecycle, :ready, [surface]) do
      :ok -> send_json(conn, 200, %{status: "ok"})
      {:error, reason} -> send_json(conn, 503, %{status: "not_ready", reason: reason})
    end
  end

  get "/v1/comma/billing/stripe/checkout/return" do
    send_billing_return_page(
      conn,
      conn.query_params["environment"],
      conn.query_params["status"] || "success"
    )
  end

  get "/v1/comma/billing/stripe/checkout/cancel" do
    send_billing_return_page(conn, conn.query_params["environment"], "cancel")
  end

  # OAuth/OIDC IdP machine endpoints (docs/identity-security.md).
  # Gated on the deployment flag: 404 until the surface is switched on.
  get "/.well-known/openid-configuration" do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      CommaWeb.OauthIdpEndpoints.discovery(conn)
    else
      CommaWeb.OauthIdpEndpoints.not_found(conn)
    end
  end

  get "/.well-known/jwks.json" do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      CommaWeb.OauthIdpEndpoints.jwks(conn)
    else
      CommaWeb.OauthIdpEndpoints.not_found(conn)
    end
  end

  get "/oauth2/authorize" do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      with {:allow, conn} <- CommaWeb.OauthIdpEndpoints.rate_limit(conn, :authorize) do
        CommaWeb.OauthIdpConsent.authorize(fetch_query_params(conn))
      end
    else
      CommaWeb.OauthIdpEndpoints.not_found(conn)
    end
  end

  post "/oauth2/authorize" do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      with {:allow, conn} <- CommaWeb.OauthIdpEndpoints.rate_limit(conn, :authorize) do
        CommaWeb.OauthIdpConsent.decide(conn)
      end
    else
      CommaWeb.OauthIdpEndpoints.not_found(conn)
    end
  end

  post "/oauth2/token" do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      with {:allow, conn} <- CommaWeb.OauthIdpEndpoints.rate_limit(conn, :token) do
        CommaWeb.OauthIdpEndpoints.token(conn)
      end
    else
      CommaWeb.OauthIdpEndpoints.not_found(conn)
    end
  end

  get "/oauth2/userinfo" do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      CommaWeb.OauthIdpEndpoints.userinfo(conn)
    else
      CommaWeb.OauthIdpEndpoints.not_found(conn)
    end
  end

  post "/v1/comma/auth/email/login" do
    case Comma.AuthChallenges.request_email_login(auth_request_attrs(conn)) do
      {:ok, challenge} ->
        send_json(conn, 200, challenge)

      {:error, :invalid_email} ->
        send_error(conn, 400, :invalid_email)

      {:error, :rate_limited, retry_after} ->
        send_rate_limited(conn, retry_after)

      {:error, :provider_unavailable, retry_after} ->
        send_unavailable(conn, :email_delivery_unavailable, retry_after)

      {:error, reason}
      when reason in [:email_delivery_unavailable, :auth_not_configured, :auth_unavailable] ->
        send_error(conn, 503, :email_delivery_unavailable)
    end
  end

  post "/v1/comma/auth/email/verify" do
    case Comma.AuthChallenges.verify_email_login(conn.body_params || %{}) do
      {:ok, session} -> send_auth_result(conn, 200, session)
      {:error, :invalid_verification_code} -> send_error(conn, 401, :invalid_verification_code)
      {:error, :rate_limited, retry_after} -> send_rate_limited(conn, retry_after)
      {:error, :disabled} -> send_error(conn, 403, :disabled)
      {:error, _internal_reason} -> send_error(conn, 503, :auth_unavailable)
    end
  end

  post "/v1/comma/auth/google/attempt" do
    case Comma.GoogleAuth.start_attempt(auth_request_attrs(conn)) do
      {:ok, attempt} -> send_json(conn, 200, attempt)
      {:error, :google_not_configured} -> send_error(conn, 503, :google_not_configured)
      {:error, :rate_limited, retry_after} -> send_rate_limited(conn, retry_after)
      {:error, _internal_reason} -> send_error(conn, 503, :auth_unavailable)
    end
  end

  post "/v1/comma/auth/google" do
    case Comma.GoogleAuth.complete(auth_request_attrs(conn)) do
      {:ok, result} ->
        send_auth_result(conn, 200, result)

      {:error, :invalid_google_attempt} ->
        send_error(conn, 401, :invalid_google_attempt)

      {:error, :invalid_google_credential} ->
        send_error(conn, 401, :invalid_google_credential)

      {:error, :invalid_google_identity} ->
        send_error(conn, 400, :invalid_google_identity)

      {:error, :google_provider_unavailable} ->
        send_error(conn, 503, :google_provider_unavailable)

      {:error, :disabled} ->
        send_error(conn, 403, :disabled)

      {:error, :rate_limited, retry_after} ->
        send_rate_limited(conn, retry_after)

      {:error, :provider_unavailable, retry_after} ->
        send_unavailable(conn, :email_delivery_unavailable, retry_after)

      {:error, reason}
      when reason in [:email_delivery_unavailable, :auth_not_configured, :auth_unavailable] ->
        send_error(conn, 503, :email_delivery_unavailable)

      {:error, reason} when reason in [:identity_conflict, :provider_already_linked] ->
        send_error(conn, 409, reason)

      {:error, reason} ->
        send_error(conn, 400, reason)
    end
  end

  post "/v1/comma/auth/google/link/verify" do
    case Comma.GoogleAuth.verify_link(conn.body_params || %{}) do
      {:ok, session} ->
        send_auth_result(conn, 200, session)

      {:error, :invalid_verification_code} ->
        send_error(conn, 401, :invalid_verification_code)

      {:error, :rate_limited, retry_after} ->
        send_rate_limited(conn, retry_after)

      {:error, :auth_unavailable} ->
        send_error(conn, 503, :auth_unavailable)

      {:error, :disabled} ->
        send_error(conn, 403, :disabled)

      {:error, :google_link_changed} ->
        send_error(conn, 409, :google_link_changed)

      {:error, reason} when reason in [:identity_conflict, :provider_already_linked] ->
        send_error(conn, 409, reason)

      {:error, reason} ->
        send_error(conn, 400, reason)
    end
  end

  post "/v1/comma/auth/telegram-miniapp" do
    if CommaWeb.ClientSurface.web_cookie?(conn) do
      {conn, cookie_token} = CommaWeb.SessionCookie.fetch_browser(conn)

      case CommaWeb.TelegramMiniAppAuth.complete(conn.body_params || %{}, cookie_token) do
        {:ok, :existing, session} ->
          send_json(conn, 200, session)

        {:ok, :issued, session} ->
          conn =
            if conn.assigns[:comma_cookie_kind] == :user,
              do: CommaWeb.SessionCookie.clear_user(conn),
              else: conn

          send_auth_result(conn, 201, session, :panel)

        {:error, :account_mismatch} ->
          send_error(conn, 409, :account_mismatch)

        {:error, _reason} ->
          send_error(conn, 401, :invalid_telegram_miniapp_login)
      end
    else
      send_error(conn, 401, :invalid_telegram_miniapp_login)
    end
  end

  get "/v1/comma/auth/ssh-keys" do
    with_session_management(conn, fn user, _session ->
      send_json(conn, 200, %{"data" => Comma.Accounts.SSHIdentities.list(user["id"])})
    end)
  end

  delete "/v1/comma/auth/ssh-keys/:id" do
    with_session_management(conn, fn user, _session ->
      case Comma.Accounts.SSHIdentities.revoke(user["id"], id) do
        :ok -> send_json(conn, 200, %{"ok" => true})
        {:error, :not_found} -> send_error(conn, 404, :not_found)
      end
    end)
  end

  get "/v1/comma/auth/sessions" do
    with_session_management(conn, fn user, _session ->
      case Comma.Accounts.list_sessions(user["id"],
             limit: parse_int(conn.query_params["limit"], 50),
             cursor: conn.query_params["cursor"]
           ) do
        {:ok, page} -> send_json(conn, 200, page)
        {:error, :invalid_cursor} -> send_error(conn, 400, :invalid_cursor)
        {:error, reason} -> send_error(conn, 400, reason)
      end
    end)
  end

  get "/v1/comma/auth/session" do
    with_user(conn, fn user, session ->
      send_json(conn, 200, %{
        "expires_at" => session["expires_at"],
        "session_id" => session["id"],
        "user" => Map.take(user, ["id", "email", "name", "status"])
      })
    end)
  end

  get "/v1/comma/me/profile" do
    with_profile_management(conn, fn user, _session ->
      case Comma.ProfileAvatar.get(user["id"]) do
        {:ok, profile} -> send_json(conn, 200, profile)
        {:error, reason} -> send_profile_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/me/profile" do
    with_profile_management(conn, fn user, _session ->
      case Comma.ProfileAvatar.update_name(user["id"], conn.body_params || %{}) do
        {:ok, profile} -> send_json(conn, 200, profile)
        {:error, reason} -> send_profile_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/me/avatar" do
    with_profile_management(conn, fn user, _session ->
      case Comma.ProfileAvatar.upload(user["id"], (conn.body_params || %{})["avatar"]) do
        {:ok, profile} -> send_json(conn, 200, profile)
        {:error, reason} -> send_profile_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/me/avatar/:avatar_id" do
    with_profile_management(conn, fn user, _session ->
      case Comma.ProfileAvatar.fetch(user["id"], avatar_id) do
        {:ok, content_type, body} ->
          conn
          |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
          |> put_resp_content_type(content_type)
          |> send_resp(200, body)

        {:error, reason} ->
          send_profile_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/me/avatar" do
    with_profile_management(conn, fn user, _session ->
      case Comma.ProfileAvatar.delete(user["id"]) do
        {:ok, profile} -> send_json(conn, 200, profile)
        {:error, reason} -> send_profile_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/me/synchronicity/status" do
    with_profile_management(conn, fn user, _session ->
      case Comma.Synchronicity.status(user["id"]) do
        {:ok, status} -> send_json(conn, 200, status)
        {:error, reason} -> synchronicity_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/me/recordings/transcribe" do
    with_profile_management(conn, fn _user, _session ->
      CommaWeb.RecordingTranscription.call(conn)
    end)
  end

  put "/v1/comma/me/synchronicity/devices/current" do
    with_profile_management(conn, fn user, _session ->
      params = conn.body_params || %{}

      case Comma.Synchronicity.enroll_device(user["id"], params["nk"], params["label"]) do
        {:ok, device} -> send_json(conn, 200, device)
        {:error, reason} -> synchronicity_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/auth/logout" do
    with_user(conn, fn _user, _session ->
      :ok = Comma.Accounts.revoke_session_token(presented_token(conn))

      conn
      |> maybe_clear_web_session_cookie()
      |> send_json(200, %{"signed_out" => true})
    end)
  end

  delete "/v1/comma/auth/sessions/:id" do
    with_session_management(conn, fn user, _session ->
      :ok = Comma.Accounts.revoke_session(user["id"], id)
      send_json(conn, 200, %{"revoked" => true})
    end)
  end

  post "/v1/comma/auth/sessions/revoke-all" do
    with_session_management(conn, fn user, session ->
      keep_current? = (conn.body_params || %{})["keep_current"] == true

      opts =
        if keep_current?,
          do: [except_session_id: session["id"]],
          else: []

      {:ok, count} = Comma.Accounts.revoke_all_sessions(user["id"], opts)
      send_json(conn, 200, %{"revoked_count" => count})
    end)
  end

  post "/v1/comma/billing/stripe/webhook" do
    payload = conn.assigns[:raw_body] || ""
    signature_header = conn |> get_req_header("stripe-signature") |> List.first() || ""

    case BillingStripe.handle_webhook(payload, signature_header) do
      {:ok, _result} -> send_json(conn, 200, %{"received" => true})
      {:error, reason} -> stripe_webhook_error(conn, reason)
    end
  end

  get "/v1/comma/admin/compute/agent-vmm/overview" do
    with_admin_query(conn, fn ->
      tenant_id = conn.query_params["tenant_id"]

      case SalixStore.AgentVMMAdminProjection.overview(tenant_id || "", %{}) do
        {:ok, overview} -> send_json(conn, 200, overview)
        {:error, reason} -> agent_vmm_query_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/admin/compute/agent-vmm/nodes" do
    with_admin_query(conn, fn ->
      tenant_id = conn.query_params["tenant_id"] || ""
      filters = agent_vmm_filters(conn.query_params)

      with {:ok, cursor} <-
             decode_agent_vmm_cursor(conn.query_params["cursor"], tenant_id, filters),
           {:ok, page} <-
             SalixStore.AgentVMMAdminProjection.page_nodes(
               tenant_id,
               filters,
               cursor,
               min(max(parse_int(conn.query_params["limit"], 50), 1), 50)
             ),
           {:ok, next_cursor} <-
             encode_agent_vmm_cursor(page.next_cursor, tenant_id, filters) do
        send_json(conn, 200, %{
          "data" => page.nodes,
          "next_cursor" => next_cursor,
          "has_more" => not is_nil(next_cursor)
        })
      else
        {:error, reason} -> agent_vmm_query_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/admin/compute/agent-vmm/nodes/:registration_id" do
    with_admin_query(conn, fn ->
      tenant_id = conn.query_params["tenant_id"] || ""

      case SalixStore.AgentVMMAdminProjection.get_node(tenant_id, registration_id) do
        {:ok, node} -> send_json(conn, 200, node)
        {:error, reason} -> agent_vmm_query_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/admin/compute/agent-vmm/commands/:action/:target_id" do
    attrs = conn.body_params || %{}
    tenant_id = if is_binary(attrs["tenant_id"]), do: attrs["tenant_id"], else: "invalid"

    result =
      run_agent_vmm_admin_command(conn, action, tenant_id, target_id, attrs)

    case result do
      {:ok, response} -> send_json(conn, 202, response)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/users" do
    attrs = conn.body_params || %{}
    email = attrs["email"] |> to_string() |> String.trim() |> String.downcase()

    result =
      run_admin_command(
        conn,
        "create_user",
        "user",
        email,
        "create-user:#{email}",
        fn actor, command_attrs ->
          Comma.Admin.create_user_with_access(
            command_attrs,
            command_attrs["admin_access"],
            actor,
            admin_reason(actor, command_attrs)
          )
        end
      )

    case result do
      {:ok, user} -> send_json(conn, 201, user)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  get "/v1/comma/admin/audit-events" do
    with_admin_query(conn, fn ->
      case Comma.Admin.list_audit_events(
             limit: parse_int(conn.query_params["limit"], 50),
             cursor: conn.query_params["cursor"],
             cursor_secret: conn.assigns[:auth_token]
           ) do
        {:ok, page} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_json(200, page)

        {:error, :invalid_cursor} ->
          send_error(conn, 400, :invalid_cursor)

        {:error, reason} ->
          send_error(conn, 500, reason)
      end
    end)
  end

  get "/v1/comma/admin/users" do
    with_admin_query(conn, fn ->
      case Comma.Admin.list_users(
             limit: parse_int(conn.query_params["limit"], 100),
             cursor: conn.query_params["cursor"],
             email: conn.query_params["email"],
             cursor_secret: conn.assigns[:auth_token]
           ) do
        {:ok, page} -> send_json(conn, 200, page)
        {:error, :invalid_cursor} -> send_error(conn, 400, :invalid_cursor)
        {:error, :invalid_filter} -> send_error(conn, 400, :invalid_filter)
        {:error, reason} -> send_error(conn, 500, reason)
      end
    end)
  end

  get "/v1/comma/admin/users/:id" do
    with_admin_query(conn, fn ->
      case Comma.Admin.get_user(id) do
        {:ok, user} -> send_json(conn, 200, user)
        {:error, :not_found} -> send_error(conn, 404, :not_found)
        {:error, reason} -> send_error(conn, 500, reason)
      end
    end)
  end

  get "/v1/comma/admin/users/:id/sessions" do
    with_admin_query(conn, fn ->
      case Comma.Admin.list_user_sessions(id,
             limit: parse_int(conn.query_params["limit"], 50),
             cursor: conn.query_params["cursor"]
           ) do
        {:ok, page} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_json(200, page)

        {:error, :invalid_cursor} ->
          send_error(conn, 400, :invalid_cursor)

        {:error, :not_found} ->
          send_error(conn, 404, :not_found)

        {:error, reason} ->
          send_error(conn, 500, reason)
      end
    end)
  end

  get "/v1/comma/admin/users/:id/workspaces" do
    with_admin_query(conn, fn ->
      case Comma.Admin.get_user_workspace_billing(id) do
        {:ok, overview} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_json(200, overview)

        {:error, :not_found} ->
          send_error(conn, 404, :not_found)

        {:error, :workspace_invariant} ->
          send_error(conn, 409, :workspace_invariant)

        {:error, :billing_unavailable} ->
          send_error(conn, 503, :billing_unavailable)

        {:error, reason} ->
          send_error(conn, 500, reason)
      end
    end)
  end

  get "/v1/comma/admin/users/:id/workspaces/agent-models" do
    with_admin_query(conn, fn ->
      case Comma.Admin.get_user_workspace_agent_models(id) do
        {:ok, projection} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_json(200, projection)

        {:error, reason} ->
          workspace_agent_models_error(conn, reason)
      end
    end)
  end

  # The Workspace's own Signal number, overriding the platform number
  # (docs/messaging-voice.md). Salix owns the setting; Comma audits the change.
  get "/v1/comma/admin/users/:id/workspaces/signal-number" do
    with_admin_query(conn, fn ->
      with {:ok, workspace} <- Comma.Admin.user_workspace_tenant(id),
           {:ok, view} <- Salix.Control.Signal.tenant_number(workspace["salix_tenant_id"]) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(
          200,
          view |> public_signal() |> Map.put("workspace_id", workspace["workspace_id"])
        )
      else
        {:error, reason} -> signal_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/admin/users/:id/workspaces/signal-number" do
    number = signal_number_param(conn.body_params)

    result =
      run_admin_command(
        conn,
        "update_workspace_signal_number",
        "user_workspace",
        id,
        "workspace-signal-number:#{id}:#{number}",
        fn _actor, _attrs ->
          with {:ok, workspace} <- Comma.Admin.user_workspace_tenant(id) do
            Salix.Control.Signal.put_tenant_number(workspace["salix_tenant_id"], %{
              "number" => number
            })
          end
        end
      )

    case result do
      {:ok, view} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(200, public_signal(view))

      {:error, reason} ->
        signal_error(conn, reason)
    end
  end

  patch "/v1/comma/admin/users/:id" do
    result =
      run_admin_command(
        conn,
        "update_user",
        "user",
        id,
        "update-user:#{id}",
        fn _actor, attrs -> Comma.Admin.update_user(id, attrs) end
      )

    case result do
      {:ok, user} -> send_json(conn, 200, user)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  put "/v1/comma/admin/users/:id/admin-access" do
    attrs = conn.body_params || %{}
    decision = attrs["decision"]

    result =
      run_admin_command(
        conn,
        "set_admin_access",
        "user",
        id,
        "admin-access:#{id}:#{decision}",
        fn actor, command_attrs ->
          Comma.Admin.set_admin_access(
            id,
            command_attrs["decision"],
            actor,
            admin_reason(actor, command_attrs)
          )
        end
      )

    case result do
      {:ok, user} -> send_json(conn, 200, user)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/users/:id/sessions" do
    with_ops_admin(conn, fn ->
      case Comma.Admin.create_session(id, conn.body_params || %{}) do
        {:ok, session} ->
          send_json(conn, 201, session)

        {:error, :not_found} ->
          send_error(conn, 404, :not_found)

        {:error, reason} ->
          send_error(conn, 400, reason)
      end
    end)
  end

  post "/v1/comma/admin/users/:id/support-sessions" do
    result =
      run_admin_command(
        conn,
        "create_support_session",
        "user",
        id,
        "support-session:#{id}",
        fn _actor, attrs -> Comma.Admin.create_support_session(id, attrs) end
      )

    case result do
      {:ok, session} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(201, session)

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/users/:id/sessions/revoke-all" do
    result =
      run_admin_command(
        conn,
        "revoke_all_user_sessions",
        "user",
        id,
        "revoke-all-sessions:#{id}",
        fn _actor, _attrs -> Comma.Admin.revoke_all_user_sessions(id) end
      )

    case result do
      {:ok, response} -> send_json(conn, 200, response)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/users/:id/sessions/:session_id/revoke" do
    result =
      run_admin_command(
        conn,
        "revoke_user_session",
        "session",
        session_id,
        "revoke-session:#{session_id}",
        fn _actor, _attrs -> Comma.Admin.revoke_user_session(id, session_id) end
      )

    case result do
      {:ok, response} -> send_json(conn, 200, response)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/users/:id/workspaces" do
    result =
      run_admin_command(
        conn,
        "bootstrap_workspace",
        "user",
        id,
        "default-workspace:#{id}",
        fn _actor, _attrs -> Comma.Admin.ensure_default_workspace(id) end
      )

    case result do
      {:ok, workspace} -> send_json(conn, 200, workspace)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  put "/v1/comma/admin/users/:id/workspaces/:workspace_id/vm" do
    enabled = (conn.body_params || %{})["enabled"]
    state = if enabled == true, do: "enable", else: "disable"

    result =
      run_admin_command(
        conn,
        "update_workspace_vm",
        "workspace",
        workspace_id,
        "workspace-vm:#{workspace_id}:#{state}",
        fn _actor, attrs ->
          Comma.Admin.update_user_workspace_vm(id, workspace_id, attrs["enabled"])
        end
      )

    case result do
      {:ok, projection} ->
        conn |> put_resp_header("cache-control", "no-store") |> send_json(202, projection)

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  put "/v1/comma/admin/users/:id/workspaces/agent-models/:role" do
    attrs = conn.body_params || %{}

    template_id =
      case attrs["template_id"] do
        nil -> "default"
        value when is_binary(value) -> String.trim(value)
        _invalid -> "invalid"
      end

    result =
      run_admin_command(
        conn,
        "update_workspace_agent_model",
        "user_workspace",
        id,
        "workspace-agent-model:#{id}:#{role}:#{template_id}",
        fn _actor, command_attrs ->
          Comma.Admin.update_user_workspace_agent_model(
            id,
            role,
            command_attrs["template_id"]
          )
        end
      )

    case result do
      {:ok, agent_model} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(200, agent_model)

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/users/:id/workspace-credits" do
    result = run_workspace_credit_command(conn, id)

    case result do
      {:ok, manual_grant} ->
        send_json(conn, 201, public_manual_grant_result(manual_grant))

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  # OAuth IdP client lifecycle (docs/identity-security.md, PR 8/10).
  # Named admin commands with reason/confirmation/idempotency + durable
  # audit via run_admin_command; the client secret appears exactly once,
  # in the create/rotate response, never in queries or audit rows.
  get "/v1/comma/admin/oauth-clients" do
    with_admin_query(conn, fn ->
      if CommaWeb.OauthIdpEndpoints.enabled?() do
        send_json(conn, 200, %{"data" => Comma.OauthIdp.ClientAdmin.list()})
      else
        send_error(conn, 404, :not_found)
      end
    end)
  end

  post "/v1/comma/admin/oauth-clients" do
    # The rejected-audit target for invalid input; validation itself
    # never calls to_string on untrusted terms (a structured name is a
    # typed 400, not a 500).
    rejected_target =
      case conn.body_params do
        %{"name" => name} when is_binary(name) -> String.slice(String.trim(name), 0, 64)
        _other -> "invalid"
      end

    result =
      run_oauth_client_command(conn, "create_oauth_client", rejected_target, fn attrs ->
        with {:ok, command} <- Comma.OauthIdp.ClientAdmin.parse_create(attrs) do
          {:ok,
           %{
             command: {:create, command},
             target_type: "oauth_client",
             target_id: command.name,
             expected_confirmation: "create-oauth-client:#{command.name}",
             fingerprint: Map.take(attrs, ["name", "redirect_uris", "confidential"])
           }}
        end
      end)

    case result do
      {:ok, client} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(201, client)

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/oauth-clients/:id/rotate-secret" do
    result =
      run_oauth_client_command(conn, "rotate_oauth_client_secret", id, fn attrs ->
        with {:ok, client_id} <- Comma.OauthIdp.ClientAdmin.parse_rotate(id, attrs) do
          {:ok, oauth_lifecycle_prepared(:rotate, "rotate-oauth-client-secret", client_id)}
        end
      end)

    case result do
      {:ok, client} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(200, client)

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/oauth-clients/:id/disable" do
    result =
      run_oauth_client_command(conn, "disable_oauth_client", id, fn attrs ->
        with {:ok, client_id} <- Comma.OauthIdp.ClientAdmin.parse_lifecycle(id, attrs) do
          {:ok, oauth_lifecycle_prepared(:disable, "disable-oauth-client", client_id)}
        end
      end)

    case result do
      {:ok, client} -> send_json(conn, 200, client)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  post "/v1/comma/admin/oauth-clients/:id/enable" do
    result =
      run_oauth_client_command(conn, "enable_oauth_client", id, fn attrs ->
        with {:ok, client_id} <- Comma.OauthIdp.ClientAdmin.parse_lifecycle(id, attrs) do
          {:ok, oauth_lifecycle_prepared(:enable, "enable-oauth-client", client_id)}
        end
      end)

    case result do
      {:ok, client} -> send_json(conn, 200, client)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  get "/v1/comma/admin/billing/free-router-models" do
    with_admin_query(conn, fn ->
      case Comma.Billing.RouterModels.get() do
        {:ok, policy} -> send_json(conn, 200, policy)
        {:error, reason} -> send_error(conn, 503, reason)
      end
    end)
  end

  get "/v1/comma/admin/model-selection-policy" do
    with_admin_query(conn, fn ->
      case Comma.ModelSelectionPolicy.get() do
        {:ok, policy} -> send_json(conn, 200, policy)
        {:error, reason} -> send_error(conn, 503, reason)
      end
    end)
  end

  get "/v1/comma/admin/model-selection-policy/templates" do
    with_admin_query(conn, fn ->
      case SalixAgent.Templates.list_public_bounded(100) do
        {:ok, templates} ->
          send_json(conn, 200, %{"data" => SalixAgent.AgentDefaults.selectable(templates)})

        {:error, reason} ->
          send_error(conn, 503, reason)
      end
    end)
  end

  put "/v1/comma/admin/model-selection-policy" do
    result =
      run_admin_command(
        conn,
        "update_model_selection_policy",
        "model_selection_policy",
        "comma",
        "update-model-selection-policy:comma",
        fn _actor, attrs -> Comma.ModelSelectionPolicy.update(attrs) end
      )

    case result do
      {:ok, policy} ->
        send_json(conn, 200, policy)

      {:error, :model_selection_policy_conflict} ->
        send_error(conn, 409, :model_selection_policy_conflict)

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  put "/v1/comma/admin/billing/free-router-models" do
    result =
      run_admin_command(
        conn,
        "update_free_router_models",
        "billing_policy",
        "comma",
        "update-free-router-models:comma",
        fn _actor, attrs -> Comma.Billing.RouterModels.update(attrs) end
      )

    case result do
      {:ok, policy} -> send_json(conn, 200, policy)
      {:error, :billing_policy_conflict} -> send_error(conn, 409, :billing_policy_conflict)
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  get "/v1/comma/admin/billing/package-versions" do
    with_admin_query(conn, fn ->
      case BillingCommerce.list_package_versions(%{
             "surface" => conn.query_params["surface"] || "comma",
             "issuable_only?" => true,
             "latest_per_package?" => true
           }) do
        {:ok, %{data: versions}} ->
          send_json(conn, 200, %{"data" => Enum.map(versions, &public_package_version/1)})

        {:error, reason} ->
          send_error(conn, 500, reason)
      end
    end)
  end

  post "/v1/comma/admin/billing/redeem-codes" do
    attrs = conn.body_params || %{}
    target = "#{attrs["package_code"]}:#{attrs["package_version"]}"

    result =
      run_redeem_command(
        conn,
        "create_redeem_code",
        "redeem_code",
        target,
        &BillingCommerce.RedeemCodeCommands.prepare_human_create/3,
        &BillingCommerce.RedeemCodeCommands.legacy_create/1,
        &BillingCommerce.create_redeem_code/1
      )

    case result do
      {:ok, code} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(201, public_redeem_code(code, include_plaintext?: true))

      {:error, reason} ->
        admin_command_error(conn, reason)
    end
  end

  get "/v1/comma/admin/billing/redeem-codes" do
    with_admin_query(conn, fn ->
      case BillingCommerce.list_redeem_codes(%{
             "limit" => parse_int(conn.query_params["limit"], 100)
           }) do
        {:ok, %{data: codes}} ->
          send_json(conn, 200, %{"data" => Enum.map(codes, &public_redeem_code/1)})

        {:error, reason} ->
          send_error(conn, 500, reason)
      end
    end)
  end

  post "/v1/comma/admin/billing/redeem-codes/:id/disable" do
    result =
      run_redeem_command(
        conn,
        "disable_redeem_code",
        "redeem_code",
        id,
        fn attrs, actor, contract ->
          BillingCommerce.RedeemCodeCommands.prepare_human_disable(
            id,
            attrs,
            actor,
            contract
          )
        end,
        fn attrs ->
          attrs
          |> Map.put("id", id)
          |> BillingCommerce.RedeemCodeCommands.legacy_disable()
        end,
        &BillingCommerce.disable_redeem_code/1
      )

    case result do
      {:ok, code} -> send_json(conn, 200, public_redeem_code(code))
      {:error, reason} -> admin_command_error(conn, reason)
    end
  end

  get "/v1/comma/admin/billing/redemptions" do
    with_admin_query(conn, fn ->
      attrs = %{
        "redeem_code_id" => conn.query_params["redeem_code_id"],
        "limit" => parse_int(conn.query_params["limit"], 100)
      }

      case BillingCommerce.list_redemptions(attrs) do
        {:ok, %{data: redemptions}} ->
          send_json(conn, 200, %{"data" => Enum.map(redemptions, &public_redemption/1)})

        {:error, :invalid_redeem_code_id} ->
          send_error(conn, 400, :invalid_redeem_code_id)

        {:error, reason} ->
          send_error(conn, 500, reason)
      end
    end)
  end

  post "/v1/comma/admin/billing/redeem-codes/apply" do
    attrs = conn.body_params || %{}
    billing_account_id = attrs["billing_account_id"] |> to_string() |> String.trim()

    result =
      run_redeem_command(
        conn,
        "apply_redeem_code",
        "billing_account",
        billing_account_id,
        &BillingCommerce.RedeemCodeCommands.prepare_human_apply/3,
        &BillingCommerce.RedeemCodeCommands.legacy_apply/1,
        &BillingCommerce.apply_redeem_code/1
      )

    case result do
      {:ok, result} -> send_json(conn, 201, public_redemption_result(result))
      {:error, reason} -> redeem_command_error(conn, reason)
    end
  end

  get "/v1/comma/integrations/telegram/connect/callback" do
    conn = fetch_query_params(conn)

    case CommaWeb.TelegramIntegration.complete_connect(
           conn.query_params["code"],
           conn.query_params["state"]
         ) do
      {:ok, link} ->
        send_telegram_callback_page(conn, true, conn.query_params["state"], link["workspace_id"])

      {:error, reason} ->
        send_telegram_callback_page(conn, false, conn.query_params["state"], nil, reason)
    end
  end

  post "/v1/comma/integrations/telegram/webhook" do
    presented = get_req_header(conn, "x-telegram-bot-api-secret-token")

    if match?([secret] when is_binary(secret), presented) and
         CommaWeb.TelegramBot.verify_webhook_secret(hd(presented)) do
      result =
        CommaWeb.TelegramTelemetry.observe(:telegram_webhook, fn ->
          CommaWeb.TelegramIntegration.handle_webhook(conn.body_params || %{})
        end)

      case result do
        :ok -> send_json(conn, 200, %{ok: true})
        {:error, _reason} -> send_error(conn, 503, :telegram_delivery_unavailable)
      end
    else
      send_error(conn, 401, :unauthorized)
    end
  end

  get "/v1/comma/workspaces" do
    with_user(conn, fn user, session ->
      case Comma.Workspaces.list_for_user(user["id"], session) do
        {:ok, workspaces} ->
          send_json(conn, 200, %{"data" => Enum.map(workspaces, &Comma.Workspaces.public/1)})

        {:error, reason} ->
          comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/model-discovery" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <-
             SalixAgent.ModelDiscovery.discover(conn.body_params, workspace["salix_tenant_id"]) do
        send_json(conn, 200, result)
      else
        {:error, reason} when is_atom(reason) -> comma_error(conn, reason)
        {:error, _} -> send_error(conn, 502, :model_discovery_unavailable)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/subscription-accounts" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      SalixAgent.AccountPool.list(tenant, conn.params["after"] || "")
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/subscription-accounts" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      CommaWeb.SubscriptionAccounts.create(tenant, conn.body_params)
    end)
  end

  patch "/v1/comma/workspaces/:workspace_id/subscription-accounts/:id" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      CommaWeb.SubscriptionAccounts.update(tenant, id, conn.body_params)
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/subscription-accounts/:id" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      SalixAgent.AccountPool.delete(tenant, id, conn.body_params["version"])
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/subscription-accounts/:id/quota/reset" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      SalixAgent.AccountPool.reset_quota(tenant, id, conn.body_params)
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/subscription-accounts/:id/quota" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      SalixAgent.AccountPool.quota(tenant, id)
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/subscription-accounts/oauth" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      CommaWeb.SubscriptionAccounts.begin_oauth(tenant, conn.body_params)
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/subscription-accounts/oauth/:id" do
    with_subscription_accounts(conn, workspace_id, fn tenant ->
      CommaWeb.SubscriptionAccounts.complete_oauth(tenant, id, conn.body_params)
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/model-templates" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <- CommaWeb.ModelTemplates.list(workspace) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, {:conflict, _}} -> send_error(conn, 409, :model_template_in_use)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/model-templates" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <- CommaWeb.ModelTemplates.create(workspace, conn.body_params) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(201, result)
      else
        {:error, {:conflict, _}} -> send_error(conn, 409, :model_template_in_use)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/model-templates/resolve-subscription" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <-
             CommaWeb.ModelTemplates.resolve_subscription(workspace, conn.body_params) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/workspaces/:workspace_id/model-templates/:template_id" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <-
             CommaWeb.ModelTemplates.update(workspace, template_id, conn.body_params) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, {:conflict, _}} -> send_error(conn, 409, :model_template_in_use)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/model-templates/:template_id" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <- CommaWeb.ModelTemplates.delete(workspace, template_id) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, {:conflict, _}} -> send_error(conn, 409, :model_template_in_use)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/agent-models" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <- CommaWeb.SalixClient.get_user_workspace_agent_models(workspace) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, {:conflict, _}} -> send_error(conn, 409, :model_template_in_use)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/agent-models/workers" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <-
             CommaWeb.SalixClient.workspace_worker_models(workspace, conn.params["cursor"]) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/agent-models/worker-default" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <-
             CommaWeb.SalixClient.update_user_workspace_worker_default(
               workspace,
               conn.body_params["template_id"]
             ) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/agent-models/:role" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <-
             CommaWeb.SalixClient.update_user_workspace_agent_model(
               workspace,
               role,
               conn.body_params["template_id"]
             ) do
        conn |> put_resp_header("cache-control", "no-store") |> send_json(200, result)
      else
        {:error, {:conflict, _}} -> send_error(conn, 409, :model_template_in_use)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/integrations/telegram" do
    with_user(conn, fn user, session ->
      case CommaWeb.TelegramIntegration.state(user, session, workspace_id) do
        {:ok, state} -> send_json(conn, 200, state)
        {:error, reason} -> telegram_integration_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/telegram/connect" do
    with_user(conn, fn user, session ->
      case CommaWeb.TelegramIntegration.start_connect(
             user,
             session,
             workspace_id,
             conn.body_params["environment"]
           ) do
        {:ok, attempt} -> send_json(conn, 201, attempt)
        {:error, reason} -> telegram_integration_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/telegram/connect" do
    with_user(conn, fn user, session ->
      case Comma.TelegramLinks.cancel_attempt(
             user,
             session,
             workspace_id,
             conn.body_params || %{}
           ) do
        {:ok, :ok} -> send_json(conn, 200, %{"cancelled" => true})
        {:error, reason} -> telegram_integration_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/telegram" do
    with_user(conn, fn user, session ->
      case CommaWeb.TelegramIntegration.disconnect(user, session, workspace_id) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> telegram_integration_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/integrations/wechat" do
    with_user(conn, fn user, session ->
      wechat_result(conn, CommaWeb.WeChatIntegration.state(user, session, workspace_id))
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/wechat/connect" do
    with_user(conn, fn user, session ->
      wechat_result(
        conn,
        CommaWeb.WeChatIntegration.start_connect(user, session, workspace_id),
        201
      )
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/wechat/connect/poll" do
    with_user(conn, fn user, session ->
      wechat_result(
        conn,
        CommaWeb.WeChatIntegration.poll_connect(
          user,
          session,
          workspace_id,
          conn.body_params["attempt_id"],
          conn.body_params["verify_code"]
        )
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/wechat/connect" do
    with_user(conn, fn user, session ->
      wechat_result(
        conn,
        CommaWeb.WeChatIntegration.cancel_connect(
          user,
          session,
          workspace_id,
          conn.body_params["attempt_id"]
        )
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/wechat" do
    with_user(conn, fn user, session ->
      wechat_result(conn, CommaWeb.WeChatIntegration.disconnect(user, session, workspace_id))
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/integrations/imessage" do
    with_user(conn, fn user, session ->
      case CommaWeb.IMessageIntegration.state(user, session, workspace_id) do
        {:ok, state} -> send_json(conn, 200, state)
        {:error, reason} -> imessage_integration_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/imessage/connect" do
    with_user(conn, fn user, session ->
      case CommaWeb.IMessageIntegration.start_connect(
             user,
             session,
             workspace_id
           ) do
        {:ok, attempt} -> send_json(conn, 201, attempt)
        {:error, reason} -> imessage_integration_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/imessage/connect" do
    with_user(conn, fn user, session ->
      case Comma.IMessageLinks.cancel_attempt(
             user,
             session,
             workspace_id,
             conn.body_params || %{}
           ) do
        {:ok, :ok} -> send_json(conn, 200, %{"cancelled" => true})
        {:error, reason} -> imessage_integration_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/imessage" do
    with_user(conn, fn user, session ->
      case CommaWeb.IMessageIntegration.disconnect(user, session, workspace_id) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> imessage_integration_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/me/bootstrap" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, result} <- Comma.WorkspaceBootstrap.ensure_default(user["id"]) do
        case result["status"] do
          "ready" ->
            send_json(conn, 200, result)

          "provisioning" ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(result["retry_after_seconds"]))
            |> send_json(202, result)
        end
      else
        {:error, reason} -> bootstrap_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces" do
    with_user(conn, fn user, session ->
      case Comma.Workspaces.create_for_session(user["id"], session, conn.body_params || %{}) do
        {:error, :forbidden} ->
          send_error(conn, 403, :forbidden)

        {:error, :workspace_creation_managed} ->
          send_error(conn, 409, :workspace_creation_managed)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/devices" do
    with_user(conn, fn user, session ->
      case Comma.Devices.page(user, session, workspace_id, conn.query_params) do
        {:ok, page} -> send_json(conn, 200, page)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/devices/:device_id" do
    with_user(conn, fn user, session ->
      case Comma.Devices.get(user, session, workspace_id, device_id) do
        {:ok, device} -> send_json(conn, 200, device)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/devices/:device_id" do
    with_user(conn, fn user, session ->
      case Comma.Devices.rename(user, session, workspace_id, device_id, conn.body_params || %{}) do
        {:ok, device} -> send_json(conn, 200, device)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/devices/:device_id" do
    with_user(conn, fn user, session ->
      case Comma.Devices.remove(user, session, workspace_id, device_id) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/devices/:device_id/access" do
    with_user(conn, fn user, session ->
      case Comma.Devices.set_access(
             user,
             session,
             workspace_id,
             device_id,
             conn.body_params || %{}
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/connector-token" do
    with_user(conn, fn user, session ->
      case create_workspace_connector_token(user, session, workspace_id, conn.body_params || %{}) do
        {:ok, token} -> send_json(conn, 201, public_connector_token(token))
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/connector-token" do
    with_user(conn, fn user, session ->
      case revoke_workspace_connector_token(user, session, workspace_id, conn.body_params || %{}) do
        :ok -> send_json(conn, 200, %{"revoked" => true})
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  # ---- Inbound API keys (docs/product-features.md) ----
  #
  # Keys that let an external service post to this workspace's Router. The
  # workspace's default group owns them; the signed-in user is the creator the
  # key acts as under information-flow checking.
  get "/v1/comma/workspaces/:workspace_id/router-api-keys" do
    with_router_api_keys(conn, workspace_id, fn workspace, _user ->
      Salix.Control.GroupApiKeys.list(
        workspace["default_group_id"],
        workspace["salix_tenant_id"]
      )
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/router-api-keys" do
    with_router_api_keys(conn, workspace_id, 201, fn workspace, user ->
      Salix.Control.GroupApiKeys.create(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        router_api_key_attrs(conn.body_params),
        "comma_user:" <> user["id"]
      )
    end)
  end

  patch "/v1/comma/workspaces/:workspace_id/router-api-keys/:key_id" do
    with_router_api_keys(conn, workspace_id, fn workspace, _user ->
      Salix.Control.GroupApiKeys.update(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        key_id,
        router_api_key_attrs(conn.body_params)
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/router-api-keys/:key_id" do
    with_router_api_keys(conn, workspace_id, fn workspace, _user ->
      case Salix.Control.GroupApiKeys.delete(
             workspace["default_group_id"],
             workspace["salix_tenant_id"],
             key_id
           ) do
        :ok -> {:ok, %{"deleted" => true}}
        error -> error
      end
    end)
  end

  # ---- Voice (docs/messaging-voice.md) ----
  #
  # Voice agent API keys are the `voice` kind of the same Group API Key record
  # as inbound keys. A voice key opens only the voice readiness and session
  # routes of the workspace's default group; it acts as the signed-in creator.
  get "/v1/comma/workspaces/:workspace_id/voice-api-keys" do
    with_voice_api_keys(conn, workspace_id, fn workspace, _user ->
      Salix.Control.GroupApiKeys.list(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        "voice"
      )
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/voice-api-keys" do
    with_voice_api_keys(conn, workspace_id, 201, fn workspace, user ->
      Salix.Control.GroupApiKeys.create(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        router_api_key_attrs(conn.body_params),
        "comma_user:" <> user["id"],
        "voice"
      )
    end)
  end

  patch "/v1/comma/workspaces/:workspace_id/voice-api-keys/:key_id" do
    with_voice_api_keys(conn, workspace_id, fn workspace, _user ->
      Salix.Control.GroupApiKeys.update(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        key_id,
        router_api_key_attrs(conn.body_params),
        "voice"
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/voice-api-keys/:key_id" do
    with_voice_api_keys(conn, workspace_id, fn workspace, _user ->
      case Salix.Control.GroupApiKeys.delete(
             workspace["default_group_id"],
             workspace["salix_tenant_id"],
             key_id,
             "voice"
           ) do
        :ok -> {:ok, %{"deleted" => true}}
        error -> error
      end
    end)
  end

  # The caller numbers verified for the workspace's default group, the
  # platform lines they call, their PINs and the platform readiness. An SMS
  # code proves each number; the PIN hash never leaves Salix.
  get "/v1/comma/workspaces/:workspace_id/integrations/voice" do
    with_voice_numbers(conn, workspace_id, fn workspace, _user ->
      Salix.Control.VoiceNumbers.status(
        workspace["default_group_id"],
        workspace["salix_tenant_id"]
      )
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/voice/numbers/verify-start" do
    with_voice_numbers(conn, workspace_id, fn workspace, _user ->
      Salix.Control.VoiceNumbers.verify_start(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        voice_number_attrs(conn.body_params, ["e164", "line"])
      )
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/voice/numbers/verify-check" do
    with_voice_numbers(conn, workspace_id, fn workspace, _user ->
      Salix.Control.VoiceNumbers.verify_check(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        voice_number_attrs(conn.body_params, ["e164", "line", "code"])
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/voice/numbers/:e164" do
    with_voice_numbers(conn, workspace_id, fn workspace, _user ->
      Salix.Control.VoiceNumbers.remove_number(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        e164
      )
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/integrations/voice/pin" do
    with_voice_numbers(conn, workspace_id, fn workspace, _user ->
      Salix.Control.VoiceNumbers.set_pin(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        voice_number_attrs(conn.body_params, ["e164", "pin"])
      )
    end)
  end

  # ---- Signal (docs/messaging-voice.md) ----
  #
  # The Signal chats connected to the workspace's default group. A connection
  # code is shown once; the user sends it on Signal to the workspace's Signal
  # number. The workspace may set its own number, overriding the platform one.
  get "/v1/comma/workspaces/:workspace_id/integrations/signal" do
    with_workspace_signal(conn, workspace_id, fn workspace, _user ->
      Salix.Control.Signal.status(workspace["default_group_id"], workspace["salix_tenant_id"])
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/integrations/signal/claims" do
    with_workspace_signal(conn, workspace_id, fn workspace, user ->
      Salix.Control.Signal.start_claim(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        "comma_user:" <> user["id"]
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/signal/claims/:claim_id" do
    with_workspace_signal(conn, workspace_id, fn workspace, _user ->
      Salix.Control.Signal.cancel_claim(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        claim_id
      )
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/integrations/signal/bindings/:binding_id" do
    with_workspace_signal(conn, workspace_id, fn workspace, _user ->
      Salix.Control.Signal.remove_binding(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        binding_id
      )
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/integrations/signal/number" do
    with_workspace_signal(conn, workspace_id, fn workspace, _user ->
      Salix.Control.Signal.tenant_number(workspace["salix_tenant_id"])
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/integrations/signal/number" do
    with_workspace_signal(conn, workspace_id, fn workspace, _user ->
      Salix.Control.Signal.put_tenant_number(workspace["salix_tenant_id"], %{
        "number" => signal_number_param(conn.body_params)
      })
    end)
  end

  post "/v1/comma/groups/:group_id/meeting-tasks" do
    with_user(conn, fn user, session ->
      case Comma.MeetingTasks.enter(user, session, group_id, conn.body_params || %{}) do
        {:ok, task} -> send_json(conn, 200, task)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/meeting-tasks/:occurrence_id" do
    with_user(conn, fn user, session ->
      case Comma.MeetingTasks.update(
             user,
             session,
             group_id,
             occurrence_id,
             conn.body_params || %{}
           ) do
        {:ok, task} -> send_json(conn, 200, task)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/local-file-refs" do
    with_user(conn, fn user, session ->
      case register_workspace_local_file_ref(
             user,
             session,
             workspace_id,
             conn.body_params || %{}
           ) do
        {:ok, ref} -> send_json(conn, 201, ref)
        {:error, reason} -> local_file_ref_error(conn, reason, workspace_id)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/compute" do
    with_user(conn, fn user, session ->
      case compute_page_options(conn.query_params) do
        {:ok, options} ->
          case Comma.Compute.get(user, session, workspace_id, options) do
            {:ok, result} -> send_json(conn, 200, result)
            {:error, reason} -> compute_error(conn, reason)
          end

        {:error, reason} ->
          compute_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/compute/requests/:request_id" do
    with_user(conn, fn user, session ->
      case Comma.Compute.get_creation(user, session, workspace_id, request_id) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute/environments" do
    with_user(conn, fn user, session ->
      case Comma.Compute.create_environment(user, session, workspace_id, conn.body_params || %{}) do
        {:ok, result} -> send_json(conn, 201, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute/workloads" do
    with_user(conn, fn user, session ->
      case Comma.Compute.create_workload(user, session, workspace_id, conn.body_params || %{}) do
        {:ok, result} -> send_json(conn, 201, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute/grants" do
    with_user(conn, fn user, session ->
      case Comma.Compute.issue_grant(user, session, workspace_id, conn.body_params || %{}) do
        {:ok, result} -> send_json(conn, 201, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      request_id = conn |> get_req_header("idempotency-key") |> List.first()
      attrs = Map.put(conn.body_params || %{}, "request_id", request_id)

      case Comma.Compute.request_agent_vmm_install(user, session, workspace_id, attrs) do
        {:ok, descriptor} ->
          send_json(conn, 200, %{
            "operation" => descriptor.operation,
            "descriptor" => install_descriptor(conn, descriptor)
          })

        {:error, reason} ->
          compute_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations/:operation_id" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      case Comma.Compute.get_agent_vmm_install(user, session, workspace_id, operation_id) do
        {:ok, operation} -> send_json(conn, 200, %{"operation" => operation})
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations/:operation_id/retry" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      case Comma.Compute.retry_agent_vmm_install(user, session, workspace_id, operation_id) do
        {:ok, descriptor} ->
          send_json(conn, 200, %{
            "operation" => descriptor.operation,
            "descriptor" => install_descriptor(conn, descriptor)
          })

        {:error, reason} ->
          compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations/:operation_id/revoke" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      case Comma.Compute.revoke_agent_vmm_install(user, session, workspace_id, operation_id) do
        {:ok, operation} -> send_json(conn, 200, %{"operation" => operation})
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations/:operation_id/enable" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      case Comma.Compute.configure_agent_vmm_install(
             user,
             session,
             workspace_id,
             operation_id,
             true
           ) do
        {:ok, operation} -> send_json(conn, 200, %{"operation" => operation})
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations/:operation_id/initialize-workload" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      case Comma.Compute.initialize_agent_vmm_workload(user, session, workspace_id, operation_id) do
        {:ok, operation} -> send_json(conn, 200, %{"operation" => operation})
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute-nodes/agent-vmm/install-operations/:operation_id/disable" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_user(conn, fn user, session ->
      case Comma.Compute.configure_agent_vmm_install(
             user,
             session,
             workspace_id,
             operation_id,
             false
           ) do
        {:ok, operation} -> send_json(conn, 200, %{"operation" => operation})
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/workspaces/:workspace_id/compute/environments/:environment_id/retention" do
    with_user(conn, fn user, session ->
      case Comma.Compute.retain(
             user,
             session,
             workspace_id,
             environment_id,
             conn.body_params || %{}
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute/environments/:environment_id/drain" do
    with_user(conn, fn user, session ->
      case Comma.Compute.drain(
             user,
             session,
             workspace_id,
             environment_id,
             conn.body_params || %{}
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/compute/environments/:environment_id/revoke" do
    with_user(conn, fn user, session ->
      case Comma.Compute.revoke(
             user,
             session,
             workspace_id,
             environment_id,
             conn.body_params || %{}
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> compute_error(conn, reason)
      end
    end)
  end

  # The owner's automatic proactive messages, shown in Routine settings.
  get "/v1/comma/groups/:group_id/proactive" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, result} <- CommaWeb.Proactive.settings(user, session, group_id) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/groups/:group_id/proactive" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, result} <-
             CommaWeb.Proactive.configure(user, session, group_id, conn.body_params || %{}) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/assistant-chat" do
    ensure_group_chat(conn, group_id)
  end

  defp ensure_group_chat(conn, group_id) do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, conversation} <-
             Comma.AssistantChats.ensure_chat(user, session, group_id) do
        # Home entry starts the owner's source collection chain off the request
        # path. A later entry restarts a chain that stopped.
        case CommaWeb.MemberSourceIngest.enqueue(user, session, group_id) do
          :ok -> :ok
          {:error, _} -> Logger.warning("member source collection could not be queued")
        end

        send_json(conn, 200, conversation)
      else
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/skills" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, skills} <- Comma.Skills.list(user, session, workspace_id) do
        send_json(conn, 200, %{"data" => skills})
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/skills/:skill_id/file" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           path when is_binary(path) <- conn.query_params["path"],
           {:ok, file} <- Comma.Skills.read_file(user, session, workspace_id, skill_id, path) do
        send_json(conn, 200, file)
      else
        nil -> comma_error(conn, :not_found)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/skills/:skill_id" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, skill} <- Comma.Skills.get(user, session, workspace_id, skill_id) do
        send_json(conn, 200, skill)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/plugins" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, plugins} <- Comma.Plugins.list(user, session, workspace_id) do
        send_json(conn, 200, %{"data" => plugins})
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  # Rolling-upgrade compatibility for clients that predate unified Install.
  # The current Comma client does not expose connection as a product action.
  get "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/connection" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, status} <-
             CommaWeb.PluginConnections.get(user, session, workspace_id, plugin_id) do
        send_json(conn, 200, status)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/personal-sources" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, sources} <-
             CommaWeb.PluginConnections.personal_sources(user, session, workspace_id, plugin_id) do
        send_json(conn, 200, sources)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/personal-sources/prepare" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, confirmation} <-
             CommaWeb.PluginConnections.prepare_existing(
               user,
               session,
               workspace_id,
               plugin_id,
               conn.body_params["toolkit"],
               conn.body_params["connection_id"]
             ) do
        send_json(conn, 200, confirmation)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/personal-sources/confirm" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, confirmed} <-
             CommaWeb.PluginConnections.confirm_existing(
               user,
               session,
               workspace_id,
               plugin_id,
               conn.body_params["state"]
             ) do
        send_json(conn, 200, confirmed)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/reauthorize" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, result} <-
             CommaWeb.PluginConnections.reauthorize(
               user,
               session,
               workspace_id,
               plugin_id,
               conn.body_params || %{}
             ) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/personal-sources/cancel" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, :ok} <-
             CommaWeb.PluginConnections.cancel_operation(
               user,
               session,
               workspace_id,
               plugin_id,
               conn.body_params["state"]
             ) do
        send_json(conn, 200, %{"cancelled" => true})
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/authorize" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, authorization} <-
             CommaWeb.PluginConnections.authorize_legacy(
               user,
               session,
               workspace_id,
               plugin_id
             ) do
        send_json(conn, 200, authorization)
      else
        {:error, {:precondition_failed, message}} ->
          send_json(conn, 412, %{error: message})

        {:error, {:internal, _message}} ->
          send_error(conn, 503, :plugins_unavailable)

        {:error, reason} ->
          comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/recommendations" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, recommendations} <-
             CommaWeb.RecommendationRuntime.ensure(
               user,
               session,
               workspace,
               conn.query_params["timezone"],
               conn.query_params["locale"],
               exposure: true
             ) do
        send_json(conn, 200, recommendations)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/workspaces/:workspace_id/recommendations/settings" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, _recommendations} <-
             CommaWeb.RecommendationRuntime.ensure(user, session, workspace),
           {:ok, recommendations} <-
             Comma.Recommendations.update_settings(
               user,
               session,
               workspace_id,
               conn.body_params || %{}
             ),
           {:ok, _profile} <- CommaWeb.RecommendationRuntime.reconcile(user, session, workspace) do
        send_json(conn, 200, recommendations)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id/recommendations/link-preview" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, profile} <-
             Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"]),
           {:ok, preview} <-
             CommaWeb.RecommendationLinkPreview.preview(
               workspace,
               profile.sources,
               conn.query_params["href"],
               conn.query_params["sourceId"]
             ) do
        send_json(conn, 200, preview)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/recommendations/refresh" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           :ok <- CommaWeb.RecommendationRuntime.prepare_refresh(user, session, workspace),
           {:ok, result} <-
             Comma.Recommendations.request_refresh(user, session, workspace_id, "manual") do
        send_json(conn, 202, result)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id/install" do
    with_user(conn, fn user, session ->
      install =
        if conn.body_params["contract"] == "unified_v1" do
          fn user, session, workspace_id, plugin_id ->
            CommaWeb.PluginConnections.install(
              user,
              session,
              workspace_id,
              plugin_id,
              conn.body_params
            )
          end
        else
          &Comma.Plugins.install/4
        end

      with :ok <- full_workspace_session(session),
           {:ok, result} <- install.(user, session, workspace_id, plugin_id) do
        send_json(conn, 200, result)
      else
        {:error, {:precondition_failed, message}} ->
          send_json(conn, 412, %{error: message})

        {:error, {:internal, _message}} ->
          send_error(conn, 503, :plugins_unavailable)

        {:error, reason} ->
          comma_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/workspaces/:workspace_id/plugins/:plugin_id" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, plugin} <-
             CommaWeb.PluginConnections.uninstall(user, session, workspace_id, plugin_id) do
        send_json(conn, 200, plugin)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/files" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, group_scope} <- Comma.Workspaces.authorize_group(user, session, group_id),
           {:ok, upload} <- extract_upload(conn.body_params || %{}),
           {:ok, file} <- Comma.GroupFiles.store(group_scope, upload.filename, upload.binary) do
        send_json(conn, 201, file)
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/files" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, group_scope} <- Comma.Workspaces.authorize_group(user, session, group_id) do
        case Comma.GroupFiles.fetch_image(group_scope, conn.query_params["path"]) do
          {:ok, content_type, body} ->
            conn
            |> put_resp_header("cache-control", "private, no-store")
            |> put_resp_header("content-type", content_type)
            |> put_resp_header("x-content-type-options", "nosniff")
            |> send_resp(200, body)

          {:error, reason} ->
            group_file_read_error(conn, reason)
        end
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/agents/:agent_id/resources" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, group_scope} <- Comma.Workspaces.authorize_group(user, session, group_id),
           %{"ref" => ref} = params when map_size(params) == 1 <- conn.body_params || %{},
           {:ok, body} <- Comma.AgentResources.fetch_blob(group_scope, agent_id, ref) do
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("content-type", "application/octet-stream")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, body)
      else
        {:error, :not_found} -> send_error(conn, 404, :not_found)
        {:error, :forbidden} -> send_error(conn, 403, :forbidden)
        {:error, _internal_reason} -> send_error(conn, 503, :workspace_unavailable)
        _invalid -> send_error(conn, 400, :invalid_resource_ref)
      end
    end)
  end

  # An attachment is addressed by the message it arrived on, not by a workspace
  # path: reading one is exactly as authorized as reading that message.
  get "/v1/comma/groups/:group_id/conversations/:conversation_id/messages/:message_id/attachments/:index" do
    with_user(conn, fn user, session ->
      with :ok <- authorize_task_attachment_session(user, session, group_id, conversation_id),
           {:ok, group_scope} <- Comma.Workspaces.authorize_group(user, session, group_id),
           {:ok, index} <- Comma.ConversationAttachments.parse_index(index) do
        case Comma.ConversationAttachments.fetch(
               group_scope,
               conversation_id,
               message_id,
               index
             ) do
          {:ok, content_type, file_name, body} ->
            conn
            |> put_resp_header("cache-control", "private, no-store")
            |> put_resp_header("content-type", content_type)
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header(
              "content-disposition",
              "attachment; filename*=UTF-8''" <> URI.encode(file_name)
            )
            |> send_resp(200, body)

          {:error, reason} ->
            group_file_read_error(conn, reason)
        end
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/workspaces/:workspace_id" do
    with_user(conn, fn user, session ->
      case Comma.Workspaces.authorize(user, session, workspace_id) do
        {:ok, workspace} -> send_json(conn, 200, Comma.Workspaces.public(workspace))
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/workspaces/:workspace_id" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <-
             Comma.Workspaces.update(user, session, workspace_id, conn.body_params || %{}) do
        send_json(conn, 200, Comma.Workspaces.public(workspace))
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/billing/plans" do
    with {:ok, plans} <- comma_billing_plans() do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_json(200, %{
        "data" => Enum.map(plans, &public_billing_plan/1),
        "signup_credits" => Comma.Billing.SignupCredits.public_policy()
      })
    else
      {:error, reason} -> comma_error(conn, reason)
    end
  end

  get "/v1/comma/workspaces/:workspace_id/billing/summary" do
    with_user(conn, fn user, session ->
      with {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id) do
        send_json(conn, 200, billing_summary(workspace))
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/billing/checkout" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, checkout} <- create_checkout(workspace, user, conn.body_params || %{}) do
        send_json(conn, 201, public_billing_session(checkout))
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/billing/subscription/change" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, portal} <-
             create_subscription_change(workspace, user, conn.body_params || %{}, :change) do
        send_json(conn, 201, portal)
      else
        {:error, reason} -> subscription_change_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/billing/subscription/preview" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, preview} <-
             create_subscription_change(workspace, user, conn.body_params || %{}, :preview) do
        send_json(conn, 200, preview)
      else
        {:error, reason} -> subscription_change_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/billing/subscription/cancel" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, attrs} <- subscription_provider_attrs(workspace, user, conn.body_params || %{}),
           {:ok, result} <- BillingStripe.cancel_subscription_renewal(attrs) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> subscription_change_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/billing/redeem" do
    with_user(conn, fn user, session ->
      attrs = conn.body_params || %{}

      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, command} <-
             BillingCommerce.RedeemCodeCommands.legacy_apply(%{
               "code" => attrs["code"],
               "billing_account_id" => workspace["billing_account_id"],
               "surface" => "comma",
               "product_owner_type" => "workspace",
               "product_owner_id" => workspace["id"],
               "idempotency_key" => attrs["client_request_id"],
               "operator" => %{
                 "id" => user["id"],
                 "type" => "comma_user",
                 "reason" => "self_service_redeem"
               },
               "metadata" => %{"channel" => "comma_paywall"}
             }),
           {:ok, result} <- BillingCommerce.apply_redeem_code(command) do
        send_json(conn, 201, public_redemption_result(result))
      else
        {:error, reason} -> redeem_command_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/workspaces/:workspace_id/billing/portal" do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, portal} <- create_portal(workspace, user, conn.body_params || %{}) do
        send_json(conn, 201, public_billing_session(portal))
      else
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations" do
    with_user(conn, fn user, session ->
      opts = [
        limit: conn.query_params["limit"],
        cursor: conn.query_params["cursor"],
        archive: conn.query_params["archive"]
      ]

      case Comma.Conversations.list_page(user, session, group_id, opts) do
        {:ok, page} ->
          shared =
            Comma.TaskShares.shared_conversation_ids(
              group_id,
              Enum.map(page["data"], & &1["id"])
            )

          send_json_with_etag(
            conn,
            200,
            Map.update!(
              page,
              "data",
              &Enum.map(&1, fn conversation ->
                conversation
                |> Comma.Conversations.public()
                |> put_shared(shared)
              end)
            )
          )

        {:error, reason} ->
          conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/search" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.search(
             user,
             session,
             group_id,
             conn.query_params["q"],
             limit: conn.query_params["limit"]
           ) do
        {:ok, results} -> send_json(conn, 200, results)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversation-pins" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.list_pinned_tasks(user, session, group_id) do
        {:ok, pins} -> send_json_with_etag(conn, 200, pins)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/events" do
    with_user(conn, fn user, session ->
      wait_ms = task_list_sse_wait_ms(conn.query_params["wait"])

      case Comma.Conversations.list_events(
             user,
             session,
             group_id,
             conn.query_params["conversation_id"]
           ) do
        {:ok, stream_context} -> send_task_list_sse(conn, stream_context, wait_ms)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/task-summaries" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.task_summaries(
             user,
             session,
             group_id,
             String.split(conn.query_params["ids"] || "", ",", trim: true)
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/archive" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.set_task_archived(
             user,
             session,
             group_id,
             conversation_id,
             :archive,
             conn.body_params
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/unarchive" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.set_task_archived(
             user,
             session,
             group_id,
             conversation_id,
             :unarchive,
             conn.body_params
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.get(user, session, group_id, conversation_id,
             message_limit: parse_int(conn.query_params["message_limit"], 1000)
           ) do
        {:ok, conversation} ->
          shared = Comma.TaskShares.shared_conversation_ids(group_id, [conversation["id"]])
          send_json_with_etag(conn, 200, put_shared(conversation, shared))

        {:error, reason} ->
          conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/participants/:participant_id/history/events" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.participant_history(
             user,
             session,
             group_id,
             conversation_id,
             participant_id,
             stream: true
           ) do
        {:ok, context} ->
          window =
            case Integer.parse(conn.query_params["wait_ms"] || "55000") do
              {ms, ""} -> min(55_000, max(100, ms))
              _ -> 55_000
            end

          CommaWeb.ParticipantHistoryStream.send(
            conn,
            context,
            conn.query_params["after"],
            window
          )

        {:error, reason} ->
          conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/participants/:participant_id/history" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.participant_history(
             user,
             session,
             group_id,
             conversation_id,
             participant_id,
             limit: conn.query_params["limit"],
             before: conn.query_params["before"]
           ) do
        {:ok, page} ->
          conn |> put_resp_header("cache-control", "private, no-store") |> send_json(200, page)

        {:error, reason} ->
          conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/preview" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.preview(user, session, group_id, conversation_id,
             include_worker: conn.query_params["include_worker"] == "true"
           ) do
        {:ok, preview} -> send_json_with_etag(conn, 200, preview)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/groups/:group_id/conversations/:conversation_id" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.update(
             user,
             session,
             group_id,
             conversation_id,
             conn.body_params || %{}
           ) do
        {:ok, conversation} -> send_json(conn, 200, conversation)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/share" do
    with_user(conn, fn user, session ->
      case Comma.TaskShares.get(user, session, group_id, conversation_id) do
        {:ok, share} -> send_json(conn, 200, CommaWeb.TaskShareEndpoints.owner_json(share))
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/groups/:group_id/conversations/:conversation_id/share" do
    with_user(conn, fn user, session ->
      case Comma.TaskShares.publish(user, session, group_id, conversation_id) do
        {:ok, share} -> send_json(conn, 200, CommaWeb.TaskShareEndpoints.owner_json(share))
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/share/reset" do
    with_user(conn, fn user, session ->
      case Comma.TaskShares.reset(user, session, group_id, conversation_id) do
        {:ok, share} -> send_json(conn, 200, CommaWeb.TaskShareEndpoints.owner_json(share))
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/groups/:group_id/conversations/:conversation_id/share" do
    with_user(conn, fn user, session ->
      case Comma.TaskShares.revoke(user, session, group_id, conversation_id) do
        :ok -> send_json(conn, 200, %{revoked: true})
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/task-shares" do
    with_user(conn, fn user, session ->
      opts = [limit: conn.query_params["limit"], cursor: conn.query_params["cursor"]]

      case Comma.TaskShares.list(user, session, group_id, opts) do
        {:ok, page} ->
          send_json(
            conn,
            200,
            Map.update!(
              page,
              "data",
              &Enum.map(&1, fn share -> CommaWeb.TaskShareEndpoints.owner_json(share) end)
            )
          )

        {:error, reason} ->
          conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/task-order" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.get_task_order(user, session, group_id) do
        {:ok, orders} -> send_json(conn, 200, orders)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/groups/:group_id/task-order/:bucket" do
    with_user(conn, fn user, session ->
      ids = (conn.body_params || %{})["ids"]

      case Comma.Conversations.put_task_order(user, session, group_id, bucket, ids) do
        {:ok, orders} -> send_json(conn, 200, orders)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  # ---- task labels (catalog + human confirmation of agent proposals) ----

  get "/v1/comma/groups/:group_id/task-labels" do
    with_user(conn, fn user, session ->
      case Comma.TaskLabels.list(user, session, group_id) do
        {:ok, catalog} -> send_json(conn, 200, catalog)
        {:error, reason} -> task_label_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/task-labels" do
    with_user(conn, fn user, session ->
      case Comma.TaskLabels.create(user, session, group_id, conn.body_params || %{}) do
        {:ok, catalog} -> send_json(conn, 201, catalog)
        {:error, reason} -> task_label_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/groups/:group_id/task-labels/policy" do
    with_user(conn, fn user, session ->
      case Comma.TaskLabels.update_policy(user, session, group_id, conn.body_params || %{}) do
        {:ok, catalog} -> send_json(conn, 200, catalog)
        {:error, reason} -> task_label_error(conn, reason)
      end
    end)
  end

  patch "/v1/comma/groups/:group_id/task-labels/:label_id" do
    with_user(conn, fn user, session ->
      case Comma.TaskLabels.update(user, session, group_id, label_id, conn.body_params || %{}) do
        {:ok, catalog} -> send_json(conn, 200, catalog)
        {:error, reason} -> task_label_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/groups/:group_id/task-labels/:label_id" do
    with_user(conn, fn user, session ->
      case Comma.TaskLabels.delete(user, session, group_id, label_id) do
        {:ok, catalog} -> send_json(conn, 200, catalog)
        {:error, reason} -> task_label_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/task-labels/proposals/:proposal_id/resolve" do
    with_user(conn, fn user, session ->
      case Comma.TaskLabels.resolve_proposal(
             user,
             session,
             group_id,
             proposal_id,
             conn.body_params || %{}
           ) do
        {:ok, catalog} -> send_json(conn, 200, catalog)
        {:error, reason} -> task_label_error(conn, reason)
      end
    end)
  end

  put "/v1/comma/groups/:group_id/conversations/:conversation_id/pin" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.pin_task(user, session, group_id, conversation_id) do
        {:ok, pin} -> send_json(conn, 200, pin)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  delete "/v1/comma/groups/:group_id/conversations/:conversation_id/pin" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.unpin_task(user, session, group_id, conversation_id) do
        :ok -> send_resp(conn, 204, "")
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/messages" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.send_message(
             user,
             session,
             group_id,
             conversation_id,
             conn.body_params || %{}
           ) do
        {:ok, conversation} -> send_json(conn, 202, conversation)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/accept" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.accept_task_review(
             user,
             session,
             group_id,
             conversation_id,
             conn.body_params || %{}
           ) do
        {:ok, conversation} -> send_json(conn, 200, conversation)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/suggestions" do
    with_user(conn, fn user, session ->
      case Comma.ChatSuggestions.generate(user, session, group_id, conversation_id,
             locale: conn.query_params["locale"]
           ) do
        {:ok, suggestions} -> send_json(conn, 200, %{"data" => suggestions})
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/messages" do
    with_user(conn, fn user, session ->
      page_opts =
        [
          before: conn.query_params["before"],
          after: conn.query_params["after"],
          around: conn.query_params["around"],
          limit: conn.query_params["limit"]
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

      if page_opts == [] do
        case Comma.Conversations.messages(user, session, group_id, conversation_id) do
          {:ok, messages} -> send_json_with_etag(conn, 200, %{"data" => messages})
          {:error, reason} -> conversation_error(conn, reason)
        end
      else
        case Comma.Conversations.message_page(user, session, group_id, conversation_id, page_opts) do
          {:ok, page} -> send_json_with_etag(conn, 200, message_page_json(page))
          {:error, reason} -> conversation_error(conn, reason)
        end
      end
    end)
  end

  defp message_page_json(page) do
    %{
      "data" => page["messages"],
      "covered" => sequence_span(page["covered"], "first_seq", "last_seq"),
      "has_older" => page["has_older"],
      "has_newer" => page["has_newer"],
      "bounds" => sequence_span(page["bounds"], "head_seq", "tail_seq")
    }
  end

  defp sequence_span(nil, _first_key, _last_key), do: nil

  defp sequence_span(span, first_key, last_key),
    do: %{"first" => span[first_key], "last" => span[last_key]}

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/messages/:message_id/context" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.message_context(
             user,
             session,
             group_id,
             conversation_id,
             message_id
           ) do
        {:ok, messages} -> send_json_with_etag(conn, 200, %{"data" => messages})
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  get "/v1/comma/groups/:group_id/conversations/:conversation_id/events" do
    with_user(conn, fn user, session ->
      wait_param = conn.query_params["wait"]
      wait_ms = comma_sse_wait_ms(wait_param)
      stream_window_ms = comma_sse_stream_window_ms(wait_param, wait_ms)

      case Comma.Conversations.events(user, session, group_id, conversation_id) do
        {:ok, snapshot, events, stream_context} ->
          send_comma_sse(
            conn,
            conversation_id,
            snapshot,
            events,
            stream_context,
            wait_ms,
            stream_window_ms
          )

        {:error, reason} ->
          conversation_error(conn, reason)
      end
    end)
  end

  post "/v1/comma/groups/:group_id/conversations/:conversation_id/cancel" do
    with_user(conn, fn user, session ->
      case Comma.Conversations.cancel(user, session, group_id, conversation_id) do
        {:ok, conversation} -> send_json(conn, 200, conversation)
        {:error, reason} -> conversation_error(conn, reason)
      end
    end)
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  def cache_body(conn, opts), do: read_cached_body(conn, opts, [])

  defp read_cached_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw_body = IO.iodata_to_binary(Enum.reverse([body | acc]))
        {:ok, raw_body, Plug.Conn.assign(conn, :raw_body, raw_body)}

      {:more, body, conn} ->
        read_cached_body(conn, opts, [body | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_admin_query(conn, fun) do
    if conn.assigns[:admin_actor] in [:ops, :comma_user] do
      fun.()
    else
      send_error(conn, 403, :forbidden)
    end
  end

  defp run_agent_vmm_admin_command(conn, action, tenant_id, target_id, attrs) do
    case {conn.assigns[:admin_actor], conn.assigns[:comma_user]} do
      {:comma_user, actor_user} when is_map(actor_user) ->
        Comma.Admin.run_human_receipted_external_command(
          actor_user,
          action,
          attrs,
          agent_vmm_target_type(action),
          target_id,
          fn command_attrs, _actor, _contract ->
            with true <- action in SalixStore.AgentVMMAdminCommands.actions(),
                 true <- tenant_id != "invalid" and tenant_id != "",
                 revision when is_integer(revision) and revision >= 0 <-
                   command_attrs["expected_revision"] do
              command = %{
                action: action,
                tenant_id: tenant_id,
                target_id: target_id,
                expected_revision: revision
              }

              {:ok,
               %{
                 command: command,
                 target_type: agent_vmm_target_type(action),
                 target_id: target_id,
                 expected_confirmation: "#{action}:#{target_id}:#{revision}",
                 fingerprint: %{
                   "action" => action,
                   "tenant_id" => tenant_id,
                   "target_id" => target_id,
                   "expected_revision" => revision
                 }
               }}
            else
              false -> {:error, :not_found}
              _ -> {:error, :invalid_command}
            end
          end,
          fn command_id, command ->
            SalixStore.AgentVMMAdminCommands.execute(command_id, command)
          end,
          &SalixStore.AgentVMMAdminCommands.replay_receipt/2
        )

      _ ->
        {:error, :forbidden}
    end
  end

  defp agent_vmm_target_type("retry_agent_vmm_install"), do: "agent_vmm_installation"

  defp agent_vmm_target_type(action)
       when action in [
              "drain_compute_environment",
              "revoke_compute_environment",
              "create_shell_workload"
            ],
       do: "compute_environment"

  defp agent_vmm_target_type(_action), do: "agent_vmm_registration"

  defp agent_vmm_filters(params) do
    Map.take(
      params,
      ~w(group_id status desired_enabled q connection work issue updated_from updated_to)
    )
  end

  defp decode_agent_vmm_cursor(nil, _tenant_id, _filters), do: {:ok, nil}

  defp decode_agent_vmm_cursor(cursor, tenant_id, filters),
    do: SalixWeb.AgentVMMAdminCursor.decode(cursor, tenant_id, filters)

  defp encode_agent_vmm_cursor(nil, _tenant_id, _filters), do: {:ok, nil}

  defp encode_agent_vmm_cursor(cursor, tenant_id, filters),
    do: SalixWeb.AgentVMMAdminCursor.encode(tenant_id, cursor, filters)

  defp agent_vmm_query_error(conn, reason) when reason in [:invalid, :invalid_query],
    do: send_error(conn, 400, :invalid_query)

  defp agent_vmm_query_error(conn, :not_found), do: send_error(conn, 404, :not_found)
  defp agent_vmm_query_error(conn, _reason), do: send_error(conn, 503, :unavailable)

  # OAuth client commands 404 while the IdP surface is disabled — the
  # admin plane must not leak the feature's existence ahead of rollout.
  #
  # The strict command DTO is parsed BEFORE any audit intent exists
  # (run_human_external_command's prepare phase), so invalid input is
  # recorded as rejected and never consumes the idempotency key, and
  # the executed command is built from parsed data only. Client
  # resolution reads the database directly (Comma.OauthIdp.Clients), so
  # no cache-invalidation step exists on this path at all.
  defp run_oauth_client_command(conn, action, rejected_target_id, prepare) do
    if CommaWeb.OauthIdpEndpoints.enabled?() do
      attrs = (conn.body_params || %{}) |> Map.delete("admin_command_id")

      observe_admin_command(action, fn ->
        case conn.assigns[:admin_actor] do
          :ops ->
            with {:ok, prepared} <- prepare.(attrs) do
              execute_oauth_client_command(prepared.command)
            end

          :comma_user ->
            case conn.assigns[:comma_user] do
              actor_user when is_map(actor_user) ->
                Comma.Admin.run_human_external_command(
                  actor_user,
                  action,
                  attrs,
                  "oauth_client",
                  rejected_target_id,
                  fn command_attrs, _actor, _contract -> prepare.(command_attrs) end,
                  fn _command_id, command -> execute_oauth_client_command(command) end
                )

              _ ->
                {:error, :forbidden}
            end

          _ ->
            {:error, :forbidden}
        end
      end)
    else
      {:error, :not_found}
    end
  end

  defp oauth_lifecycle_prepared(operation, confirmation_slug, client_id) do
    %{
      command: {operation, client_id},
      target_type: "oauth_client",
      target_id: client_id,
      expected_confirmation: "#{confirmation_slug}:#{client_id}",
      fingerprint: %{"client_id" => client_id}
    }
  end

  defp execute_oauth_client_command({:create, command}),
    do: Comma.OauthIdp.ClientAdmin.execute_create(command)

  defp execute_oauth_client_command({:rotate, client_id}),
    do: Comma.OauthIdp.ClientAdmin.rotate_secret(client_id)

  defp execute_oauth_client_command({:disable, client_id}),
    do: Comma.OauthIdp.ClientAdmin.disable(client_id)

  defp execute_oauth_client_command({:enable, client_id}),
    do: Comma.OauthIdp.ClientAdmin.enable(client_id)

  defp run_admin_command(
         conn,
         action,
         target_type,
         target_id,
         expected_confirmation,
         command
       ) do
    attrs = (conn.body_params || %{}) |> Map.delete("admin_command_id")

    observe_admin_command(action, fn ->
      case conn.assigns[:admin_actor] do
        :ops ->
          command.(:ops, attrs)

        :comma_user ->
          case conn.assigns[:comma_user] do
            actor_user when is_map(actor_user) ->
              Comma.Admin.run_human_command(
                actor_user,
                action,
                target_type,
                target_id,
                attrs,
                expected_confirmation,
                fn command_id ->
                  command.(actor_user, Map.put(attrs, "admin_command_id", command_id))
                end
              )

            _ ->
              {:error, :forbidden}
          end

        _ ->
          {:error, :forbidden}
      end
    end)
  end

  defp run_redeem_command(
         conn,
         action,
         rejected_target_type,
         rejected_target_id,
         human_prepare,
         ops_prepare,
         execute
       )
       when is_function(human_prepare, 3) and is_function(ops_prepare, 1) and
              is_function(execute, 1) do
    attrs = conn.body_params || %{}

    observe_admin_command(action, fn ->
      case conn.assigns[:admin_actor] do
        :ops ->
          with {:ok, command} <- ops_prepare.(attrs) do
            case execute.(command) do
              {:already_applied, value} -> {:ok, value}
              result -> result
            end
          end

        :comma_user ->
          case conn.assigns[:comma_user] do
            actor_user when is_map(actor_user) ->
              Comma.Admin.run_human_external_command(
                actor_user,
                action,
                attrs,
                rejected_target_type,
                rejected_target_id,
                human_prepare,
                fn command_id, command ->
                  command
                  |> BillingCommerce.RedeemCodeCommands.bind_admin_command(command_id)
                  |> execute.()
                end
              )

            _ ->
              {:error, :forbidden}
          end

        _ ->
          {:error, :forbidden}
      end
    end)
  end

  defp run_workspace_credit_command(conn, user_id) do
    attrs = conn.body_params || %{}

    observe_admin_command("issue_workspace_credits", fn ->
      case {conn.assigns[:admin_actor], conn.assigns[:comma_user]} do
        {:comma_user, actor_user} when is_map(actor_user) ->
          Comma.Admin.run_human_external_command(
            actor_user,
            "issue_workspace_credits",
            attrs,
            "user",
            user_id,
            fn command_attrs, actor, contract ->
              with {:ok, target} <- Comma.Admin.get_user_workspace_credit_target(user_id) do
                BillingCommerce.ManualGrantCommands.prepare_human_issue(
                  command_attrs,
                  actor,
                  contract,
                  target
                )
              end
            end,
            fn command_id, command ->
              command
              |> BillingCommerce.ManualGrantCommands.bind_admin_command(command_id)
              |> BillingCommerce.issue_comma_admin_support_grant()
            end
          )

        _ ->
          {:error, :forbidden}
      end
    end)
  end

  defp observe_admin_command(action, fun) do
    started = System.monotonic_time()

    try do
      result = fun.()

      CommaProduct.Telemetry.emit_admin_command(
        action,
        admin_command_outcome(result),
        System.monotonic_time() - started
      )

      result
    rescue
      exception ->
        CommaProduct.Telemetry.emit_admin_command(
          action,
          :error,
          System.monotonic_time() - started
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp admin_command_outcome({:error, reason})
       when reason in [
              :admin_command_already_failed,
              :admin_command_already_succeeded,
              :admin_command_in_progress,
              :admin_idempotency_key_conflict
            ],
       do: :conflict

  defp admin_command_outcome({:error, reason})
       when reason in [
              :disabled,
              :forbidden,
              :invalid_admin_confirmation,
              :invalid_admin_idempotency_key,
              :invalid_admin_reason,
              :invalid_redeem_code,
              :invalid_redeem_code_id,
              :invalid_redeem_code_type,
              :invalid_redeem_request,
              :invalid_manual_grant,
              :invalid_model_template,
              :unsupported_admin_command,
              :invalid_workspace_vm,
              :invalid_workspace_agent_model,
              :invalid_workspace_agent_role,
              :invalid_oauth_client,
              :invalid_oauth_client_name,
              :reserved_oauth_client_name,
              :invalid_redirect_uri,
              :too_many_redirect_uris,
              :invalid_oauth_client_confidential,
              :invalid_oauth_client_field,
              :oauth_client_not_confidential,
              :oauth_client_not_found
            ],
       do: :rejected

  defp admin_command_outcome({:error, reason})
       when reason in [
              :admin_audit_unavailable,
              :billing_unavailable,
              :workspace_invariant,
              :workspace_agent_models_unavailable,
              :workspace_provisioning,
              :workspace_provisioning_failed,
              :workspace_unavailable,
              :model_catalog_too_large
            ],
       do: :unavailable

  defp admin_command_outcome({:error, _reason}), do: :error
  defp admin_command_outcome(_result), do: :ok

  defp admin_reason(:ops, attrs) do
    case attrs["reason"] do
      reason when is_binary(reason) and byte_size(reason) >= 3 -> String.slice(reason, 0, 500)
      _ -> "Deployment bearer command"
    end
  end

  defp admin_reason(%{"id" => _actor_user_id}, attrs), do: String.trim(attrs["reason"])

  defp with_ops_admin(conn, fun) do
    if conn.assigns[:admin_actor] == :ops do
      fun.()
    else
      send_error(conn, 403, :forbidden)
    end
  end

  defp admin_command_error(conn, %Ecto.Changeset{}),
    do: send_error(conn, 400, :validation_failed)

  defp admin_command_error(conn, :not_found), do: send_error(conn, 404, :not_found)

  defp admin_command_error(conn, :oauth_client_not_found),
    do: send_error(conn, 404, :oauth_client_not_found)

  defp admin_command_error(conn, reason) when reason in [:disabled, :forbidden],
    do: send_error(conn, 403, reason)

  defp admin_command_error(conn, reason)
       when reason in [
              :admin_command_already_failed,
              :admin_command_already_succeeded,
              :admin_command_in_progress,
              :admin_idempotency_key_conflict,
              :idempotency_conflict,
              :revision_conflict
            ],
       do: send_error(conn, 409, reason)

  defp admin_command_error(conn, reason)
       when reason in [
              :billing_account_inactive,
              :billing_account_not_found,
              :billing_account_owner_mismatch,
              :billing_account_surface_mismatch,
              :package_surface_mismatch,
              :package_version_expired,
              :package_version_inactive,
              :package_version_not_yet_effective
            ],
       do: send_error(conn, 409, reason)

  defp admin_command_error(conn, reason)
       when reason in [
              :admin_audit_unavailable,
              :billing_unavailable,
              :workspace_invariant,
              :workspace_agent_models_unavailable,
              :workspace_provisioning,
              :workspace_provisioning_failed,
              :workspace_unavailable,
              :model_catalog_too_large,
              :unavailable
            ],
       do: send_error(conn, 503, reason)

  defp admin_command_error(conn, reason), do: send_error(conn, 400, reason)

  defp workspace_agent_models_error(conn, :not_found),
    do: send_error(conn, 404, :not_found)

  defp workspace_agent_models_error(conn, reason)
       when reason in [
              :model_catalog_too_large,
              :workspace_agent_models_unavailable,
              :workspace_invariant,
              :workspace_provisioning,
              :workspace_provisioning_failed,
              :workspace_unavailable
            ],
       do: send_error(conn, 503, reason)

  defp workspace_agent_models_error(conn, _reason),
    do: send_error(conn, 503, :workspace_agent_models_unavailable)

  defp redeem_command_error(conn, reason)
       when reason in [
              :admin_command_already_failed,
              :admin_command_already_succeeded,
              :admin_command_in_progress,
              :admin_idempotency_key_conflict,
              :admin_audit_unavailable,
              :forbidden,
              :invalid_admin_confirmation,
              :invalid_admin_idempotency_key,
              :invalid_admin_reason,
              :unsupported_admin_command
            ],
       do: admin_command_error(conn, reason)

  defp redeem_command_error(conn, reason),
    do: send_error(conn, redeem_apply_status(reason), reason)

  defp presented_token(conn) do
    conn.assigns[:auth_token]
  end

  defp put_shared(%{"kind" => "agent_task", "id" => id} = conversation, shared),
    do: Map.put(conversation, "shared", MapSet.member?(shared, id))

  defp put_shared(conversation, _shared), do: conversation

  defp with_user(conn, fun) do
    case {conn.assigns[:comma_user], conn.assigns[:comma_session]} do
      {user, session} when is_map(user) and is_map(session) -> fun.(user, session)
      _ -> send_error(conn, 401, :unauthorized)
    end
  end

  defp with_session_management(conn, fun) do
    with_user(conn, fn user, session ->
      case full_workspace_session(session) do
        :ok -> fun.(user, session)
        {:error, reason} -> send_error(conn, 403, reason)
      end
    end)
  end

  defp with_profile_management(conn, fun), do: with_session_management(conn, fun)

  defp bootstrap_error(conn, reason) when reason in [:disabled, :forbidden],
    do: send_error(conn, 403, reason)

  defp bootstrap_error(conn, :not_found), do: send_error(conn, 404, :not_found)
  defp bootstrap_error(conn, _internal_reason), do: send_error(conn, 503, :workspace_unavailable)

  defp synchronicity_error(conn, :not_configured),
    do: send_error(conn, 503, :synchronicity_unavailable)

  defp synchronicity_error(conn, :workspace_not_found),
    do: send_error(conn, 404, :workspace_not_found)

  defp synchronicity_error(conn, :not_provisioned),
    do: send_error(conn, 409, :workspace_not_provisioned)

  defp synchronicity_error(conn, :owner_not_found),
    do: send_error(conn, 404, :owner_not_found)

  defp synchronicity_error(conn, :auth),
    do: send_error(conn, 502, :synchronicity_auth)

  defp synchronicity_error(conn, {:invalid, {:conflict, _reason}}),
    do: send_error(conn, 409, :device_conflict)

  defp synchronicity_error(conn, {:invalid, _reason}),
    do: send_error(conn, 400, :invalid_request)

  defp synchronicity_error(conn, {:retryable, _reason}),
    do: send_error(conn, 503, :synchronicity_unavailable)

  defp synchronicity_error(conn, _reason),
    do: send_error(conn, 502, :synchronicity_error)

  defp compute_page_options(params) do
    with true <- is_binary(params["limit"] || "50"),
         true <- is_binary(params["workload_after"] || ""),
         {limit, ""} <- Integer.parse(params["limit"] || "50"),
         true <- limit in 1..100,
         true <- byte_size(params["workload_after"] || "") <= 160 do
      {:ok,
       %{
         limit: limit,
         workload_after: params["workload_after"] || ""
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp compute_error(conn, :compute_node_not_ready),
    do: send_error(conn, 409, :compute_node_not_ready)

  defp compute_error(conn, :revision_conflict),
    do: send_error(conn, 409, :revision_conflict)

  defp compute_error(conn, :already_exists), do: send_error(conn, 409, :already_exists)

  defp compute_error(conn, :unavailable), do: send_error(conn, 503, :compute_unavailable)

  defp compute_error(conn, :idempotency_conflict),
    do: send_error(conn, 409, :idempotency_conflict)

  defp compute_error(conn, :operation_not_retryable),
    do: send_error(conn, 409, :operation_not_retryable)

  defp compute_error(conn, {:operation_exists, _operation_id}),
    do: send_error(conn, 409, :operation_not_retryable)

  defp compute_error(conn, reason), do: comma_error(conn, reason)

  defp install_descriptor(conn, descriptor) do
    request_uri =
      case Application.get_env(:salix_web, :public_base_url) do
        value when is_binary(value) and value != "" -> URI.parse(value)
        _ -> conn |> request_url() |> URI.parse()
      end

    port = if request_uri.port in [nil, 80, 443], do: nil, else: request_uri.port

    exchange_url =
      %URI{
        scheme: request_uri.scheme,
        host: request_uri.host,
        port: port,
        path: "/v1/compute/agent-vmm/install-operations/exchange"
      }
      |> URI.to_string()

    %{
      "version" => 1,
      "operation_id" => descriptor.operation.id,
      "exchange_url" => exchange_url,
      "one_time_secret" => descriptor.one_time_secret,
      "expires_at" => DateTime.to_iso8601(descriptor.expires_at)
    }
  end

  # Label catalog errors come from Salix as plain product reasons: a missing
  # label/proposal, a rejected field, or a conflict (duplicate name, already
  # resolved). Everything else is a workspace/auth failure `comma_error` owns.
  defp task_label_error(conn, :not_found), do: send_error(conn, 404, :not_found)
  defp task_label_error(conn, {:bad_request, _message} = reason), do: comma_error(conn, reason)
  defp task_label_error(conn, {:conflict, message}), do: send_json(conn, 409, %{error: message})
  defp task_label_error(conn, reason), do: comma_error(conn, reason)

  defp comma_error(conn, :not_found), do: send_error(conn, 404, :not_found)
  defp comma_error(conn, :forbidden), do: send_error(conn, 403, :forbidden)

  defp comma_error(conn, :model_not_user_selectable),
    do: send_error(conn, 403, :model_not_user_selectable)

  defp comma_error(conn, reason)
       when reason in [:model_selection_policy_missing, :model_selection_policy_unavailable],
       do: send_error(conn, 503, :model_selection_policy_unavailable)

  defp comma_error(conn, :workspace_provisioning), do: send_workspace_provisioning(conn)

  defp comma_error(conn, reason)
       when reason in [
              :workspace_invariant,
              :workspace_provisioning_failed,
              :workspace_unavailable
            ],
       do: send_error(conn, 503, :workspace_unavailable)

  defp comma_error(conn, {:unavailable, _internal_reason}),
    do: send_error(conn, 503, :workspace_unavailable)

  defp comma_error(conn, :budget_exhausted), do: send_error(conn, 402, :budget_exhausted)
  defp comma_error(conn, :tool_not_allowed), do: send_error(conn, 403, :tool_not_allowed)
  defp comma_error(conn, :expired), do: send_error(conn, 401, :expired)
  defp comma_error(conn, :skills_unavailable), do: send_error(conn, 503, :skills_unavailable)
  defp comma_error(conn, :plugins_unavailable), do: send_error(conn, 503, :plugins_unavailable)
  defp comma_error(conn, :rate_limited), do: send_error(conn, 429, :rate_limited)
  defp comma_error(conn, :file_required), do: send_error(conn, 400, :file_required)

  defp comma_error(conn, :unsupported_file_type),
    do: send_error(conn, 415, :unsupported_file_type)

  defp comma_error(conn, :file_too_large), do: send_error(conn, 413, :file_too_large)
  defp comma_error(conn, {:bad_request, message}), do: send_json(conn, 400, %{error: message})
  defp comma_error(conn, {:forbidden, message}), do: send_json(conn, 403, %{error: message})

  defp comma_error(conn, :stable_device_unavailable),
    do: send_error(conn, 403, :stable_device_unavailable)

  defp comma_error(conn, {:conflict, _message}), do: send_error(conn, 409, :conflict)
  defp comma_error(conn, :exists), do: send_error(conn, 409, :exists)
  defp comma_error(conn, :unsupported_for_kind), do: send_error(conn, 409, :unsupported_for_kind)

  defp comma_error(conn, {:unsupported_for_kind, kind, operation}) do
    send_json(conn, 409, %{
      error: "unsupported_for_kind",
      code: "unsupported_for_kind",
      kind: kind,
      operation: operation
    })
  end

  defp comma_error(conn, :stripe_customer_not_linked),
    do: send_error(conn, 409, :stripe_customer_not_linked)

  defp comma_error(conn, :stripe_price_not_synced),
    do: send_error(conn, 409, :stripe_price_not_synced)

  defp comma_error(conn, reason), do: send_error(conn, 400, reason)

  defp telegram_integration_error(conn, reason) when reason in [:not_found, :forbidden],
    do: comma_error(conn, reason)

  defp telegram_integration_error(conn, reason)
       when reason in [:telegram_unavailable, :telegram_oidc_unavailable],
       do: send_error(conn, 503, reason)

  defp telegram_integration_error(conn, :invalid_telegram_claim),
    do: send_error(conn, 400, :invalid_telegram_claim)

  defp telegram_integration_error(conn, :invalid_telegram_connection_attempt),
    do: send_error(conn, 400, :invalid_telegram_connection_attempt)

  defp telegram_integration_error(conn, :telegram_link_busy),
    do: send_error(conn, 409, :telegram_link_busy)

  defp telegram_integration_error(conn, _reason),
    do: send_error(conn, 502, :telegram_integration_unavailable)

  defp wechat_result(conn, result, status \\ 200)

  defp wechat_result(conn, {:ok, result}, status),
    do: conn |> put_resp_header("cache-control", "no-store") |> send_json(status, result)

  defp wechat_result(conn, {:error, reason}, _status) when reason in [:not_found, :forbidden],
    do: comma_error(conn, reason)

  defp wechat_result(conn, {:error, reason}, _status)
       when reason in [
              :invalid_wechat_connection_attempt,
              :invalid_wechat_verification_code,
              :wechat_login_expired
            ],
       do: send_error(conn, 400, reason)

  defp wechat_result(conn, {:error, :wechat_link_busy}, _status),
    do: send_error(conn, 409, :wechat_link_busy)

  defp wechat_result(conn, {:error, {:bad_request, _}}, _status),
    do: send_error(conn, 409, :wechat_already_connected)

  defp wechat_result(conn, {:error, _}, _status),
    do: send_error(conn, 502, :wechat_integration_unavailable)

  defp imessage_integration_error(conn, reason) when reason in [:not_found, :forbidden],
    do: comma_error(conn, reason)

  defp imessage_integration_error(conn, reason)
       when reason in [:imessage_unavailable],
       do: send_error(conn, 503, reason)

  defp imessage_integration_error(conn, :invalid_imessage_claim),
    do: send_error(conn, 400, :invalid_imessage_claim)

  defp imessage_integration_error(conn, :invalid_imessage_connection_attempt),
    do: send_error(conn, 400, :invalid_imessage_connection_attempt)

  defp imessage_integration_error(conn, :imessage_link_busy),
    do: send_error(conn, 409, :imessage_link_busy)

  defp imessage_integration_error(conn, _reason),
    do: send_error(conn, 502, :imessage_integration_unavailable)

  defp group_file_read_error(conn, :not_found), do: send_error(conn, 404, :not_found)

  defp group_file_read_error(conn, _internal_reason),
    do: send_error(conn, 503, :workspace_unavailable)

  # Salix/storage failures may contain canonical Group, Conversation, Message,
  # participant, or object-store keys. Only explicitly enumerated product
  # errors may cross this boundary; arbitrary atoms, binaries and tuples fail
  # closed so no internal reason text can become a `/v1` response.
  defp conversation_error(conn, :invalid_task_labels),
    do: send_error(conn, 400, :invalid_task_labels)

  defp conversation_error(conn, {:bad_request, "invalid conversation cursor"} = reason),
    do: comma_error(conn, reason)

  defp conversation_error(conn, {:bad_request, message} = reason)
       when message in [
              "At most 50 ids are allowed",
              "ids must contain strings",
              "Invalid archive filter",
              "Task and positive expected_updated_at are required",
              "expected_updated_at must be a positive integer",
              "q is required",
              "q must contain at least 2 characters",
              "q must contain at most 128 characters",
              "q contains an unsupported null character",
              "limit must be between 1 and 50",
              "invalid search parameters",
              "limit must be a positive integer",
              "before must be a positive integer",
              "after must be a positive integer",
              "around must be a positive integer",
              "at most one of before, after, around is allowed"
            ],
       do: comma_error(conn, reason)

  defp conversation_error(conn, :invalid_cursor),
    do: send_error(conn, 400, :invalid_cursor)

  defp conversation_error(conn, {:conflict, _internal_message} = reason),
    do: comma_error(conn, reason)

  defp conversation_error(conn, {:pin_collection_over_limit, _limit}),
    do: send_error(conn, 409, :pin_collection_over_limit)

  defp conversation_error(conn, reason)
       when reason in [:invalid_task_order, :invalid_task_order_bucket],
       do: send_error(conn, 400, reason)

  defp conversation_error(conn, {:task_order_over_limit, _limit}),
    do: send_error(conn, 400, :invalid_task_order)

  defp conversation_error(conn, {:task_order_bucket_limit, _limit}),
    do: send_error(conn, 409, :task_order_bucket_limit)

  defp conversation_error(conn, {:unsupported_for_kind, kind, operation} = reason)
       when kind in ["user_chat", "agent_task"] and
              operation in ["patch", "cancel", "events", "accept", "pin", "unpin"],
       do: comma_error(conn, reason)

  defp conversation_error(conn, {:billing_unavailable, decision}),
    do:
      send_json(conn, 402, %{
        error: "billing_unavailable",
        reason: conversation_billing_reason(decision)
      })

  defp conversation_error(conn, :workspace_provisioning),
    do: send_workspace_provisioning(conn)

  defp conversation_error(conn, reason)
       when reason in [:workspace_invariant, :workspace_provisioning_failed],
       do: send_error(conn, 503, :workspace_unavailable)

  defp conversation_error(conn, reason) when reason in @conversation_public_error_reasons,
    do: comma_error(conn, reason)

  defp conversation_error(conn, reason) when reason in @conversation_unavailable_reasons,
    do: send_error(conn, 503, :conversation_unavailable)

  defp conversation_error(conn, reason)
       when reason in [
              :mail_source_changed,
              :mail_source_handled,
              :mail_request_conflict,
              :mail_operation_pending,
              :mail_tracking_capacity,
              :mail_monitor_capacity
            ],
       do: send_error(conn, 409, reason)

  defp conversation_error(conn, reason)
       when reason in [:invalid_mail_action, :invalid_mail_source, :mail_request_id_required],
       do: send_error(conn, 400, reason)

  defp conversation_error(conn, :mail_source_not_found),
    do: send_error(conn, 404, :mail_source_not_found)

  defp conversation_error(conn, _internal_reason),
    do: send_error(conn, 503, :conversation_unavailable)

  defp conversation_billing_reason(%{reason: reason})
       when reason in @conversation_public_billing_reasons,
       do: reason

  defp conversation_billing_reason(_decision), do: "billing_unavailable"

  defp stripe_webhook_error(conn, :stripe_webhook_not_configured),
    do: send_error(conn, 503, :stripe_webhook_not_configured)

  defp stripe_webhook_error(conn, reason)
       when reason in [:invalid_signature, :invalid_signature_header, :stale_signature],
       do: send_error(conn, 400, reason)

  defp stripe_webhook_error(conn, _reason), do: send_error(conn, 500, :stripe_webhook_failed)

  defp extract_upload(%{"file" => %Plug.Upload{path: path, filename: filename}})
       when is_binary(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, %{filename: filename, binary: binary}}
      {:error, _reason} -> {:error, {:bad_request, "unreadable_upload"}}
    end
  end

  defp extract_upload(_params), do: {:error, :file_required}

  defp create_workspace_connector_token(user, session, workspace_id, attrs) do
    with :ok <- full_workspace_session(session),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, token} <-
           mint_workspace_connector(workspace, user, attrs) do
      {:ok, token}
    end
  end

  defp mint_workspace_connector(workspace, user, %{"installation" => true} = attrs) do
    SalixEnv.DeviceInstall.create_token_command(
      workspace["salix_tenant_id"],
      workspace["default_group_id"],
      connector_token_attrs(attrs, workspace, user)
    )
  end

  defp mint_workspace_connector(workspace, user, attrs) do
    SalixEnv.ConnectorTokens.create_group_connector_token(
      workspace["default_group_id"],
      workspace["salix_tenant_id"],
      connector_token_attrs(attrs, workspace, user)
    )
  end

  defp public_connector_token(token) do
    Map.drop(token, ["tenant_id", "group_id", "token_hash"])
  end

  # Same admission as the connector token: a full (not restricted) session,
  # the workspace authorized for this user, and the Salix scope resolved
  # in-process. The Salix ids never leave this endpoint.
  defp with_router_api_keys(conn, workspace_id, status \\ 200, operation) do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
           {:ok, result} <- operation.(workspace, user) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(status, public_router_api_keys(result))
      else
        {:error, :unavailable} -> send_error(conn, 503, :unavailable)
        {:error, reason} -> comma_error(conn, reason)
      end
    end)
  end

  defp public_router_api_keys(keys) when is_list(keys),
    do: Enum.map(keys, &public_router_api_keys/1)

  # Each key carries the URL an external service posts to, built on the
  # externally reachable Salix base. The URL path names the Salix group id; the
  # key record's own tenant id, group id and hash are dropped.
  defp public_router_api_keys(%{"group_id" => group_id} = key) do
    key
    |> Map.put("post_message_url", router_post_message_url(group_id))
    |> Map.drop(["tenant_id", "group_id", "key_hash"])
  end

  defp public_router_api_keys(%{} = result),
    do: Map.drop(result, ["tenant_id", "group_id", "key_hash"])

  defp router_post_message_url(group_id), do: Salix.App.RouterInbox.post_message_url(group_id)

  defp router_api_key_attrs(attrs) when is_map(attrs),
    do: Map.take(attrs, ["name", "status", "expires_at"])

  defp router_api_key_attrs(_attrs), do: %{}

  # Same admission as the inbound keys. Each key carries the voice URLs a
  # client connects to; their path names the Salix group id, which the Salix
  # voice routes require. The key record's own ids and hash are dropped.
  defp with_voice_api_keys(conn, workspace_id, status \\ 200, operation) do
    with_workspace_voice(conn, workspace_id, status, operation, &public_voice_api_keys/1)
  end

  defp with_voice_numbers(conn, workspace_id, operation) do
    with_workspace_voice(conn, workspace_id, 200, operation, &public_voice_numbers/1)
  end

  defp with_workspace_voice(conn, workspace_id, status, operation, project) do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
           {:ok, result} <- operation.(workspace, user) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(status, project.(result))
      else
        {:error, reason} -> voice_error(conn, reason)
      end
    end)
  end

  defp with_workspace_signal(conn, workspace_id, operation) do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
           {:ok, result} <- operation.(workspace, user) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(200, public_signal(result))
      else
        {:error, reason} -> signal_error(conn, reason)
      end
    end)
  end

  # Salix tenant, Group, connect and account IDs stay inside Comma's API.
  defp public_signal(view) when is_map(view) do
    view
    |> Map.take(~w(account bindings pending_claims claim override platform effective))
    |> Map.new(fn
      {key, %{} = account} when key in ~w(account override platform effective) ->
        {key, Map.take(account, ~w(e164 state scope))}

      {"bindings", bindings} ->
        {"bindings",
         Enum.map(bindings, &Map.take(&1, ~w(binding_id kind peer display_name bound_at number)))}

      {"pending_claims", claims} ->
        {"pending_claims", Enum.map(claims, &Map.take(&1, ~w(claim_id expires_at)))}

      {"claim", %{} = claim} ->
        {"claim", Map.take(claim, ~w(claim_id code command number expires_at))}

      other ->
        other
    end)
  end

  defp signal_number_param(%{"number" => number}) when is_binary(number), do: String.trim(number)
  defp signal_number_param(_attrs), do: ""

  defp signal_error(conn, reason) do
    case reason do
      reason when reason in [:not_found, :admin_user_not_found] ->
        send_error(conn, 404, :not_found)

      {:bad_request, _message} ->
        comma_error(conn, reason)

      reason when is_atom(reason) ->
        case Salix.Control.Signal.http_error(reason) do
          {503, "unavailable"} -> comma_error(conn, reason)
          {status, error} -> send_json(conn, status, %{"error" => error})
        end

      _ ->
        {status, error} = Salix.Control.Signal.http_error(reason)
        send_json(conn, status, %{"error" => error})
    end
  end

  defp voice_error(conn, :voice_number_in_use), do: send_error(conn, 409, :voice_number_in_use)
  defp voice_error(conn, :rate_limited), do: send_error(conn, 429, :rate_limited)
  defp voice_error(conn, :invalid_code), do: send_error(conn, 422, :invalid_code)
  defp voice_error(conn, :not_configured), do: send_error(conn, 503, :voice_not_configured)
  defp voice_error(conn, :unavailable), do: send_error(conn, 503, :unavailable)
  defp voice_error(conn, {:unavailable, _message}), do: send_error(conn, 503, :unavailable)
  defp voice_error(conn, reason), do: comma_error(conn, reason)

  defp public_voice_api_keys(keys) when is_list(keys),
    do: Enum.map(keys, &public_voice_api_keys/1)

  defp public_voice_api_keys(%{"group_id" => group_id} = key) do
    key
    |> Map.merge(Map.take(voice_urls(group_id), ["sessions_url", "readiness_url"]))
    |> Map.drop(["tenant_id", "group_id", "key_hash"])
  end

  defp public_voice_api_keys(%{} = result),
    do: Map.drop(result, ["tenant_id", "group_id", "key_hash"])

  defp voice_urls(group_id), do: Salix.Control.VoiceNumbers.voice_urls(group_id)

  # An explicit allowlist: the Salix status also carries the connect record
  # and the group id, and a number binding holds its PIN hash.
  defp public_voice_numbers(%{"numbers" => numbers} = status) do
    urls = if is_map(status["urls"]), do: status["urls"], else: %{}
    readiness = if is_map(status["readiness"]), do: status["readiness"], else: %{}

    %{
      "lines" => Enum.filter(List.wrap(status["lines"]), &is_binary/1),
      "numbers" => numbers |> List.wrap() |> Enum.map(&public_voice_number/1),
      "readiness" => %{
        "ready" => readiness["ready"] == true,
        "reason" => readiness["reason"]
      },
      "sessions_url" => urls["sessions_url"],
      "readiness_url" => urls["readiness_url"]
    }
  end

  defp public_voice_numbers(%{} = result),
    do: Map.take(result, ["e164", "line", "status", "expires_at"])

  defp public_voice_number(number) do
    locked_until = number["pin_locked_until"]

    %{
      "e164" => number["e164"],
      "carrier" => number["carrier"],
      "line" => number["line"],
      "verified_at" => number["verified_at"],
      "pin_set" => number["pin_configured"] == true or number["pin_set"] == true,
      "pin_locked_until" => locked_until,
      "status" => if(is_integer(locked_until), do: "locked", else: "verified")
    }
  end

  defp voice_number_attrs(attrs, fields) when is_map(attrs), do: Map.take(attrs, fields)
  defp voice_number_attrs(_attrs, _fields), do: %{}

  defp with_subscription_accounts(conn, workspace_id, operation) do
    with_user(conn, fn user, session ->
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, result} <- operation.(workspace["salix_tenant_id"]) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_json(200, result || %{"deleted" => true})
      else
        {:error, reason} when reason in [:conflict, :reset_in_progress] ->
          send_error(conn, 409, reason)

        {:error, reason} when reason in [:not_configured, :unavailable, :reset_pending] ->
          send_error(conn, 503, reason)

        {:error, reason} when is_atom(reason) ->
          comma_error(conn, reason)

        {:error, _} ->
          send_error(conn, 503, :unavailable)
      end
    end)
  end

  defp full_workspace_session(%{"restricted" => true}), do: {:error, :forbidden}
  defp full_workspace_session(_session), do: :ok

  defp authorize_task_attachment_session(
         user,
         %{"session_source" => "channel_task_panel"} = session,
         group_id,
         conversation_id
       ) do
    case Comma.Conversations.preview(user, session, group_id, conversation_id) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_task_attachment_session(_user, session, _group_id, _conversation_id),
    do: full_workspace_session(session)

  defp connector_token_attrs(attrs, workspace, user) do
    name = nonblank(attrs["name"], workspace["name"] <> " Connector")
    alias_name = nonblank(attrs["alias"], "comma")

    %{
      "name" => name,
      "alias" => alias_name,
      "expires_in_seconds" => attrs["expires_in_seconds"],
      "scope" => attrs["scope"],
      "stable_device_id" => attrs["stable_device_id"],
      "meta" => %{
        "owner_user_id" => user["id"],
        "workspace_id" => workspace["id"],
        "surface" => "comma"
      }
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp revoke_workspace_connector_token(user, session, workspace_id, attrs) do
    token = attrs["token"]

    if is_binary(token) and byte_size(token) in 1..512 do
      with :ok <- full_workspace_session(session),
           {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
           {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace) do
        SalixEnv.ConnectorTokens.revoke_group_connector_token(
          workspace["default_group_id"],
          workspace["salix_tenant_id"],
          token
        )
      end
    else
      {:error, {:bad_request, "token is required"}}
    end
  end

  defp register_workspace_local_file_ref(user, session, workspace_id, attrs) do
    with :ok <- full_workspace_session(session),
         {:ok, registration_opts} <- local_file_registration_opts(attrs),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, route} <-
           SalixEnv.LocalFileRefs.register(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             user["id"],
             attrs["stable_device_id"],
             attrs["local_file_ref"],
             registration_opts
           ) do
      {:ok,
       %{
         "local_file_ref" => route["local_file_ref"],
         "state" => "registered"
       }}
    else
      false -> {:error, :invalid_local_file_ref_request}
      {:error, _} = error -> error
    end
  end

  defp local_file_registration_opts(attrs) do
    case Map.keys(attrs) |> Enum.sort() do
      ["local_file_ref", "stable_device_id"] ->
        {:ok, []}

      [
        "connector_run_id",
        "local_file_index_version",
        "local_file_ref",
        "stable_device_id"
      ] ->
        if attrs["local_file_index_version"] == 2 do
          {:ok, connector_run_id: attrs["connector_run_id"], local_file_index_version: 2}
        else
          {:error, :invalid_local_file_ref_request}
        end

      _ ->
        {:error, :invalid_local_file_ref_request}
    end
  end

  defp local_file_ref_error(conn, :connector_owner_upgrade_required, workspace_id) do
    send_json(conn, 409, %{
      error: "connector_reconfiguration_required",
      reason: "connector_owner_missing",
      action: "reissue_connector_token",
      connector_token_endpoint: "/v1/comma/workspaces/#{workspace_id}/connector-token"
    })
  end

  defp local_file_ref_error(conn, reason, _workspace_id)
       when reason in [
              :invalid_local_file_ref,
              :invalid_local_file_device,
              :invalid_local_file_owner,
              :invalid_local_file_scope,
              :invalid_local_file_ref_request
            ],
       do: send_error(conn, 400, :invalid_local_file_ref)

  defp local_file_ref_error(conn, :local_file_ref_conflict, _workspace_id),
    do: send_error(conn, 409, :local_file_ref_conflict)

  defp local_file_ref_error(conn, reason, _workspace_id)
       when reason in [:forbidden, :not_found, :workspace_provisioning],
       do: comma_error(conn, reason)

  defp local_file_ref_error(conn, _internal_reason, _workspace_id),
    do: send_error(conn, 503, :local_file_ref_unavailable)

  defp nonblank(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp nonblank(_value, fallback), do: fallback

  defp create_checkout(workspace, user, attrs) do
    with {:ok, plan} <- plan(attrs),
         :ok <- purchasable(plan),
         :ok <- synced_price(plan),
         {:ok, customer} <-
           BillingStripe.ensure_customer(stripe_customer_attrs(workspace, user, attrs)) do
      BillingStripe.create_checkout_session(%{
        billing_account_id: workspace["billing_account_id"],
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace["id"],
        customer_id: customer.provider_customer_id,
        package_code: plan.package_code,
        package_version: plan.package_version,
        provider_price_id: plan.provider_price_id,
        mode: plan.mode,
        success_url: required_body(attrs, "success_url"),
        cancel_url: required_body(attrs, "cancel_url"),
        idempotency_key:
          "comma:checkout:#{workspace["id"]}:#{plan.provider_lookup_key}:#{required_body(attrs, "client_request_id")}"
      })
    end
  rescue
    ArgumentError -> {:error, :invalid_checkout_request}
  end

  defp create_portal(workspace, user, attrs) do
    with {:ok, customer} <-
           BillingCommerce.get_active_provider_customer(%{
             billing_account_id: workspace["billing_account_id"],
             provider: "stripe",
             provider_context: "default"
           }) do
      BillingStripe.create_customer_portal(%{
        billing_account_id: workspace["billing_account_id"],
        customer_id: customer.provider_customer_id,
        return_url: required_body(attrs, "return_url"),
        idempotency_key:
          "comma:portal:#{workspace["id"]}:#{user["id"]}:#{required_body(attrs, "client_request_id")}"
      })
    else
      {:error, :not_found} -> {:error, :stripe_customer_not_linked}
      {:error, _} = err -> err
    end
  rescue
    ArgumentError -> {:error, :invalid_portal_request}
  end

  defp create_subscription_change(workspace, user, attrs, action) do
    with {:ok, plan} <- historical_plan(attrs),
         :ok <- subscription_plan(plan),
         :ok <- synced_price(plan),
         {:ok, command} <- subscription_provider_attrs(workspace, user, attrs) do
      command =
        Map.merge(command, %{
          provider_price_id: plan.provider_price_id,
          success_url: attrs["success_url"],
          current_price_id: attrs["current_price_id"],
          period_end: attrs["period_end"],
          proration_date: attrs["proration_date"]
        })

      case action do
        :preview -> BillingStripe.preview_subscription_change(command)
        :change -> BillingStripe.change_subscription(command)
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_subscription_change_request}
  end

  defp subscription_provider_attrs(workspace, user, attrs) do
    account_id = workspace["billing_account_id"]

    with {:ok, subscription} <- active_billing_subscription(account_id),
         {:ok, customer} <-
           BillingCommerce.get_active_provider_customer(%{
             billing_account_id: account_id,
             provider: "stripe",
             provider_context: "default"
           }) do
      {:ok,
       %{
         billing_account_id: account_id,
         customer_id: customer.provider_customer_id,
         subscription_id: subscription["source_id"],
         idempotency_key:
           "comma:subscription-change:#{workspace["id"]}:#{user["id"]}:#{required_body(attrs, "client_request_id")}"
       }}
    else
      {:error, :not_found} -> {:error, :active_subscription_not_found}
      {:error, _} = error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_subscription_change_request}
  end

  defp subscription_plan(%{mode: "subscription"}), do: :ok
  defp subscription_plan(_plan), do: {:error, :subscription_plan_required}

  defp subscription_change_error(conn, reason)
       when reason in [
              :active_subscription_not_found,
              :stripe_customer_not_linked,
              :subscription_plan_already_active,
              :subscription_payment_pending,
              :subscription_quote_changed,
              :subscription_renewal_cancelled,
              :subscription_billing_period_change_unavailable
            ],
       do: send_error(conn, 409, reason)

  defp subscription_change_error(conn, reason)
       when reason in [
              :stripe_not_configured,
              :stripe_subscription_item_missing,
              :stripe_subscription_item_unsupported
            ],
       do: send_error(conn, 503, :subscription_change_unavailable)

  defp subscription_change_error(conn, reason)
       when reason in [
              :invalid_subscription_change_request,
              :subscription_plan_required
            ],
       do: send_error(conn, 400, reason)

  defp subscription_change_error(conn, %Stripe.Error{}),
    do: send_error(conn, 502, :subscription_change_unavailable)

  defp subscription_change_error(conn, reason), do: comma_error(conn, reason)

  defp stripe_customer_attrs(workspace, user, attrs) do
    %{
      billing_account_id: workspace["billing_account_id"],
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: workspace["id"],
      billing_email: user["email"],
      display_name: workspace["name"],
      created_by_actor_type: "comma_user",
      created_by_actor_id: user["id"],
      idempotency_key: "comma:customer:#{workspace["id"]}",
      metadata: %{
        "workspace_id" => workspace["id"],
        "checkout_request_id" => attrs["client_request_id"] || attrs[:client_request_id]
      }
    }
  end

  defp public_billing_session(session), do: Map.take(session, ["id", "url", "provider"])

  defp public_billing_plan(plan) do
    %{
      "plan_key" => plan.provider_lookup_key,
      "provider_lookup_key" => plan.provider_lookup_key,
      "package_code" => plan.package_code,
      "package_version" => plan.package_version,
      "mode" => plan.mode,
      "name" => plan.name,
      "currency" => plan.currency,
      "amount_minor" => plan.amount_minor,
      "grant_credits" => plan.grant_credits,
      "grant_period" => plan.grant_period,
      "billing_period" => plan.billing_period
    }
  end

  defp public_package_version(version) do
    version
    |> Map.take([
      :id,
      :package_code,
      :package_name,
      :version,
      :surface,
      :kind,
      :billing_period,
      :grant_credits,
      :grant_period,
      :currency,
      :amount_minor,
      :effective_at,
      :expires_at,
      :status
    ])
    |> stringify_datetime(:effective_at)
    |> stringify_datetime(:expires_at)
  end

  defp public_redeem_code(code, opts \\ []) do
    base =
      code
      |> Map.take([
        :id,
        :display_prefix,
        :package_code,
        :package_version,
        :code_type,
        :surface,
        :scope_product_owner_type,
        :scope_product_owner_id,
        :status,
        :max_redemptions,
        :per_account_limit,
        :valid_from,
        :expires_at,
        :metadata
      ])
      |> stringify_datetime(:valid_from)
      |> stringify_datetime(:expires_at)

    if Keyword.get(opts, :include_plaintext?, false) and is_binary(code[:code]) do
      Map.put(base, :code, code[:code])
    else
      base
    end
  end

  defp public_redemption(redemption) do
    Map.take(redemption, [
      :id,
      :redeem_code_id,
      :billing_account_id,
      :surface,
      :product_owner_type,
      :product_owner_id,
      :source_type,
      :source_id,
      :source_event_id,
      :idempotency_key,
      :operator_snapshot,
      :status,
      :metadata
    ])
  end

  defp public_redemption_result(result) do
    result
    |> Map.take([:redemption, :grant, :subscription, :cycles, :idempotent])
    |> Map.update(:redemption, nil, &public_redemption/1)
    |> Map.update(:grant, nil, &public_grant/1)
    |> Map.update(:cycles, [], fn cycles ->
      Enum.map(cycles || [], fn
        %{grant: grant} = cycle -> Map.put(cycle, :grant, public_grant(grant))
        cycle -> cycle
      end)
    end)
  end

  defp public_manual_grant_result(result) do
    result
    |> Map.take([:manual_grant, :grant, :idempotent])
    |> Map.update(:manual_grant, nil, &public_manual_grant/1)
    |> Map.update(:grant, nil, &public_grant/1)
  end

  defp public_manual_grant(nil), do: nil

  defp public_manual_grant(manual_grant) do
    manual_grant
    |> Map.take([
      :id,
      :billing_account_id,
      :package_code,
      :package_version,
      :source_type,
      :source_id,
      :source_event_id,
      :operator_snapshot,
      :valid_from,
      :expires_at,
      :credit_grant_id,
      :status
    ])
    |> stringify_datetime(:valid_from)
    |> stringify_datetime(:expires_at)
  end

  defp public_grant(nil), do: nil

  defp public_grant(grant) do
    grant
    |> Map.take([
      :id,
      :billing_account_id,
      :package_code,
      :package_version,
      :initial_credits,
      :remaining_credits,
      :valid_from,
      :expires_at,
      :source_type,
      :source_id,
      :source_event_id,
      :status
    ])
    |> stringify_datetime(:valid_from)
    |> stringify_datetime(:expires_at)
  end

  defp stringify_datetime(map, key) do
    Map.update(map, key, nil, fn
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> value
    end)
  end

  defp redeem_apply_status(:redeem_code_not_found), do: 404
  defp redeem_apply_status(:redeem_code_expired), do: 409
  defp redeem_apply_status(:redeem_code_disabled), do: 409
  defp redeem_apply_status(:redeem_scope_mismatch), do: 409
  defp redeem_apply_status(:redeem_code_max_redemptions_reached), do: 409
  defp redeem_apply_status(:redeem_code_account_limit_reached), do: 409
  defp redeem_apply_status(:redeem_idempotency_key_conflict), do: 409
  defp redeem_apply_status(_reason), do: 400

  defp comma_billing_plans do
    with {:ok, plans} <-
           BillingCommerce.list_provider_plans(%{
             surface: "comma",
             provider: "stripe",
             synced_only: true
           }) do
      keys = current_billing_keys()
      {:ok, Enum.filter(plans, &(&1.provider_lookup_key in keys and purchasable?(&1)))}
    end
  end

  defp current_billing_keys do
    Enum.map(Comma.Billing.PricingV1.catalog().versions, & &1.provider_lookup_key)
  end

  defp plan(attrs) do
    lookup_key =
      attrs["plan_key"] || attrs[:plan_key] ||
        attrs["provider_lookup_key"] || attrs[:provider_lookup_key]

    if lookup_key in current_billing_keys() do
      historical_plan(attrs)
    else
      {:error, :invalid_plan_selector}
    end
  end

  defp historical_plan(attrs) do
    BillingCommerce.get_provider_plan(%{
      surface: "comma",
      provider: "stripe",
      provider_lookup_key:
        attrs["plan_key"] || attrs[:plan_key] || attrs["provider_lookup_key"] ||
          attrs[:provider_lookup_key]
    })
  end

  defp purchasable?(plan), do: plan.provider_metadata["comma_purchasable"] == true

  defp purchasable(plan),
    do: if(purchasable?(plan), do: :ok, else: {:error, :plan_not_purchasable})

  defp synced_price(%{provider_price_id: price_id}) when is_binary(price_id) and price_id != "",
    do: :ok

  defp synced_price(_plan), do: {:error, :stripe_price_not_synced}

  defp required_body(attrs, key) do
    value = attrs[key]

    if is_binary(value) and String.trim(value) != "" do
      value
    else
      raise ArgumentError, "missing #{key}"
    end
  end

  defp billing_summary(workspace) do
    account_id = workspace["billing_account_id"]
    now = DateTime.utc_now()

    %{rows: [[credits]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT COALESCE(SUM(remaining_credits), 0)::bigint
        FROM credit_grants
        WHERE billing_account_id = $1
          AND status = 'active'
          AND remaining_credits > 0
          AND valid_from <= $2
          AND (expires_at IS NULL OR expires_at > $2)
        """,
        [account_id, now]
      )

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT id, package_code, package_version, remaining_credits, valid_from, expires_at, source_type, source_id
        FROM credit_grants
        WHERE billing_account_id = $1
          AND status = 'active'
          AND valid_from <= $2
          AND (expires_at IS NULL OR expires_at > $2)
        ORDER BY expires_at NULLS LAST, id
        """,
        [account_id, now]
      )

    active_subscription =
      case active_billing_subscription(account_id) do
        {:ok, subscription} ->
          subscription

        {:error, :not_found} ->
          nil
      end

    %{
      "billing_account_id" => account_id,
      "current_credits" => credits,
      "active_subscription" => active_subscription,
      "active_grants" =>
        Enum.map(rows, fn [
                            id,
                            package_code,
                            package_version,
                            remaining,
                            valid_from,
                            expires_at,
                            source_type,
                            source_id
                          ] ->
          %{
            "id" => id,
            "package_code" => package_code,
            "package_version" => package_version,
            "remaining_credits" => remaining,
            "valid_from" => DateTime.to_iso8601(valid_from),
            "expires_at" => if(expires_at, do: DateTime.to_iso8601(expires_at)),
            "source_type" => source_type,
            "source_id" => source_id
          }
        end)
    }
  end

  defp current_subscription_plan(metadata) do
    case metadata["provider_price_id"] do
      price_id when is_binary(price_id) and price_id != "" ->
        case BillingCommerce.get_provider_plan(%{
               surface: "comma",
               provider: "stripe",
               provider_price_id: price_id
             }) do
          {:ok, plan} -> public_billing_plan(plan)
          {:error, :not_found} -> nil
        end

      _ ->
        nil
    end
  end

  defp active_billing_subscription(account_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT package_code, package_version, status, source_id, source_metadata
        FROM billing_subscriptions
        WHERE billing_account_id = $1
          AND status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused')
        ORDER BY inserted_at DESC, id DESC
        LIMIT 1
        """,
        [account_id]
      )

    case rows do
      [[package_code, package_version, status, source_id, metadata]] ->
        metadata = BillingCore.Metadata.object(metadata)

        {:ok,
         %{
           "package_code" => package_code,
           "package_version" => package_version,
           "status" => status,
           "source_id" => source_id,
           "plan" => current_subscription_plan(metadata),
           "source_metadata" =>
             Map.take(metadata, [
               "cancel_at_period_end",
               "current_period_end",
               "scheduled_plan"
             ])
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp send_comma_sse(
         conn,
         _conversation_id,
         snapshot,
         events,
         stream_context,
         wait_ms,
         stream_window_ms
       ) do
    started = System.monotonic_time()
    stream_context = monitor_stream_owners(stream_context)
    participant_status = stream_context[:participant_status] || %{}

    initial_draft =
      case participant_status["draft"] do
        draft when is_map(draft) -> participant_draft_state(draft, stream_context)
        _ -> nil
      end

    snapshot = Map.put(snapshot, "stream", %{"drafts" => true, "window_ms" => stream_window_ms})

    # One presentation frame, not a cross-owner storage transaction. The same
    # reliable Participant read supplies status and the draft or explicit absence.
    # An unavailable read omits the field without disabling canonical Messages
    # or claiming that the current response has ended.
    snapshot =
      if is_map(stream_context[:participant_status]) do
        Map.put(
          snapshot,
          "participant_draft",
          snapshot_participant_draft(initial_draft, stream_context)
        )
      else
        snapshot
      end

    snapshot =
      case Comma.Conversations.public_participant_status(
             participant_status["activity"],
             stream_context
           ) do
        %{} = status -> Map.put(snapshot, "participant_status", status)
        nil -> snapshot
      end

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    CommaProduct.Telemetry.emit_operation(
      :sse_connect,
      :ok,
      System.monotonic_time() - started
    )

    conn =
      case chunk_event(conn, "snapshot", snapshot) do
        {:ok, conn} ->
          CommaProduct.Telemetry.emit_operation(
            :sse_first_event,
            :ok,
            System.monotonic_time() - started
          )

          with {:ok, conn} <- chunk_events(conn, events),
               {:ok, conn, nil} <-
                 chunk_participant_status(
                   conn,
                   Map.delete(participant_status, "draft"),
                   stream_context,
                   nil
                 ),
               {:ok, conn, draft_state} <-
                 chunk_started_participant_draft(conn, initial_draft, stream_context) do
            now_ms = System.monotonic_time(:millisecond)

            comma_sse_loop(
              conn,
              now_ms + wait_ms,
              stream_context,
              draft_state,
              now_ms + comma_sse_heartbeat_ms()
            )
          else
            _ -> conn
          end

        _ ->
          CommaProduct.Telemetry.emit_operation(
            :sse_first_event,
            :error,
            System.monotonic_time() - started
          )

          conn
      end

    conn
  end

  defp send_task_list_sse(conn, stream_context, wait_ms) do
    participants =
      Map.new(stream_context.task_participants, fn {id, participant} ->
        {id, Map.put(participant, :owner_ref, Process.monitor(participant.owner_pid))}
      end)

    stream_context = %{stream_context | task_participants: participants}

    owner_ref =
      case stream_context[:owner_pid] do
        owner_pid when is_pid(owner_pid) -> Process.monitor(owner_pid)
        _other -> nil
      end

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    with {:ok, conn} <- chunk_task_list_resync(conn, stream_context),
         {:ok, conn} <- chunk_task_participant_statuses(conn, stream_context) do
      now_ms = System.monotonic_time(:millisecond)
      deadline_ms = if wait_ms == :infinity, do: nil, else: now_ms + wait_ms

      task_list_sse_loop(
        conn,
        deadline_ms,
        stream_context,
        owner_ref,
        now_ms + comma_sse_heartbeat_ms()
      )
    else
      _error -> conn
    end
  end

  defp chunk_task_participant_statuses(conn, %{conversation_id: nil}), do: {:ok, conn}

  defp chunk_task_participant_statuses(conn, context) do
    chunk_event(
      conn,
      "task_participant_statuses",
      Comma.Conversations.task_participant_statuses(context)
    )
  end

  # Exact invalidations re-read only the named Participant; owner loss clears
  # only that participant. See tla/salix/TaskParticipantStatus.tla.
  defp update_task_participant(context, group_id, conversation_id, participant_id) do
    with true <- group_id == context.workspace["default_group_id"],
         true <- conversation_id == context.conversation_id,
         %{owner_ref: _} = participant <- context.task_participants[participant_id],
         {:ok, status} <- Comma.Conversations.participant_status(participant) do
      put_in(context, [:task_participants, participant_id, :status], status)
    else
      _ -> context
    end
  end

  defp task_list_sse_loop(conn, deadline_ms, stream_context, owner_ref, heartbeat_at_ms) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      is_integer(deadline_ms) and now_ms >= deadline_ms ->
        conn

      heartbeat_at_ms <= now_ms ->
        case chunk_heartbeat(conn) do
          {:ok, conn} ->
            task_list_sse_loop(
              conn,
              deadline_ms,
              stream_context,
              owner_ref,
              now_ms + comma_sse_heartbeat_ms()
            )

          _error ->
            conn
        end

      true ->
        timeout =
          if is_integer(deadline_ms),
            do: min(deadline_ms - now_ms, heartbeat_at_ms - now_ms),
            else: heartbeat_at_ms - now_ms

        receive do
          {:group_conversation_list_invalidated, group_id, kind, _conversation_id, version} ->
            if group_id == stream_context[:group_id] and kind == stream_context[:kind] do
              case chunk_task_list_invalidation(conn, stream_context, version) do
                {:ok, conn} ->
                  task_list_sse_loop(
                    conn,
                    deadline_ms,
                    stream_context,
                    owner_ref,
                    heartbeat_at_ms
                  )

                _error ->
                  conn
              end
            else
              task_list_sse_loop(
                conn,
                deadline_ms,
                stream_context,
                owner_ref,
                heartbeat_at_ms
              )
            end

          {:DOWN, ^owner_ref, :process, _owner_pid, _reason} when is_reference(owner_ref) ->
            conn

          {:DOWN, participant_ref, :process, _owner_pid, _reason} ->
            participants =
              Map.reject(stream_context.task_participants, fn {_id, participant} ->
                participant.owner_ref == participant_ref
              end)

            next = %{stream_context | task_participants: participants}
            continue_task_participant_stream(conn, deadline_ms, next, owner_ref, heartbeat_at_ms)

          {:conversation_participant_status_changed, group_id, conversation_id, participant_id} ->
            next =
              update_task_participant(stream_context, group_id, conversation_id, participant_id)

            continue_task_participant_stream(conn, deadline_ms, next, owner_ref, heartbeat_at_ms)

          _unrelated ->
            task_list_sse_loop(
              conn,
              deadline_ms,
              stream_context,
              owner_ref,
              heartbeat_at_ms
            )
        after
          timeout ->
            task_list_sse_loop(
              conn,
              deadline_ms,
              stream_context,
              owner_ref,
              heartbeat_at_ms
            )
        end
    end
  end

  defp continue_task_participant_stream(conn, deadline, context, owner_ref, heartbeat) do
    case chunk_task_participant_statuses(conn, context) do
      {:ok, conn} -> task_list_sse_loop(conn, deadline, context, owner_ref, heartbeat)
      _ -> conn
    end
  end

  defp chunk_task_list_invalidation(conn, stream_context, version)
       when is_binary(version) and version != "" do
    chunk_event(conn, "conversation_list_invalidated", %{
      "type" => "conversation_list_invalidated",
      "group_id" => stream_context[:group_id],
      "kind" => stream_context[:kind],
      "version" => version
    })
  end

  defp chunk_task_list_resync(
         conn,
         %{resync_required: true, version: version} = stream_context
       )
       when is_binary(version) and version != "" do
    chunk_event(conn, "conversation_list_resync_required", %{
      "type" => "conversation_list_resync_required",
      "group_id" => stream_context[:group_id],
      "kind" => stream_context[:kind],
      "version" => version
    })
  end

  defp comma_sse_loop(conn, deadline_ms, stream_context, draft_state, heartbeat_at_ms) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      now_ms >= deadline_ms ->
        conn

      heartbeat_at_ms <= now_ms ->
        case chunk_heartbeat(conn) do
          {:ok, conn} ->
            comma_sse_loop(
              conn,
              deadline_ms,
              stream_context,
              draft_state,
              now_ms + comma_sse_heartbeat_ms()
            )

          _ ->
            conn
        end

      true ->
        timeout = min(deadline_ms - now_ms, heartbeat_at_ms - now_ms)

        receive do
          {:conversation_message_created, _group_id, _salix_id, _message_id, _salix_seq} ->
            chunk_conversation_invalidation(
              conn,
              deadline_ms,
              stream_context,
              draft_state,
              heartbeat_at_ms
            )

          {:DOWN, owner_ref, :process, _owner_pid, _reason} ->
            cond do
              owner_ref == stream_context[:owner_ref] ->
                case chunk_event(conn, "conversation_invalidated", %{
                       "type" => "conversation_invalidated",
                       "conversation_id" => stream_context[:conversation_id]
                     }) do
                  {:ok, conn} -> conn
                  _ -> conn
                end

              owner_ref == stream_context[:participant_owner_ref] ->
                case chunk_participant_owner_unavailable(
                       conn,
                       stream_context,
                       draft_state
                     ) do
                  {:ok, conn} ->
                    stream_context =
                      Map.drop(stream_context, [
                        :participant_owner_pid,
                        :participant_owner_ref,
                        :participant_status
                      ])

                    comma_sse_loop(conn, deadline_ms, stream_context, nil, heartbeat_at_ms)

                  _error ->
                    conn
                end

              true ->
                comma_sse_loop(conn, deadline_ms, stream_context, draft_state, heartbeat_at_ms)
            end

          {:conversation_participant_status_changed, group_id, source_conversation_id,
           participant_id} ->
            if group_id == get_in(stream_context, [:workspace, "default_group_id"]) and
                 source_conversation_id == stream_context[:source_conversation_id] and
                 participant_id == stream_context[:participant_id] do
              case Comma.Conversations.participant_status(stream_context) do
                {:ok, participant_status} ->
                  case chunk_participant_status(
                         conn,
                         participant_status,
                         stream_context,
                         draft_state
                       ) do
                    {:ok, conn, next_draft_state} ->
                      comma_sse_loop(
                        conn,
                        deadline_ms,
                        stream_context,
                        next_draft_state,
                        heartbeat_at_ms
                      )

                    _error ->
                      conn
                  end

                {:error, _reason} ->
                  comma_sse_loop(conn, deadline_ms, stream_context, draft_state, heartbeat_at_ms)
              end
            else
              comma_sse_loop(conn, deadline_ms, stream_context, draft_state, heartbeat_at_ms)
            end
        after
          timeout ->
            comma_sse_loop(conn, deadline_ms, stream_context, draft_state, heartbeat_at_ms)
        end
    end
  end

  defp chunk_conversation_invalidation(
         conn,
         deadline_ms,
         stream_context,
         draft_state,
         heartbeat_at_ms
       ) do
    event = %{
      "type" => "conversation_invalidated",
      "conversation_id" => stream_context[:conversation_id]
    }

    next_draft_state =
      case draft_state do
        %{response_identity: response_identity} when is_binary(response_identity) -> draft_state
        _legacy_or_missing_draft -> nil
      end

    case chunk_event(conn, "conversation_invalidated", event) do
      {:ok, conn} ->
        # Conversation and Participant owners invalidate independently.
        # Preserve identified transient bookkeeping across a canonical refresh
        # until the exact Participant snapshot publishes its draft clear. The
        # client still reconciles the canonical transcript atomically.
        comma_sse_loop(
          conn,
          deadline_ms,
          stream_context,
          next_draft_state,
          heartbeat_at_ms
        )

      _ ->
        conn
    end
  end

  defp chunk_participant_status(conn, participant_status, stream_context, draft_state)
       when is_map(participant_status) do
    with {:ok, conn} <-
           chunk_participant_display_status(
             conn,
             participant_status["activity"],
             stream_context
           ),
         {:ok, conn} <-
           chunk_participant_activity(
             conn,
             participant_status["presentation_activity"],
             stream_context
           ),
         {:ok, conn, draft_state} <-
           chunk_participant_draft(
             conn,
             participant_status["draft"],
             stream_context,
             draft_state
           ) do
      {:ok, conn, draft_state}
    end
  end

  defp chunk_participant_status(conn, _participant_status, _stream_context, draft_state),
    do: {:ok, conn, draft_state}

  defp chunk_participant_owner_unavailable(conn, stream_context, draft_state) do
    event = %{
      "type" => "participant_status_cleared",
      "conversation_id" => stream_context[:conversation_id],
      "participant_id" => stream_context[:participant_id],
      "reason" => "owner_unavailable"
    }

    with {:ok, conn} <- chunk_event(conn, "participant_status_cleared", event),
         {:ok, conn, nil} <-
           chunk_participant_draft(conn, nil, stream_context, draft_state) do
      {:ok, conn}
    end
  end

  defp chunk_participant_display_status(conn, activity, stream_context)
       when is_map(activity) do
    case Comma.Conversations.public_participant_status(activity, stream_context) do
      nil -> {:ok, conn}
      public_status -> chunk_event(conn, "participant_status", public_status)
    end
  end

  defp chunk_participant_display_status(conn, _activity, _stream_context), do: {:ok, conn}

  defp chunk_participant_activity(conn, activity, stream_context) when is_map(activity) do
    case Comma.Conversations.public_activity(activity, stream_context) do
      nil -> {:ok, conn}
      public_activity -> chunk_event(conn, "activity", public_activity)
    end
  end

  defp chunk_participant_activity(conn, _activity, _stream_context), do: {:ok, conn}

  defp chunk_participant_draft(conn, draft, stream_context, nil) when is_map(draft) do
    chunk_started_participant_draft(
      conn,
      participant_draft_state(draft, stream_context),
      stream_context
    )
  end

  defp chunk_participant_draft(conn, draft, stream_context, current)
       when is_map(draft) and is_map(current) do
    case participant_draft_state(draft, stream_context) do
      nil ->
        cancel_participant_draft(conn, stream_context, current)

      %{response_identity: response_identity}
      when response_identity != current.response_identity ->
        with {:ok, conn, nil} <- cancel_participant_draft(conn, stream_context, current),
             {:ok, conn, next} <- chunk_participant_draft(conn, draft, stream_context, nil) do
          {:ok, conn, next}
        end

      next ->
        next = %{next | draft_id: current.draft_id}

        cond do
          next.revision <= current.revision ->
            {:ok, conn, current}

          next.text == current.text ->
            {:ok, conn, next}

          true ->
            delta = draft_delta_suffix(current.text, next.text)

            event =
              public_draft(
                next,
                stream_context,
                "message_draft_delta",
                "delta",
                delta
              )

            case chunk_event(conn, "message_draft_delta", event) do
              {:ok, conn} -> {:ok, conn, next}
              error -> error
            end
        end
    end
  end

  defp chunk_participant_draft(conn, _draft, stream_context, current)
       when is_map(current),
       do: cancel_participant_draft(conn, stream_context, current)

  defp chunk_participant_draft(conn, _draft, _stream_context, nil), do: {:ok, conn, nil}

  defp snapshot_participant_draft(nil, _stream_context), do: nil

  defp snapshot_participant_draft(draft_state, stream_context),
    do: public_draft(draft_state, stream_context, "message_draft_started", "started")

  defp chunk_started_participant_draft(conn, nil, _stream_context), do: {:ok, conn, nil}

  defp chunk_started_participant_draft(conn, draft_state, stream_context) do
    case chunk_event(
           conn,
           "message_draft_started",
           snapshot_participant_draft(draft_state, stream_context)
         ) do
      {:ok, conn} -> {:ok, conn, draft_state}
      error -> error
    end
  end

  defp cancel_participant_draft(conn, stream_context, draft_state) do
    event =
      public_draft(
        draft_state,
        stream_context,
        "message_draft_cancelled",
        "cancelled"
      )

    case chunk_event(conn, "message_draft_cancelled", event) do
      {:ok, conn} -> {:ok, conn, nil}
      error -> error
    end
  end

  defp participant_draft_state(draft, stream_context) do
    response_identity =
      Comma.Conversations.visible_reply_response_identity(draft["response_key"])

    source_message_ids = draft["source_message_ids"]
    revision = draft["revision"]
    text = draft["text"]

    canonical_source_message_ids =
      Comma.Conversations.canonical_source_message_ids(source_message_ids, stream_context)

    if is_binary(response_identity) and is_integer(revision) and revision > 0 and
         is_binary(text) and is_list(source_message_ids) and source_message_ids != [] and
         length(canonical_source_message_ids) == length(source_message_ids) do
      %{
        draft_id: "draft_" <> Ecto.UUID.generate(),
        response_identity: response_identity,
        revision: revision,
        source_message_ids: canonical_source_message_ids,
        text: text
      }
    end
  end

  defp public_draft(draft_state, stream_context, type, status, delta \\ nil) do
    %{
      "type" => type,
      "conversation_id" => stream_context[:conversation_id],
      "draft_id" => draft_state[:draft_id],
      "response_key" => draft_state[:response_identity],
      "revision" => draft_state[:revision],
      "status" => status,
      "text" => draft_state[:text],
      "delta" => delta,
      "source_message_ids" => draft_state[:source_message_ids]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp draft_delta_suffix(previous, current)
       when is_binary(previous) and is_binary(current) do
    if String.starts_with?(current, previous) do
      binary_part(current, byte_size(previous), byte_size(current) - byte_size(previous))
    end
  end

  defp draft_delta_suffix(_previous, _current), do: nil

  defp chunk_heartbeat(conn), do: chunk(conn, ": heartbeat\n\n")

  defp monitor_stream_owners(stream_context) do
    stream_context
    |> monitor_stream_owner(:owner_pid, :owner_ref)
    |> monitor_stream_owner(:participant_owner_pid, :participant_owner_ref)
  end

  defp monitor_stream_owner(stream_context, pid_key, ref_key) do
    case stream_context[pid_key] do
      owner_pid when is_pid(owner_pid) ->
        Map.put(stream_context, ref_key, Process.monitor(owner_pid))

      _other ->
        stream_context
    end
  end

  defp chunk_events(conn, events), do: Enum.reduce_while(events, {:ok, conn}, &chunk_reduce/2)

  defp chunk_reduce(event, {:ok, conn}) do
    case chunk_event(conn, event_name(event), event) do
      {:ok, conn} -> {:cont, {:ok, conn}}
      other -> {:halt, other}
    end
  end

  defp chunk_event(conn, event, data),
    do: chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")

  defp event_name(%{"type" => type}) when is_binary(type), do: type
  defp event_name(_event), do: "event"

  defp comma_sse_wait_ms(value) do
    value
    |> parse_int(@default_comma_sse_wait_ms)
    |> max(0)
    |> min(@max_comma_sse_wait_ms)
  end

  defp task_list_sse_wait_ms(value) when value in [nil, ""], do: :infinity
  defp task_list_sse_wait_ms(value), do: comma_sse_wait_ms(value)

  defp comma_sse_stream_window_ms(nil, _wait_ms), do: @max_comma_sse_wait_ms
  defp comma_sse_stream_window_ms("", _wait_ms), do: @max_comma_sse_wait_ms
  defp comma_sse_stream_window_ms(_value, wait_ms), do: wait_ms

  defp comma_sse_heartbeat_ms do
    :comma_web
    |> Application.get_env(:comma_sse_heartbeat_ms, @default_comma_sse_heartbeat_ms)
    |> parse_int(@default_comma_sse_heartbeat_ms)
    |> max(1)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_telegram_callback_page(conn, success?, state, workspace_id, reason \\ nil) do
    {:ok, client} = billing_return_client(CommaWeb.TelegramOIDC.callback_environment(state))
    # Fixed app route only. The client re-reads the authorized Workspace; this
    # URL carries neither a token nor a claimed connection success.
    deep_link =
      "#{client.scheme}://telegram/return" <>
        if(is_binary(workspace_id),
          do: "?workspace_id=" <> URI.encode_www_form(workspace_id),
          else: ""
        )

    html = CommaWeb.TelegramCallbackPage.render(client, deep_link, success?, reason)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header(
      "content-security-policy",
      CommaWeb.AppReturnPage.content_security_policy()
    )
    |> put_resp_content_type("text/html")
    |> send_resp(if(success?, do: 200, else: 400), html)
  end

  defp send_billing_return_page(conn, environment, status) do
    with {:ok, client} <- billing_return_client(environment),
         {:ok, result} <- billing_return_status(status) do
      deep_link = "#{client.scheme}://billing/return?status=#{result.status}"

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "content-security-policy",
        CommaWeb.AppReturnPage.content_security_policy()
      )
      |> put_resp_content_type("text/html")
      |> send_resp(200, billing_return_html(client, result, deep_link))
    else
      :error -> send_error(conn, 400, :invalid_billing_return)
    end
  end

  defp billing_return_client("dev"),
    do: {:ok, %{environment: "Development", name: "Comma Dev", scheme: "comma-dev"}}

  defp billing_return_client("staging"),
    do: {:ok, %{environment: "Staging", name: "Comma Staging", scheme: "comma-staging"}}

  defp billing_return_client("prod"),
    do: {:ok, %{environment: "Production", name: "Comma", scheme: "comma"}}

  defp billing_return_client(_environment), do: :error

  defp billing_return_status("success") do
    {:ok,
     %{
       detail: "Your subscription or credits are being activated.",
       status: "success",
       title: "Payment successful"
     }}
  end

  defp billing_return_status("cancel") do
    {:ok,
     %{
       detail: "No payment was completed.",
       status: "cancel",
       title: "Checkout canceled"
     }}
  end

  defp billing_return_status("portal") do
    {:ok,
     %{
       detail: "Return to Comma to view your latest billing status.",
       status: "portal",
       title: "Billing updated"
     }}
  end

  defp billing_return_status("subscription") do
    {:ok,
     %{
       detail: "Return to Comma to view your updated plan and credits.",
       status: "subscription",
       title: "Subscription updated"
     }}
  end

  defp billing_return_status(_status), do: :error

  defp billing_return_html(client, result, deep_link) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{result.title} · #{client.name}</title>
        <style>
          :root { color-scheme: light dark; font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
          body { align-items: center; background: Canvas; color: CanvasText; display: flex; justify-content: center; margin: 0; min-height: 100vh; padding: 24px; }
          main { border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 22px; box-shadow: 0 18px 55px color-mix(in srgb, CanvasText 10%, transparent); box-sizing: border-box; max-width: 520px; padding: 38px; width: 100%; }
          .environment { color: color-mix(in srgb, CanvasText 58%, transparent); font-size: 13px; font-weight: 650; letter-spacing: .08em; margin: 0 0 18px; text-transform: uppercase; }
          h1 { font-size: 30px; letter-spacing: -.025em; margin: 0 0 12px; }
          p { color: color-mix(in srgb, CanvasText 68%, transparent); line-height: 1.55; margin: 0; }
          .opening { font-size: 14px; margin-top: 10px; }
          a { background: #2862ff; border-radius: 12px; color: white; display: block; font-weight: 650; margin-top: 28px; padding: 13px 18px; text-align: center; text-decoration: none; }
          a:hover { background: #1f52dd; }
        </style>
      </head>
      <body>
        <main>
          <p class="environment">#{client.environment} environment</p>
          <h1>#{result.title}</h1>
          <p>#{result.detail}</p>
          <p class="opening">Opening #{client.name} automatically. This tab will close after 1.5 seconds.</p>
          <a id="comma-return" data-auto-return="true" href="#{deep_link}" aria-label="Open #{client.name}">Open #{client.name}</a>
        </main>
        #{CommaWeb.AppReturnPage.script()}
      </body>
    </html>
    """
  end

  defp send_auth_result(conn, status, session, cookie_kind \\ :user)

  defp send_auth_result(conn, status, %{"token" => _token} = session, cookie_kind) do
    if CommaWeb.ClientSurface.cookie?(conn) do
      conn
      |> then(fn conn ->
        if cookie_kind == :panel,
          do: CommaWeb.SessionCookie.put_panel_session(conn, session),
          else: CommaWeb.SessionCookie.put_session(conn, session)
      end)
      |> send_json(status, %{
        "expires_at" => Map.fetch!(session, "expires_at"),
        "session_id" => Map.fetch!(session, "session_id"),
        "user" => Map.fetch!(session, "user")
      })
    else
      send_json(conn, status, session)
    end
  end

  defp send_auth_result(conn, status, result, _cookie_kind) do
    send_json(conn, status, result)
  end

  defp maybe_clear_web_session_cookie(conn) do
    if CommaWeb.ClientSurface.cookie?(conn) do
      CommaWeb.SessionCookie.clear(conn)
    else
      conn
    end
  end

  defp send_json_with_etag(conn, status, body) do
    etag = public_etag(body)

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "private, no-cache")

    if etag_matches?(conn, etag) do
      send_resp(conn, 304, "")
    else
      send_json(conn, status, body)
    end
  end

  defp public_etag(body) do
    digest =
      body
      |> stable_etag_representation()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    ~s("comma-#{digest}")
  end

  # `freshness.refreshed_at` records when Comma last observed the canonical Salix
  # representation. It is useful response metadata, but it is not a content
  # change: including it would turn every successful poll into a new ETag and
  # defeat the 304 contract.
  defp stable_etag_representation(value) when is_list(value),
    do: Enum.map(value, &stable_etag_representation/1)

  defp stable_etag_representation(value) when is_map(value) do
    Map.new(value, fn
      {key, freshness} when key in ["freshness", :freshness] and is_map(freshness) ->
        stable_freshness = Map.drop(freshness, ["refreshed_at", :refreshed_at])
        {key, stable_etag_representation(stable_freshness)}

      {key, nested} ->
        {key, stable_etag_representation(nested)}
    end)
  end

  defp stable_etag_representation(value), do: value

  defp etag_matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  defp auth_request_attrs(conn) do
    Map.put(conn.body_params || %{}, "remote_ip", remote_ip_string(conn.remote_ip))
  end

  defp remote_ip_string(remote_ip) do
    case :inet.ntoa(remote_ip) do
      {:error, _reason} -> "unknown"
      address -> to_string(address)
    end
  end

  defp send_rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
    |> send_error(429, :rate_limited)
  end

  defp send_unavailable(conn, reason, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
    |> send_error(503, reason)
  end

  defp send_workspace_provisioning(conn) do
    retry_after = Comma.WorkspaceBootstrap.retry_after_seconds()

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send_json(202, %{
      error: "workspace_provisioning",
      retry_after_seconds: retry_after
    })
  end

  defp send_profile_error(conn, reason)

  defp send_profile_error(conn, reason)
       when reason in [
              :avatar_required,
              :avatar_too_large,
              :invalid_avatar,
              :invalid_profile,
              :name_required,
              :name_too_long,
              :unsupported_avatar_type
            ],
       do: send_error(conn, 400, reason)

  defp send_profile_error(conn, :not_found), do: send_error(conn, 404, :not_found)

  defp send_profile_error(conn, reason)
       when reason in [:avatar_activation_conflict],
       do: send_error(conn, 409, reason)

  defp send_profile_error(conn, :avatar_storage_unavailable),
    do: send_error(conn, 503, :avatar_storage_unavailable)

  defp send_profile_error(conn, {:storage, _reason}),
    do: send_error(conn, 503, :avatar_storage_unavailable)

  defp send_profile_error(conn, _reason), do: send_error(conn, 500, :profile_unavailable)

  defp send_error(conn, _status, {:billing_unavailable, decision}) do
    send_json(conn, 402, %{
      error: "billing_unavailable",
      reason: decision_reason(decision)
    })
  end

  defp send_error(conn, status, reason),
    do: send_json(conn, status, %{error: error_reason(reason)})

  defp decision_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp decision_reason(_decision), do: "billing_unavailable"

  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(reason) when is_binary(reason), do: reason
  defp error_reason(_reason), do: "internal_error"

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end
end
