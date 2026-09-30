defmodule SalixWeb.Dashboard.Layouts do
  @moduledoc """
  Dashboard layouts: the `root/1` HTML document (links the built assets) and the
  `app/1` shell (sidebar + topbar + `<main>`).

  ## App shell API (page LiveViews set these assigns)

  The `app/1` layout is the LiveView layout (`{Layouts, :app}`). It reads:

    * `@active_nav`  — atom marking the active sidebar item
      (`:home | :cluster | :tenants | :templates | :groups | :initial_agents |
        :agents | :environments | :im | :oauth | :composio | :drive | :cloud_vm | :voice | :signal | :config`)
    * `@breadcrumbs` — list of `{label, path | nil}` for the topbar; default `[]`
    * `@flash`       — the flash map (always present in LiveView)

  Page LiveViews assign `:active_nav` and `:breadcrumbs` in `mount/3` (sensible
  defaults are applied here when missing).
  """
  use SalixWeb.Dashboard, :html

  embed_templates("layouts/*")

  # Built assets are served by Plug.Static mounted at `/dash`, so their URLs
  # carry the `/dash` prefix. `static_path/1` applies the prod digest (via the
  # cache manifest) and is a no-op in dev; we prepend the mount prefix. Using a
  # helper instead of `~p"/dash/assets/..."` avoids a verified-routes warning,
  # since the sigil cannot model a prefixed static mount.
  defp dash_static(path), do: "/dash" <> SalixWeb.DashboardEndpoint.static_path(path)

  @doc "App shell layout for LiveViews (sidebar + topbar + main)."
  attr(:flash, :map, default: %{})
  attr(:active_nav, :atom, default: nil)
  attr(:breadcrumbs, :list, default: [])
  attr(:current_tenant, :string, default: nil)
  attr(:tenants, :list, default: [])
  attr(:inner_content, :any, default: nil)
  slot(:inner_block)

  def app(assigns) do
    ~H"""
    <div
      id="dash-shell"
      phx-hook="BrowserLocalTime"
      class="flex h-screen w-full overflow-hidden bg-white text-neutral-900"
    >
      <div id="dash-navigation" phx-hook="ResponsiveNavigation" class="contents">
        <button
          id="dash-navigation-backdrop"
          type="button"
          tabindex="-1"
          aria-label="Close navigation"
          class="hidden fixed inset-0 z-40 bg-neutral-900/30 lg:hidden"
        />
        <.sidebar active_nav={@active_nav} current_tenant={@current_tenant} tenants={@tenants} />
      </div>
      <div id="dash-content" class="flex min-w-0 flex-1 flex-col">
        <.topbar breadcrumbs={@breadcrumbs} />
        <main class="relative min-h-0 min-w-0 flex-1 overflow-y-auto">
          <div class="mx-auto max-w-6xl px-4 py-6 sm:px-6">
            {@inner_content || render_slot(@inner_block)}
          </div>
        </main>
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  # ---- Sidebar ----

  attr(:active_nav, :atom, default: nil)
  attr(:current_tenant, :string, default: nil)
  attr(:tenants, :list, default: [])

  defp sidebar(assigns) do
    assigns =
      assign(
        assigns,
        :current_tenant_label,
        tenant_label(assigns.tenants, assigns.current_tenant)
      )

    ~H"""
    <aside
      id="dash-sidebar"
      aria-label="Dashboard navigation"
      tabindex="-1"
      class="hidden fixed inset-y-0 left-0 z-50 w-60 max-w-[calc(100vw-2rem)] shrink-0 flex-col border-r border-neutral-200 bg-neutral-50 lg:static lg:flex lg:max-w-none"
    >
      <div class="flex items-center gap-2 px-3 pt-3">
        <div class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-brand-500 text-sm font-semibold text-white">
          S
        </div>
        <span class="text-sm font-semibold text-neutral-800">Salix Admin</span>
        <button id="dash-navigation-close" type="button" aria-label="Close navigation" class="ml-auto rounded p-1 text-neutral-600 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500 lg:hidden">
          <.icon name="x-mark" class="h-5 w-5" />
        </button>
      </div>

      <div class="px-2 pb-1 pt-2">
        <.dropdown
          id="tenant-switcher"
          class="w-full"
          menu_class="w-full max-w-full max-h-[calc(100vh-7rem)] overflow-y-auto"
        >
          <:trigger>
            <div class="flex w-full items-center justify-between rounded-md border border-neutral-200 bg-white px-2 py-1.5 hover:bg-neutral-50">
              <div class="flex min-w-0 items-center gap-2">
                <.icon name="building-office" class="h-3.5 w-3.5 text-neutral-400" />
                <span class="truncate text-xs font-medium text-neutral-700">{@current_tenant_label}</span>
              </div>
              <.icon name="chevron-down" class="h-3.5 w-3.5 text-neutral-400" />
            </div>
          </:trigger>
          <p class="px-3 pb-1 pt-1 text-[10px] font-medium uppercase tracking-wide text-neutral-400">
            Tenant
          </p>
          <.dropdown_item
            :for={t <- @tenants}
            href={"/dash/tenant/select?tenant_id=#{t["tenant_id"]}"}
            class={t["tenant_id"] == @current_tenant && "bg-neutral-50 font-medium text-neutral-900"}
          >
            <span class="flex min-w-0 items-center gap-2">
              <span class="flex h-3.5 w-3.5 shrink-0 items-center justify-center">
                <.icon :if={t["tenant_id"] == @current_tenant} name="check" class="h-3.5 w-3.5" />
              </span>
              <span class="min-w-0 truncate">{t["name"] || t["tenant_id"]}</span>
            </span>
          </.dropdown_item>
          <.link
            navigate="/dash/tenants"
            class="block border-t border-neutral-100 px-3 py-1.5 text-sm text-neutral-500 hover:bg-neutral-50"
          >
            Manage tenants
          </.link>
        </.dropdown>
      </div>

      <nav aria-label="Main navigation" class="min-h-0 flex-1 space-y-0.5 overflow-y-auto px-2">
        <.nav_item label="Home" icon="home" navigate="/dash" active={@active_nav == :home} />
        <.nav_item label="Cluster" icon="server" navigate="/dash/cluster" active={@active_nav == :cluster} />
        <.nav_item label="Tenants" icon="building-office" navigate="/dash/tenants" active={@active_nav == :tenants} />
        <.nav_item label="Subscription Proxy" icon="key" navigate="/dash/account-pool" active={@active_nav == :account_pool} />
        <.nav_item label="Templates" icon="template" navigate="/dash/templates" active={@active_nav == :templates} />
        <.nav_item label="Agent Groups" icon="folder" navigate="/dash/groups" active={@active_nav == :groups} />
        <.nav_item label="Initial Agents" icon="cube" navigate="/dash/initial-agents" active={@active_nav == :initial_agents} />
        <.nav_item label="Agents" icon="cube" navigate="/dash/agents" active={@active_nav == :agents} />
        <.nav_item label="Trajectory Evals" icon="chart-bar" navigate="/dash/trajectory-evals" active={@active_nav == :trajectory_evals} />
        <.nav_item label="Runtime Health" icon="pulse" navigate="/dash/runtime" active={@active_nav == :runtime} />
        <.nav_item label="Devices" icon="bolt" navigate="/dash/environments" active={@active_nav == :environments} />
        <.nav_item label="Compute Nodes" icon="server" navigate="/dash/compute-nodes" active={@active_nav == :compute_nodes} />
        <.nav_item label="IM" icon="chat" navigate="/dash/im" active={@active_nav == :im} />
        <.nav_item label="MCP" icon="plug" navigate="/dash/mcp" active={@active_nav == :mcp} />
        <.nav_item label="Plugins" icon="cube" navigate="/dash/plugins" active={@active_nav == :plugins} />
        <.nav_item label="OAuth Apps" icon="key" navigate="/dash/oauth" active={@active_nav == :oauth} />
        <.nav_item label="Browser Run" icon="globe-alt" navigate="/dash/browser" active={@active_nav == :browser} />
        <.nav_item label="Composio" icon="bolt" navigate="/dash/composio" active={@active_nav == :composio} />
        <.nav_item label="Drive" icon="folder" navigate="/dash/drive" active={@active_nav == :drive} />
        <.nav_item
          label="Cloud VM"
          icon="server"
          navigate="/dash/cloud-vm"
          active={@active_nav == :cloud_vm}
        />
        <.nav_item label="Voice" icon="chat" navigate="/dash/voice" active={@active_nav == :voice} />
        <.nav_item label="Signal" icon="chat" navigate="/dash/signal" active={@active_nav == :signal} />
        <.nav_item label="Config" icon="cog" navigate="/dash/agent-defaults" active={@active_nav == :config} />
        <.nav_item label="LiveDashboard" icon="server" navigate="/dash/live-dashboard" active={@active_nav == :live_dashboard} />
      </nav>

      <div class="border-t border-neutral-200 p-2">
        <.link
          href="/dash/logout"
          method="delete"
          class="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900"
        >
          <.icon name="logout" class="h-4 w-4" />
          <span>Sign out</span>
        </.link>
      </div>
    </aside>
    """
  end

  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)
  attr(:active, :boolean, default: false)

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm",
        @active && "bg-neutral-200/60 font-medium text-neutral-900",
        !@active && "text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900"
      ]}
    >
      <.icon name={@icon} class="h-4 w-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  # ---- Topbar ----

  attr(:breadcrumbs, :list, default: [])

  defp topbar(assigns) do
    ~H"""
    <header class="flex h-11 shrink-0 items-center justify-between border-b border-neutral-200 px-4">
      <button
        id="dash-navigation-toggle"
        type="button"
        aria-label="Open navigation"
        aria-controls="dash-sidebar"
        aria-expanded="false"
        class="mr-2 shrink-0 rounded p-1 text-neutral-600 focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand-500 lg:hidden"
      >
        <span class="text-sm font-medium">Menu</span>
      </button>
      <nav aria-label="Breadcrumb" class="flex min-w-0 flex-1 items-center gap-1.5 overflow-x-auto whitespace-nowrap text-sm">
        <%= for {{label, path}, idx} <- Enum.with_index(@breadcrumbs) do %>
          <.icon :if={idx > 0} name="chevron-right" class="h-3.5 w-3.5 text-neutral-300" />
          <%= if path do %>
            <.link navigate={path} class="text-neutral-500 hover:text-neutral-900">{label}</.link>
          <% else %>
            <span class="font-medium text-neutral-900">{label}</span>
          <% end %>
        <% end %>
      </nav>
    </header>
    """
  end

  # Display name for the active tenant, falling back to the id.
  defp tenant_label(_tenants, nil), do: "No tenant"

  defp tenant_label(tenants, tenant_id) do
    case Enum.find(tenants, &(&1["tenant_id"] == tenant_id)) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> tenant_id
    end
  end
end
