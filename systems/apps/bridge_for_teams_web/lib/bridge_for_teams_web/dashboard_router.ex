defmodule BridgeForTeamsWeb.DashboardRouter do
  @moduledoc """
  Router for the BridgeForTeams LiveView dashboard (port 4101). The `:browser`
  pipeline runs the standard plugs plus `fetch_current_user` (resolves the
  signed session cookie into `:current_user`). Authenticated pages live in the
  `:authenticated` `live_session` with the `{Dashboard.Auth, :ensure_authenticated}`
  on_mount hook; anonymous users are redirected to `/login`, which drives the
  existing OIDC flow via `BridgeForTeamsWeb.Dashboard.AuthController`.

  ## Adding a route

  Add a `live "/path", SomeLive` inside the `:authenticated` live_session (so it
  inherits auth + the app layout), or a `get/post` to a controller in the
  `:browser` scope for non-LiveView actions. Page-slice ownership is documented
  in the build manifest.
  """
  use BridgeForTeamsWeb.Dashboard, :router

  def telemetry_route(conn) do
    case Phoenix.Router.route_info(__MODULE__, conn.method, conn.path_info, conn.host) do
      %{route: route} -> route
      _ -> "unmatched"
    end
  end

  import Plug.Conn

  alias BridgeForTeams.Auth
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.Accounts
  alias BridgeForTeamsWeb.JSON

  import BridgeForTeamsWeb.Dashboard.Auth, only: [fetch_current_user: 2, require_authenticated: 2]

  pipeline :dashboard_api do
    plug(:put_runtime_auth_no_store)
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
    plug(:require_dashboard_api_authenticated)
  end

  pipeline :provisioner_api do
    plug(:accepts, ["json"])
    plug(:authenticate_provisioner_api_key)
  end

  pipeline :cli_api do
    plug(:put_runtime_auth_no_store)
    plug(:accepts, ["json"])
    plug(:authenticate_cli_session)
  end

  # My Space data-import endpoint: a temporary import token (minted from the
  # Agent Swarm dashboard) is tried first, falling back to the CLI-session auth
  # so scripted/CLI use keeps working.
  pipeline :dashboard_import_api do
    plug(:accepts, ["json"])
    plug(:authenticate_dashboard_import)
  end

  pipeline :cli_auth_api do
    plug(:accepts, ["json"])
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BridgeForTeamsWeb.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
    plug(BridgeForTeamsWeb.Dashboard.Locale)
  end

  pipeline :authenticated_browser do
    plug(:require_authenticated)
  end

  scope "/", BridgeForTeamsWeb do
    get("/live", HealthController, :live)
    get("/ready", HealthController, :ready)
    get("/health", HealthController, :ready)
  end

  # Public auth actions (login form + OIDC start/callback/logout).
  scope "/", BridgeForTeamsWeb.Dashboard do
    pipe_through(:browser)

    # Locale switcher (writes the session cookie, then redirects back).
    get("/locale/:locale", LocaleController, :update)

    get("/login", AuthController, :login)
    get("/signup", AuthController, :signup)
    post("/signup", AuthController, :create_from_invite)
    post("/auth/start", AuthController, :start)
    get("/auth/callback", AuthController, :callback)
    get("/auth/recovery", AuthController, :recover)

    # Email magic-link fallback for orgs without an SSO connection.
    get("/auth/email", AuthController, :email_login)
    post("/auth/email/send", AuthController, :send_login_link)
    get("/auth/email/verify", AuthController, :verify_login_link)

    delete("/logout", AuthController, :logout)

    # Dev/e2e-only login bypass (404 unless :dev_login flag is set; never prod).
    get("/dev/login", AuthController, :dev_login)
  end

  scope "/", BridgeForTeamsWeb do
    pipe_through([:browser, :authenticated_browser])
    get("/runtime-auth/projects/:project_id", ProjectDeviceController, :runtime_auth_management)
  end

  # Public product bootstrap endpoints that do not require an authenticated CLI
  # or dashboard session.
  scope "/v1", BridgeForTeamsWeb do
    get("/cli/install.sh", BFTCLIInstallController, :show)
    get("/cli/release", BFTCLIInstallController, :release)
    get("/orgs/:org_id/runners/install.sh", MacMiniInstallController, :show)
  end

  scope "/dashboard", BridgeForTeamsWeb do
    pipe_through(:dashboard_api)

    post(
      "/orgs/:org/projects/:project/runtime-auth",
      ProjectDeviceController,
      :private_runtime_auth
    )

    get(
      "/orgs/:org/projects/:project/runtime-auth/requests",
      ProjectDeviceController,
      :runtime_auth_requests
    )

    post(
      "/orgs/:org/projects/:project/runtime-auth/requests/:request_id/complete",
      ProjectDeviceController,
      :complete_runtime_auth_request
    )

    get(
      "/orgs/:org/projects/:project/devices/:device_id/runtimes/:runtime_id/managed-auth",
      ProjectComputeController,
      :managed_auth
    )

    put(
      "/orgs/:org/projects/:project/devices/:device_id/runtimes/:runtime_id/managed-auth",
      ProjectComputeController,
      :managed_auth
    )

    delete(
      "/orgs/:org/projects/:project/devices/:device_id/runtimes/:runtime_id/managed-auth",
      ProjectComputeController,
      :managed_auth
    )

    get(
      "/orgs/:org/projects/:project/workloads/:id/managed-auth",
      ProjectComputeController,
      :managed_auth
    )

    put(
      "/orgs/:org/projects/:project/workloads/:id/managed-auth",
      ProjectComputeController,
      :managed_auth
    )

    delete(
      "/orgs/:org/projects/:project/workloads/:id/managed-auth",
      ProjectComputeController,
      :managed_auth
    )

    get("/cli/sessions", CLIAuthController, :sessions)
    delete("/cli/sessions/:session_id", CLIAuthController, :revoke_session)
    get("/cli/device-authorizations/:user_code", CLIAuthController, :device_authorization)

    post(
      "/cli/device-authorizations/:user_code/approve",
      CLIAuthController,
      :approve_device_authorization
    )

    post(
      "/cli/device-authorizations/:user_code/cancel",
      CLIAuthController,
      :cancel_device_authorization
    )
  end

  scope "/v1", BridgeForTeamsWeb do
    pipe_through(:cli_api)

    get("/orgs/:org/projects/:project/agents", ProjectAgentController, :index)
    get("/orgs/:org/projects/:project/agents/runtimes", ProjectAgentController, :runtimes)
    get("/orgs/:org/projects/:project/agents/workloads", ProjectAgentController, :workloads)
    post("/orgs/:org/projects/:project/agents", ProjectAgentController, :create)

    patch(
      "/orgs/:org/projects/:project/agents/:agent/runtime",
      ProjectAgentController,
      :rebind_runtime
    )

    patch("/orgs/:org/projects/:project/agents/:agent", ProjectAgentController, :update)

    get("/orgs/:org/projects/:project/devices", ProjectDeviceController, :index)
    post("/orgs/:org/projects/:project/devices", ProjectDeviceController, :create)

    get("/orgs/:org/projects/:project/compute", ProjectComputeController, :index)

    post(
      "/orgs/:org/projects/:project/compute-nodes/agent-vmm/install-operations",
      ProjectComputeController,
      :request_agent_vmm_install
    )

    get(
      "/orgs/:org/projects/:project/compute-nodes/agent-vmm/install-operations/:operation_id",
      ProjectComputeController,
      :get_agent_vmm_install
    )

    post(
      "/orgs/:org/projects/:project/compute-nodes/agent-vmm/install-operations/:operation_id/retry",
      ProjectComputeController,
      :retry_agent_vmm_install
    )

    post(
      "/orgs/:org/projects/:project/compute-nodes/agent-vmm/install-operations/:operation_id/revoke",
      ProjectComputeController,
      :revoke_agent_vmm_install
    )

    post(
      "/orgs/:org/projects/:project/compute-nodes/agent-vmm/install-operations/:operation_id/enable",
      ProjectComputeController,
      :enable_agent_vmm_install
    )

    post(
      "/orgs/:org/projects/:project/compute-nodes/agent-vmm/install-operations/:operation_id/disable",
      ProjectComputeController,
      :disable_agent_vmm_install
    )

    post("/orgs/:org/compute/pools", OrgComputeController, :create_pool)
    put("/orgs/:org/compute/pools/:pool_id", OrgComputeController, :update_pool)
    post("/orgs/:org/compute/providers", OrgComputeController, :configure_default_provider)

    post(
      "/orgs/:org/compute/pools/:pool_id/providers",
      OrgComputeController,
      :configure_provider
    )

    put(
      "/orgs/:org/compute/providers/:provider_id",
      OrgComputeController,
      :update_provider
    )

    post(
      "/orgs/:org/projects/:project/compute/grants",
      ProjectComputeController,
      :grant
    )

    post(
      "/orgs/:org/projects/:project/compute/environments",
      ProjectComputeController,
      :create_environment
    )

    post(
      "/orgs/:org/projects/:project/compute/workloads",
      ProjectComputeController,
      :create_workload
    )

    put(
      "/orgs/:org/projects/:project/compute/environments/:environment_id/retention",
      ProjectComputeController,
      :retain
    )

    post(
      "/orgs/:org/projects/:project/compute/environments/:environment_id/drain",
      ProjectComputeController,
      :drain
    )

    post(
      "/orgs/:org/projects/:project/compute/environments/:environment_id/revoke",
      ProjectComputeController,
      :revoke
    )

    post(
      "/orgs/:org/projects/:project/devices/requests/:request_id/stop",
      ProjectDeviceController,
      :stop_request
    )

    post(
      "/orgs/:org/projects/:project/devices/:device_id/disconnect",
      ProjectDeviceController,
      :disconnect
    )

    get(
      "/orgs/:org/projects/:project/devices/:device_id/runtimes/:device_runtime_id/auth",
      ProjectDeviceController,
      :runtime_auth
    )

    post(
      "/orgs/:org/projects/:project/devices/:device_id/runtimes/:device_runtime_id/auth/login",
      ProjectDeviceController,
      :start_runtime_login
    )

    delete(
      "/orgs/:org/projects/:project/devices/:device_id/runtimes/:device_runtime_id/auth/login",
      ProjectDeviceController,
      :cancel_runtime_login
    )

    get("/orgs/:org/projects/:project/im/slack/connects", ProjectIMConnectController, :index)

    post(
      "/orgs/:org/projects/:project/im/slack/connects",
      ProjectIMConnectController,
      :create_slack
    )

    patch(
      "/orgs/:org/projects/:project/im/slack/connects/:connect_id",
      ProjectIMConnectController,
      :update_slack
    )

    post(
      "/orgs/:org/projects/:project/im/slack/connects/:connect_id/disable",
      ProjectIMConnectController,
      :disable_slack
    )

    post(
      "/orgs/:org/projects/:project/im/slack/connects/:connect_id/enable",
      ProjectIMConnectController,
      :enable_slack
    )

    delete(
      "/orgs/:org/projects/:project/im/slack/connects/:connect_id",
      ProjectIMConnectController,
      :delete_slack
    )

    get("/orgs/:org/runners", RunnerController, :index)
    post("/orgs/:org/runners/install-command", RunnerController, :install_command)
  end

  scope "/v1", BridgeForTeamsWeb do
    pipe_through(:dashboard_import_api)

    post("/orgs/:org/projects/:project/dashboard/import", DashboardImportController, :create)
  end

  scope "/v1/cli", BridgeForTeamsWeb do
    pipe_through(:cli_auth_api)

    post("/auth/device", CLIAuthController, :start_device_authorization)
    post("/auth/device/poll", CLIAuthController, :poll_device_authorization)
  end

  scope "/v1/cli", BridgeForTeamsWeb do
    pipe_through(:cli_api)

    get("/context", CLIController, :context)
    get("/orgs", CLIController, :orgs)
    get("/projects", CLIController, :projects)
    get("/conversations", CLIController, :conversations)
    get("/conversations/:conversation_id", CLIController, :conversation)
    get("/conversations/:conversation_id/messages", CLIController, :conversation_messages)
    post("/conversations/:conversation_id/messages", CLIController, :conversation_send)

    get(
      "/conversations/:conversation_id/participants/:participant_id/status",
      CLIController,
      :conversation_participant_status
    )

    get("/conversations/:conversation_id/trace", CLIController, :conversation_trace)
    get("/conversations/:conversation_id/delivery", CLIController, :conversation_delivery)
    post("/conversations/:conversation_id/redeliver", CLIController, :conversation_redeliver)
    post("/feishu/apps", CLIController, :upsert_feishu_app)
    get("/feishu/apps/selected", CLIController, :selected_feishu_app)
    post("/feishu/setup", CLIController, :feishu_setup)
    post("/feishu/connect", CLIController, :feishu_connect)
    post("/feishu/checks", CLIController, :feishu_checks)
    post("/sso/checks", CLIController, :sso_checks)
    post("/auth/logout", CLIAuthController, :logout)
    post("/auth/orgs/device", CLIAuthController, :start_org_grant_authorization)
    post("/auth/orgs/device/poll", CLIAuthController, :poll_org_grant_authorization)
    post("/auth/orgs/revoke", CLIAuthController, :revoke_org_grant)
    post("/slack/setup", CLIController, :slack_setup)
    get("/meetings/calendar/status", CLIController, :meeting_calendar_status)
    post("/meetings/replay", CLIController, :meeting_summary_replay)
  end

  scope "/v1", BridgeForTeamsWeb do
    pipe_through(:provisioner_api)

    post("/orgs/:org_id/runners", MacMiniProvisionerController, :register)

    post(
      "/orgs/:org_id/runners/:provisioner_id/heartbeat",
      MacMiniProvisionerController,
      :heartbeat
    )

    post(
      "/orgs/:org_id/runners/:provisioner_id/claim",
      MacMiniProvisionerController,
      :claim
    )

    get(
      "/orgs/:org_id/runners/:provisioner_id/provision-requests/:request_id",
      MacMiniProvisionerController,
      :show_request
    )

    post(
      "/orgs/:org_id/runners/:provisioner_id/provision-requests/:request_id/status",
      MacMiniProvisionerController,
      :status
    )
  end

  # Authenticated dashboard pages.
  scope "/", BridgeForTeamsWeb.Dashboard do
    pipe_through([:browser, :require_authenticated])

    get(
      "/orgs/:org/projects/:id/tasks/:conversation_id/debug-trace",
      ConversationTraceController,
      :show
    )

    get(
      "/orgs/:org/projects/:id/tasks/:conversation_id/messages/:message_id/attachments/:index",
      ConversationAttachmentController,
      :show
    )

    get(
      "/tasks/:tenant_id/:group_id/:conversation_id",
      SalixConversationController,
      :show
    )

    get("/orgs/:org/operations/audit.csv", OperationsExportController, :audit)

    get("/impersonate", ImpersonationController, :new)
    post("/impersonate", ImpersonationController, :create)

    # Reopen the first-run flow (user-menu action; available to everyone,
    # onboarded or not). Same scope as the wizard: authenticated, not gated.
    post("/onboarding/restart", OnboardingController, :restart)

    # First-run onboarding: authenticated but NOT gated by :require_onboarded
    # (this is where the gate sends people). Steps are live_actions so the
    # OAuth consent round trip can land back on /onboarding/integrations.
    live_session :onboarding,
      on_mount: [
        {BridgeForTeamsWeb.Dashboard.Auth, :ensure_authenticated},
        {BridgeForTeamsWeb.Dashboard.Auth, :set_locale}
      ] do
      live("/onboarding", OnboardingLive, :capabilities)
      live("/onboarding/profile", OnboardingLive, :profile)
      live("/onboarding/integrations", OnboardingLive, :integrations)
      live("/onboarding/tasks", OnboardingLive, :tasks)
    end

    live_session :authenticated,
      on_mount: [
        {BridgeForTeamsWeb.Dashboard.Auth, :ensure_authenticated},
        {BridgeForTeamsWeb.Dashboard.Auth, :require_onboarded},
        {BridgeForTeamsWeb.Dashboard.Auth, :set_locale},
        # Member onboarding overlays (welcome modal / quick-setup checklist /
        # guided tour): assigns @onboarding + @oauth_reminder_alert for the app
        # shell. Runs after the first-run gate — the full-screen /onboarding
        # flow renders without the shell and does not use these assigns.
        BridgeForTeamsWeb.Dashboard.Onboarding
      ] do
      # slice "orgs-shell"
      live("/", HomeLive, :index)
      live("/new-home", NewHomeLive, :index)
      live("/new-home/chat", NewHomeLive, :chat)
      # Retired sheet URL — the wall lives inline on /new-home now; the
      # LiveView patches stale tabs and bookmarks back to the board.
      live("/new-home/widgets", NewHomeLive, :widgets)
      live("/new-home/artifacts/:id", ArtifactLive.Show, :show)
      live("/orgs", OrgLive.Index, :index)
      live("/orgs/:org", HomeLive, :show)
      live("/cli/device-login", CLIDeviceLoginLive, :new)
      live("/cli/device-login/:user_code", CLIDeviceLoginLive, :show)

      # slice "projects"
      live("/orgs/:org/projects", ProjectLive.Index, :index)

      # slice "operations"
      live("/orgs/:org/operations", OperationsLive.Index, :overview)
      live("/orgs/:org/operations/delivery", OperationsLive.Index, :delivery)
      live("/orgs/:org/operations/integrations", OperationsLive.Index, :integrations)
      live("/orgs/:org/operations/runners", OperationsLive.Index, :runners)
      live("/orgs/:org/operations/events", OperationsLive.Index, :events)
      live("/orgs/:org/operations/checks", OperationsLive.Index, :checks)
      live("/orgs/:org/operations/audit", OperationsLive.Index, :audit)

      # slice "triage" — owner/admin product surface. Source/channel/listening
      # authority is enforced inside the focused setup and again at ingress.
      live("/orgs/:org/triage", TriageLive.Index, :overview)
      live("/orgs/:org/triage/context", TriageLive.Index, :context)
      live("/orgs/:org/triage/timeline", TriageLive.Index, :timeline)
      live("/orgs/:org/triage/knowledge", TriageLive.Index, :knowledge)
      live("/orgs/:org/triage/memory", TriageLive.Index, :memory)
      live("/orgs/:org/triage/data", TriageLive.Index, :data)

      live("/orgs/:org/meetings", MeetingPreparationLive, :index)
      live("/orgs/:org/meetings/past", MeetingPreparationLive, :past)
      live("/orgs/:org/meetings/settings", MeetingPreparationLive, :settings)

      # slice "information-flow" — owner/admin only. Decides what the assistant
      # may carry between conversations; the mode is written through the group
      # control API, which validates it.
      live("/orgs/:org/information-flow", InformationFlowLive, :index)

      # slice "fin"
      live("/orgs/:org/fin", FinLive.Index, :index)

      # slice "plugins" — org-level plugin catalog and tenant definitions.
      live("/orgs/:org/plugins", PluginLive.Index, :index)

      # slice "project-detail"
      live("/orgs/:org/projects/:id", ProjectLive.Show, :show)
      live("/orgs/:org/projects/:id/agents", ProjectLive.Show, :agents)
      live("/orgs/:org/projects/:id/agents/:agent_id", AgentLive.Show, :show)
      live("/orgs/:org/projects/:id/tasks", ProjectLive.Show, :tasks)
      live("/orgs/:org/projects/:id/schedules", ProjectLive.Show, :schedules)
      live("/orgs/:org/projects/:id/integrations", ProjectLive.Show, :integrations)
      live("/orgs/:org/projects/:id/connections", ProjectLive.Show, :connections)
      live("/orgs/:org/projects/:id/plugins", ProjectLive.Show, :plugins)
      live("/orgs/:org/projects/:id/plugins/:plugin_id", ProjectLive.Show, :plugin)
      live("/orgs/:org/projects/:id/skills", ProjectLive.Show, :skills)
      live("/orgs/:org/projects/:id/settings", ProjectLive.Show, :settings)
      live("/orgs/:org/projects/:id/access", ProjectLive.Show, :settings)

      live(
        "/orgs/:org/projects/:id/tasks/:conversation_id",
        ConversationLive.Show,
        :show
      )

      live(
        "/orgs/:org/projects/:id/tasks/:conversation_id/session",
        ConversationSessionLive.Show,
        :show
      )

      live("/orgs/:org/projects/:id/devices", ProjectLive.Show, :environments)
      live("/orgs/:org/projects/:id/websites", ProjectLive.Show, :websites)

      # slice "members-settings"
      live("/orgs/:org/members", MemberLive.Index, :index)
      live("/orgs/:org/settings", SettingsLive, :index)
      live("/orgs/:org/settings/models", SettingsLive, :models)
      live("/orgs/:org/settings/models/templates", PrivateTemplatesLive, :index)
      live("/orgs/:org/settings/subscriptions", SubscriptionsLive, :index)
      live("/orgs/:org/settings/sso", SettingsLive, :sso)
      live("/orgs/:org/settings/oauth", SettingsLive, :oauth)
      live("/orgs/:org/settings/composio", SettingsLive, :composio)
      live("/orgs/:org/settings/signal", SettingsLive, :signal)
      live("/orgs/:org/settings/feishu", SettingsLive, :feishu)
    end
  end

  defp authenticate_provisioner_api_key(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, %{org_id: org_id, scopes: scopes, runner_stable_id: runner_stable_id}} <-
           Auth.authenticate_api_key(token) do
      conn
      |> assign(:current_org, org_id)
      |> assign(:auth_scopes, scopes)
      |> assign(:auth_runner_stable_id, runner_stable_id)
    else
      _ ->
        conn
        |> JSON.send_error(:unauthenticated, 401)
        |> halt()
    end
  end

  # This runs before authentication so unauthorized runtime-auth requests
  # receive the same non-cacheable treatment as successful ceremonies.
  defp put_runtime_auth_no_store(conn, _opts) do
    case conn.path_info do
      ["dashboard", "orgs", _org, "projects", _project, "runtime-auth" | _rest] ->
        put_resp_header(conn, "cache-control", "no-store")

      [
        "dashboard",
        "orgs",
        _org,
        "projects",
        _project,
        "workloads",
        _workload,
        "managed-auth"
      ] ->
        put_resp_header(conn, "cache-control", "no-store")

      [
        "v1",
        "orgs",
        _org,
        "projects",
        _project,
        "devices",
        _device_id,
        "runtimes",
        _device_runtime_id,
        "auth"
        | _rest
      ] ->
        put_resp_header(conn, "cache-control", "no-store")

      _other ->
        conn
    end
  end

  # Try a temporary import token first (project-admin minted, org/project
  # scoped). If the bearer is not a valid import token, fall back to the
  # existing CLI-session auth so scripted/CLI imports keep working.
  defp authenticate_dashboard_import(conn, opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, %{user: user, org_id: org_id, project_id: project_id}} <-
           Auth.authenticate_import_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:import_token_org_id, org_id)
      |> assign(:import_token_project_id, project_id)
    else
      _ -> authenticate_cli_session(conn, opts)
    end
  end

  defp authenticate_cli_session(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, session} <- Sessions.fetch(token, touch: false),
         :ok <- CLILogin.validate_cli_session(session),
         {:ok, user} <- Accounts.get_user(session.user_id),
         "active" <- user.status,
         {:ok, _session} <- CLILogin.refresh_cli_session(session) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_cli_token, token)
      |> assign(:current_cli_session, session)
    else
      {:error, {:cli_session_refresh_failed, _reason}} ->
        conn
        |> send_cli_error(
          500,
          "cli_session_refresh_failed",
          "Could not refresh the BFT CLI session. Retry the command."
        )
        |> halt()

      _ ->
        conn
        |> send_cli_error(401, "unauthenticated", "Run bft auth login first.")
        |> halt()
    end
  end

  defp require_dashboard_api_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> send_cli_error(401, "unauthenticated", "Log in to the BFT dashboard first.")
      |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_bearer_token}
    end
  end

  defp send_cli_error(conn, status, code, message) do
    JSON.send_json(
      conn,
      %{
        "ok" => false,
        "error" => %{
          "code" => code,
          "message" => message,
          "details" => %{}
        }
      },
      status
    )
  end
end
