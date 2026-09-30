defmodule BridgeForTeamsWeb.Dashboard.Layouts do
  @moduledoc """
  Dashboard layouts: the `root/1` HTML document (links the built assets) and the
  `app/1` shell (sidebar + topbar + `<main>`).

  ## App shell API (STABLE — page LiveViews set these assigns)

  The `app/1` layout is the LiveView layout (`{Layouts, :app}`). It reads:

    * `@current_user`  — the authenticated `%BridgeForTeams.Schema.User{}` (from on_mount)
    * `@current_org`   — the active `%Organization{}` or `nil`
    * `@current_org_role` — the user's role in the active org, when known
    * `@orgs`          — orgs the user belongs to (for the switcher); default `[]`
    * `@active_nav`    — atom marking the active sidebar item
                         (`:overview | :new_home | :projects | :fin | :operations | :triage | :members | :plugins | :settings`)
    * `@breadcrumbs`   — list of `{label, path | nil}` for the topbar; default `[]`
    * `@flash`         — the flash map (always present in LiveView)

  Page LiveViews assign `:current_org`, `:orgs`, `:active_nav`, and `:breadcrumbs`
  in `mount/3` (sensible defaults are applied here when missing).
  """
  use BridgeForTeamsWeb.Dashboard, :html

  alias BridgeForTeamsWeb.Dashboard.OnboardingComponents

  embed_templates("layouts/*")

  @doc """
  App shell layout for LiveViews. The chrome (sidebar, topbar — and on New
  Home, the chat rail) lives on a light gray layer; the center work surface is
  a raised white panel above it. Pages that arrange their own raised panels
  (e.g. New Home with its gray-level chat rail) assign `:content_chrome, :bare`.
  """
  attr(:flash, :map, default: %{})
  attr(:current_user, :any, default: nil)
  attr(:current_org, :any, default: nil)
  attr(:current_org_role, :string, default: nil)
  attr(:orgs, :list, default: [])
  attr(:active_nav, :atom, default: nil)
  attr(:breadcrumbs, :list, default: [])
  attr(:locale, :string, default: "en")
  attr(:onboarding, :map, default: nil)
  attr(:suppress_onboarding_checklist, :boolean, default: false)
  attr(:oauth_reminder_alert, :map, default: nil)
  attr(:content_chrome, :atom, default: :panel)
  attr(:inner_content, :any, default: nil)
  slot(:inner_block)

  def app(assigns) do
    assigns =
      assigns
      |> assign(:sidebar_project, sidebar_project(assigns))
      |> assign(:project_nav_active, project_nav_active(assigns))

    ~H"""
    <div
      id="dashboard-shell"
      phx-hook="NavigationSearch"
      class="flex h-dvh w-full flex-col overflow-hidden bg-neutral-100 text-neutral-900 lg:flex-row"
    >
      <header class="flex h-12 shrink-0 items-center gap-2 border-b border-neutral-200 px-3 lg:hidden">
        <button
          type="button"
          data-navigation-open-trigger
          class="grid h-10 w-10 place-items-center rounded-md text-neutral-600 hover:bg-neutral-200/70 hover:text-neutral-900"
          aria-label={gettext("Open navigation")}
          aria-controls="dashboard-navigation"
          phx-click={JS.show(to: "#dashboard-navigation", display: "flex")}
        >
          <.icon name="drag-handle" class="h-4 w-4 rotate-90" />
        </button>
        <div class="flex min-w-0 flex-1 items-center gap-2 px-1">
          <.org_avatar org={@current_org} size="xs" />
          <span class="truncate text-sm font-medium text-neutral-800">{org_name(@current_org)}</span>
        </div>
      </header>
      <div
        id="dashboard-navigation"
        class="fixed inset-0 z-50 hidden shrink-0 lg:static lg:z-auto lg:!flex"
      >
        <button
          type="button"
          class="absolute inset-0 bg-neutral-900/25 lg:hidden"
          aria-label={gettext("Close navigation")}
          phx-click={JS.hide(to: "#dashboard-navigation")}
        />
        <.sidebar
          current_user={@current_user}
          current_org={@current_org}
          current_org_role={@current_org_role}
          orgs={@orgs}
          active_nav={@active_nav}
          project={@sidebar_project}
          project_nav_active={@project_nav_active}
          locale={@locale}
          close_target="#dashboard-navigation"
          class="absolute inset-y-0 left-0 bg-neutral-100 shadow-popover lg:static lg:shadow-none"
        />
      </div>
      <div class="flex min-h-0 min-w-0 flex-1 flex-col">
        <main id="dashboard-main" class="min-h-0 flex-1 p-0 lg:p-3">
          <%= if assigns[:content_chrome] == :bare do %>
            {@inner_content || render_slot(@inner_block)}
          <% else %>
            <div
              class={[
                "panel-raised h-full",
                assigns[:content_chrome] == :workbench &&
                  "flex min-h-0 flex-col overflow-y-auto lg:overflow-hidden",
                assigns[:content_chrome] != :workbench && "overflow-y-auto"
              ]}
              data-scroll-main
            >
              <.panel_breadcrumbs :if={length(@breadcrumbs) > 1} breadcrumbs={@breadcrumbs} />
              <div
                class={[
                  "mx-auto w-full max-w-6xl px-4 py-5 sm:px-6 lg:px-8 lg:py-7",
                  assigns[:content_chrome] == :workbench &&
                    "lg:flex lg:min-h-0 lg:flex-1 lg:flex-col"
                ]}
              >
                {@inner_content || render_slot(@inner_block)}
              </div>
            </div>
          <% end %>
        </main>
      </div>
      <.navigation_search
        current_org={@current_org}
        current_org_role={@current_org_role}
        project={@sidebar_project}
      />
      <.flash_group flash={@flash} />
      <OnboardingComponents.onboarding_ui :if={@onboarding} onboarding={@onboarding} />
      <OnboardingComponents.checklist_widget
        :if={@onboarding && !@suppress_onboarding_checklist}
        onboarding={@onboarding}
      />
      <OnboardingComponents.oauth_reminder_toast
        :if={@oauth_reminder_alert}
        alert={@oauth_reminder_alert}
      />
    </div>
    """
  end

  @doc """
  Full-screen layout for the first-run onboarding LiveView: no sidebar, the
  auth-page background and logo header, and the flash group (the app shell is
  absent, so flashes must render here).
  """
  attr(:flash, :map, default: %{})
  attr(:inner_content, :any, default: nil)
  slot(:inner_block)

  def onboarding(assigns) do
    ~H"""
    <div class="min-h-dvh bg-neutral-100">
      <div class="mx-auto flex min-h-dvh w-full max-w-3xl flex-col px-6 py-8">
        <div class="mb-8 flex items-center justify-center gap-2">
          <img src={~p"/images/bridge-icon-512.png"} alt="" class="h-7 w-7 rounded-md" />
          <span class="text-base font-semibold tracking-tight">Bridge For Teams</span>
        </div>
        {@inner_content || render_slot(@inner_block)}
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  # ---- Sidebar ----

  attr(:current_user, :any, default: nil)
  attr(:current_org, :any, default: nil)
  attr(:current_org_role, :string, default: nil)
  attr(:orgs, :list, default: [])
  attr(:active_nav, :atom, default: nil)
  attr(:project, :any, default: nil)
  attr(:project_nav_active, :atom, default: nil)
  attr(:locale, :string, default: "en")
  attr(:close_target, :string, default: nil)
  attr(:class, :string, default: nil)

  defp sidebar(assigns) do
    ~H"""
    <aside class={["flex w-[min(20rem,calc(100vw-3rem))] shrink-0 flex-col lg:w-64", @class]}>
      <div class="space-y-2 px-3 pb-3 pt-3">
        <div class="flex items-center gap-1">
          <div class="min-w-0 flex-1">
            <.org_switcher
              current_org={@current_org}
              orgs={@orgs}
              close_target={@close_target}
            />
          </div>
          <button
            type="button"
            aria-label={gettext("Close navigation")}
            class="grid h-10 w-10 shrink-0 place-items-center rounded-md text-neutral-500 hover:bg-neutral-200/60 hover:text-neutral-900 lg:hidden"
            phx-click={JS.hide(to: @close_target)}
          >
            <.icon name="x-mark" class="h-4 w-4" />
          </button>
        </div>
        <button
          type="button"
          data-navigation-search-trigger
          aria-controls="navigation-search-dialog"
          aria-expanded="false"
          aria-keyshortcuts="Meta+K Control+K"
          class="flex h-10 w-full items-center gap-2 rounded-md border border-neutral-200 bg-white px-2.5 text-left text-[13px] text-neutral-500 shadow-subtle transition-colors hover:border-neutral-300 hover:text-neutral-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1 lg:h-9"
        >
          <.icon name="search" variant="outlined" class="h-4 w-4" />
          <span class="min-w-0 flex-1 truncate">{gettext("Search navigation")}</span>
          <kbd class="hidden rounded border border-neutral-200 bg-neutral-50 px-1.5 py-0.5 font-sans text-[10px] text-neutral-400 lg:inline">⌘K</kbd>
        </button>
      </div>

      <nav
        class="min-h-0 flex-1 space-y-4 overflow-y-auto px-2 pb-3"
        aria-label={gettext("Primary navigation")}
      >
        <section aria-labelledby="personal-navigation-label">
          <.sidebar_section_label id="personal-navigation-label" label={gettext("Personal")} />
          <div class="space-y-px">
            <.nav_item
              label={gettext("My Space")}
              icon="user"
              navigate={new_home_path()}
              active={@active_nav == :new_home}
              close_target={@close_target}
            />
          </div>
        </section>

        <section :if={@current_org} aria-labelledby="workspace-navigation-label">
          <.sidebar_section_label id="workspace-navigation-label" label={gettext("Workspace")} />
          <div class="space-y-px">
            <.nav_item
              label={gettext("Overview")}
              icon="home"
              navigate={org_show_path(@current_org)}
              active={@active_nav == :overview}
              close_target={@close_target}
            />
          <.nav_item
            label={gettext("Agent Swarms")}
            icon="folder"
            navigate={org_projects_path(@current_org)}
            active={@active_nav == :projects && is_nil(@project)}
            section_active={@active_nav == :projects}
            data_tour="nav-swarms"
            close_target={@close_target}
          />
            <.nav_item
              label={gettext("Fin")}
              icon="zap"
              navigate={org_fin_path(@current_org)}
              active={@active_nav == :fin}
              close_target={@close_target}
            />
          <.nav_item
            :if={can_view_operations?(@current_org_role)}
            label={gettext("Operations")}
            icon="chart-bar"
            navigate={org_operations_path(@current_org)}
            active={@active_nav == :operations}
            close_target={@close_target}
          />
          <.nav_item
            :if={triage_workbench_visible?(@current_org_role)}
            label={gettext("Triage")}
            icon="inbox"
            navigate={org_triage_path(@current_org)}
            active={@active_nav == :triage}
            close_target={@close_target}
          />
          <.nav_item
            :if={information_flow_visible?(@current_org_role)}
            label={gettext("Information flow")}
            icon="shield-check"
            navigate={org_information_flow_path(@current_org)}
            active={@active_nav == :information_flow}
            close_target={@close_target}
          />
          <.nav_item
            :if={can_manage_settings?(@current_org_role)}
            label={gettext("Meetings")}
            icon="calendar"
            navigate={org_meetings_path(@current_org)}
            active={@active_nav == :meetings}
            close_target={@close_target}
          />
          </div>
        </section>

        <.project_navigation
          :if={@project && @current_org}
          project={@project}
          org={@current_org}
          active={@project_nav_active}
          close_target={@close_target}
        />
      </nav>

      <.administration_navigation
        :if={@current_org}
        org={@current_org}
        role={@current_org_role}
        active_nav={@active_nav}
        close_target={@close_target}
      />

      <div class="border-t border-neutral-200/80 p-2">
        <.user_menu current_user={@current_user} locale={@locale} />
      </div>
    </aside>
    """
  end

  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)
  attr(:active, :boolean, default: false)
  attr(:section_active, :boolean, default: false)
  attr(:data_tour, :string, default: nil)
  attr(:close_target, :string, default: nil)
  attr(:tone, :string, default: "workspace", values: ~w(workspace project))

  defp nav_item(assigns) do
    assigns = assign(assigns, :highlighted, assigns.active || assigns.section_active)

    ~H"""
    <.link
      navigate={@navigate}
      data-tour={@data_tour}
      phx-click={@close_target && JS.hide(to: @close_target)}
      aria-current={@active && "page"}
      class={[
        "flex min-h-10 items-center gap-2 rounded-md px-2 text-[13px] transition-colors duration-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1 lg:min-h-8",
        @highlighted && @tone == "workspace" && "bg-neutral-200/80 font-medium text-neutral-900",
        @highlighted && @tone == "project" && "bg-brand-50 font-medium text-brand-700",
        !@highlighted && "font-book text-neutral-600 hover:bg-neutral-200/50 hover:text-neutral-900"
      ]}
    >
      <.icon
        name={@icon}
        variant="outlined"
        class={nav_icon_class(@highlighted, @tone)}
      />
      <span class="truncate">{@label}</span>
    </.link>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)

  defp sidebar_section_label(assigns) do
    ~H"""
    <div id={@id} class="px-2 pb-1 text-[11px] font-medium text-neutral-400">{@label}</div>
    """
  end

  attr(:project, :any, required: true)
  attr(:org, :any, required: true)
  attr(:active, :atom, default: nil)
  attr(:close_target, :string, default: nil)

  defp project_navigation(assigns) do
    ~H"""
    <section class="border-t border-neutral-200/80 pt-3" aria-label={gettext("Current Agent Swarm")}>
      <details
        id={"agent-swarm-navigation-#{@project.id}"}
        open
        phx-hook="PersistDisclosure"
        data-storage-key={"bft:sidebar:agent-swarm:#{@project.id}"}
        data-default-open="true"
        class="group"
      >
        <summary class="flex min-h-10 min-w-0 cursor-pointer list-none items-center gap-1 rounded-md px-2 py-1.5 marker:hidden hover:bg-neutral-200/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1">
          <span class="min-w-0 flex-1 truncate text-[13px] font-medium text-neutral-800">
            {@project.name}
          </span>
          <.link
            navigate={project_settings_path(@org, @project)}
            phx-click={@close_target && JS.hide(to: @close_target)}
            aria-label={gettext("Agent Swarm settings")}
            title={gettext("Agent Swarm settings")}
            class={[
              "grid h-8 w-8 shrink-0 place-items-center rounded-md text-neutral-500 hover:bg-neutral-200/70 hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500",
              @active == :settings && "bg-brand-50 text-brand-700"
            ]}
          >
            <.icon name="cog" variant="outlined" class="h-4 w-4" />
          </.link>
          <.icon name="chevron-down" variant="outlined" class="h-4 w-4 shrink-0 text-neutral-400 transition-transform group-open:rotate-180" />
        </summary>

        <div class="space-y-3 pb-1 pt-2">
          <.project_nav_group label={gettext("Work")}>
            <.nav_item label={gettext("Tasks")} icon="chat-bubble" navigate={project_tasks_path(@org, @project)} active={@active == :tasks} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Agents")} icon="users" navigate={project_agents_path(@org, @project)} active={@active == :agents} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Schedules")} icon="calendar" navigate={project_schedules_path(@org, @project)} active={@active == :schedules} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Devices")} icon="bolt" navigate={project_devices_path(@org, @project)} active={@active == :environments} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Websites")} icon="globe" navigate={project_websites_path(@org, @project)} active={@active == :websites} tone="project" close_target={@close_target} />
          </.project_nav_group>

          <.project_nav_group label={gettext("Configure")}>
            <.nav_item label={gettext("Plugins")} icon="plug" navigate={project_plugins_path(@org, @project)} active={@active == :plugins} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Skills")} icon="sparkles" navigate={project_skills_path(@org, @project)} active={@active == :skills} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Integrations")} icon="cube" navigate={project_integrations_path(@org, @project)} active={@active == :integrations} tone="project" close_target={@close_target} />
            <.nav_item label={gettext("Connections")} icon="attachment" navigate={project_connections_path(@org, @project)} active={@active == :connections} tone="project" close_target={@close_target} />
          </.project_nav_group>

        </div>
      </details>
    </section>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp project_nav_group(assigns) do
    ~H"""
    <section aria-label={@label}>
      <div class="px-2 pb-1 text-[11px] font-medium text-neutral-400">{@label}</div>
      <div class="space-y-px pl-2">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr(:org, :any, required: true)
  attr(:role, :string, default: nil)
  attr(:active_nav, :atom, default: nil)
  attr(:close_target, :string, default: nil)

  defp administration_navigation(assigns) do
    assigns = assign(assigns, :active, assigns.active_nav in [:members, :plugins, :settings])

    ~H"""
    <nav
      class="border-t border-neutral-200/80 px-2 py-2"
      aria-label={gettext("Administration")}
    >
      <details
        id={"administration-navigation-#{@org.id}"}
        open={@active}
        phx-hook="PersistDisclosure"
        data-storage-key={"bft:sidebar:administration:#{@org.id}"}
        data-default-open={to_string(@active)}
        data-force-open={to_string(@active)}
        class="group"
      >
        <summary class={[
          "flex min-h-10 cursor-pointer list-none items-center gap-2 rounded-md px-2 text-[13px] marker:hidden focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1 lg:min-h-8",
          @active && "bg-neutral-200/80 font-medium text-neutral-900",
          !@active && "text-neutral-600 hover:bg-neutral-200/50 hover:text-neutral-900"
        ]}>
          <.icon name="cog" variant="outlined" class="h-4 w-4 text-neutral-500" />
          <span class="min-w-0 flex-1 truncate">{gettext("Administration")}</span>
          <.icon name="chevron-down" variant="outlined" class="h-4 w-4 text-neutral-400 transition-transform group-open:rotate-180" />
        </summary>
        <div class="space-y-px pb-1 pl-2 pt-1">
          <.nav_item label={gettext("Members")} icon="users" navigate={org_members_path(@org)} active={@active_nav == :members} close_target={@close_target} />
          <.nav_item label={gettext("Organization plugins")} icon="plug" navigate={org_plugins_path(@org)} active={@active_nav == :plugins} close_target={@close_target} />
          <.nav_item
            :if={can_manage_settings?(@role)}
            label={gettext("Settings")}
            icon="cog"
            navigate={org_settings_path(@org)}
            active={@active_nav == :settings}
            data_tour="nav-settings"
            close_target={@close_target}
          />
        </div>
      </details>
    </nav>
    """
  end

  attr(:current_org, :any, default: nil)
  attr(:orgs, :list, default: [])
  attr(:close_target, :string, default: nil)

  defp org_switcher(assigns) do
    ~H"""
    <details
      id="org-switcher"
      class="group relative w-full"
      phx-click-away={JS.remove_attribute("open", to: "#org-switcher")}
    >
      <summary class="flex min-h-10 w-full cursor-pointer list-none items-center justify-between rounded-md px-2 py-1.5 marker:hidden transition-colors duration-100 hover:bg-neutral-200/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1">
        <div class="flex min-w-0 items-center gap-2">
            <.org_avatar org={@current_org} size="xs" />
          <span class="truncate text-sm font-medium text-neutral-800">{org_name(@current_org)}</span>
        </div>
        <.icon name="chevron-down" variant="outlined" class="h-4 w-4 shrink-0 text-neutral-400 transition-transform group-open:rotate-180" />
      </summary>
      <div
        id="org-switcher-menu"
        class="absolute left-0 top-full z-40 mt-1 max-h-[min(24rem,calc(100vh-8rem))] w-full overflow-y-auto rounded-lg bg-white py-1 shadow-popover"
      >
        <.link
          :for={org <- @orgs}
          navigate={org_show_path(org)}
          phx-click={close_navigation(JS.remove_attribute("open", to: "#org-switcher"), @close_target)}
          class="flex min-h-10 items-center gap-2 px-3 py-1.5 text-sm text-neutral-700 hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand-500 lg:min-h-8"
        >
          <.org_avatar org={org} size="xs" />
          <span class="min-w-0 flex-1 truncate">{org.name}</span>
          <.icon :if={@current_org && org.id == @current_org.id} name="check" variant="outlined" class="h-4 w-4 text-brand-600" />
        </.link>
        <.link
          navigate={orgs_path()}
          phx-click={close_navigation(JS.remove_attribute("open", to: "#org-switcher"), @close_target)}
          class="block min-h-10 border-t border-neutral-100 px-3 py-2 text-sm text-neutral-500 hover:bg-neutral-50 hover:text-neutral-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand-500 lg:min-h-8 lg:py-1.5"
        >
          {gettext("View all organizations")}
        </.link>
      </div>
    </details>
    """
  end

  attr(:current_user, :any, default: nil)
  attr(:locale, :string, default: "en")

  defp user_menu(assigns) do
    ~H"""
    <details
      id="user-menu"
      class="group relative w-full"
      phx-click-away={JS.remove_attribute("open", to: "#user-menu")}
    >
      <summary class="flex min-h-10 w-full cursor-pointer list-none items-center gap-2 rounded-md px-2 py-1.5 marker:hidden transition-colors duration-100 hover:bg-neutral-200/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1">
        <div class="flex h-6 w-6 items-center justify-center rounded-full bg-neutral-300 text-[10px] font-semibold text-neutral-700">
          {user_initial(@current_user)}
        </div>
        <div class="min-w-0 flex-1 text-left">
          <p class="truncate text-xs font-medium text-neutral-800">{user_label(@current_user)}</p>
        </div>
        <.icon name="chevron-down" variant="outlined" class="h-4 w-4 text-neutral-400 transition-transform group-open:rotate-180" />
      </summary>
      <div class="absolute bottom-full left-0 z-40 mb-1 w-full rounded-lg bg-white py-1 shadow-popover">
        <div class="px-3 py-1.5 text-[10px] font-semibold text-neutral-400">
          {gettext("Language")}
        </div>
        <.link
          :for={{label, value} <- BridgeForTeamsWeb.I18n.options()}
          href={"/locale/#{value}"}
          class={["flex min-h-10 items-center justify-between px-3 py-1.5 text-sm text-neutral-700 hover:bg-neutral-50 lg:min-h-8", value == @locale && "font-medium text-neutral-900"]}
        >
          <span>{label}</span>
          <.icon :if={value == @locale} name="check" variant="outlined" class="h-4 w-4 text-brand-600" />
        </.link>
        <.link
          id="dashboard-restart-onboarding"
          href="/onboarding/restart"
          method="post"
          class="block min-h-10 border-t border-neutral-100 px-3 py-2 text-sm text-neutral-700 hover:bg-neutral-50 lg:min-h-8 lg:py-1.5"
        >
          {gettext("Restart onboarding")}
        </.link>
        <.link
          id="dashboard-logout"
          href="/logout"
          method="delete"
          class="block min-h-10 border-t border-neutral-100 px-3 py-2 text-sm text-neutral-700 hover:bg-neutral-50 lg:min-h-8 lg:py-1.5"
        >
          {gettext("Sign out")}
        </.link>
      </div>
    </details>
    """
  end

  attr(:current_org, :any, default: nil)
  attr(:current_org_role, :string, default: nil)
  attr(:project, :any, default: nil)

  defp navigation_search(assigns) do
    ~H"""
    <div
      id="navigation-search-dialog"
      data-navigation-search-dialog
      aria-hidden="true"
      class="fixed inset-0 z-[80] hidden"
    >
      <button
        type="button"
        data-navigation-search-close
        tabindex="-1"
        aria-label={gettext("Close navigation search")}
        class="absolute inset-0 bg-neutral-900/30"
      />
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="navigation-search-title"
        class="relative mx-auto mt-[10vh] w-[min(36rem,calc(100vw-2rem))] overflow-hidden rounded-lg bg-white shadow-popover"
      >
        <h2 id="navigation-search-title" class="sr-only">{gettext("Search navigation")}</h2>
        <div class="flex items-center gap-2 border-b border-neutral-200 px-3">
          <.icon name="search" variant="outlined" class="h-4 w-4 shrink-0 text-neutral-400" />
          <input
            type="search"
            data-navigation-search-input
            aria-labelledby="navigation-search-title"
            autocomplete="off"
            placeholder={gettext("Search pages and Agent Swarm sections")}
            class="h-12 min-w-0 flex-1 border-0 bg-transparent px-0 text-sm text-neutral-900 placeholder:text-neutral-400 focus:outline-none focus:ring-0"
          />
          <kbd class="rounded border border-neutral-200 bg-neutral-50 px-1.5 py-0.5 font-sans text-[10px] text-neutral-400">Esc</kbd>
        </div>
        <nav
          class="max-h-[min(28rem,70vh)] overflow-y-auto p-2"
          aria-label={gettext("Navigation search results")}
        >
          <.navigation_search_item label={gettext("My Space")} scope={gettext("Personal")} icon="user" navigate={new_home_path()} />
          <.navigation_search_item :if={@current_org} label={gettext("Overview")} scope={gettext("Workspace")} icon="home" navigate={org_show_path(@current_org)} />
          <.navigation_search_item :if={@current_org} label={gettext("Agent Swarms")} scope={gettext("Workspace")} icon="folder" navigate={org_projects_path(@current_org)} />
          <.navigation_search_item :if={@current_org} label={gettext("Fin")} scope={gettext("Workspace")} icon="zap" navigate={org_fin_path(@current_org)} />
          <.navigation_search_item :if={@current_org && can_view_operations?(@current_org_role)} label={gettext("Operations")} scope={gettext("Workspace")} icon="chart-bar" navigate={org_operations_path(@current_org)} />
          <.navigation_search_item :if={@current_org && triage_workbench_visible?(@current_org_role)} label={gettext("Triage")} scope={gettext("Workspace")} icon="inbox" navigate={org_triage_path(@current_org)} />
          <.navigation_search_item :if={@current_org && can_manage_settings?(@current_org_role)} label={gettext("Meetings")} scope={gettext("Workspace")} icon="calendar" navigate={org_meetings_path(@current_org)} />

          <.navigation_search_item :if={@project && @current_org} label={gettext("Agents")} scope={@project.name} icon="users" navigate={project_agents_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Tasks")} scope={@project.name} icon="chat-bubble" navigate={project_tasks_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Schedules")} scope={@project.name} icon="calendar" navigate={project_schedules_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Plugins")} scope={@project.name} icon="plug" navigate={project_plugins_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Skills")} scope={@project.name} icon="sparkles" navigate={project_skills_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Integrations")} scope={@project.name} icon="cube" navigate={project_integrations_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Connections")} scope={@project.name} icon="attachment" navigate={project_connections_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Devices")} scope={@project.name} icon="bolt" navigate={project_devices_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Websites")} scope={@project.name} icon="globe" navigate={project_websites_path(@current_org, @project)} />
          <.navigation_search_item :if={@project && @current_org} label={gettext("Settings")} scope={@project.name} icon="cog" navigate={project_settings_path(@current_org, @project)} />

          <.navigation_search_item :if={@current_org} label={gettext("Members")} scope={gettext("Administration")} icon="users" navigate={org_members_path(@current_org)} />
          <.navigation_search_item :if={@current_org} label={gettext("Organization plugins")} scope={gettext("Administration")} icon="plug" navigate={org_plugins_path(@current_org)} />
          <.navigation_search_item :if={@current_org && can_manage_settings?(@current_org_role)} label={gettext("Settings")} scope={gettext("Administration")} icon="cog" navigate={org_settings_path(@current_org)} />
          <.navigation_search_item label={gettext("View all organizations")} scope={gettext("Workspace")} icon="building-office" navigate={orgs_path()} />

          <p
            data-navigation-search-empty
            class="hidden px-3 py-8 text-center text-sm text-neutral-500"
          >
            {gettext("No matching navigation destinations")}
          </p>
        </nav>
      </section>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:scope, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)

  defp navigation_search_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      data-navigation-search-item
      data-search-text={String.downcase("#{@scope} #{@label}")}
      class="flex min-h-11 items-center gap-3 rounded-md px-3 py-2 text-sm text-neutral-700 hover:bg-neutral-100 hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand-500"
    >
      <.icon name={@icon} variant="outlined" class="h-4 w-4 shrink-0 text-neutral-500" />
      <span class="min-w-0 flex-1 truncate">{@label}</span>
      <span class="truncate text-xs text-neutral-400">{@scope}</span>
    </.link>
    """
  end

  # ---- Breadcrumbs (rendered inside the work panel, Linear-style) ----

  attr(:breadcrumbs, :list, default: [])

  defp panel_breadcrumbs(assigns) do
    ~H"""
    <header class="sticky top-0 z-10 flex h-11 shrink-0 items-center bg-neutral-50 px-4">
      <nav class="flex items-center gap-1.5 text-[13px]">
        <%= for {{label, path}, idx} <- Enum.with_index(@breadcrumbs) do %>
          <.icon :if={idx > 0} name="chevron-right" class="h-3.5 w-3.5 text-neutral-400" />
          <%= if path do %>
            <.link
              navigate={path}
              class="text-neutral-500 transition-colors duration-100 hover:text-neutral-900"
            >
              {label}
            </.link>
          <% else %>
            <span class="font-medium text-neutral-900">{label}</span>
          <% end %>
        <% end %>
      </nav>
    </header>
    """
  end

  # ---- helpers ----

  defp sidebar_project(assigns) do
    if assigns[:active_nav] == :projects, do: assigns[:project], else: nil
  end

  defp project_nav_active(assigns) do
    tab = assigns[:tab]

    cond do
      assigns[:active_nav] != :projects -> nil
      is_atom(tab) and not is_nil(tab) -> tab
      Map.has_key?(assigns, :agent) -> :agents
      Map.has_key?(assigns, :conversation) -> :tasks
      true -> :agents
    end
  end

  defp nav_icon_class(true, "project"), do: "h-4 w-4 shrink-0 text-brand-600"
  defp nav_icon_class(_active, _tone), do: "h-4 w-4 shrink-0 text-neutral-500"

  defp close_navigation(js, nil), do: js
  defp close_navigation(js, target), do: JS.hide(js, to: target)

  defp org_name(nil), do: gettext("Select org")
  defp org_name(%{name: name}), do: name

  defp user_label(nil), do: gettext("Account")
  defp user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(%{email: email}), do: email

  defp user_initial(nil), do: "?"

  defp user_initial(%{name: name}) when is_binary(name) and name != "",
    do: String.first(name) |> String.upcase()

  defp user_initial(%{email: email}) when is_binary(email),
    do: String.first(email) |> String.upcase()

  defp user_initial(_), do: "?"

  # Routes (kept as plain strings so this module has no compile dep on the
  # router macro; page agents may use ~p in their own modules).
  defp new_home_path, do: "/new-home"
  defp orgs_path, do: "/orgs"
  defp org_show_path(org), do: "/orgs/#{org.slug}"
  defp org_projects_path(org), do: "/orgs/#{org.slug}/projects"
  defp org_fin_path(org), do: "/orgs/#{org.slug}/fin"
  defp org_plugins_path(org), do: "/orgs/#{org.slug}/plugins"
  defp org_operations_path(org), do: "/orgs/#{org.slug}/operations"
  defp org_triage_path(org), do: "/orgs/#{org.slug}/triage"
  defp org_meetings_path(org), do: "/orgs/#{org.slug}/meetings"
  defp org_information_flow_path(org), do: "/orgs/#{org.slug}/information-flow"
  defp org_members_path(org), do: "/orgs/#{org.slug}/members"
  defp org_settings_path(org), do: "/orgs/#{org.slug}/settings"

  defp project_path(org, project), do: "/orgs/#{org.slug}/projects/#{project.id}"

  defp project_agents_path(org, project),
    do: "#{project_path(org, project)}/agents"

  defp project_tasks_path(org, project),
    do: "#{project_path(org, project)}/tasks"

  defp project_schedules_path(org, project),
    do: "#{project_path(org, project)}/schedules"

  defp project_integrations_path(org, project),
    do: "#{project_path(org, project)}/integrations"

  defp project_connections_path(org, project),
    do: "#{project_path(org, project)}/connections"

  defp project_plugins_path(org, project),
    do: "#{project_path(org, project)}/plugins"

  defp project_skills_path(org, project),
    do: "#{project_path(org, project)}/skills"

  defp project_settings_path(org, project),
    do: "#{project_path(org, project)}/settings"

  defp project_devices_path(org, project),
    do: "#{project_path(org, project)}/devices"

  defp project_websites_path(org, project),
    do: "#{project_path(org, project)}/websites"

  defp can_view_operations?(role), do: role in ["owner", "admin"]

  # Triage is a normal owner/admin product surface. Source readiness, channel
  # authority and listening state are enforced inside the Workbench and at
  # ingress; navigation has no second deployment gate.
  defp triage_workbench_visible?(role), do: role in ["owner", "admin"]

  # Mirrors InformationFlowLive's mount guard: the page flips whether a Group
  # refuses effects, so members never see the link.
  defp information_flow_visible?(role), do: role in ["owner", "admin"]

  # Mirrors SettingsLive's mount guard so members never see a link they can't open.
  defp can_manage_settings?(role), do: role in ["owner", "admin"]
end
