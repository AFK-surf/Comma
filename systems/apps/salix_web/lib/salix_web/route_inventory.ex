defmodule SalixWeb.RouteInventory do
  @moduledoc """
  Route classifier for the Salix HTTP surface.

  It classifies route *patterns* from `SalixWeb.Router`, not concrete request
  paths, into the current product, admin, callback, infrastructure, and runtime
  surfaces.
  """

  @type surface ::
          :client
          | :admin
          | :public_callback
          | :public_site_connector
          | :public_infra
          | :internal_runtime

  @spec classify(String.t(), String.t()) :: surface() | :unknown
  def classify("get", "/v1/remote-shell/client.py"), do: :public_callback

  def classify("post", "/v1/remote-shell/:group_id/registrations/:request_id"),
    do: :public_callback

  def classify(_method, path) when path in ["/live", "/ready", "/health"], do: :public_infra
  def classify(_method, "/v1/oauth/mcp/callback"), do: :public_callback
  def classify(_method, "/v1/oauth/:provider/callback"), do: :public_callback
  def classify(_method, "/v1/im/slack/oauth/callback"), do: :public_callback
  def classify(_method, "/v1/im/slack/events"), do: :public_callback
  def classify(_method, "/v1/im/slack/commands"), do: :public_callback
  def classify(_method, "/v1/im/slack/interactions"), do: :public_callback
  def classify(_method, "/v1/im/feishu/events"), do: :public_callback

  def classify("post", "/v1/calendar/google/notifications/:group_id/:calendar_id/:source_id"),
    do: :public_callback

  # Twilio voice webhooks (signed) and the media stream (token-addressed).
  def classify("post", "/v1/voice/twilio/" <> _), do: :public_callback
  def classify("get", "/v1/voice/twilio/stream/:token"), do: :public_callback

  def classify("post", "/v1/loop-webhooks/:secret"), do: :public_callback
  def classify("post", "/v1/composio-webhooks/:secret"), do: :public_callback

  def classify("get", "/v1/calendar/feeds/:cfd1_id/:secret"), do: :public_callback

  def classify("post", "/v1/agent-groups/:id/meeting-agent/runtime-events"),
    do: :public_callback

  def classify("get", "/v1/e2e-report-sessions/:token/*path"), do: :public_callback
  def classify("get", "/site/" <> _), do: :public_site_connector
  def classify("get", "/v1/device-connection/*path"), do: :public_site_connector
  def classify("get", "/v1/connect"), do: :public_site_connector
  def classify(_method, "/v1/agent-groups/:id/meeting-agent" <> _), do: :client

  # The Router post_message API (docs/product-features.md): a
  # product surface an external service reaches with a group-scoped key, not
  # an unauthenticated provider callback and not a tenant runtime route.
  def classify("post", "/v1/agent-groups/:id/router/post-message"), do: :client
  # comma.voice.v1 readiness and sessions: the voice agent key surface.
  def classify("get", "/v1/agent-groups/:group_id/voice"), do: :client
  def classify("get", "/v1/agent-groups/:group_id/voice/sessions"), do: :client
  # The background Loop event ingress shares the group-key surface.
  def classify("post", "/v1/agent-groups/:group_id/loops/:loop_id/events"), do: :client

  def classify(_method, "/v1/agent-groups/" <> rest) do
    if String.contains?(rest, "/capability-requests"), do: :client, else: :unknown
  end

  # Genuinely-admin routes (cluster, tenants CRUD, templates, e2e-reports).
  def classify(_method, "/v1/admin/" <> _), do: :admin

  # Tenant-scoped runtime + relocated runtime config/integration routes.
  def classify(_method, "/v1/runtime/" <> _), do: :internal_runtime
  def classify(_method, "/v1/compute/" <> _), do: :internal_runtime
  def classify(_method, "/v1/compute-node/work-activity/" <> _), do: :internal_runtime
  def classify(_method, "/v1/integrations/" <> _), do: :internal_runtime
  def classify(_method, "/v1/agent-defaults"), do: :internal_runtime
  def classify(_method, "/v1/templates"), do: :internal_runtime
  def classify(_method, "/v1/templates/" <> _), do: :internal_runtime
  def classify(_method, "/v1/initial-agents"), do: :internal_runtime
  def classify(_method, "/v1/initial-agents/" <> _), do: :internal_runtime

  def classify(_method, _path), do: :unknown
end
