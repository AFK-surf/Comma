defmodule SalixWeb.Auth do
  @moduledoc """
  Bearer-token auth plug. The admin token from app config is valid ONLY on
  `/v1/admin/*` paths and grants the `:admin` role. All other
  (non-admin) `/v1/*` tenant APIs are authorized by tenant API keys, which are
  S3-backed control records; the authenticated tenant comes from the key, not
  from any hardcoded default. Admin tokens are NOT accepted on tenant APIs.

  Public carve-outs: `/site/` paths expose files agents intentionally
  published under their website VFS roots (the path-addressed fallback for the
  host-based public site server in `SalixWeb.Endpoint`, which bypasses this
  plug entirely — willow's `Handler()` branches before the API mux).
  """
  import Plug.Conn

  alias Salix.Control.Tenants

  def init(opts), do: opts

  def call(conn, _opts) do
    path = conn.request_path
    token = presented(conn)

    cond do
      conn.method == "POST" and composio_webhook_path?(path) ->
        SalixWeb.ComposioWebhook.admit(conn)

      conn.method == "POST" and loop_webhook_path?(path) ->
        SalixWeb.LoopWebhook.admit(conn)

      # Twilio sends no bearer token: the route checks the webhook signature
      # or the stream token (docs/messaging-voice.md).
      (conn.method == "POST" and SalixWeb.TwilioWebhook.webhook_path?(path)) or
          (conn.method == "GET" and SalixWeb.TwilioWebhook.stream_path?(path)) ->
        SalixWeb.TwilioWebhook.admit(conn)

      public_path?(path) ->
        conn

      admin_path?(path) ->
        # Admin token is valid ONLY on /v1/admin/* paths.
        if admin_token?(token) do
          assign(conn, :auth_role, :admin)
        else
          deny(conn)
        end

      connect_path?(path) ->
        authenticate_connector(conn, token)

      runtime_carrier_path?(path) ->
        authenticate_runtime_carrier(conn, token)

      install_operation_path?(path) ->
        authenticate_install_operation(conn)

      compute_gateway_path?(path) ->
        authenticate_compute_gateway(conn, token)

      router_inbox_path?(path) ->
        authenticate_group_api_key(conn, token, "inbound")

      voice_session_path?(path) ->
        authenticate_group_api_key(conn, token, "voice")

      true ->
        authenticate_tenant(conn, token)
    end
  end

  # The Router post_message API (docs/product-features.md)
  # is the only path a group API key opens, and the only credential that
  # opens it: a tenant key or admin token presented here is refused, and a
  # group key presented anywhere else falls into the tenant branch, where its
  # hash matches nothing.
  @doc false
  def router_inbox_path?(path) do
    Regex.match?(~r|^/v1/agent-groups/[^/]+/router/post-message$|, path) or
      loop_events_path?(path)
  end

  # The background Loop event ingress (docs/salix/tasks-background-execution.md)
  # opens to the same group API key: an external system that may post to
  # the Router may also feed one of the group's Loops.
  @doc false
  def loop_events_path?(path) do
    Regex.match?(~r|^/v1/agent-groups/[^/]+/loops/[^/]+/events$|, path)
  end

  # The voice readiness and session routes (docs/messaging-voice.md) open
  # only to a voice agent key (`salix_vk_`), and a voice key opens nothing
  # else: the key kind must match the path, so an inbound key is refused here
  # and a voice key is refused on the Router inbox.
  @doc false
  def voice_session_path?(path) do
    Regex.match?(~r|^/v1/agent-groups/[^/]+/voice(/sessions)?$|, path)
  end

  defp authenticate_group_api_key(conn, token, kind) do
    case Salix.Control.GroupApiKeys.validate(token) do
      {:ok, %{"tenant_id" => tenant_id, "kind" => ^kind} = record} ->
        conn
        |> assign(:auth_role, if(kind == "voice", do: :voice_key, else: :group_api_key))
        |> assign(:tenant_id, tenant_id)
        |> assign(:group_api_key, record)

      {:error, :unavailable} ->
        if kind == "inbound", do: Salix.App.RouterInbox.emit(:unavailable)
        unavailable(conn)

      _other ->
        if kind == "inbound", do: Salix.App.RouterInbox.emit(:unauthorized)
        deny(conn)
    end
  end

  @doc false
  def remote_shell_callback_path?(path),
    do: Regex.match?(~r{\A/v1/remote-shell/[^/]+/registrations/[^/]+\z}, path)

  @doc false
  def loop_webhook_path?(path),
    do: Regex.match?(~r|\A/v1/loop-webhooks/[A-Za-z0-9_-]{43}\z|, path)

  def composio_webhook_path?(path),
    do: Regex.match?(~r|\A/v1/composio-webhooks/[A-Za-z0-9_-]{43}\z|, path)

  defp public_path?(path) do
    # /health: k8s liveness/readiness probes and LB health checks authenticate
    # with nothing; the endpoint leaks no data. /site/ paths are public
    # user-visible website links.
    # /v1/oauth/{provider}/callback: the provider browser redirect carries no
    # bearer token; the one-time CAS-consumed `state` param is the credential
    # (willow registers the callback outside auth).
    path in ["/live", "/ready", "/health"] or
      String.starts_with?(path, "/site/") or
      String.starts_with?(path, "/v1/device-connection/") or
      path == "/v1/remote-shell/client.py" or remote_shell_callback_path?(path) or
      path in [
        "/v1/im/slack/oauth/callback",
        "/v1/im/slack/events",
        "/v1/im/slack/commands",
        "/v1/im/slack/interactions"
      ] or
      String.starts_with?(path, "/v1/calendar/google/notifications/") or
      String.starts_with?(path, "/v1/calendar/feeds/") or
      meeting_runtime_event_path?(path) or
      String.starts_with?(path, "/v1/e2e-report-sessions/") or
      path == "/v1/im/feishu/events" or
      (String.starts_with?(path, "/v1/oauth/") and String.ends_with?(path, "/callback"))
  end

  defp meeting_runtime_event_path?(path) do
    Regex.match?(~r|^/v1/agent-groups/[^/]+/meeting-agent/runtime-events$|, path)
  end

  defp connect_path?("/v1/connect"), do: true
  defp connect_path?(_path), do: false

  defp compute_gateway_path?(path), do: String.starts_with?(path, "/v1/compute/")

  defp install_operation_path?(path) do
    path in [
      "/v1/compute/agent-vmm/install-operations/exchange",
      "/v1/compute/agent-vmm/install-operations/ack"
    ]
  end

  # The operation row is the credential owner. This plug only isolates the
  # InstallOperation scheme from gateway/tenant credentials; the route performs
  # the constant-time hash validation while holding the operation lock.
  defp authenticate_install_operation(conn) do
    case get_req_header(conn, "authorization") do
      ["InstallOperation " <> secret] when secret != "" and byte_size(secret) <= 128 ->
        conn
        |> assign(:auth_role, :install_operation)
        |> assign(:install_operation_secret, secret)

      _ ->
        deny(conn)
    end
  end

  defp runtime_carrier_path?("/v1/compute/runtime/" <> _), do: true
  defp runtime_carrier_path?(_path), do: false

  defp authenticate_runtime_carrier(conn, token) when is_binary(token) and token != "" do
    assign(conn, :auth_role, :compute_runtime)
  end

  defp authenticate_runtime_carrier(conn, _token), do: deny(conn)

  defp authenticate_compute_gateway(conn, token) do
    configured = Application.get_env(:salix_web, :agent_vmm_gateway_control_secret)
    gateway_ids = get_req_header(conn, "x-agent-vmm-gateway-instance")

    if secure_equal?(token, configured) and match?([id] when id != "", gateway_ids) do
      [gateway_id] = gateway_ids
      conn |> assign(:auth_role, :compute_gateway) |> assign(:gateway_instance_id, gateway_id)
    else
      deny(conn)
    end
  end

  defp admin_path?(path) do
    String.starts_with?(path, "/v1/admin/")
  end

  defp presented(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t] -> t
      [t] -> t
      _ -> nil
    end
  end

  defp authenticate_connector(conn, token) do
    case SalixEnv.ConnectorTokens.validate_connector_token(token) do
      {:ok, tenant_id, rec} ->
        conn
        |> assign(:auth_role, :connector)
        |> assign(:tenant_id, tenant_id)
        |> assign(:connector_token, rec)

      _other ->
        authenticate_tenant(conn, token)
    end
  end

  defp authenticate_tenant(conn, token) do
    case Tenants.validate_api_key(token) do
      {:ok, tenant_id, _rec} ->
        conn
        |> assign(:auth_role, :tenant)
        |> assign(:tenant_id, tenant_id)

      # Store/gate fault (cold node, DB unreachable, cutover pending): the key
      # may well be valid — say "try again", not "you're unauthorized".
      {:error, :unavailable} ->
        unavailable(conn)

      _other ->
        deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end

  defp unavailable(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "unavailable"}))
    |> halt()
  end

  defp admin_token?(token) when is_binary(token) and token != "" do
    case admin_token() do
      configured when is_binary(configured) and configured != "" -> token == configured
      _ -> false
    end
  end

  defp admin_token?(_token), do: false

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and left != "" and
              byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  @doc """
  The configured system-wide admin token (`:salix_web, :api_token`), or `nil`
  when unset. Public so the admin dashboard login (`SalixWeb.Dashboard.Auth`)
  validates against the exact same source as this bearer-auth plug, and the two
  can never drift.
  """
  @spec admin_token() :: String.t() | nil
  def admin_token do
    Application.get_env(:salix_web, :api_token)
  end
end
