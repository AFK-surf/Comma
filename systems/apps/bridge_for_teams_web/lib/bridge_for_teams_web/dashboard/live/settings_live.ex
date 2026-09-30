defmodule BridgeForTeamsWeb.Dashboard.SettingsLive do
  @moduledoc """
  Org settings page (`/orgs/:org/settings`). Edits the org name, configures the
  org's SSO connection (generic OIDC or Feishu; client_secret is write-only),
  and manages the org's OAuth provider apps
  (Notion/Linear/… client credentials, tenant-scoped in Salix; secrets are
  write-only). Optional danger zone archives the org.

  Owned by slice "members-settings". Org/SSO reads/writes through
  `BridgeForTeams.Orgs`; OAuth provider apps through
  `BridgeForTeams.OrgOAuthApps` (forwarded to the Salix runtime over erpc).

  The umbrella does not pull in `phoenix_ecto`, so `Ecto.Changeset` has no
  `Phoenix.HTML.FormData` impl — forms are driven from plain params maps with
  field errors surfaced via separate `@org_errors` / `@sso_errors` maps.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{
    FeishuAppBindings,
    FeishuScopes,
    Memberships,
    Models,
    Observability,
    OrgComposioSettings,
    OrgOAuthApps,
    OrgSignalNumber,
    Orgs,
    ProjectIMConnects,
    Projects,
    RunChecks
  }

  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.Onboarding
  alias BridgeForTeamsWeb.Dashboard.Onboarding, as: OnboardingHook

  @sso_roles ~w(admin member)
  @sso_providers [{"Generic OIDC", "generic_oidc"}, {"Feishu", "feishu"}]
  @feishu_provisioning_policies [
    {"Auto-create members on first login (JIT)", "jit"},
    {"Only allow already-linked users", "existing_identity"}
  ]
  # Brand-cased display names and developer-console URLs (where you create an
  # OAuth app) for the providers Salix supports. Unknown providers fall back to
  # a capitalized label with no console link.
  @oauth_provider_info %{
    "github" => {"GitHub", "https://github.com/settings/applications/new"},
    "google" => {"Google", "https://console.cloud.google.com/apis/credentials"},
    "linear" => {"Linear", "https://linear.app/settings/api/applications/new"},
    "notion" => {"Notion", "https://www.notion.so/my-integrations"},
    "slack" => {"Slack", "https://api.slack.com/apps"}
  }
  @oauth_app_name "Comma Bridge for Teams"
  @linear_oauth_app_create_url "https://linear.app/settings/api/applications/new"
  @slack_app_create_url "https://api.slack.com/apps"
  @github_app_create_url "https://github.com/settings/apps/new"

  # Settings is organized into tabs that mirror the Agent Swarm page: each tab is
  # its own `live` route into this view, resolved from `live_action`. The `:index`
  # route is the General tab.
  @tab_actions ~w(general models sso oauth composio signal feishu)a

  @impl true
  def mount(%{"org" => slug} = _params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id) do
      if can_manage_settings?(org_role) do
        mount_settings(socket, org, orgs, org_role)
      else
        # A member legitimately knows the org exists, so tell them the real
        # reason and keep them inside the org instead of bouncing to /orgs.
        {:ok,
         socket
         |> put_flash(:error, gettext("Only organization admins can manage settings."))
         |> redirect(to: ~p"/orgs/#{org.slug}")}
      end
    else
      # Unknown org or non-member: stay vague to avoid leaking org existence.
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  defp mount_settings(socket, org, orgs, org_role) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:active_nav, :settings)
     |> assign(:current_org, org)
     |> assign(:current_org_role, org_role)
     |> assign(:orgs, orgs)
     |> assign(:sso_roles, @sso_roles)
     |> assign(:sso_providers, @sso_providers)
     |> assign(:feishu_provisioning_policies, @feishu_provisioning_policies)
     |> assign(:dashboard_redirect_uri, dashboard_redirect_uri())
     |> assign(:cli_sessions, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    tab = resolve_tab(socket.assigns.live_action)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:breadcrumbs, breadcrumbs(socket.assigns.current_org, tab))
     |> load_tab(tab)}
  end

  defp resolve_tab(:index), do: :general
  defp resolve_tab(action) when action in @tab_actions, do: action
  defp resolve_tab(_action), do: :general

  # Load only the active tab's data — General/SSO read Postgres, while Models and
  # OAuth apps hit the Salix runtime, so they stay off the other tabs' critical
  # path (same lazy per-tab loading as the Agent Swarm page).
  defp load_tab(socket, :general) do
    org = socket.assigns.current_org

    socket
    |> assign_org_form(org_params(org), %{})
    |> assign_cli_sessions()
  end

  defp load_tab(socket, :models) do
    assign_models(socket, socket.assigns.current_org)
  end

  defp load_tab(socket, :sso) do
    org = socket.assigns.current_org
    sso = Orgs.get_sso_connection(org.id)

    socket
    |> assign(:sso, sso)
    |> assign(:sso_checks, nil)
    |> assign(:feishu_sso_binding, feishu_sso_binding(org.id))
    |> assign_sso_form(sso_params(sso), %{})
  end

  defp load_tab(socket, :oauth) do
    socket
    |> assign_oauth_apps(socket.assigns.current_org)
    |> assign(
      :oauth_reminders,
      Onboarding.pending_oauth_reminders(socket.assigns.current_org.id)
    )
  end

  defp load_tab(socket, :composio) do
    assign_composio_settings(socket, socket.assigns.current_org)
  end

  # The org's own Signal number (docs/messaging-voice.md) lives in Salix, so
  # only this tab reads it.
  defp load_tab(socket, :signal) do
    case OrgSignalNumber.get(socket.assigns.current_org.id) do
      {:ok, view} -> socket |> assign(:signal_number, view) |> assign(:signal_error, false)
      {:error, _reason} -> socket |> assign(:signal_number, %{}) |> assign(:signal_error, true)
    end
  end

  defp load_tab(socket, :feishu) do
    org = socket.assigns.current_org

    socket
    |> assign_feishu_bindings(org)
    |> assign(:feishu_binding_form, feishu_binding_form(%{}))
  end

  defp breadcrumbs(org, :general),
    do: [{org.name, ~p"/orgs/#{org.slug}"}, {gettext("Settings"), nil}]

  defp breadcrumbs(org, tab) do
    [
      {org.name, ~p"/orgs/#{org.slug}"},
      {gettext("Settings"), ~p"/orgs/#{org.slug}/settings"},
      {tab_label(tab), nil}
    ]
  end

  defp tab_label(:models), do: gettext("Models")
  defp tab_label(:sso), do: gettext("Single sign-on")
  defp tab_label(:oauth), do: gettext("OAuth apps")
  defp tab_label(:composio), do: gettext("Composio")
  defp tab_label(:signal), do: gettext("Signal")
  defp tab_label(:feishu), do: gettext("Feishu apps")

  @impl true
  def handle_event("save-org", %{"organization" => params}, socket) do
    if can_manage_settings?(socket.assigns.current_org_role) do
      case Orgs.update_org(socket.assigns.current_org, params, audit_opts(socket)) do
        {:ok, org} ->
          slug_changed? = org.slug != socket.assigns.current_org.slug

          socket =
            socket
            |> put_flash(:info, gettext("Organization updated."))
            |> assign(:current_org, org)
            |> assign(:orgs, Orgs.list_orgs_for_user(socket.assigns.current_user.id))
            |> assign_org_form(org_params(org), %{})

          # Only re-route when the slug changed, so existing links stay valid.
          socket =
            if slug_changed?,
              do: push_navigate(socket, to: ~p"/orgs/#{org.slug}/settings"),
              else: socket

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Couldn't update organization."))
           |> assign_org_form(params, errors_for(changeset))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("save-models", %{"models" => params}, socket) do
    if can_manage_settings?(socket.assigns.current_org_role) do
      allowed = parse_allowed(params["allowed"])
      worker_default = blank_to_nil(params["default_template_id"])
      router_default = blank_to_nil(params["default_router_template_id"])

      disallowed =
        [
          {"default_template_id", worker_default},
          {"default_router_template_id", router_default}
        ]
        |> Enum.filter(fn {_field, default} ->
          default && allowed != [] && default not in allowed
        end)
        |> Enum.map(&elem(&1, 0))

      cond do
        disallowed != [] ->
          record_model_validation_event(socket, "fail", "default_template_not_allowed", %{
            "allowed_template_count" => length(allowed),
            "default_template_configured" => true,
            "field_errors" => Map.new(disallowed, &{&1, ["must be one of the allowed models"]})
          })

          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("The default model must be one of the allowed models.")
           )}

        true ->
          attrs = %{
            "allowed_template_ids" => allowed,
            "default_template_id" => worker_default,
            "default_router_template_id" => router_default
          }

          case Orgs.update_org(socket.assigns.current_org, attrs, audit_opts(socket)) do
            {:ok, org} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Model settings saved."))
               |> assign(:current_org, org)
               |> assign_models(org)}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Couldn't save the model settings."))}
          end
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("save-sso", %{"sso" => params}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case Orgs.upsert_sso_connection(
             org.id,
             attach_feishu_app(params, socket.assigns),
             audit_opts(socket)
           ) do
        {:ok, sso} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("SSO connection saved."))
           |> assign(:sso, sso)
           |> assign_sso_form(sso_params(sso), %{})}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Couldn't save the SSO connection."))
           |> assign_sso_form(params, errors_for(changeset))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("change-sso", %{"sso" => params}, socket) do
    {:noreply, assign_sso_form(socket, params, %{})}
  end

  def handle_event("run-sso-checks", _params, socket) do
    case RunChecks.run_sso(socket.assigns.current_org.id,
           redirect_uri: dashboard_redirect_uri()
         ) do
      {:ok, checks} ->
        {:noreply,
         socket
         |> persist_run_checks_activity(checks)
         |> assign(:sso_checks, checks)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not run SSO checks."))}
    end
  end

  def handle_event("save-feishu-binding", %{"feishu_binding" => attrs}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case FeishuAppBindings.upsert_binding(org.id, attrs, audit_opts(socket)) do
        {:ok, _binding} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Feishu app saved."))
           |> assign_feishu_bindings(org)
           |> assign(:feishu_binding_form, feishu_binding_form(%{}))}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             feishu_binding_error_message(reason)
           )
           |> assign(:feishu_binding_form, feishu_binding_form(attrs))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("connect-feishu-route", %{"feishu_route" => params}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      app_id = trim(params["app_id"])
      project_id = trim(params["project_id"])

      binding =
        Enum.find(socket.assigns.feishu_bindings, &(&1.app_id == app_id and &1.bot_enabled))

      project = Enum.find(socket.assigns.feishu_route_projects, &(&1.id == project_id))

      cond do
        is_nil(binding) ->
          {:noreply, put_flash(socket, :error, gettext("Choose a bot-enabled Feishu app first."))}

        is_nil(project) ->
          {:noreply,
           put_flash(socket, :error, gettext("Choose an Agent Swarm before connecting the bot."))}

        true ->
          case ProjectIMConnects.create_project_connect(
                 org.id,
                 project.id,
                 "feishu",
                 %{
                   "app_id" => app_id
                 },
                 audit_opts(socket)
               ) do
            {:ok, _connect} ->
              {:noreply,
               socket
               |> put_flash(
                 :info,
                 gettext("Feishu bot connected to %{project}.", project: project.name)
               )
               |> assign_feishu_bindings(org)}

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 gettext("Couldn't connect the Feishu bot route (%{reason}).",
                   reason: describe_error(reason)
                 )
               )}
          end
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event(
        "disable-feishu-route",
        %{"project-id" => project_id, "connect-id" => connect_id},
        socket
      ) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      route =
        socket.assigns.feishu_binding_routes
        |> Map.values()
        |> List.flatten()
        |> Enum.find(fn route ->
          route.project_id == project_id and route.connect_id == connect_id and not route.disabled
        end)

      case route do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Feishu bot route not found."))}

        _route ->
          case ProjectIMConnects.disable_project_connect(
                 org.id,
                 project_id,
                 connect_id,
                 audit_opts(socket)
               ) do
            {:ok, _connect} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Connect disabled."))
               |> assign_feishu_bindings(org)}

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 gettext("Couldn't disable the Feishu bot route (%{reason}).",
                   reason: describe_error(reason)
                 )
               )}
          end
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("edit-feishu-binding", %{"id" => id}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case FeishuAppBindings.get_binding(org.id, id) do
        {:ok, binding} ->
          {:noreply, assign(socket, :feishu_binding_form, feishu_binding_form(binding))}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Feishu app not found."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("cancel-feishu-binding-edit", _params, socket) do
    {:noreply, assign(socket, :feishu_binding_form, feishu_binding_form(%{}))}
  end

  def handle_event("delete-feishu-binding", %{"id" => id}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case FeishuAppBindings.delete_binding(org.id, id, audit_opts(socket)) do
        {:ok, _binding} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Feishu app removed."))
           |> assign_feishu_bindings(org)
           |> assign(:feishu_binding_form, feishu_binding_form(%{}))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't remove the Feishu app (%{reason}).",
               reason: describe_error(reason)
             )
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("save-oauth", %{"oauth" => %{"provider" => provider} = params}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case OrgOAuthApps.upsert_org_oauth_app(org.id, provider, params, audit_opts(socket)) do
        {:ok, _app} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("%{provider} OAuth app saved.", provider: provider_label(provider))
           )
           |> assign_oauth_apps(org)
           |> OnboardingHook.rebuild(refresh_oauth: true)}

        {:error, {:bad_request, message}} ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't save the OAuth app (%{reason}).", reason: describe_error(reason))
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("delete-oauth", %{"provider" => provider}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case OrgOAuthApps.delete_org_oauth_app(org.id, provider, audit_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("%{provider} OAuth app removed.", provider: provider_label(provider))
           )
           |> assign_oauth_apps(org)
           |> OnboardingHook.rebuild(refresh_oauth: true)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't remove the OAuth app (%{reason}).", reason: describe_error(reason))
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("save-signal", %{"signal" => %{"number" => number}}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case OrgSignalNumber.put(org.id, number, audit_opts(socket)) do
        {:ok, view} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Signal number saved."))
           |> assign(:signal_number, view)
           |> assign(:signal_error, false)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, signal_error_text(reason))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("save-composio", %{"composio" => params}, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case OrgComposioSettings.upsert_org_composio_settings(org.id, params, audit_opts(socket)) do
        {:ok, _view} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Composio settings saved."))
           |> assign_composio_settings(org)}

        {:error, {:bad_request, message}} ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't save the Composio settings (%{reason}).",
               reason: describe_error(reason)
             )
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("delete-composio", _params, socket) do
    org = socket.assigns.current_org

    if can_manage_settings?(socket.assigns.current_org_role) do
      case OrgComposioSettings.delete_org_composio_settings(org.id, audit_opts(socket)) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Composio settings removed."))
           |> assign_composio_settings(org)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't remove the Composio settings (%{reason}).",
               reason: describe_error(reason)
             )
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  def handle_event("revoke-cli-session", %{"session-id" => session_id}, socket) do
    if can_manage_settings?(socket.assigns.current_org_role) do
      :ok = CLILogin.revoke_cli_session_for_user(socket.assigns.current_user, session_id)

      {:noreply,
       socket
       |> assign_cli_sessions()
       |> put_flash(:info, gettext("BFT CLI session revoked."))}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage settings."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">{gettext("Settings")}</h1>
          <p class="text-sm text-neutral-500">{gettext("Manage %{name}.", name: @current_org.name)}</p>
        </div>
        <.button
          href={~p"/orgs/#{@current_org.slug}/operations/audit"}
          variant="ghost"
          size="sm"
        >
          {gettext("View audit")}
        </.button>
      </div>

      <.tabs>
        <:tab
          label={gettext("General")}
          patch={~p"/orgs/#{@current_org.slug}/settings"}
          active={@tab == :general}
        />
        <:tab
          label={gettext("Models")}
          patch={~p"/orgs/#{@current_org.slug}/settings/models"}
          active={@tab == :models}
        />
        <:tab
          label={gettext("Single sign-on")}
          patch={~p"/orgs/#{@current_org.slug}/settings/sso"}
          active={@tab == :sso}
        />
        <:tab
          label={gettext("OAuth apps")}
          patch={~p"/orgs/#{@current_org.slug}/settings/oauth"}
          active={@tab == :oauth}
        />
        <:tab
          label={gettext("Composio")}
          patch={~p"/orgs/#{@current_org.slug}/settings/composio"}
          active={@tab == :composio}
        />
        <:tab
          label={gettext("Signal")}
          patch={~p"/orgs/#{@current_org.slug}/settings/signal"}
          active={@tab == :signal}
        />
        <:tab
          label={gettext("Feishu apps")}
          patch={~p"/orgs/#{@current_org.slug}/settings/feishu"}
          active={@tab == :feishu}
        />
      </.tabs>

      <div :if={@tab == :general} class="max-w-2xl space-y-6">
      <.card>
        <:title>{gettext("General")}</:title>
        <.form for={@org_form} phx-submit="save-org" id="org-form">
          <div class="space-y-4">
            <.input
              name="organization[name]"
              value={@org_form.params["name"]}
              errors={@org_errors[:name] || []}
              label={gettext("Organization name")}
              required
            />
            <.input
              name="organization[slug]"
              value={@org_form.params["slug"]}
              errors={@org_errors[:slug] || []}
              label={gettext("Slug")}
              hint={gettext("Used in URLs. Changing it changes your links.")}
            />
            <.org_icon_upload
              id="org-settings-icon"
              name="organization[icon]"
              value={@org_form.params["icon"]}
              initial={org_initial(@current_org)}
              errors={@org_errors[:icon] || []}
            />
            <.select
              name="organization[default_locale]"
              value={@org_form.params["default_locale"]}
              errors={@org_errors[:default_locale] || []}
              label={gettext("Default language")}
              prompt={gettext("Detect from browser")}
              options={BridgeForTeamsWeb.I18n.options()}
            />
          </div>
          <div class="mt-5 flex justify-end">
            <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>{gettext("Save changes")}</.button>
          </div>
        </.form>
      </.card>

      <.card>
        <:title>{gettext("BFT CLI access")}</:title>

        <div
          id="bft-cli-login-onboarding"
          class="rounded-md border border-neutral-200 bg-neutral-50 p-3"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p class="text-sm leading-5 text-neutral-700">
                {gettext("Sign the local bft CLI into this BFT API from the terminal, then approve the request in the dashboard.")}
              </p>
              <p class="mt-1 text-xs leading-5 text-neutral-500">
                {gettext("The bearer session is stored locally by the CLI and can be revoked here.")}
              </p>
            </div>
            <.badge color="green">{gettext("API wrapper")}</.badge>
          </div>

          <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
            <div class="rounded-md border border-neutral-200 bg-white px-3 py-2">
              <dt class="text-neutral-500">{gettext("API base")}</dt>
              <dd class="mt-1 truncate font-mono text-neutral-900">{dashboard_base_url() |> String.trim_trailing("/")}</dd>
            </div>
            <div class="rounded-md border border-neutral-200 bg-white px-3 py-2">
              <dt class="text-neutral-500">{gettext("Config")}</dt>
              <dd class="mt-1 truncate font-mono text-neutral-900">~/.bridge-for-teams/cli.json</dd>
            </div>
          </dl>

          <div class="mt-3">
            <div class="mb-2 flex items-center justify-between gap-2">
              <h3 class="text-sm font-medium text-neutral-900">{gettext("Install bft CLI")}</h3>
              <button
                type="button"
                id="copy-bft-cli-install-command"
                phx-hook="CopyToClipboard"
                data-copy-target="#bft-cli-install-command"
                class="shrink-0 rounded-md border border-neutral-300 bg-white px-2 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100"
              >
                {gettext("Copy")}
              </button>
            </div>
            <pre
              id="bft-cli-install-command"
              class="overflow-x-auto rounded-md border border-neutral-800 bg-neutral-950 px-3 py-2 text-xs leading-5 text-neutral-100"
            ><code>{bft_cli_install_command()}</code></pre>
          </div>

          <div
            id="bft-cli-device-login-command-wrap"
            class="mt-3"
          >
            <div class="mb-2 flex items-center justify-between gap-2">
              <h3 class="text-sm font-medium text-neutral-900">{gettext("Login command")}</h3>
              <button
                type="button"
                id="copy-bft-cli-login-command"
                phx-hook="CopyToClipboard"
                data-copy-target="#bft-cli-device-login-command"
                class="shrink-0 rounded-md border border-neutral-300 bg-white px-2 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100"
              >
                {gettext("Copy")}
              </button>
            </div>
            <pre
              id="bft-cli-device-login-command"
              class="overflow-x-auto rounded-md border border-neutral-800 bg-neutral-950 px-3 py-2 text-xs leading-5 text-neutral-100"
            ><code>{cli_device_login_command()}</code></pre>
          </div>

          <div id="bft-cli-sessions" class="mt-4">
            <div class="mb-2 flex items-center justify-between gap-2">
              <h3 class="text-sm font-medium text-neutral-900">{gettext("Authorized CLI sessions")}</h3>
              <.badge color={if @cli_sessions == [], do: "neutral", else: "green"}>{length(@cli_sessions)}</.badge>
            </div>

            <div :if={@cli_sessions == []} class="rounded-md border border-dashed border-neutral-300 bg-white px-3 py-4 text-xs text-neutral-500">
              {gettext("No authorized CLI sessions yet. Run the login command and approve it here.")}
            </div>

            <div :if={@cli_sessions != []} class="overflow-hidden rounded-md border border-neutral-200 bg-white">
              <div :for={session <- @cli_sessions} id={"bft-cli-session-#{session.id}"} class="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-100 px-3 py-2 last:border-b-0">
                <div class="min-w-0">
                  <div class="truncate text-sm font-medium text-neutral-900">{session.client_name || gettext("bft CLI")}</div>
                  <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-neutral-500">
                    <span class="font-mono">{session.id}</span>
                    <span>{gettext("Created %{time}", time: format_datetime(session.created_at))}</span>
                    <span>{gettext("Last seen %{time}", time: format_datetime(session.last_seen_at))}</span>
                    <span>{gettext("Expires %{time}", time: format_datetime(session.expires_at))}</span>
                    <span>{gettext("Device %{device}", device: session.device || "—")}</span>
                  </div>
                </div>
                <.button
                  type="button"
                  variant="secondary"
                  size="sm"
                  phx-click="revoke-cli-session"
                  phx-value-session-id={session.id}
                >
                  {gettext("Revoke")}
                </.button>
              </div>
            </div>
          </div>
        </div>
      </.card>

      </div>

      <div :if={@tab == :models} class="max-w-2xl">
      <.card>
        <:title>{gettext("Models")}</:title>
        <:actions>
          <.button
            href={~p"/orgs/#{@current_org.slug}/operations/integrations?#{%{surface: "models"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View in Operations")}
          </.button>
          <.button
            href={~p"/orgs/#{@current_org.slug}/operations/checks?#{%{surface: "models"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View checks")}
          </.button>
          <.badge :if={@model_catalog_error} color="amber">{gettext("Runtime unavailable")}</.badge>
        </:actions>
        <div class="mb-4 flex flex-wrap gap-2">
          <.button navigate={~p"/orgs/#{@current_org.slug}/settings/models/templates"}>Manage private templates</.button>
          <.button navigate={~p"/orgs/#{@current_org.slug}/settings/subscriptions"}>Organization accounts</.button>
        </div>
        <p class="mb-4 text-xs text-neutral-500">
          {gettext("Choose which models your Agent Swarm admins can assign to agents, and a default for new agents. Models come from the Salix template catalog.")}
        </p>

        <div
          :if={@model_catalog_error}
          class="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-700"
        >
          {gettext("Couldn't reach the runtime to load the model catalog. Try again shortly.")}
        </div>

        <p :if={not @model_catalog_error and @model_catalog == []} class="text-sm text-neutral-500">
          {gettext("No models are defined in the Salix template catalog yet.")}
        </p>

        <.form
          :if={not @model_catalog_error and @model_catalog != []}
          for={to_form(%{}, as: :models)}
          phx-submit="save-models"
          id="models-form"
        >
          <div class="space-y-4">
            <fieldset id="models-allowed" aria-describedby="models-allowed-help" class="space-y-2">
              <legend class="text-sm font-medium text-neutral-900">
                {gettext("Allowed models")}
              </legend>
              <input type="hidden" name="models[allowed][]" value="" />
              <div class="grid gap-2">
                <label
                  :for={template <- @model_catalog}
                  for={model_checkbox_id(template)}
                  class="group flex cursor-pointer items-start gap-3 rounded-lg border border-neutral-200 bg-white px-3 py-2.5 transition-colors hover:border-brand-300 hover:bg-brand-50/40 has-[:checked]:border-brand-500 has-[:checked]:bg-brand-50"
                >
                  <input
                    id={model_checkbox_id(template)}
                    type="checkbox"
                    name="models[allowed][]"
                    value={template["template_id"]}
                    checked={template["template_id"] in @allowed_template_ids}
                    class="mt-0.5 h-4 w-4 rounded border-neutral-300 text-brand-600 focus:ring-brand-500"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-medium text-neutral-900">
                      {Models.option_label(template)}
                    </span>
                    <span class="mt-0.5 block truncate font-mono text-[11px] text-neutral-500">
                      {template["template_id"]}
                    </span>
                  </span>
                </label>
              </div>
            </fieldset>
            <p id="models-allowed-help" class="text-xs text-neutral-500">
              {gettext("Leave every box unchecked to allow every model in the catalog.")}
            </p>
            <.select
              name="models[default_router_template_id]"
              value={@default_router_template_id || ""}
              label={gettext("New Router default model")}
              prompt={follow_platform_prompt(@platform_defaults["router"])}
              options={Models.options(@model_catalog, @default_router_template_id)}
              model_catalog={@model_catalog}
              model_default_icon={@platform_defaults["router"]["model_icon"]}
            />
            <.select
              name="models[default_template_id]"
              value={@default_template_id || ""}
              label={gettext("New Worker default model")}
              prompt={follow_platform_prompt(@platform_defaults["worker"])}
              options={Models.options(@model_catalog, @default_template_id)}
              model_catalog={@model_catalog}
              model_default_icon={@platform_defaults["worker"]["model_icon"]}
            />
            <p class="text-xs text-neutral-500">
              {gettext("These choices only apply when creating new agents. Default follows the platform model. Existing agents keep their own choices.")}
            </p>
          </div>
          <div class="mt-5 flex justify-end">
            <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>
              {gettext("Save models")}
            </.button>
          </div>
        </.form>
      </.card>
      </div>

      <div :if={@tab == :sso} class="max-w-2xl">
      <.card>
        <:title>{gettext("Single sign-on")}</:title>
        <:actions>
          <.button
            href={~p"/orgs/#{@current_org.slug}/operations/integrations?#{%{surface: "sso"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View in Operations")}
          </.button>
          <.button
            href={~p"/orgs/#{@current_org.slug}/operations/checks?#{%{surface: "sso"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View checks")}
          </.button>
          <.status_pill :if={@sso} status="pending" label={gettext("Saved · not verified")} />
          <.badge :if={is_nil(@sso)} color="neutral">{gettext("Not configured")}</.badge>
        </:actions>
        <p class="mb-4 text-xs text-neutral-500">
          {gettext("Connect the identity provider for dashboard sign-in. Project access still comes from BridgeForTeams memberships.")}
        </p>
        <.form for={@sso_form} phx-change="change-sso" phx-submit="save-sso" id="sso-form">
          <div class="space-y-5">
            <div>
              <.select
                name="sso[provider]"
                value={sso_provider(@sso_form)}
                label={gettext("Provider")}
                options={@sso_providers}
              />
              <p class="mt-1 text-xs text-neutral-500">
                {gettext("One SSO connection per organization. Switching provider replaces the current one.")}
              </p>
            </div>

            <%!-- Generic OIDC: unchanged field set --%>
            <div :if={sso_provider(@sso_form) == "generic_oidc"} class="space-y-4">
              <.input
                name="sso[issuer]"
                value={@sso_form.params["issuer"]}
                errors={@sso_errors[:issuer] || []}
                label={gettext("Issuer URL")}
                placeholder="https://idp.example.com"
                required
              />
              <.input
                name="sso[client_id]"
                value={@sso_form.params["client_id"]}
                errors={@sso_errors[:client_id] || []}
                label={gettext("Client ID")}
                required
              />
              <.input
                name="sso[client_secret]"
                value={@sso_form.params["client_secret"] || ""}
                errors={@sso_errors[:client_secret] || []}
                type="password"
                label={gettext("Client secret")}
                hint={
                  if @sso,
                    do: gettext("Leave blank to keep the current secret."),
                    else: gettext("Write-only; never displayed back.")
                }
                autocomplete="off"
              />
              <.input
                name="sso[allowed_domains]"
                value={@sso_form.params["allowed_domains"]}
                label={gettext("Allowed email domains")}
                placeholder="example.com, sub.example.com"
                hint={gettext("Comma-separated. Leave blank to allow any domain.")}
              />
              <.select
                name="sso[default_role]"
                value={@sso_form.params["default_role"]}
                label={gettext("Default role")}
                options={Enum.map(@sso_roles, &{String.capitalize(&1), &1})}
              />
            </div>

            <%!-- Feishu: credentials live in the Feishu apps tab; SSO reuses the binding --%>
            <div :if={sso_provider(@sso_form) == "feishu"} class="space-y-4">
              <div
                :if={is_nil(@feishu_sso_binding)}
                class="rounded-md border border-amber-200 bg-amber-50/70 p-4"
              >
                <p class="text-sm font-medium text-neutral-800">
                  {gettext("No Feishu app is enabled for sign-in yet.")}
                </p>
                <p class="mt-1 text-xs text-neutral-600">
                  {gettext("Register the org's Feishu app once in Feishu apps and tick \"Use for dashboard login (SSO)\". This card then reuses its App ID and secret — no need to enter them twice.")}
                </p>
                <.link
                  navigate={~p"/orgs/#{@current_org.slug}/settings/feishu"}
                  class="mt-2 inline-block text-xs font-semibold text-brand-600 hover:underline"
                >
                  {gettext("Go to Feishu apps →")}
                </.link>
              </div>

              <div :if={@feishu_sso_binding} class="space-y-4">
                <section class="space-y-3 rounded-md border border-neutral-200 bg-neutral-50/60 p-4">
                  <h4 class="text-xs font-semibold tracking-wide text-neutral-700">
                    {gettext("1 · In the Feishu developer console")}
                  </h4>
                  <div class="flex items-end gap-2">
                    <div class="grow">
                      <.input
                        name="sso[redirect_uri]"
                        value={@dashboard_redirect_uri}
                        label={gettext("Redirect URI")}
                        readonly
                      />
                    </div>
                    <button
                      type="button"
                      class="mb-px shrink-0 rounded-md border border-neutral-300 bg-white px-3 py-2 text-xs font-medium text-neutral-700 hover:bg-neutral-50"
                      onclick={"navigator.clipboard.writeText('#{@dashboard_redirect_uri}')"}
                    >
                      {gettext("Copy")}
                    </button>
                  </div>
                  <p class="text-xs text-neutral-500">
                    {gettext("Paste this into the Feishu app's security / redirect URL settings. Required login permission: contact:user.base:readonly.")}
                  </p>
                </section>

                <section class="space-y-3 rounded-md border border-neutral-200 p-4">
                  <h4 class="text-xs font-semibold tracking-wide text-neutral-700">
                    {gettext("2 · Feishu app")}
                  </h4>
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <div class="text-sm font-medium text-neutral-800">
                        {@feishu_sso_binding.display_name || @feishu_sso_binding.app_id}
                      </div>
                      <div class="font-mono text-xs text-neutral-500">{@feishu_sso_binding.app_id}</div>
                    </div>
                    <.badge color={if @feishu_sso_binding.app_secret_configured, do: "green", else: "red"}>
                      {if @feishu_sso_binding.app_secret_configured,
                        do: gettext("secret configured"),
                        else: gettext("secret missing")}
                    </.badge>
                  </div>
                  <p class="text-xs text-neutral-500">
                    {gettext("App ID and secret are managed in Feishu apps; SSO reuses them — no need to re-enter here.")}
                  </p>
                  <.link
                    navigate={~p"/orgs/#{@current_org.slug}/settings/feishu"}
                    class="inline-block text-xs font-medium text-brand-600 hover:underline"
                  >
                    {gettext("Manage in Feishu apps →")}
                  </.link>
                  <.input
                    name="sso[provider_config][scope]"
                    value={sso_provider_config(@sso_form, "scope", "contact:user.base:readonly")}
                    label={gettext("Feishu scopes")}
                    hint={gettext("Permissions requested at login. The default contact:user.base:readonly is enough to sign in.")}
                  />
                </section>

                <section class="space-y-4 rounded-md border border-neutral-200 p-4">
                  <h4 class="text-xs font-semibold tracking-wide text-neutral-700">
                    {gettext("3 · How accounts are created on first login")}
                  </h4>
                  <div>
                    <.select
                      name="sso[provider_config][provisioning_policy]"
                      value={sso_provider_config(@sso_form, "provisioning_policy", "jit")}
                      label={gettext("First-login provisioning")}
                      options={@feishu_provisioning_policies}
                    />
                    <p class="mt-1 text-xs text-neutral-500">
                      {gettext("JIT: anyone in your Feishu tenant becomes a member on first login. Linked-only: reject users not already linked.")}
                    </p>
                  </div>
                  <div :if={sso_provider_config(@sso_form, "provisioning_policy", "jit") == "jit"}>
                    <.select
                      name="sso[default_role]"
                      value={@sso_form.params["default_role"]}
                      label={gettext("First-login organization role")}
                      options={Enum.map(@sso_roles, &{String.capitalize(&1), &1})}
                    />
                    <p class="mt-1 text-xs text-neutral-500">
                      {gettext("Role given to a Feishu user created on first login (JIT only).")}
                    </p>
                  </div>
                </section>
              </div>
            </div>
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <button
              :if={sso_provider(@sso_form) == "feishu" and @feishu_sso_binding}
              type="button"
              phx-click="run-sso-checks"
              class="mr-auto rounded-md border border-neutral-300 bg-white px-3 py-2 text-xs font-medium text-neutral-700 hover:bg-neutral-50"
            >
              {gettext("Run checks")}
            </button>
            <.button
              :if={sso_provider(@sso_form) != "feishu" or @feishu_sso_binding}
              variant="primary"
              type="submit"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save SSO connection")}
            </.button>
          </div>
        </.form>
        <.run_checks_panel :if={@sso_checks} checks={@sso_checks} />
      </.card>
      </div>

      <div :if={@tab == :feishu} class="max-w-4xl space-y-6">
        <.card>
          <:title>{gettext("Feishu apps")}</:title>
          <:actions>
            <.button
              href={~p"/orgs/#{@current_org.slug}/operations/integrations?#{%{surface: "bot"}}"}
              variant="ghost"
              size="sm"
            >
              {gettext("View in Operations")}
            </.button>
            <.button
              href={~p"/orgs/#{@current_org.slug}/operations/checks?#{%{surface: "bot"}}"}
              variant="ghost"
              size="sm"
            >
              {gettext("View checks")}
            </.button>
          </:actions>
          <p class="mb-4 text-xs text-neutral-500">
            {gettext(
              "Register the org's Feishu custom app once, then enable it for dashboard login (SSO) and/or the group bot. The SSO card and Agent Swarm integration both reuse this binding instead of re-asking for credentials."
            )}
          </p>
          <p class="mb-4 rounded-md border border-amber-200 bg-amber-50/70 px-3 py-2 text-xs text-amber-900">
            {gettext(
              "Current limitation: one org can have one bot-enabled Feishu app, and that app can be connected to one Agent Swarm until multi-route support lands."
            )}
          </p>

          <section class="mb-5 rounded-md border border-neutral-200 bg-neutral-50/70 p-4">
            <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
              <div>
                <h4 class="text-sm font-semibold text-neutral-800">
                  {gettext("Feishu permission scopes")}
                </h4>
                <p class="mt-1 text-xs text-neutral-500">
                  {gettext(
                    "In Feishu: Permissions & Scopes → Batch import/export scopes → Import JSON. Pick the flow that matches this app, import the JSON, then publish/install the app version."
                  )}
                </p>
              </div>
              <.badge color="amber">{gettext("manual Feishu step")}</.badge>
            </div>

            <div class="mt-4 grid grid-cols-1 gap-3">
              <div
                :for={card <- @feishu_scope_cards}
                id={"feishu-scope-card-#{card.id}"}
                class="rounded-md border border-neutral-200 bg-white p-3"
              >
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-xs font-semibold text-neutral-700">{card.title}</p>
                    <p class="mt-1 text-xs text-neutral-500">{card.description}</p>
                  </div>
                  <button
                    type="button"
                    id={"copy-feishu-scopes-#{card.id}"}
                    phx-hook="CopyToClipboard"
                    data-copy-target={"#feishu-scopes-json-#{card.id}"}
                    class="shrink-0 rounded-md border border-neutral-300 bg-white px-2 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100"
                  >
                    {gettext("Copy JSON")}
                  </button>
                </div>
                <pre
                  id={"feishu-scopes-json-#{card.id}"}
                  class="mt-2 max-h-56 overflow-auto rounded-md border border-neutral-200 bg-neutral-950 px-3 py-2 font-mono text-xs leading-relaxed text-neutral-50"
                >{card.json}</pre>
                <div class="mt-2 flex flex-wrap gap-1">
                  <.badge :for={scope <- card.required_scopes} color="green">{scope}</.badge>
                </div>
              </div>
            </div>

            <div class="mt-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2">
              <p class="text-xs font-semibold text-amber-950">
                {gettext("Optional scopes")}
              </p>
              <ul class="mt-2 space-y-2 text-xs text-amber-950">
                <li :for={scope <- @feishu_optional_scopes}>
                  <span class="font-mono font-semibold">{scope.scope}</span>
                  <span class="font-medium"> · {scope.label}</span>
                  <span class="text-amber-900"> — {scope.note}</span>
                </li>
              </ul>
            </div>
          </section>

          <.table :if={@feishu_bindings != []} id="feishu-bindings" rows={@feishu_bindings}>
            <:col :let={b} label={gettext("App")}>
              <div class="text-sm font-medium text-neutral-800">{b.display_name || b.app_id}</div>
              <div class="font-mono text-xs text-neutral-500">{b.app_id}</div>
            </:col>
            <:col :let={b} label={gettext("Capabilities")}>
              <div class="flex flex-wrap gap-1">
                <.badge :if={b.sso_enabled} color="brand">{gettext("SSO")}</.badge>
                <.badge :if={b.bot_enabled} color="brand">{gettext("Bot")}</.badge>
                <.badge :if={!b.sso_enabled and !b.bot_enabled} color="neutral">{gettext("none")}</.badge>
              </div>
            </:col>
            <:col :let={b} label={gettext("Bot route")}>
              <div :if={!b.bot_enabled} class="text-xs text-neutral-500">
                {gettext("Bot disabled")}
              </div>
              <div :if={b.bot_enabled} class="space-y-1 text-xs">
                <div
                  :if={
                    routes_for_binding(@feishu_binding_routes, b) == [] and
                      @feishu_binding_routes_error
                  }
                  class="text-amber-800"
                >
                  <p>{gettext("Agent Swarm route state could not be verified.")}</p>
                  <p class="mt-1 text-neutral-600">
                    {gettext("Retry shortly before connecting this Feishu app; an existing route may be hidden while Salix is unavailable.")}
                  </p>
                </div>
                <div
                  :if={
                    routes_for_binding(@feishu_binding_routes, b) == [] and
                      is_nil(@feishu_binding_routes_error)
                  }
                  class="text-amber-800"
                >
                  <p>{gettext("Not connected to an Agent Swarm yet.")}</p>
                  <.form
                    :if={@feishu_route_projects != []}
                    for={to_form(%{}, as: :feishu_route)}
                    id={"feishu-route-form-#{b.id}"}
                    phx-submit="connect-feishu-route"
                    class="mt-2 flex flex-wrap items-center gap-2"
                  >
                    <input type="hidden" name="feishu_route[app_id]" value={b.app_id} />
                    <select
                      name="feishu_route[project_id]"
                      class="h-8 rounded-md border border-neutral-300 bg-white px-2 text-xs text-neutral-800"
                    >
                      <option
                        :for={project <- @feishu_route_projects}
                        value={project.id}
                      >
                        {project.name}
                      </option>
                    </select>
                    <button
                      type="submit"
                      class="rounded-md bg-brand-600 px-2.5 py-1.5 text-xs font-semibold text-white hover:bg-brand-700"
                      phx-disable-with={gettext("Connecting…")}
                    >
                      {gettext("Connect")}
                    </button>
                  </.form>
                  <div :if={@feishu_route_projects == []} class="mt-1">
                    {gettext("Create an Agent Swarm first, then connect this bot app.")}
                    <.link
                      navigate={~p"/orgs/#{@current_org.slug}/projects"}
                      class="ml-1 font-semibold text-brand-600 hover:underline"
                    >
                      {gettext("Open Agent Swarms →")}
                    </.link>
                  </div>
                </div>
                <div
                  :for={route <- routes_for_binding(@feishu_binding_routes, b)}
                  class="flex flex-wrap items-center gap-2"
                >
                  <.link
                    navigate={~p"/orgs/#{@current_org.slug}/projects/#{route.project_id}/integrations"}
                    class="font-medium text-brand-600 hover:underline"
                  >
                    {route.project_name}
                  </.link>
                  <.badge color={if route.disabled, do: "red", else: "green"}>
                    {if route.disabled, do: gettext("disabled"), else: gettext("connected")}
                  </.badge>
                  <span class="font-mono text-neutral-500">{route.salix_group_id}</span>
                </div>
                <p
                  :if={routes_for_binding(@feishu_binding_routes, b) != [] and @feishu_binding_routes_error}
                  class="text-amber-700"
                >
                  {gettext("Some Agent Swarm routes could not be checked; retry before changing this app.")}
                </p>
              </div>
            </:col>
            <:col :let={b} label={gettext("Secret")}>
              <.badge color={if b.app_secret_configured, do: "green", else: "red"}>
                {if b.app_secret_configured, do: gettext("configured"), else: gettext("missing")}
              </.badge>
            </:col>
            <:action :let={b}>
              <button
                :for={route <- routes_for_binding(@feishu_binding_routes, b)}
                :if={!route.disabled}
                type="button"
                phx-click="disable-feishu-route"
                phx-value-project-id={route.project_id}
                phx-value-connect-id={route.connect_id}
                phx-disable-with={gettext("Disabling…")}
                class="text-xs font-medium text-neutral-600 hover:text-neutral-900"
              >
                {gettext("Disable")}
              </button>
              <button
                type="button"
                phx-click="edit-feishu-binding"
                phx-value-id={b.id}
                class="text-xs font-medium text-brand-600 hover:text-brand-700"
              >
                {gettext("Edit")}
              </button>
              <button
                type="button"
                phx-click="delete-feishu-binding"
                phx-value-id={b.id}
                data-confirm={gettext("Remove this Feishu app binding? SSO and bot secrets for this app will be disconnected.")}
                class="text-xs font-medium text-red-600 hover:text-red-700"
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>

          <.form
            for={@feishu_binding_form}
            phx-submit="save-feishu-binding"
            id="feishu-binding-form"
            class="mt-4 space-y-4"
          >
            <input
              :if={@feishu_binding_form.params["id"]}
              type="hidden"
              name="feishu_binding[id]"
              value={@feishu_binding_form.params["id"]}
            />
            <h4 class="text-xs font-semibold tracking-wide text-neutral-700">
              {if @feishu_binding_form.params["id"],
                do: gettext("Edit Feishu app"),
                else: gettext("Add a Feishu app")}
            </h4>
            <.input
              name="feishu_binding[display_name]"
              value={@feishu_binding_form.params["display_name"]}
              label={gettext("Display name")}
              placeholder={gettext("Company Feishu")}
            />
            <.input
              name="feishu_binding[app_id]"
              value={@feishu_binding_form.params["app_id"]}
              label={gettext("Feishu App ID")}
              placeholder="cli_xxx"
              hint={
                if @feishu_binding_form.params["id"],
                  do: gettext("App ID is fixed for an existing binding. Delete and add a new app to change it."),
                  else: gettext("Feishu developer console → Credentials & Basic Info.")
              }
              readonly={@feishu_binding_form.params["id"] != nil}
              required
            />
            <.secret_input
              name="feishu_binding[app_secret]"
              label={gettext("Feishu App Secret")}
              hint={gettext("Write-only; never displayed back. Leave blank to keep the current secret.")}
            />
            <div class="space-y-2">
              <label class="flex items-center gap-2 text-sm text-neutral-700">
                <input type="hidden" name="feishu_binding[sso_enabled]" value="false" />
                <input
                  type="checkbox"
                  name="feishu_binding[sso_enabled]"
                  value="true"
                  checked={@feishu_binding_form.params["sso_enabled"] in ["true", true]}
                  class="h-4 w-4 rounded border-neutral-300 text-brand-600 focus:ring-brand-500"
                />
                {gettext("Use for dashboard login (SSO)")}
              </label>
              <label class="flex items-center gap-2 text-sm text-neutral-700">
                <input type="hidden" name="feishu_binding[bot_enabled]" value="false" />
                <input
                  type="checkbox"
                  name="feishu_binding[bot_enabled]"
                  value="true"
                  checked={@feishu_binding_form.params["bot_enabled"] in ["true", true]}
                  class="h-4 w-4 rounded border-neutral-300 text-brand-600 focus:ring-brand-500"
                />
                {gettext("Use for the group bot (IM)")}
              </label>
              <p class="pl-6 text-xs text-neutral-500">
                {gettext(
                  "Requires an App Secret here, or an existing Feishu SSO secret for the same App ID. Only one bot-enabled app is supported for now."
                )}
              </p>
            </div>
            <.secret_input
              name="feishu_binding[verification_token]"
              label={gettext("Verification token (for bot)")}
              hint={gettext("Feishu → Events & Callbacks → security settings. Needed for the bot/webhook.")}
            />
            <.secret_input
              name="feishu_binding[encrypt_key]"
              label={gettext("Encrypt key (optional, for bot)")}
            />
            <div class="rounded-md border border-neutral-200 bg-neutral-50/60 p-3">
              <p class="text-xs text-neutral-500">
                {gettext("For SSO: register this Redirect URI in the Feishu app.")}
              </p>
              <div class="mt-1 flex items-end gap-2">
                <code class="grow truncate rounded-md border border-neutral-200 bg-white px-2 py-2 text-xs text-neutral-700">{@dashboard_redirect_uri}</code>
                <button
                  type="button"
                  class="shrink-0 rounded-md border border-neutral-300 bg-white px-3 py-2 text-xs font-medium text-neutral-700 hover:bg-neutral-50"
                  onclick={"navigator.clipboard.writeText('#{@dashboard_redirect_uri}')"}
                >
                  {gettext("Copy")}
                </button>
              </div>
            </div>
            <div class="flex justify-end gap-2">
              <button
                :if={@feishu_binding_form.params["id"]}
                type="button"
                phx-click="cancel-feishu-binding-edit"
                class="rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
              >
                {gettext("Cancel")}
              </button>
              <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>
                {gettext("Save Feishu app")}
              </.button>
            </div>
          </.form>
        </.card>
      </div>

      <div :if={@tab == :oauth} class="max-w-2xl">

      <div
        :if={@oauth_reminders != [] and not Enum.any?(@oauth_apps, &oauth_app_configured?/1)}
        id="oauth-reminders"
        class="mb-4 flex items-start gap-2 rounded-md border border-amber-300 bg-amber-50 px-3 py-2.5 text-xs text-amber-800"
      >
        <.icon name="clock" class="mt-px h-3.5 w-3.5 shrink-0" />
        <p>
          {ngettext(
            "%{count} member is waiting for an OAuth client to be configured so they can connect accounts: %{names}.",
            "%{count} members are waiting for an OAuth client to be configured so they can connect accounts: %{names}.",
            length(@oauth_reminders),
            names: reminder_names(@oauth_reminders)
          )}
        </p>
      </div>

      <.card>
        <:title>{gettext("OAuth provider apps")}</:title>
        <:actions>
          <.button
            href={~p"/orgs/#{@current_org.slug}/operations/integrations?#{%{surface: "oauth"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View in Operations")}
          </.button>
          <.button
            href={~p"/orgs/#{@current_org.slug}/operations/checks?#{%{surface: "oauth"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View checks")}
          </.button>
          <.badge :if={@oauth_apps_error} color="amber">{gettext("Runtime unavailable")}</.badge>
        </:actions>
        <p class="mb-4 text-xs text-neutral-500">
          {gettext("Client credentials for organization-level OAuth integrations (e.g. Notion, Linear). Agents in this organization's Agent Swarms use them to run the provider's authorization flow. Secrets are write-only and never displayed back.")}
        </p>

        <div
          :if={@oauth_apps_error}
          class="mb-4 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-700"
        >
          {gettext("Couldn't reach the runtime to load OAuth provider apps. Try again shortly.")}
        </div>

        <div class="space-y-4">
          <div
            :for={app <- @oauth_apps}
            class="rounded-md border border-neutral-200 p-4"
            id={"oauth-app-#{app["provider"]}"}
          >
            <div class="mb-3 flex items-center justify-between">
              <h3 class="text-sm font-medium">{provider_label(app["provider"])}</h3>
              <div class="flex items-center gap-2">
                <.badge :if={app["source"] == "default"} color="brand">
                  {gettext("Platform default")}
                </.badge>
                <%= cond do %>
                  <% app["client_secret_configured"] -> %>
                    <.badge color="green">{gettext("Configured")}</.badge>
                  <% setup_url = provider_setup_url(app["provider"]) -> %>
                    <a href={setup_url} target="_blank" rel="noopener noreferrer" class="group relative">
                      <.badge color="neutral" class="group-hover:bg-neutral-200 group-hover:text-neutral-800">
                        {gettext("Not configured")}
                      </.badge>
                      <span class="pointer-events-none absolute right-0 top-full z-10 mt-1 hidden items-center gap-1 whitespace-nowrap rounded-md bg-neutral-900 px-2 py-1 text-xs text-white shadow-md group-hover:flex">
                        {gettext("Create app on %{provider}", provider: provider_label(app["provider"]))}
                        <.icon name="arrow-up-right" class="h-3 w-3" />
                      </span>
                    </a>
                  <% true -> %>
                    <.badge color="neutral">{gettext("Not configured")}</.badge>
                <% end %>
              </div>
            </div>

            <.form for={to_form(%{}, as: :oauth)} phx-submit="save-oauth" id={"oauth-form-#{app["provider"]}"}>
              <input type="hidden" name="oauth[provider]" value={app["provider"]} />
              <div class="space-y-3">
                <.input
                  name="oauth[client_id]"
                  value={app["client_id"]}
                  label={gettext("Client ID")}
                  required
                />
                <.input
                  name="oauth[client_secret]"
                  value=""
                  type="password"
                  label={gettext("Client secret")}
                  hint={
                    if app["client_secret_configured"],
                      do: gettext("Leave blank to keep the current secret."),
                      else: gettext("Write-only; never displayed back.")
                  }
                  autocomplete="off"
                />
              </div>
              <div class="mt-4 flex items-center justify-end gap-2">
                <.button
                  :if={oauth_app_configured?(app)}
                  type="button"
                  variant="danger"
                  size="sm"
                  phx-click="delete-oauth"
                  phx-value-provider={app["provider"]}
                  data-confirm={gettext("Remove the %{provider} OAuth app?", provider: provider_label(app["provider"]))}
                >
                  {gettext("Remove")}
                </.button>
                <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
                  {gettext("Save")}
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </.card>
      </div>

      <div :if={@tab == :signal} class="max-w-2xl">
        <.card>
          <:title>{gettext("Signal number")}</:title>
          <:actions>
            <.badge :if={@signal_error} color="amber">{gettext("Runtime unavailable")}</.badge>
          </:actions>
          <p class="mb-4 text-xs text-neutral-500">
            {gettext("People and Signal groups connect to this organization's projects by sending a one-time code to a Signal number. By default that is the platform number. Set a number registered for this organization to use it instead. Connected chats keep the number they connected with.")}
          </p>
          <div :if={!@signal_error} class="mb-4 space-y-1 text-sm" id="signal-number-status">
            <p>
              {gettext("In use:")}
              <span class="font-mono">{get_in(@signal_number, ["effective", "e164"]) || gettext("No Signal number")}</span>
            </p>
            <p class="text-xs text-neutral-500">
              {gettext("Platform number:")}
              <span class="font-mono">{get_in(@signal_number, ["platform", "e164"]) || gettext("not set")}</span>
            </p>
          </div>
          <.form :if={!@signal_error} for={to_form(%{}, as: :signal)} phx-submit="save-signal" id="signal-form">
            <.input
              name="signal[number]"
              value={get_in(@signal_number, ["override", "e164"])}
              label={gettext("Organization Signal number")}
              hint={gettext("E.164, for example +15551234567. Leave blank to use the platform number.")}
              autocomplete="off"
            />
            <div class="mt-4 flex items-center justify-end">
              <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
                {gettext("Save")}
              </.button>
            </div>
          </.form>
        </.card>
      </div>

      <div :if={@tab == :composio} class="max-w-2xl">
        <.card>
          <:title>{gettext("Composio")}</:title>
          <:actions>
            <.badge :if={@composio_error} color="amber">{gettext("Runtime unavailable")}</.badge>
            <.badge :if={!@composio_error && @composio_settings["source"] == "default"} color="brand">
              {gettext("Platform default")}
            </.badge>
            <.badge :if={!@composio_error} color={if @composio_settings["enabled"], do: "green", else: "neutral"}>
              {if @composio_settings["enabled"], do: gettext("Enabled"), else: gettext("Not configured")}
            </.badge>
          </:actions>
          <p class="mb-4 text-xs text-neutral-500">
            {gettext("Connect this organization's Composio project so agents can link third-party toolkits (Gmail, Google Calendar, Notion, Linear, …) through Composio-hosted auth and call them directly — an alternative to configuring an OAuth app per provider. The API key is write-only and never displayed back.")}
          </p>

          <div
            :if={@composio_error}
            class="mb-4 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-700"
          >
            {gettext("Couldn't reach the runtime to load the Composio settings. Try again shortly.")}
          </div>

          <.form :if={!@composio_error} for={to_form(%{}, as: :composio)} phx-submit="save-composio" id="composio-form">
            <div class="space-y-3">
              <.input
                name="composio[api_key]"
                value=""
                type="password"
                label={gettext("Composio API key")}
                hint={
                  if @composio_settings["api_key_configured"],
                    do: gettext("Leave blank to keep the current key."),
                    else: gettext("Write-only; never displayed back. Create one at composio.dev.")
                }
                autocomplete="off"
              />
              <.input
                name="composio[base_url]"
                value={@composio_settings["base_url"]}
                label={gettext("Base URL (optional)")}
                placeholder="https://backend.composio.dev"
              />
              <label class="flex items-center gap-2 text-sm">
                <input type="hidden" name="composio[enabled]" value="false" />
                <input
                  type="checkbox"
                  name="composio[enabled]"
                  value="true"
                  checked={@composio_settings["enabled"] or not @composio_settings["api_key_configured"]}
                />
                {gettext("Enabled")}
              </label>
            </div>
            <div class="mt-4 flex items-center justify-end gap-2">
              <.button
                :if={@composio_settings["api_key_configured"]}
                type="button"
                variant="danger"
                size="sm"
                phx-click="delete-composio"
                data-confirm={gettext("Remove this organization's Composio settings?")}
              >
                {gettext("Remove")}
              </.button>
              <.button variant="primary" size="sm" type="submit" phx-disable-with={gettext("Saving…")}>
                {gettext("Save")}
              </.button>
            </div>
          </.form>
        </.card>
      </div>
    </div>
    """
  end

  # ---- helpers ----

  defp assign_org_form(socket, params, errors) do
    socket
    |> assign(:org_form, to_form(params, as: :organization))
    |> assign(:org_errors, errors)
  end

  defp assign_sso_form(socket, params, errors) do
    socket
    |> assign(:sso_form, to_form(params, as: :sso))
    |> assign(:sso_errors, errors)
  end

  defp can_manage_settings?(role), do: role in ["owner", "admin"]

  defp bft_cli_install_command do
    install_url =
      dashboard_base_url()
      |> String.trim_trailing("/")
      |> then(&(&1 <> "/v1/cli/install.sh"))

    """
    curl -fsSL #{shell_path(install_url)} | sh
    """
    |> trim_command()
  end

  defp cli_device_login_command do
    api_base_url = dashboard_base_url() |> String.trim_trailing("/")

    """
    bft auth login --url #{shell_path(api_base_url)} --output text
    bft onboarding smoke --step cli-login
    """
    |> trim_command()
  end

  defp assign_cli_sessions(socket) do
    assign(socket, :cli_sessions, CLILogin.list_cli_sessions(socket.assigns.current_user))
  end

  defp trim_command(command) do
    command
    |> String.trim()
    |> String.replace(~r/\n[ \t]+/, "\n")
  end

  defp shell_path("$HOME/" <> rest), do: ~s("$HOME/#{escape_double_quotes(rest)}")
  defp shell_path(path), do: ~s("#{escape_double_quotes(path)}")

  defp escape_double_quotes(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # Load the org's OAuth provider apps from the Salix runtime. The page must
  # still render if the runtime is briefly unreachable, so an error degrades to
  # an empty list plus a banner rather than crashing the LiveView.
  defp assign_oauth_apps(socket, org) do
    case OrgOAuthApps.list_org_oauth_apps(org.id) do
      {:ok, apps} ->
        socket
        |> assign(:oauth_apps, apps)
        |> assign(:oauth_apps_error, false)

      {:error, _reason} ->
        socket
        |> assign(:oauth_apps, [])
        |> assign(:oauth_apps_error, true)
    end
  end

  defp assign_composio_settings(socket, org) do
    case OrgComposioSettings.get_org_composio_settings(org.id) do
      {:ok, view} ->
        socket
        |> assign(:composio_settings, view)
        |> assign(:composio_error, false)

      {:error, _reason} ->
        socket
        |> assign(:composio_settings, %{})
        |> assign(:composio_error, true)
    end
  end

  defp signal_error_text({:bad_request, message}) when is_binary(message), do: message

  defp signal_error_text(:signal_account_not_found),
    do: gettext("This number is not registered for Signal on this server.")

  defp signal_error_text(:signal_account_scope),
    do: gettext("This number belongs to another organization.")

  defp signal_error_text(:signal_account_inactive), do: gettext("This number is not active.")

  defp signal_error_text(reason),
    do: gettext("Couldn't save the Signal number (%{reason}).", reason: describe_error(reason))

  defp oauth_app_configured?(app) do
    app["client_secret_configured"] == true or (app["client_id"] || "") != "" or
      app["source"] == "default"
  end

  # Load the Salix model (template) catalog for the allowlist/default editor.
  # Degrades to an empty catalog plus a banner if the runtime is unreachable.
  defp assign_models(socket, org) do
    {catalog, error?} =
      case Models.catalog(org) do
        {:ok, templates} -> {templates, false}
        {:error, _reason} -> {[], true}
      end

    socket
    |> assign(:model_catalog, catalog)
    |> assign(:model_catalog_error, error?)
    |> assign(:allowed_template_ids, org.allowed_template_ids || [])
    |> assign(:default_template_id, org.default_template_id)
    |> assign(:default_router_template_id, org.default_router_template_id)
    |> assign(:platform_defaults, Models.platform_defaults())
  end

  defp follow_platform_prompt(nil), do: gettext("Default (unavailable)")

  defp follow_platform_prompt(template),
    do: gettext("Default (%{model})", model: Models.label(template))

  # Checkbox params arrive as a list (with a leading "" from the hidden field so
  # the key always exists); drop blanks and dedupe.
  defp model_checkbox_id(%{"template_id" => template_id}) when is_binary(template_id),
    do: "models-allowed-" <> Base.url_encode64(template_id, padding: false)

  defp model_checkbox_id(_template), do: "models-allowed-unknown"

  defp parse_allowed(values) when is_list(values),
    do: values |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

  defp parse_allowed(value) when is_binary(value) and value != "", do: [value]
  defp parse_allowed(_values), do: []

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp provider_label(provider) do
    provider = to_string(provider)

    case Map.get(@oauth_provider_info, provider) do
      {label, _console_url} -> label
      nil -> String.capitalize(provider)
    end
  end

  defp provider_console_url(provider) do
    case Map.get(@oauth_provider_info, to_string(provider)) do
      {_label, console_url} -> console_url
      nil -> nil
    end
  end

  defp provider_setup_url(provider) do
    case to_string(provider) do
      "github" -> github_app_create_url()
      "linear" -> linear_oauth_app_create_url()
      "slack" -> slack_app_create_url()
      _ -> provider_console_url(provider)
    end
  end

  defp linear_oauth_app_create_url do
    query =
      URI.encode_query(%{
        "developer.name" => "Comma",
        "display.description" => "Connect Linear to Comma Bridge for Teams agents.",
        "distribution" => "private",
        "oauth.client_name" => @oauth_app_name,
        "oauth.client_uri" => dashboard_base_url() |> String.trim_trailing("/"),
        "oauth.grant_types" => "authorization_code",
        "oauth.redirect_uris" => salix_oauth_callback_url("linear")
      })

    @linear_oauth_app_create_url <> "?" <> query
  end

  defp slack_app_create_url do
    query =
      URI.encode_query(%{
        "manifest_json" => Jason.encode!(slack_app_manifest()),
        "new_app" => "1"
      })

    @slack_app_create_url <> "?" <> query
  end

  defp slack_app_manifest do
    %{
      "display_information" => %{
        "background_color" => "#1D1C1D",
        "description" => "Connect Slack to Comma Bridge for Teams.",
        "name" => @oauth_app_name
      },
      "oauth_config" => %{
        "redirect_urls" => [salix_oauth_callback_url("slack")],
        "scopes" => %{"user" => ["users:read"]}
      },
      "settings" => %{
        "org_deploy_enabled" => false,
        "socket_mode_enabled" => false,
        "token_rotation_enabled" => false
      }
    }
  end

  defp github_app_create_url do
    query =
      [
        {"name", @oauth_app_name},
        {"description", "Connect OAuth providers to Comma Bridge for Teams agents."},
        {"url", dashboard_base_url() |> String.trim_trailing("/")},
        {"callback_urls[]", salix_oauth_callback_url("github")},
        {"request_oauth_on_install", "true"},
        {"public", "false"},
        {"webhook_active", "false"}
      ]
      |> URI.encode_query()

    @github_app_create_url <> "?" <> query
  end

  defp salix_oauth_callback_url(provider) do
    salix_public_base_url() <> "/v1/oauth/#{provider}/callback"
  end

  defp salix_public_base_url do
    case Application.get_env(:salix_web, :public_base_url) do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/")

      _ ->
        salix_endpoint_base_url()
    end
  end

  defp salix_endpoint_base_url do
    "http://127.0.0.1:#{Application.get_env(:salix_web, :port, 4000)}"
  end

  defp reminder_names(reminders) do
    reminders
    |> Enum.map(fn %{user: user} -> user.name || user.email || user.id end)
    |> Enum.join(", ")
  end

  defp describe_error(:unavailable), do: "runtime unavailable"
  defp describe_error(:timeout), do: "runtime timed out"
  defp describe_error(reason), do: inspect(reason)

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_datetime(_), do: "—"

  defp org_params(org),
    do: %{
      "name" => org.name || "",
      "slug" => org.slug || "",
      "icon" => org.icon || "",
      "default_locale" => org.default_locale || ""
    }

  defp sso_params(nil),
    do: %{
      "provider" => "generic_oidc",
      "default_role" => "member",
      "provider_config" => %{"scope" => "", "provisioning_policy" => "jit"}
    }

  defp sso_params(sso) do
    provider_config = sso.provider_config || %{}

    %{
      "provider" => sso.provider || "generic_oidc",
      "issuer" => sso.issuer || "",
      "client_id" => sso.client_id || "",
      "allowed_domains" => Enum.join(sso.allowed_domains || [], ", "),
      "default_role" => sso.default_role || "member",
      "provider_config" => %{
        "scope" => provider_config["scope"] || provider_config[:scope] || "",
        "provisioning_policy" =>
          provider_config["provisioning_policy"] || provider_config[:provisioning_policy] || "jit"
      }
    }
  end

  defp sso_provider(form) do
    case form.params["provider"] do
      "feishu" -> "feishu"
      _ -> "generic_oidc"
    end
  end

  defp sso_provider_config(form, key, default) do
    case form.params["provider_config"] do
      config when is_map(config) -> config[key] || config[String.to_atom(key)] || default
      _ -> default
    end
  end

  defp feishu_binding_form(%BridgeForTeams.Schema.FeishuAppBinding{} = binding) do
    binding
    |> feishu_binding_params()
    |> feishu_binding_form()
  end

  defp feishu_binding_form(params), do: to_form(stringify_keys(params), as: :feishu_binding)

  defp assign_feishu_bindings(socket, org) do
    projects = Projects.list_projects(org.id)
    {routes, route_error} = feishu_binding_routes(org, projects)

    socket
    |> assign(:feishu_bindings, FeishuAppBindings.list_bindings(org.id))
    |> assign(:feishu_scope_cards, FeishuScopes.import_cards())
    |> assign(:feishu_optional_scopes, FeishuScopes.optional_bot_scopes())
    |> assign(:feishu_route_projects, projects)
    |> assign(:feishu_binding_routes, routes)
    |> assign(:feishu_binding_routes_error, route_error)
  end

  defp feishu_binding_routes(org, projects) do
    {route_pairs, errors} =
      Enum.reduce(projects, {[], []}, fn project, {routes, errors} ->
        case ProjectIMConnects.list_project_connects(org.id, project.id, "feishu") do
          {:ok, connects} ->
            project_routes =
              Enum.map(connects, fn connect ->
                {connect["app_id"],
                 %{
                   project_id: project.id,
                   project_name: project.name,
                   salix_group_id: project.salix_group_id,
                   connect_id: connect["connect_id"],
                   disabled: not is_nil(connect["disabled_at"])
                 }}
              end)

            {project_routes ++ routes, errors}

          {:error, reason} ->
            {routes, [%{project: project, reason: reason} | errors]}
        end
      end)

    routes_by_app =
      route_pairs
      |> Enum.reject(fn {app_id, _route} -> app_id in [nil, ""] end)
      |> Enum.group_by(fn {app_id, _route} -> app_id end, fn {_app_id, route} -> route end)

    {routes_by_app, List.first(errors)}
  end

  defp routes_for_binding(routes_by_app, binding) do
    Map.get(routes_by_app || %{}, binding.app_id, [])
  end

  defp feishu_binding_params(binding) do
    %{
      "id" => binding.id,
      "app_id" => binding.app_id,
      "display_name" => binding.display_name,
      "sso_enabled" => binding.sso_enabled,
      "bot_enabled" => binding.bot_enabled
    }
  end

  defp feishu_binding_error_message({:missing_bot_secret, :app_secret}),
    do:
      gettext(
        "Could not enable the Feishu bot. Enter the App Secret, or first enable SSO for this same Feishu App ID so the bot can reuse that secret."
      )

  defp feishu_binding_error_message(:bot_app_already_enabled),
    do:
      gettext(
        "Only one Feishu app can be enabled for the group bot right now. Disable the existing bot app before enabling another."
      )

  defp feishu_binding_error_message(:app_id_immutable),
    do:
      gettext(
        "App ID cannot be changed for an existing Feishu app. Delete it and add a new app instead."
      )

  defp feishu_binding_error_message(:not_found),
    do: gettext("Feishu app not found.")

  defp feishu_binding_error_message(_reason),
    do: gettext("Could not save the Feishu app. Check the App ID and secret.")

  attr(:name, :string, required: true)
  attr(:label, :string, default: nil)
  attr(:hint, :string, default: nil)
  attr(:rest, :global)

  # A write-only secret input with an inline, client-only Show/Hide toggle pinned
  # to the field's right edge. The input renders value="", so revealing can only
  # ever show what's typed this session — it never decrypts or echoes a saved
  # secret.
  defp secret_input(assigns) do
    ~H"""
    <div>
      <.field_label :if={@label}>{@label}</.field_label>
      <div class="relative">
        <input
          type="password"
          name={@name}
          value=""
          autocomplete="off"
          class="block h-8 w-full rounded-md border border-neutral-300 pl-2.5 pr-16 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          {@rest}
        />
        <button
          type="button"
          data-show={gettext("Show")}
          data-hide={gettext("Hide")}
          class="absolute inset-y-0 right-0 flex items-center rounded-r-md px-3 text-xs font-medium text-neutral-500 hover:text-neutral-700"
          onclick="var i=this.parentElement.querySelector('input'); var p=i.type==='password'; i.type=p?'text':'password'; this.textContent=p?this.dataset.hide:this.dataset.show;"
        >
          {gettext("Show")}
        </button>
      </div>
      <p :if={@hint} class="mt-1 text-xs text-neutral-500">{@hint}</p>
    </div>
    """
  end

  # The org's Feishu app binding that is enabled for SSO, if any. The SSO card
  # references it instead of asking for the App ID/secret again. Older builds
  # could leave multiple SSO-enabled bindings behind, so prefer the one most
  # recently saved until the next binding save cleans the posture up.
  defp feishu_sso_binding(org_id) do
    org_id
    |> FeishuAppBindings.list_bindings()
    |> Enum.filter(& &1.sso_enabled)
    |> Enum.max_by(&binding_timestamp/1, fn -> nil end)
  end

  defp binding_timestamp(%{updated_at: %DateTime{} = updated_at}),
    do: DateTime.to_unix(updated_at, :microsecond)

  defp binding_timestamp(%{created_at: %DateTime{} = created_at}),
    do: DateTime.to_unix(created_at, :microsecond)

  defp binding_timestamp(_binding), do: 0

  # Feishu SSO reuses the org Feishu app binding: pull the App ID from the
  # binding so the connection points at the same app (the secret was already
  # fanned out when the binding was saved; a blank secret here keeps it).
  defp attach_feishu_app(%{"provider" => "feishu"} = params, %{
         feishu_sso_binding: %{app_id: app_id}
       })
       when is_binary(app_id) do
    Map.put(params, "client_id", app_id)
  end

  defp attach_feishu_app(params, _assigns), do: params

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp dashboard_redirect_uri do
    dashboard_base_url()
    |> String.trim_trailing("/")
    |> then(&(&1 <> "/auth/callback"))
  end

  defp dashboard_base_url do
    case Application.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" ->
        base

      _ ->
        dashboard_endpoint_base_url()
    end
  end

  defp dashboard_endpoint_base_url do
    endpoint_config =
      Application.get_env(
        :bridge_for_teams_web,
        BridgeForTeamsWeb.DashboardEndpoint,
        []
      )

    url_config = Keyword.get(endpoint_config, :url, [])
    http_config = Keyword.get(endpoint_config, :http, [])

    scheme = Keyword.get(url_config, :scheme, "http")
    host = Keyword.get(url_config, :host, "localhost")
    port = Keyword.get(url_config, :port) || Keyword.get(http_config, :port)

    port_suffix =
      case {scheme, port} do
        {"http", port} when port in [nil, 80] -> ""
        {"https", port} when port in [nil, 443] -> ""
        {_scheme, nil} -> ""
        {_scheme, port} -> ":#{port}"
      end

    "#{scheme}://#{host}#{port_suffix}"
  end

  defp persist_run_checks_activity(socket, checks) do
    case Observability.record_run_checks_activity(checks,
           ran_by_user_id: socket.assigns.current_user.id
         ) do
      {:ok, _check} ->
        socket

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          gettext("Checks ran, but Operations could not record them.")
        )
    end
  end

  defp audit_opts(socket) do
    user = socket.assigns.current_user

    [
      actor_user_id: user.id,
      actor_label: audit_actor_label(user),
      request_id: Ecto.UUID.generate()
    ]
  end

  defp audit_actor_label(user) do
    cond do
      is_binary(user.email) and user.email != "" -> user.email
      is_binary(user.name) and user.name != "" -> user.name
      true -> user.id
    end
  end

  defp record_model_validation_event(socket, status, reason_class, evidence) do
    org = socket.assigns.current_org

    _result =
      Observability.record_validation_event(%{
        org_id: org.id,
        actor_user_id: socket.assigns.current_user.id,
        surface: "models",
        resource_type: "model_settings",
        resource_id: org.id,
        resource_label: org.name,
        status: status,
        reason_class: reason_class,
        evidence: evidence
      })

    :ok
  end

  defp errors_for(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp org_initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp org_initial(_), do: "?"
end
