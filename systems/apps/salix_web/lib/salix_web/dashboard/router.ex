defmodule SalixWeb.Dashboard.Router do
  @moduledoc """
  Router for the Salix admin dashboard. Every route lives under `/dash` (the
  prefix `SalixWeb.Endpoint` delegates to this endpoint). The `:browser` pipeline
  runs the standard plugs plus `fetch_admin` (resolves the signed session cookie
  into `:admin?`). Authenticated pages live in the `:authenticated` `live_session`
  with the `{Dashboard.Auth, :ensure_admin}` on_mount hook; anonymous users are
  redirected to `/dash/login`.

  ## Adding a route

  Add a `live "/dash/path", SomeLive` inside the `:authenticated` live_session (so
  it inherits auth + the app layout), or a `get/post` to a controller in the
  authenticated `:browser` scope for non-LiveView actions (e.g. file downloads).
  """
  use SalixWeb.Dashboard, :router

  def telemetry_route(conn) do
    case Phoenix.Router.route_info(__MODULE__, conn.method, conn.path_info, conn.host) do
      %{route: route} -> route
      _ -> "unmatched"
    end
  end

  import SalixWeb.Dashboard.Auth, only: [fetch_admin: 2, require_admin: 2]
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SalixWeb.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_admin)
  end

  # Public auth actions (admin-token login form + session create/logout).
  scope "/dash", SalixWeb.Dashboard do
    pipe_through(:browser)

    get("/login", AuthController, :login)
    post("/session", AuthController, :create)
    delete("/logout", AuthController, :logout)
  end

  # Authenticated dashboard pages.
  scope "/dash", SalixWeb.Dashboard do
    pipe_through([:browser, :require_admin])

    # Binary VFS download (controller, not LiveView) — must precede the
    # `/agents/:id/files/*path` live route so it isn't captured by the glob.
    get("/agents/:id/files/download", FileController, :download)

    # Raw-JSON session reasoning trace (controller, not LiveView) — opened in a
    # new tab from the session view's "Raw JSON" button.
    get("/agents/:id/sessions/:session_id/trace", SessionTraceController, :show)

    # Tenant switcher target (controller sets the session cookie; LiveView can't).
    get("/tenant/select", TenantController, :select)

    # Phoenix LiveDashboard — runtime/metrics introspection. `live_dashboard`
    # establishes its OWN `live_session` (so it sits OUTSIDE `:authenticated`),
    # gated at the socket by the same `:ensure_admin` on_mount and at HTTP by the
    # `:require_admin` pipeline above. `live_socket_path` points at the shared
    # `/dash/live` socket (DashboardEndpoint) instead of the default `/live`.
    live_dashboard("/live-dashboard",
      metrics: SalixWeb.Telemetry,
      live_socket_path: "/dash/live",
      on_mount: [{SalixWeb.Dashboard.Auth, :ensure_admin}]
    )

    live_session :authenticated,
      on_mount: [{SalixWeb.Dashboard.Auth, :ensure_admin}] do
      live("/", HomeLive, :index)
      live("/cluster", ClusterLive, :index)
      live("/tenants", TenantLive.Index, :index)
      live("/tenants/:id", TenantLive.Show, :show)
      live("/account-pool", AccountPoolLive, :index)
      live("/templates", TemplateLive.Index, :index)
      live("/templates/new", TemplateLive.Form, :new)
      live("/templates/:id", TemplateLive.Form, :edit)
      live("/groups", GroupLive.Index, :index)
      live("/groups/:id", GroupLive.Show, :show)
      live("/groups/:id/slack/:connect_id/commands", SlackCommandsLive, :index)
      live("/oauth", OAuthLive, :index)
      live("/composio", ComposioLive, :index)
      live("/browser", BrowserLive, :index)
      live("/drive", DriveLive, :index)
      live("/cloud-vm", CloudVMLive, :index)
      live("/voice", VoiceLive, :index)
      live("/signal", SignalLive, :index)
      live("/signal/register", SignalRegisterLive, :index)
      live("/initial-agents", InitialAgentLive.Index, :index)
      live("/initial-agents/new", InitialAgentLive.Form, :new)
      live("/initial-agents/:slot", InitialAgentLive.Form, :edit)
      live("/agents", AgentLive.Index, :index)
      live("/agents/new", AgentLive.New, :new)
      live("/agents/:id", AgentLive.Show, :show)
      live("/agents/:id/sessions", SessionLive.Index, :index)
      live("/agents/:id/sessions/:session_id", SessionLive.Show, :show)
      live("/trajectory-evals", TrajectoryEvalLive, :index)
      live("/runtime", RuntimeHealthLive, :overview)
      live("/runtime/tools", RuntimeHealthLive, :tools)
      live("/runtime/models", RuntimeHealthLive, :models)
      live("/runtime/activity", RuntimeHealthLive, :activity)
      live("/im", IMLive.Index, :index)
      live("/im-config", IMConfigLive, :index)
      live("/slack-commands", SlackCommandsLive, :index)
      live("/slack-command-templates", SlackCommandTemplatesLive, :index)
      live("/mcp", MCPLive, :index)
      live("/plugins", PluginLive, :index)
      live("/agents/:id/files", FileLive, :index)
      live("/agents/:id/files/*path", FileLive, :index)
      live("/environments", EnvironmentLive.Index, :index)
      live("/environments/:group_id/:id", EnvironmentLive.Show, :show)
      live("/compute-nodes", ComputeNodeLive.Index, :index)
      live("/compute-nodes/:id", ComputeNodeLive.Show, :show)
      live("/agent-defaults", AgentDefaultsLive, :index)
    end
  end
end
