defmodule BridgeForTeamsWeb.Dashboard.FinLive.Index do
  @moduledoc """
  Organization Fin runner management page (`/orgs/:org/fin`).

  The fleet is visible to every organization member. Owners and admins can
  onboard runners and manage runner-scoped credentials from this page.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Auth, Environments, MacMiniOnboarding, Memberships, Orgs}
  alias BridgeForTeamsWeb.MacMiniRelease
  alias Phoenix.LiveView.JS

  @fin_fleet_refresh_interval_ms 5_000
  @fin_fleet_page_limit 25
  @bft_agent_skill_path Path.expand(
                          "../../../../../priv/bft-operator/SKILL.md",
                          __DIR__
                        )
  @external_resource @bft_agent_skill_path
  @bft_agent_skill File.read!(@bft_agent_skill_path)

  @impl true
  def mount(%{"org" => slug}, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id) do
      can_manage_fin = can_manage_fin?(org_role)

      {:ok,
       socket
       |> assign(:page_title, gettext("Fin"))
       |> assign(:active_nav, :fin)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:can_manage_fin, can_manage_fin)
       |> assign(:orgs, orgs)
       |> assign(:breadcrumbs, [{org.name, ~p"/orgs/#{org.slug}"}, {gettext("Fin"), nil}])
       |> assign(:mac_mini_cursor, nil)
       |> assign(:mac_mini_next_cursor, nil)
       |> assign(:mac_mini_total_count, 0)
       |> assign(:expanded_runner_id, nil)
       |> assign(:runner_connector_status_counts_by_runner_id, %{})
       |> assign(:fin_fleet_refresh_ref, nil)
       |> assign(:runner_panel_open, false)
       |> assign(:runner_onboarding_mode, "manual")
       |> assign(:runner_pending_delete, nil)
       |> assign(:mac_mini_install_command, nil)
       |> assign(:mac_mini_api_keys, [])
       |> assign(:runner_credentials_by_stable_id, %{})
       |> assign(:mac_mini_onboarding, can_manage_fin && mac_mini_onboarding(org))
       |> assign_mac_minis()
       |> maybe_assign_mac_mini_api_keys()
       |> schedule_fin_fleet_refresh()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_mac_minis(socket, params)}
  end

  @impl true
  def handle_info(:refresh_fin_mac_minis, socket) do
    {:noreply,
     socket
     |> assign(:fin_fleet_refresh_ref, nil)
     |> assign_mac_minis()
     |> schedule_fin_fleet_refresh()}
  end

  @impl true
  def handle_event("open-runner-onboarding", _params, socket) do
    if socket.assigns.can_manage_fin do
      {:noreply,
       socket
       |> assign(:runner_panel_open, true)
       |> assign(:runner_onboarding_mode, "manual")}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage runners."))}
    end
  end

  def handle_event("close-runner-onboarding", _params, socket) do
    {:noreply,
     socket
     |> assign(:runner_panel_open, false)
     |> assign(:runner_onboarding_mode, "manual")
     |> assign(:mac_mini_install_command, nil)}
  end

  def handle_event("select-runner-onboarding-mode", %{"mode" => mode}, socket)
      when mode in ["manual", "agent"] do
    if socket.assigns.can_manage_fin do
      {:noreply, assign(socket, :runner_onboarding_mode, mode)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create-mac-mini-runner-key", _params, socket) do
    org = socket.assigns.current_org

    if socket.assigns.can_manage_fin do
      with {:ok, server_build_id} <- MacMiniRelease.server_build_id(),
           result <-
             MacMiniOnboarding.create_install_code(
               org.id,
               audit_opts(socket) ++
                 [
                   created_by_id: socket.assigns.current_user.id,
                   wrapper_url: mac_mini_wrapper_url(org),
                   server_build_id: server_build_id
                 ]
             ) do
        case result do
          {:ok, %{command: command}} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext(
                 "Runner install command created. It expires in 15 minutes and can be used once."
               )
             )
             |> assign(:runner_panel_open, true)
             |> assign(:mac_mini_install_command, command)
             |> assign_mac_mini_api_keys()}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Couldn't create the runner install command (%{reason}).",
                 reason: describe_error(reason)
               )
             )}
        end
      else
        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Server release is unavailable."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage runners."))}
    end
  end

  def handle_event("revoke-mac-mini-runner-key", %{"id" => key_id}, socket) do
    org = socket.assigns.current_org

    if socket.assigns.can_manage_fin do
      with :ok <- ensure_mac_mini_api_key(org.id, key_id),
           {:ok, _api_key} <- Auth.revoke_api_key(org.id, key_id, audit_opts(socket)) do
        {:noreply,
         socket
         |> put_flash(:info, gettext("Runner API key revoked."))
         |> assign_mac_mini_api_keys()}
      else
        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Runner API key not found."))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't revoke the runner API key (%{reason}).",
               reason: describe_error(reason)
             )
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage runners."))}
    end
  end

  def handle_event(
        "rotate-mac-mini-runner-key",
        %{"id" => key_id, "stable-id" => stable_id},
        socket
      ) do
    org = socket.assigns.current_org

    if socket.assigns.can_manage_fin do
      audit_opts = audit_opts(socket)

      with {:ok, server_build_id} <- MacMiniRelease.server_build_id(),
           :ok <- ensure_mac_mini_api_key(org.id, key_id),
           {:ok, _revoked} <- Auth.revoke_api_key(org.id, key_id, audit_opts),
           {:ok, %{command: command}} <-
             MacMiniOnboarding.create_install_code(
               org.id,
               audit_opts ++
                 [
                   created_by_id: socket.assigns.current_user.id,
                   wrapper_url: mac_mini_wrapper_url(org),
                   server_build_id: server_build_id,
                   runner_stable_id: stable_id,
                   audit_metadata: %{"rotated_key_id" => key_id}
                 ]
             ) do
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Runner API key revoked. A one-time install command is ready for the host.")
         )
         |> assign(:runner_panel_open, true)
         |> assign(:mac_mini_install_command, command)
         |> assign_mac_mini_api_keys()}
      else
        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Runner API key not found."))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Couldn't rotate the runner API key (%{reason}).",
               reason: describe_error(reason)
             )
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage runners."))}
    end
  end

  def handle_event("request-remove-runner", %{"id" => runner_id}, socket) do
    if socket.assigns.can_manage_fin do
      runner = Enum.find(socket.assigns.mac_minis, &(&1.id == runner_id))
      {:noreply, assign(socket, :runner_pending_delete, runner)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can manage runners."))}
    end
  end

  def handle_event("cancel-remove-runner", _params, socket),
    do: {:noreply, assign(socket, :runner_pending_delete, nil)}

  def handle_event("toggle-runner-details", %{"id" => runner_id}, socket) do
    if Enum.any?(socket.assigns.mac_minis, &(&1.id == runner_id)) do
      if socket.assigns.expanded_runner_id == runner_id do
        {:noreply,
         socket
         |> assign(:expanded_runner_id, nil)
         |> assign(:runner_connector_page, empty_runner_connector_page())}
      else
        {:noreply,
         socket
         |> assign(:expanded_runner_id, runner_id)
         |> assign_runner_connector_page(runner_id, nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("page-runner-connectors", %{"id" => runner_id} = params, socket) do
    page = socket.assigns.runner_connector_page

    case {socket.assigns.expanded_runner_id == runner_id, params["direction"]} do
      {true, "first"} ->
        {:noreply, assign_runner_connector_page(socket, runner_id, nil)}

      {true, "next"} when is_binary(page.next_cursor) ->
        {:noreply, assign_runner_connector_page(socket, runner_id, page.next_cursor)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm-remove-runner", _params, socket) do
    org = socket.assigns.current_org

    with true <- socket.assigns.can_manage_fin,
         %{id: runner_id} <- socket.assigns.runner_pending_delete,
         {:ok, _runner} <- MacMiniOnboarding.remove_runner(org.id, runner_id, audit_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Runner removed and its access revoked."))
       |> assign(:runner_pending_delete, nil)
       |> assign_mac_minis()
       |> assign_mac_mini_api_keys()}
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can manage runners."))}

      nil ->
        {:noreply, assign(socket, :runner_pending_delete, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Couldn't remove the runner (%{reason}).", reason: describe_error(reason))
         )
         |> assign(:runner_pending_delete, nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-lg font-semibold tracking-tight text-neutral-950">{gettext("Fin")}</h1>
          <p class="mt-1 max-w-2xl text-sm leading-6 text-neutral-500">
            {gettext("Manage the runner fleet that executes work for %{name}.", name: @current_org.name)}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.button
            :if={@can_manage_fin}
            id="add-fin-runner"
            type="button"
            variant="primary"
            size="sm"
            phx-click="open-runner-onboarding"
          >
            <.icon name="plus" class="mr-1 h-3.5 w-3.5" />
            {gettext("Add runner")}
          </.button>
        </div>
      </header>

      <section aria-labelledby="fin-runners-heading">
        <div class="mb-3 flex items-end justify-between gap-4">
          <div>
            <h2 id="fin-runners-heading" class="text-sm font-semibold text-neutral-950">
              {gettext("Runners")}
            </h2>
            <p class="mt-1 text-xs text-neutral-500">
              {gettext("Heartbeat, host, version, and capacity for every registered machine.")}
            </p>
          </div>
          <span class="text-xs tabular-nums text-neutral-500">
            {ngettext("%{count} runner", "%{count} runners", @mac_mini_total_count)}
          </span>
        </div>

        <div :if={@mac_minis == []} id="fin-mac-minis-empty" class="border-y border-neutral-200 py-12">
          <.empty_state
            icon="bolt"
            title={gettext("No runners connected")}
            description={gettext("Add a runner to execute Fin workloads for this organization.")}
          >
            <:actions>
              <.button
                :if={@can_manage_fin}
                id="add-fin-runner-empty"
                type="button"
                variant="primary"
                size="sm"
                phx-click="open-runner-onboarding"
              >
                {gettext("Add runner")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <div :if={@mac_minis != []} id="fin-mac-minis" class="divide-y divide-neutral-200 border-y border-neutral-200">
          <article
            :for={runner <- @mac_minis}
            id={"fin-runner-#{runner.id}"}
            class="py-2"
          >
            <% connector_status_counts =
              Map.get(@runner_connector_status_counts_by_runner_id, runner.id, []) %>
            <% connector_count = Enum.sum(Enum.map(connector_status_counts, &elem(&1, 1))) %>
            <% runner_expanded = @expanded_runner_id == runner.id %>
            <% connector_page =
              if runner_expanded, do: @runner_connector_page, else: empty_runner_connector_page() %>
            <% runner_keys = Map.get(@runner_credentials_by_stable_id, runner.stable_id, []) %>
            <% active_key = Enum.find(runner_keys, &is_nil(&1.revoked_at)) %>

            <header class="flex min-w-0 items-start gap-2">
              <h3 class="min-w-0 flex-1">
                <button
                  id={"fin-runner-toggle-#{runner.id}"}
                  type="button"
                  class="min-h-12 w-full cursor-pointer rounded-md px-2 py-2 text-left transition-colors duration-150 hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1"
                  phx-click="toggle-runner-details"
                  phx-value-id={runner.id}
                  aria-expanded={to_string(runner_expanded)}
                  aria-controls={"fin-runner-details-#{runner.id}"}
                >
                  <span class="sr-only">
                    {if runner_expanded,
                      do: gettext("Collapse %{runner}", runner: provisioner_name(runner)),
                      else: gettext("Expand %{runner}", runner: provisioner_name(runner))}
                  </span>
                  <span class="grid min-w-0 gap-2 sm:grid-cols-[minmax(14rem,1fr)_auto] sm:items-center sm:gap-4">
                    <span class="min-w-0">
                      <span class="flex min-w-0 items-center gap-2">
                        <span class={[
                          "h-2 w-2 shrink-0 rounded-full",
                          runner_status_dot_class(provisioner_status(runner))
                        ]} />
                        <span class="truncate text-sm font-medium text-neutral-950" title={provisioner_name(runner)}>
                          {provisioner_name(runner)}
                        </span>
                      </span>
                      <span class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 pl-4 text-xs text-neutral-500">
                        <code>{runner.stable_id}</code>
                        <.status_pill status={provisioner_status(runner)} />
                        <span :if={runner.status != provisioner_status(runner)}>
                          {gettext("reported %{status}", status: runner.status)}
                        </span>
                      </span>
                    </span>
                    <span class="flex min-w-0 flex-wrap items-center gap-x-4 gap-y-1 text-xs text-neutral-500 sm:justify-end">
                      <span class="whitespace-nowrap">
                        {gettext("Capacity")}
                        <span class="ml-1 font-medium tabular-nums text-neutral-800">{provisioner_capacity(runner)}</span>
                      </span>
                      <span class="whitespace-nowrap">
                        {gettext("Connectors")}
                        <span class="ml-1 font-medium tabular-nums text-neutral-800">{connector_count}</span>
                      </span>
                      <span :if={connector_status_counts != []}>{gettext("Provisioning")}</span>
                      <.status_pill
                        :for={{status, count} <- connector_status_counts}
                        status={status}
                        label={"#{count} #{connector_assignment_status_label(status)}"}
                      />
                      <.icon
                        name="chevron-down"
                        variant="outlined"
                        class={"h-4 w-4 shrink-0 text-neutral-400 transition-transform duration-150 #{if runner_expanded, do: "rotate-180", else: ""}"}
                      />
                    </span>
                  </span>
                </button>
              </h3>
              <.button
                :if={@can_manage_fin}
                type="button"
                variant="danger"
                size="sm"
                phx-click="request-remove-runner"
                phx-value-id={runner.id}
              >
                {gettext("Remove")}
              </.button>
            </header>

            <div
              id={"fin-runner-details-#{runner.id}"}
              hidden={!runner_expanded}
              class={[
                "gap-4 px-2 pb-2 pt-3 lg:grid-cols-[minmax(14rem,1.15fr)_minmax(0,2fr)_auto] lg:items-center",
                runner_expanded && "grid"
              ]}
            >
              <dl class="grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-4 lg:col-span-2">
                <.runner_fact
                  label={gettext("Host")}
                  value={blank_dash(runner.host_identity)}
                  detail={blank_dash(runner.os_summary)}
                />
                <.runner_fact
                  label={gettext("Capacity")}
                  value={provisioner_capacity(runner)}
                  detail={gettext("connectors")}
                />
                <.runner_fact
                  label={gettext("Version")}
                  value={blank_dash(runner.version)}
                  detail={component_versions(runner.capabilities)}
                  warning={salix_connect_update_available?(runner)}
                />
                <.runner_fact
                  label={gettext("Last seen")}
                  value={last_seen_age(runner)}
                  detail={format_datetime(runner.last_seen_at)}
                />
              </dl>

              <div class="flex flex-wrap items-center justify-end gap-2 lg:max-w-64">
                <span class="mr-auto text-xs text-neutral-500 lg:mr-0">
                  <%= if active_key do %>
                    {gettext("Access active")}
                  <% else %>
                    {gettext("No active credential")}
                  <% end %>
                </span>
                <.button
                  :if={@can_manage_fin and active_key}
                  type="button"
                  variant="secondary"
                  size="sm"
                  phx-click="rotate-mac-mini-runner-key"
                  phx-value-id={active_key.id}
                  phx-value-stable-id={runner.stable_id}
                >
                  {gettext("Rotate access")}
                </.button>
              </div>

              <div
                id={"fin-runner-connectors-#{runner.id}"}
                class="border-t border-neutral-100 pt-3 lg:col-span-3"
              >
                <div class="mb-2 flex items-center gap-2">
                  <h4 class="text-xs font-medium text-neutral-700">{gettext("Connectors")}</h4>
                  <span class="text-xs tabular-nums text-neutral-500">{connector_count}</span>
                </div>
                <p :if={connector_count == 0} class="text-xs text-neutral-500">
                  {gettext("No connectors assigned to this runner.")}
                </p>
                <div :if={connector_page.entries != []} class="divide-y divide-neutral-100 rounded-md bg-neutral-50 px-3">
                  <div
                    :for={connector <- connector_page.entries}
                    id={"fin-runner-connector-#{connector.id}"}
                    class="grid gap-2 py-2.5 sm:grid-cols-[minmax(10rem,1fr)_minmax(12rem,1fr)] sm:items-start sm:gap-6"
                  >
                    <div class="min-w-0">
                      <div class="flex min-w-0 items-center gap-2">
                        <span class="truncate text-xs font-medium text-neutral-900" title={runner_connector_name(connector)}>
                          {runner_connector_name(connector)}
                        </span>
                        <span class="text-xs text-neutral-500">{gettext("Provisioning")}</span>
                        <.status_pill
                          status={connector.provisioning_status}
                          label={connector_assignment_status_label(connector.provisioning_status)}
                        />
                      </div>
                    </div>
                    <div class="flex min-w-0 items-center text-xs">
                      <span class="shrink-0 text-neutral-500">{gettext("Agent Swarm")}</span>
                      <.link
                        navigate={~p"/orgs/#{@current_org.slug}/projects/#{connector.project_id}"}
                        class="ml-1 min-w-0 truncate font-medium text-brand-700 hover:underline focus-visible:underline"
                        title={connector.project_name}
                      >
                        {connector.project_name}
                      </.link>
                    </div>
                  </div>
                </div>
                <div
                  :if={connector_page.cursor || connector_page.next_cursor}
                  class="mt-3 flex items-center gap-3 text-xs font-medium text-brand-700"
                >
                  <button
                    :if={connector_page.cursor}
                    type="button"
                    phx-click="page-runner-connectors"
                    phx-value-id={runner.id}
                    phx-value-direction="first"
                    class="hover:underline"
                  >
                    {gettext("First connectors")}
                  </button>
                  <button
                    :if={connector_page.next_cursor}
                    type="button"
                    phx-click="page-runner-connectors"
                    phx-value-id={runner.id}
                    phx-value-direction="next"
                    class="hover:underline"
                  >
                    {gettext("Next connectors")}
                  </button>
                </div>
              </div>
            </div>
          </article>
        </div>

        <.fleet_pagination
          :if={@mac_minis != []}
          org={@current_org}
          current_cursor={@mac_mini_cursor}
          next_cursor={@mac_mini_next_cursor}
          current_count={length(@mac_minis)}
          total_count={@mac_mini_total_count}
        />
      </section>

      <.runner_onboarding_panel
        :if={@can_manage_fin and @runner_panel_open}
        command={@mac_mini_install_command}
        mode={@runner_onboarding_mode}
        onboarding={@mac_mini_onboarding}
      />

      <.modal
        :if={@runner_pending_delete}
        id="remove-runner-modal"
        show
        on_cancel={JS.push("cancel-remove-runner")}
      >
        <:title>{gettext("Remove runner")}</:title>
        <p class="text-sm text-neutral-600">
          {gettext("Remove %{name}? Its API access will be revoked and the runner will disappear from this organization. This does not remove local files from the host.",
            name: provisioner_name(@runner_pending_delete)
          )}
        </p>
        <div class="mt-5 flex items-center justify-end gap-2">
          <.button type="button" phx-click="cancel-remove-runner">{gettext("Cancel")}</.button>
          <.button type="button" variant="danger" phx-click="confirm-remove-runner">
            {gettext("Remove")}
          </.button>
        </div>
      </.modal>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:detail, :string, default: nil)
  attr(:warning, :boolean, default: false)

  defp runner_fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-[11px] font-medium text-neutral-500">{@label}</dt>
      <dd class={["mt-0.5 break-words text-xs font-medium", @warning && "text-amber-700", !@warning && "text-neutral-800"]}>
        {@value}
      </dd>
      <dd :if={@detail not in [nil, "", "—"]} class="mt-0.5 break-words text-[11px] leading-4 text-neutral-500">
        {@detail}
      </dd>
      <dd :if={@warning} class="mt-0.5 text-[11px] font-medium text-amber-700">
        {gettext("Update available")}
      </dd>
    </div>
    """
  end

  attr(:command, :string, default: nil)
  attr(:mode, :string, required: true)
  attr(:onboarding, :map, required: true)

  defp runner_onboarding_panel(assigns) do
    ~H"""
    <.side_panel
      id="fin-runner-onboarding"
      show
      size="xl"
      on_cancel={JS.push("close-runner-onboarding")}
    >
      <:title>{gettext("Add runner")}</:title>

      <div
        class="mb-6 inline-flex w-fit rounded-md bg-neutral-100 p-0.5"
        role="tablist"
        aria-label={gettext("Runner onboarding method")}
      >
        <button
          type="button"
          id="runner-onboarding-mode-manual"
          role="tab"
          aria-selected={to_string(@mode == "manual")}
          aria-controls="runner-onboarding-manual"
          phx-click="select-runner-onboarding-mode"
          phx-value-mode="manual"
          class={runner_onboarding_mode_class(@mode == "manual")}
        >
          {gettext("Manual commands")}
        </button>
        <button
          type="button"
          id="runner-onboarding-mode-agent"
          role="tab"
          aria-selected={to_string(@mode == "agent")}
          aria-controls="runner-onboarding-agent"
          phx-click="select-runner-onboarding-mode"
          phx-value-mode="agent"
          class={runner_onboarding_mode_class(@mode == "agent")}
        >
          {gettext("Use local agent")}
        </button>
      </div>

      <div :if={@mode == "manual"} id="runner-onboarding-manual" class="space-y-7">
        <section aria-labelledby="runner-install-heading">
          <div class="flex gap-3">
            <span class="grid h-7 w-7 shrink-0 place-items-center rounded-full bg-brand-50 text-xs font-semibold text-brand-700">1</span>
            <div class="min-w-0 flex-1">
              <h3 id="runner-install-heading" class="text-sm font-semibold text-neutral-950">
                {gettext("Install or update")}
              </h3>
              <p class="mt-1 text-sm leading-6 text-neutral-600">
                {gettext("Generate a one-time command, then run it on the target Mac. Re-running the installer safely converges existing components to the published release.")}
              </p>

              <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
                <div class="rounded-md border border-neutral-200 px-3 py-2">
                  <dt class="text-neutral-500">{gettext("Organization ID")}</dt>
                  <dd class="mt-1 break-all font-mono text-neutral-900">{@onboarding.org_id}</dd>
                </div>
                <div class="rounded-md border border-neutral-200 px-3 py-2">
                  <dt class="text-neutral-500">{gettext("API base")}</dt>
                  <dd class="mt-1 break-all font-mono text-neutral-900">{@onboarding.api_base_url}</dd>
                </div>
              </dl>

              <div class="mt-3 flex flex-wrap items-center gap-3">
                <.button
                  type="button"
                  variant="primary"
                  size="sm"
                  phx-click="create-mac-mini-runner-key"
                  phx-disable-with={gettext("Generating...")}
                >
                  {if @command, do: gettext("Generate another command"), else: gettext("Generate command")}
                </.button>
                <span class="text-xs text-neutral-500">
                  {gettext("Expires after 15 minutes and works once.")}
                </span>
              </div>

              <div
                :if={is_nil(@command)}
                id="mac-mini-runner-install-command-placeholder"
                class="mt-3 rounded-md border border-dashed border-neutral-300 bg-neutral-50 px-3 py-4 text-xs leading-5 text-neutral-500"
              >
                {gettext("The durable runner credential is created only when the target machine consumes this command.")}
              </div>

              <div :if={@command} class="mt-3">
                <div
                  id="mac-mini-install-code-once"
                  role="status"
                  class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800"
                >
                  {gettext("This install code expires in 15 minutes and can be used once.")}
                </div>
                <div class="mt-2 flex items-center justify-between gap-2">
                  <span class="text-xs font-medium text-neutral-700">{gettext("Install command")}</span>
                  <button
                    type="button"
                    id="copy-mac-mini-runner-install-command"
                    phx-hook="CopyToClipboard"
                    data-copy-target="#mac-mini-runner-install-command"
                    class="rounded-md px-2 py-1 text-xs font-medium text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900"
                  >
                    {gettext("Copy")}
                  </button>
                </div>
                <pre
                  id="mac-mini-runner-install-command"
                  class="mt-1 max-h-56 overflow-auto rounded-md bg-neutral-950 px-3 py-3 text-xs leading-5 text-neutral-100"
                ><code>{@command}</code></pre>
              </div>
            </div>
          </div>
        </section>

        <section
          :for={{step, index} <- Enum.with_index(primary_local_steps(@onboarding), 2)}
          aria-labelledby={"runner-step-#{step.id}"}
          class="flex gap-3 border-t border-neutral-200 pt-6"
        >
          <span class="grid h-7 w-7 shrink-0 place-items-center rounded-full bg-neutral-100 text-xs font-semibold text-neutral-700">
            {index}
          </span>
          <div class="min-w-0 flex-1">
            <h3 id={"runner-step-#{step.id}"} class="text-sm font-semibold text-neutral-950">{step.title}</h3>
            <p class="mt-1 text-sm leading-6 text-neutral-600">{step.description}</p>
            <div class="mt-2 flex items-center justify-between gap-2">
              <span class="text-xs font-medium text-neutral-500">{gettext("Run on the target Mac")}</span>
              <button
                type="button"
                id={"copy-mac-mini-local-step-#{step.id}"}
                phx-hook="CopyToClipboard"
                data-copy-target={"#mac-mini-local-command-#{step.id}"}
                class="rounded-md px-2 py-1 text-xs font-medium text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900"
              >
                {gettext("Copy")}
              </button>
            </div>
            <pre
              id={"mac-mini-local-command-#{step.id}"}
              class="mt-1 overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-xs leading-5 text-neutral-900"
            ><code>{step.command}</code></pre>
          </div>
        </section>

        <details id="mac-mini-advanced-commands" class="rounded-md border border-neutral-200">
          <summary class="cursor-pointer px-3 py-2 text-sm font-medium text-neutral-800">
            {gettext("Advanced diagnostics")}
          </summary>
          <div class="space-y-4 border-t border-neutral-200 p-3">
            <div :for={step <- advanced_local_steps(@onboarding)}>
              <div class="flex items-start justify-between gap-2">
                <div>
                  <h3 class="text-xs font-semibold text-neutral-900">{step.title}</h3>
                  <p class="mt-1 text-xs leading-5 text-neutral-500">{step.description}</p>
                </div>
                <button
                  type="button"
                  id={"copy-mac-mini-local-step-#{step.id}"}
                  phx-hook="CopyToClipboard"
                  data-copy-target={"#mac-mini-local-command-#{step.id}"}
                  class="rounded-md px-2 py-1 text-xs font-medium text-neutral-600 hover:bg-neutral-100"
                >
                  {gettext("Copy")}
                </button>
              </div>
              <pre
                id={"mac-mini-local-command-#{step.id}"}
                class="mt-2 overflow-x-auto rounded-md bg-neutral-950 px-3 py-2 text-xs leading-5 text-neutral-100"
              ><code>{step.command}</code></pre>
            </div>

            <dl class="grid gap-2 text-xs sm:grid-cols-2">
              <.path_fact label={gettext("Config")} value={@onboarding.config_path} />
              <.path_fact label={gettext("Install status")} value={@onboarding.install_status_path} />
              <.path_fact label={gettext("Worker status")} value={@onboarding.worker_status_path} />
              <.path_fact label={gettext("Logs")} value={@onboarding.logs_dir} />
            </dl>
          </div>
        </details>
      </div>

      <div :if={@mode == "agent"} id="runner-onboarding-agent" class="space-y-5">
        <div class="rounded-md border border-brand-200 bg-brand-50 px-3 py-3">
          <h3 class="text-sm font-semibold text-brand-950">{gettext("Let your local agent operate BFT")}</h3>
          <p class="mt-1 text-sm leading-6 text-brand-800">
            {gettext("Copy the handoff into an agent running on the target Mac. You approve browser login and every change; the handoff contains no credential or one-time install code.")}
          </p>
        </div>

        <section aria-labelledby="bft-agent-handoff-heading">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h3 id="bft-agent-handoff-heading" class="text-sm font-semibold text-neutral-950">
                {gettext("Agent handoff")}
              </h3>
              <p class="mt-1 text-xs leading-5 text-neutral-500">
                {gettext("Includes this API and organization, plus the safe CLI discovery flow.")}
              </p>
            </div>
            <button
              type="button"
              id="copy-bft-agent-handoff"
              phx-hook="CopyToClipboard"
              data-copy-target="#bft-agent-handoff"
              class="shrink-0 rounded-md border border-neutral-300 bg-white px-2 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100"
            >
              {gettext("Copy")}
            </button>
          </div>
          <pre
            id="bft-agent-handoff"
            class="mt-2 max-h-72 overflow-auto rounded-md bg-neutral-950 px-3 py-3 text-xs leading-5 text-neutral-100"
          ><code>{@onboarding.agent_handoff}</code></pre>
        </section>

        <section aria-labelledby="bft-agent-skill-heading" class="border-t border-neutral-200 pt-5">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h3 id="bft-agent-skill-heading" class="text-sm font-semibold text-neutral-950">
                {gettext("Reusable BFT Skill")}
              </h3>
              <p class="mt-1 text-xs leading-5 text-neutral-500">
                {gettext("Paste it directly or save it as SKILL.md in your local agent.")}
              </p>
            </div>
            <button
              type="button"
              id="copy-bft-agent-skill"
              phx-hook="CopyToClipboard"
              data-copy-target="#bft-agent-skill"
              class="shrink-0 rounded-md border border-neutral-300 bg-white px-2 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100"
            >
              {gettext("Copy")}
            </button>
          </div>
          <pre
            id="bft-agent-skill"
            class="mt-2 max-h-72 overflow-auto rounded-md border border-neutral-200 bg-neutral-50 px-3 py-3 text-xs leading-5 text-neutral-900"
          ><code>{@onboarding.agent_skill}</code></pre>
        </section>
      </div>

      <:footer>
        <.button type="button" phx-click="close-runner-onboarding">{gettext("Close")}</.button>
      </:footer>
    </.side_panel>
    """
  end

  defp runner_onboarding_mode_class(active?) do
    [
      "h-8 rounded px-3 text-xs font-medium transition-colors",
      active? && "bg-white text-neutral-900 shadow-subtle",
      !active? && "text-neutral-500 hover:text-neutral-800"
    ]
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp path_fact(assigns) do
    ~H"""
    <div class="min-w-0 rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2">
      <dt class="text-neutral-500">{@label}</dt>
      <dd class="mt-1 truncate font-mono text-neutral-900" title={@value}>{@value}</dd>
    </div>
    """
  end

  attr(:org, :map, required: true)
  attr(:current_cursor, :string, default: nil)
  attr(:next_cursor, :string, default: nil)
  attr(:current_count, :integer, required: true)
  attr(:total_count, :integer, required: true)

  defp fleet_pagination(assigns) do
    ~H"""
    <div class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <p class="text-xs text-neutral-500">
        {gettext("Showing %{count} of %{total} runners",
          count: @current_count,
          total: @total_count
        )}
      </p>
      <div class="flex items-center gap-3">
        <.link
          :if={@current_cursor}
          patch={fin_path(@org, %{})}
          class="text-sm font-medium text-neutral-600 hover:text-brand-700 hover:underline"
        >
          {gettext("First page")}
        </.link>
        <.link
          :if={@next_cursor}
          patch={fin_path(@org, %{"cursor" => @next_cursor})}
          class="text-sm font-medium text-brand-700 hover:underline"
        >
          {gettext("Next runners")}
        </.link>
      </div>
    </div>
    """
  end

  defp assign_mac_minis(socket, params \\ nil) do
    org_id = socket.assigns.current_org.id
    cursor = mac_mini_cursor(socket, params)
    page = page_mac_minis(org_id, cursor)
    runner_ids = Enum.map(page.entries, & &1.id)

    runner_connector_status_counts_by_runner_id =
      Environments.runner_connector_assignment_status_counts(
        org_id,
        runner_ids,
        socket.assigns.current_user.id
      )

    expanded_runner_id =
      if socket.assigns.expanded_runner_id in runner_ids,
        do: socket.assigns.expanded_runner_id

    socket
    |> assign(:mac_minis, page.entries)
    |> assign(
      :runner_connector_status_counts_by_runner_id,
      runner_connector_status_counts_by_runner_id
    )
    |> assign(:expanded_runner_id, expanded_runner_id)
    |> assign(:mac_mini_cursor, page.cursor)
    |> assign(:mac_mini_next_cursor, page.next_cursor)
    |> assign(:mac_mini_total_count, page.total_count)
    |> reload_expanded_runner_connector_page()
  end

  defp reload_expanded_runner_connector_page(%{assigns: %{expanded_runner_id: nil}} = socket),
    do: assign(socket, :runner_connector_page, empty_runner_connector_page())

  defp reload_expanded_runner_connector_page(socket),
    do:
      assign_runner_connector_page(
        socket,
        socket.assigns.expanded_runner_id,
        socket.assigns.runner_connector_page.cursor
      )

  defp assign_runner_connector_page(socket, runner_id, cursor) do
    page =
      Environments.page_runner_connector_assignments(
        socket.assigns.current_org.id,
        runner_id,
        socket.assigns.current_user.id,
        after: cursor
      )

    assign(socket, :runner_connector_page, page)
  end

  defp empty_runner_connector_page, do: %{entries: [], cursor: nil, next_cursor: nil}

  defp maybe_assign_mac_mini_api_keys(%{assigns: %{can_manage_fin: true}} = socket),
    do: assign_mac_mini_api_keys(socket)

  defp maybe_assign_mac_mini_api_keys(socket), do: socket

  defp assign_mac_mini_api_keys(socket) do
    org_id = socket.assigns.current_org.id

    api_keys =
      org_id
      |> Auth.list_api_keys()
      |> Enum.filter(&mac_mini_api_key?/1)

    credentials_by_stable_id =
      org_id
      |> MacMiniOnboarding.list_runner_credentials()
      |> Enum.group_by(& &1.stable_id, & &1.api_key)

    socket
    |> assign(:mac_mini_api_keys, api_keys)
    |> assign(:runner_credentials_by_stable_id, credentials_by_stable_id)
  end

  defp mac_mini_onboarding(org) do
    api_base_url = dashboard_base_url() |> String.trim_trailing("/")
    install_prefix = "$HOME/.bridge-for-teams"
    state_dir = "$HOME/.bridge-for-teams/state"
    runner_path = Path.join(install_prefix, "bin/bft-runner")
    config_path = Path.join(install_prefix, "runner.json")
    install_status_path = Path.join(install_prefix, "runner-install-status.json")
    worker_status_path = Path.join(state_dir, "runner-status.json")
    logs_dir = Path.join(state_dir, "logs")

    local_steps =
      [
        %{
          id: "doctor",
          title: gettext("Check local posture"),
          description:
            gettext("Run a no-secret preflight before starting a long-running worker."),
          command: "#{shell_path(runner_path)} doctor"
        },
        %{
          id: "foreground",
          title: gettext("Smoke in the foreground"),
          description:
            gettext("Start the worker and confirm that this page receives a fresh heartbeat."),
          command: shell_path(runner_path)
        },
        %{
          id: "launchd",
          title: gettext("Make the runner persistent"),
          description: gettext("After the smoke succeeds, start the managed login service."),
          command: "#{shell_path(runner_path)} service start"
        },
        %{
          id: "status-logs",
          title: gettext("Inspect status and logs"),
          description: gettext("Read the local worker state and redacted logs for diagnostics."),
          command: "#{shell_path(runner_path)} status\n#{shell_path(runner_path)} logs"
        }
      ]

    %{
      org_id: org.id,
      api_base_url: api_base_url,
      agent_handoff: bft_agent_handoff(api_base_url, org.id),
      agent_skill: @bft_agent_skill,
      config_path: display_home_path(config_path),
      install_status_path: display_home_path(install_status_path),
      worker_status_path: display_home_path(worker_status_path),
      logs_dir: display_home_path(logs_dir),
      local_steps: local_steps
    }
  end

  defp bft_agent_handoff(api_base_url, org_id) do
    """
    Help me connect and operate a BFT runner from this Mac.

    Target API base: #{api_base_url}
    Target organization: #{org_id}

    Use the installed bft CLI as the source of truth. Start by running:
    bft commands --json
    bft agent help overview --json
    bft agent help auth --json
    bft agent help runners --json
    bft agent help output --json

    If bft is missing, explain that first and ask before running:
    curl -fsSL #{shell_path(api_base_url <> "/v1/cli/install.sh")} | sh

    Check auth status. If login is needed, run:
    bft auth login --url #{shell_path(api_base_url)} --output text
    Then wait for me to approve the browser device flow. Never print or copy a persisted token.

    Inspect the target organization and existing runners before changing anything. Before every command marked mutating, tell me the exact target and effect and wait for explicit approval. Use --confirm-mutating when the command metadata or help requires it, and only after I approve. After approval, create exactly one runner install command and execute it immediately; do not generate a second one just to inspect the response. Treat the returned command as a secret: execute it locally without repeating it in chat or logs.

    Ask whether I want a temporary foreground runner or the persistent login service. Do not run both. Verify local status and a recent online heartbeat with bft runners list before reporting success.
    """
    |> String.trim()
  end

  defp primary_local_steps(onboarding),
    do: Enum.filter(onboarding.local_steps, &(&1.id in ~w(doctor foreground launchd)))

  defp advanced_local_steps(onboarding),
    do: Enum.filter(onboarding.local_steps, &(&1.id == "status-logs"))

  defp ensure_mac_mini_api_key(org_id, key_id) do
    if org_id
       |> Auth.list_api_keys()
       |> Enum.any?(&(&1.id == key_id and mac_mini_api_key?(&1))) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp mac_mini_api_key?(api_key) do
    Enum.any?(api_key.scopes || [], &(&1 in ["*", "runners:*", "runners:write"]))
  end

  defp provisioner_name(%{name: name, stable_id: stable_id}) do
    cond do
      is_binary(name) and name != "" -> name
      is_binary(stable_id) and stable_id != "" -> stable_id
      true -> gettext("Runner")
    end
  end

  defp runner_connector_name(connector), do: connector.env_alias || connector.name

  defp connector_assignment_status_label("pending"), do: gettext("pending")
  defp connector_assignment_status_label("preflight"), do: gettext("preflight")
  defp connector_assignment_status_label("preflight_complete"), do: gettext("preflight complete")
  defp connector_assignment_status_label("starting_connector"), do: gettext("starting connector")

  defp connector_assignment_status_label("waiting_for_attach"),
    do: gettext("waiting for connector attach")

  defp connector_assignment_status_label("connected"), do: gettext("connected")
  defp connector_assignment_status_label("stop_requested"), do: gettext("stop requested")
  defp connector_assignment_status_label("stopping"), do: gettext("stopping")
  defp connector_assignment_status_label("stopped"), do: gettext("stopped")
  defp connector_assignment_status_label("failed"), do: gettext("failed")
  defp connector_assignment_status_label(status), do: status

  defp provisioner_capacity(%{capacity: capacity, current_connector_count: current}),
    do: "#{current || 0} / #{capacity || 0}"

  defp provisioner_status(%{effective_status: status}) when is_binary(status) and status != "",
    do: status

  defp provisioner_status(%{status: status}) when is_binary(status) and status != "", do: status
  defp provisioner_status(_), do: "unknown"

  defp runner_status_dot_class("online"), do: "bg-green-500"

  defp runner_status_dot_class(status) when status in ["recently_lost", "degraded"],
    do: "bg-amber-500"

  defp runner_status_dot_class("offline"), do: "bg-red-500"
  defp runner_status_dot_class(_), do: "bg-neutral-400"

  defp component_versions(capabilities), do: MacMiniRelease.component_versions_label(capabilities)

  defp salix_connect_update_available?(runner) do
    target = MacMiniRelease.updates(nil, runner)["salix-connect"]

    MacMiniRelease.component_update_available?(runner.capabilities, "salix-connect", target)
  end

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(_), do: "—"

  defp last_seen_age(%{last_seen_age_seconds: nil}), do: gettext("never seen")
  defp last_seen_age(%{last_seen_age_seconds: seconds}), do: last_seen_age(seconds)

  defp last_seen_age(seconds) when is_integer(seconds) and seconds < 60,
    do: ngettext("%{count}s ago", "%{count}s ago", seconds)

  defp last_seen_age(seconds) when is_integer(seconds) and seconds < 3600 do
    minutes = div(seconds, 60)
    ngettext("%{count}m ago", "%{count}m ago", minutes)
  end

  defp last_seen_age(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    ngettext("%{count}h ago", "%{count}h ago", hours)
  end

  defp last_seen_age(_), do: gettext("never seen")

  defp page_mac_minis(org_id, cursor) do
    page =
      Environments.page_mac_mini_provisioners(org_id,
        limit: @fin_fleet_page_limit,
        after: cursor
      )

    if page.entries == [] and page.total_count > 0 and cursor not in [nil, ""] do
      org_id
      |> Environments.page_mac_mini_provisioners(limit: @fin_fleet_page_limit)
      |> Map.put(:cursor, nil)
    else
      Map.put(page, :cursor, cursor)
    end
  end

  defp schedule_fin_fleet_refresh(socket) do
    if connected?(socket) and is_nil(socket.assigns.fin_fleet_refresh_ref) do
      assign(
        socket,
        :fin_fleet_refresh_ref,
        Process.send_after(self(), :refresh_fin_mac_minis, @fin_fleet_refresh_interval_ms)
      )
    else
      socket
    end
  end

  defp can_manage_fin?(role), do: role in ["owner", "admin"]

  defp mac_mini_cursor(_socket, %{"cursor" => cursor}) when is_binary(cursor) and cursor != "",
    do: cursor

  defp mac_mini_cursor(%{assigns: %{mac_mini_cursor: cursor}}, _params), do: cursor
  defp mac_mini_cursor(_socket, _params), do: nil

  defp fin_path(org, params), do: ~p"/orgs/#{org.slug}/fin?#{compact_query_params(params)}"

  defp compact_query_params(params),
    do: Map.reject(params, fn {_key, value} -> value in [nil, ""] end)

  defp mac_mini_wrapper_url(org) do
    dashboard_base_url()
    |> String.trim_trailing("/")
    |> then(&(&1 <> "/v1/orgs/#{org.id}/runners/install.sh"))
  end

  defp dashboard_base_url do
    case Application.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> dashboard_endpoint_base_url()
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

  defp shell_path("$HOME/" <> rest), do: ~s("$HOME/#{escape_double_quotes(rest)}")
  defp shell_path(path), do: ~s("#{escape_double_quotes(path)}")

  defp display_home_path("$HOME/" <> rest), do: "~/" <> rest
  defp display_home_path(path), do: path

  defp escape_double_quotes(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp blank_dash(value) when is_binary(value) and value != "", do: value
  defp blank_dash(_value), do: "—"
  defp describe_error(:unavailable), do: gettext("runtime unavailable")
  defp describe_error(:timeout), do: gettext("runtime timed out")
  defp describe_error(reason), do: inspect(reason)
end
