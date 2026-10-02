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

  pipeline :dashboard_locale do
    plug(BridgeForTeamsWeb.Dashboard.Locale)
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

  # JSON API for the React dashboard; same browser session and locale as the pages.
  scope "/dashboard/api/v1", BridgeForTeamsWeb do
    pipe_through([:dashboard_api, :dashboard_locale])

    get("/session", DashboardAPIController, :session)
    get("/orgs/:org/context", DashboardAPIController, :context)
    get("/orgs/:org/overview", DashboardAPIController, :overview)
    # The first-run checklist on the Overview.
    get("/orgs/:org/onboarding", DashboardAPIController, :onboarding)
    post("/orgs/:org/onboarding/dismiss", DashboardAPIController, :dismiss_onboarding)
    get("/orgs/:org/health", DashboardAPIController, :health)
    get("/orgs/:org/audit", DashboardAPIController, :audit)
    get("/orgs/:org/projects", DashboardAPIController, :projects)
    post("/orgs/:org/projects", DashboardAPIController, :create_project)
    get("/orgs/:org/projects/:id/overview", DashboardAPIController, :project_overview)

    # One Agent Swarm's React pages: Agents (with the agent detail rail),
    # Devices (with Compute environments), Tasks (with its Scheduled view),
    # the Overview's Websites panel, and Settings with Access.
    scope "/orgs/:org/projects/:id" do
      get("/agents", DashboardAPIController, :project_agents)
      post("/agents", DashboardAPIController, :create_project_agent)
      get("/agents/targets", DashboardAPIController, :project_agent_targets)
      get("/agents/workloads", DashboardAPIController, :project_agent_workloads)
      get("/agents/:agent_id", DashboardAPIController, :project_agent)
      patch("/agents/:agent_id", DashboardAPIController, :configure_project_agent)
      get("/agents/:agent_id/config", DashboardAPIController, :project_agent_config)
      put("/agents/:agent_id/runtime", DashboardAPIController, :rebind_project_agent)
      post("/agents/:agent_id/archive", DashboardAPIController, :archive_project_agent)

      post(
        "/agents/:agent_id/router-session",
        DashboardAPIController,
        :switch_project_agent_session
      )

      get("/devices", DashboardAPIController, :project_devices)
      post("/devices", DashboardAPIController, :create_project_device)
      get("/devices/provisioning", DashboardAPIController, :project_device_provisioning)
      get("/devices/runners", DashboardAPIController, :project_device_runners)
      put("/devices/cloud", DashboardAPIController, :set_project_cloud_computer)
      post("/devices/:device_id/disconnect", DashboardAPIController, :disconnect_project_device)
      delete("/devices/:device_id", DashboardAPIController, :delete_project_device)

      post(
        "/compute/:environment_id/shell",
        DashboardAPIController,
        :create_project_shell_workload
      )

      post("/compute/:environment_id/drain", DashboardAPIController, :drain_project_environment)
      post("/compute/:environment_id/revoke", DashboardAPIController, :revoke_project_environment)
      get("/websites", DashboardAPIController, :project_websites)
      get("/tasks", DashboardAPIController, :project_tasks)
      post("/tasks", DashboardAPIController, :create_project_task)
      get("/schedules", DashboardAPIController, :project_schedules)
      delete("/schedules/:schedule_id", DashboardAPIController, :delete_project_schedule)
      get("/settings", DashboardAPIController, :project_settings)
      patch("/settings", DashboardAPIController, :update_project_settings)
      post("/archive", DashboardAPIController, :archive_project)
      get("/access", DashboardAPIController, :project_access)
      post("/access", DashboardAPIController, :grant_project_access)
      patch("/access/:user_id", DashboardAPIController, :update_project_access)
      delete("/access/:user_id", DashboardAPIController, :remove_project_access)
    end

    get("/orgs/:org/plugins", DashboardAPIController, :plugins)
    post("/orgs/:org/plugins", DashboardAPIController, :create_plugin)
    put("/orgs/:org/plugins/:plugin_id", DashboardAPIController, :update_plugin)

    # Meetings and Data policy: owner/admin pages of one Agent Swarm.
    get("/orgs/:org/meetings/:project_id", DashboardAPIController, :meetings)
    put("/orgs/:org/meetings/:project_id/settings", DashboardAPIController, :save_meetings)
    get("/orgs/:org/meetings/:project_id/:read", DashboardAPIController, :meetings_read)
    get("/orgs/:org/data-policy/:project_id", DashboardAPIController, :data_policy)
    patch("/orgs/:org/data-policy/:project_id", DashboardAPIController, :update_data_policy)

    scope "/orgs/:org/data-policy/:project_id/connects/:connect_id" do
      put("/scopes/:scope_id", DashboardAPIController, :classify_data_policy_scope)
      delete("/scopes/:scope_id", DashboardAPIController, :reset_data_policy_scope)
      post("/clearances", DashboardAPIController, :grant_data_policy_clearance)
      # The tag and principal travel in the JSON body: a tag such as `.` or
      # `..` does not survive as a path segment.
      delete("/clearances", DashboardAPIController, :withdraw_data_policy_clearance)

      put("/placements/:user_id", DashboardAPIController, :place_data_policy_principal)
    end

    # Slack triage: owner/admin pages for one router Agent (`agent` param).
    scope "/orgs/:org/triage" do
      get("/", DashboardAPIController, :triage)
      get("/evaluation", DashboardAPIController, :triage_evaluation)
      get("/channels", DashboardAPIController, :triage_channels)
      put("/sources/:connect_id", DashboardAPIController, :set_triage_source)
      post("/sources/:connect_id/channels", DashboardAPIController, :add_triage_channels)

      put(
        "/sources/:connect_id/channels/:channel_id",
        DashboardAPIController,
        :set_triage_channel
      )

      get("/worker", DashboardAPIController, :triage_worker)
      put("/worker", DashboardAPIController, :save_triage_worker)
      get("/activity", DashboardAPIController, :triage_activity)
      post("/reveal", DashboardAPIController, :reveal_triage_text)
      get("/heatmap", DashboardAPIController, :triage_heatmap)
      get("/processing", DashboardAPIController, :triage_processing)
      get("/delegation", DashboardAPIController, :triage_delegation)
      get("/knowledge", DashboardAPIController, :triage_knowledge)
    end

    get("/orgs/:org/members", DashboardAPIController, :members)
    post("/orgs/:org/members", DashboardAPIController, :invite_member)
    patch("/orgs/:org/members/:user_id", DashboardAPIController, :update_member)
    delete("/orgs/:org/members/:user_id", DashboardAPIController, :remove_member)

    get("/orgs/:org/runners", DashboardAPIController, :runners)
    get("/orgs/:org/runners/onboarding", DashboardAPIController, :runner_onboarding)

    post(
      "/orgs/:org/runners/install-commands",
      DashboardAPIController,
      :create_runner_install_command
    )

    delete("/orgs/:org/runners/keys/:id", DashboardAPIController, :revoke_runner_key)
    post("/orgs/:org/runners/keys/:id/rotate", DashboardAPIController, :rotate_runner_key)
    get("/orgs/:org/runners/:id/connectors", DashboardAPIController, :runner_connectors)
    delete("/orgs/:org/runners/:id", DashboardAPIController, :remove_runner)

    get("/orgs/:org/settings/general", DashboardAPIController, :settings_general)
    patch("/orgs/:org/settings/general", DashboardAPIController, :update_settings_general)

    delete(
      "/orgs/:org/settings/cli-sessions/:id",
      DashboardAPIController,
      :revoke_settings_cli_session
    )

    get("/orgs/:org/settings/models", DashboardAPIController, :settings_models)
    put("/orgs/:org/settings/models", DashboardAPIController, :update_settings_models)

    scope "/orgs/:org/settings/models" do
      get("/templates", DashboardAPIController, :model_templates)
      post("/templates", DashboardAPIController, :create_model_template)
      post("/templates/discover", DashboardAPIController, :discover_template_models)
      put("/templates/:id", DashboardAPIController, :update_model_template)
      delete("/templates/:id", DashboardAPIController, :delete_model_template)
      get("/accounts", DashboardAPIController, :model_accounts)
      post("/accounts", DashboardAPIController, :create_model_account)
      post("/accounts/oauth", DashboardAPIController, :begin_model_account_oauth)

      post(
        "/accounts/oauth/:attempt_id/complete",
        DashboardAPIController,
        :complete_model_account_oauth
      )

      patch("/accounts/:id", DashboardAPIController, :update_model_account)
      delete("/accounts/:id", DashboardAPIController, :delete_model_account)
      post("/accounts/:id/quota", DashboardAPIController, :refresh_model_account_quota)
      post("/accounts/:id/reset", DashboardAPIController, :reset_model_account_quota)
      get("/accounts/:id/usage", DashboardAPIController, :model_account_usage)
    end

    get("/orgs/:org/settings/sso", DashboardAPIController, :settings_sso)
    put("/orgs/:org/settings/sso", DashboardAPIController, :update_settings_sso)
    post("/orgs/:org/settings/sso/checks", DashboardAPIController, :run_settings_sso_checks)
    get("/orgs/:org/settings/integrations", DashboardAPIController, :settings_integrations)

    put(
      "/orgs/:org/settings/integrations/oauth/:provider",
      DashboardAPIController,
      :save_settings_oauth_app
    )

    delete(
      "/orgs/:org/settings/integrations/oauth/:provider",
      DashboardAPIController,
      :delete_settings_oauth_app
    )

    put(
      "/orgs/:org/settings/integrations/composio",
      DashboardAPIController,
      :save_settings_composio
    )

    delete(
      "/orgs/:org/settings/integrations/composio",
      DashboardAPIController,
      :delete_settings_composio
    )

    put("/orgs/:org/settings/integrations/signal", DashboardAPIController, :save_settings_signal)

    post(
      "/orgs/:org/settings/integrations/feishu/apps",
      DashboardAPIController,
      :create_settings_feishu_app
    )

    put(
      "/orgs/:org/settings/integrations/feishu/apps/:id",
      DashboardAPIController,
      :update_settings_feishu_app
    )

    delete(
      "/orgs/:org/settings/integrations/feishu/apps/:id",
      DashboardAPIController,
      :delete_settings_feishu_app
    )

    post(
      "/orgs/:org/settings/integrations/feishu/routes",
      DashboardAPIController,
      :connect_settings_feishu_route
    )

    post(
      "/orgs/:org/settings/integrations/feishu/projects/:project_id/routes/:connect_id/disable",
      DashboardAPIController,
      :disable_settings_feishu_route
    )

    get("/cli/device-login/:user_code", DashboardAPIController, :cli_login)
    post("/cli/device-login/:user_code/approve", DashboardAPIController, :approve_cli_login)
    post("/cli/device-login/:user_code/deny", DashboardAPIController, :deny_cli_login)
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

    # Pages owned by the React dashboard (clients/apps/bft). Pages move here
    # from the LiveView live_session one at a time.
    get("/", SPAController, :index)
    # The organization picker is the top-bar switcher; `/orgs` opens the
    # first organization like `/`.
    get("/orgs", SPAController, :index)
    get("/orgs/:org", SPAController, :index)
    get("/orgs/:org/projects", SPAController, :index)
    get("/orgs/:org/projects/:id", SPAController, :index)
    # Agent Swarm pages: Agents (an agent's address opens it in the detail
    # rail), Devices, Tasks (the retired Schedules page is its Scheduled
    # view), Settings (Access is a section of it), and the retired Websites
    # page, which opens the Overview.
    for page <- ~w(agents devices tasks schedules settings access websites) do
      get("/orgs/:org/projects/:id/#{page}", SPAController, :index)
    end

    get("/orgs/:org/projects/:id/agents/:agent_id", SPAController, :index)

    get("/orgs/:org/plugins", SPAController, :index)
    get("/orgs/:org/meetings", SPAController, :index)
    get("/orgs/:org/meetings/past", SPAController, :index)
    get("/orgs/:org/meetings/settings", SPAController, :index)
    get("/orgs/:org/information-flow", SPAController, :index)
    # Health replaced the Operations console; old tab bookmarks land on it.
    get("/orgs/:org/operations", SPAController, :index)
    get("/orgs/:org/operations/:tab", SPAController, :index)
    get("/orgs/:org/members", SPAController, :index)
    # Slack triage: Overview, Timeline and Knowledge. The retired Context,
    # Memory and Raw data addresses open the Overview.
    get("/orgs/:org/triage", SPAController, :index)

    for page <- ~w(timeline knowledge context memory data) do
      get("/orgs/:org/triage/#{page}", SPAController, :index)
    end

    # The Runners page keeps the URL of the retired Fin page.
    get("/orgs/:org/fin", SPAController, :index)
    # Settings: General, AI models, Single sign-on and Integrations. The
    # retired OAuth, Signal and Feishu tab URLs open the Integrations page.
    get("/orgs/:org/settings", SPAController, :index)
    get("/orgs/:org/settings/models", SPAController, :index)
    get("/orgs/:org/settings/sso", SPAController, :index)
    get("/orgs/:org/settings/oauth", SPAController, :index)
    get("/orgs/:org/settings/signal", SPAController, :index)
    get("/orgs/:org/settings/feishu", SPAController, :index)
    # The onboarding integrations step sends admins to Composio before they
    # finish onboarding, so these two pages skip the first-run gate.
    get("/orgs/:org/settings/integrations", SPAController, :before_onboarding)
    get("/orgs/:org/settings/composio", SPAController, :before_onboarding)
    # The retired private-template and organization-account pages are
    # sections of AI models now.
    get("/orgs/:org/settings/models/templates", SPAController, :index)
    get("/orgs/:org/settings/subscriptions", SPAController, :index)
    # BFT CLI device-login approval: owners and admins only, and exempt from
    # the first-run gate so a deep link from the terminal is not lost.
    get("/cli/device-login", SPAController, :cli_device_login)
    get("/cli/device-login/:user_code", SPAController, :cli_device_login)

    get("/impersonate", ImpersonationController, :new)
    post("/impersonate", ImpersonationController, :create)

    # Reopen the first-run flow (user-menu action; available to everyone,
    # onboarded or not). Same scope as the wizard: authenticated, not gated.
    post("/onboarding/restart", OnboardingController, :restart)
    # The retired tasks step: stale tabs and bookmarks resume the wizard.
    get("/onboarding/tasks", OnboardingController, :resume)

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
      # slice "project-detail"
      live("/orgs/:org/projects/:id/integrations", ProjectLive.Show, :integrations)
      live("/orgs/:org/projects/:id/connections", ProjectLive.Show, :connections)
      live("/orgs/:org/projects/:id/plugins", ProjectLive.Show, :plugins)
      live("/orgs/:org/projects/:id/plugins/:plugin_id", ProjectLive.Show, :plugin)
      live("/orgs/:org/projects/:id/skills", ProjectLive.Show, :skills)

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
