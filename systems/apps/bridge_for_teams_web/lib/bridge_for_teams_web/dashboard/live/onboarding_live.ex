defmodule BridgeForTeamsWeb.Dashboard.OnboardingLive do
  @moduledoc """
  First-run onboarding (`/onboarding`): a three-step full-screen flow shown to
  users who have not finished it yet (`Dashboard.Auth :require_onboarded` gates
  every other dashboard surface).

  Steps are live_actions so each is URL-addressable — the Composio Connect
  round trip on the integrations step leaves the app entirely and must land
  back on `/onboarding/integrations` (passed as the Connect Link's
  `callback_url`; a legacy Salix OAuth callback may still append
  `?oauth_error=…` on failure):

    1. `:capabilities`  — grant agent capabilities (grouped toggles).
    2. `:profile`       — review the generated user model (identity + real org
                          contacts; behavioral sections framed as forward-looking
                          plans gated on the real connection set).
    3. `:integrations`  — connect third-party toolkits through Composio-hosted
                          Connect Links via
                          `ProjectComposioConnections.start_connection/5`.
                          Composio-only by design: the org opts in once with an
                          API key (or rides the platform default) instead of
                          configuring per-provider OAuth apps. Continuing
                          from this step completes onboarding.

  Owned by slice "orgs-shell".
  """
  use BridgeForTeamsWeb.Dashboard, :onboarding_live_view

  require Logger

  alias BridgeForTeams.{
    Memberships,
    Orgs,
    ProjectComposioConnections,
    ProjectIMConnects,
    Projects,
    UserOnboardings
  }

  alias BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog

  import BridgeForTeamsWeb.Dashboard.BrandLogos, only: [brand_logo: 1]

  @steps ~w(capabilities profile integrations)
  @max_contacts 4

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case UserOnboardings.ensure_onboarding(user.id) do
      {:ok, %{status: status}} when status in ["completed", "skipped"] ->
        {:ok, redirect(socket, to: ~p"/")}

      {:ok, onboarding} ->
        orgs = Orgs.list_orgs_for_user(user.id)
        current_org = List.first(orgs)
        if current_org, do: ensure_default_swarm(current_org, user)

        {:ok,
         socket
         |> assign(:page_title, gettext("Welcome"))
         |> assign(:onboarding, onboarding)
         |> assign(:current_org, current_org)
         |> assign(:current_org_role, org_role(current_org, user.id))
         |> assign(:org_members, org_members(current_org, user.id))
         |> assign(
           :capabilities,
           Map.merge(Catalog.default_capabilities(), onboarding.capabilities)
         )
         |> assign(:project, nil)
         |> assign(:can_connect, false)
         |> assign(:composio_configured, false)
         |> assign(:connections, [])
         |> assign(:im_connects, [])
         |> assign(:integrations_loaded, false)
         |> assign(:integrations_unavailable, false)
         |> assign(:resumed, false)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Something went wrong. Please try again."))
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    step = socket.assigns.live_action

    socket =
      socket
      |> assign(:step, step)
      |> assign(:current_url, uri)
      |> maybe_flash_oauth_outcome(params)

    case maybe_resume(socket, step) do
      {:resume, socket, path} -> {:noreply, push_patch(socket, to: path)}
      {:stay, socket} -> {:noreply, load_step(socket, step)}
    end
  end

  # On the bare `/onboarding` entry, jump to the step the user previously
  # reached — but only on the first params pass, so Back navigation works.
  defp maybe_resume(%{assigns: %{resumed: false}} = socket, :capabilities) do
    stored = resume_step(socket.assigns.onboarding.current_step)
    socket = assign(socket, :resumed, true)

    if stored in @steps and stored != "capabilities" do
      {:resume, socket, step_path(stored)}
    else
      {:stay, socket}
    end
  end

  defp maybe_resume(socket, _step), do: {:stay, assign(socket, :resumed, true)}

  # A record stored on the retired fourth step ("tasks") had already passed
  # integrations, so it resumes on integrations, whose Continue now finishes.
  defp resume_step("tasks"), do: "integrations"
  defp resume_step(step), do: step

  # The profile step frames what the agent will learn against the *real*
  # connection set, so it loads the same integration snapshot the later steps
  # use (best-effort; a Salix hiccup just leaves the plans in their pre-connect
  # phrasing).
  defp load_step(socket, :profile), do: load_integrations(socket)
  defp load_step(socket, :integrations), do: load_integrations(socket)
  defp load_step(socket, _step), do: socket

  # The Salix OAuth callback returns the browser here, appending
  # `?oauth_error=...` only on failure (a success just shows up as connected).
  defp maybe_flash_oauth_outcome(socket, %{"oauth_error" => reason})
       when is_binary(reason) and reason != "" do
    put_flash(socket, :error, gettext("We couldn't connect that account. Please try again."))
  end

  defp maybe_flash_oauth_outcome(socket, _params), do: socket

  # ---- events: capabilities --------------------------------------------------

  @impl true
  def handle_event("toggle_capability", %{"key" => key}, socket) do
    capabilities = Map.update(socket.assigns.capabilities, key, true, &(!&1))
    {:noreply, assign(socket, :capabilities, capabilities)}
  end

  def handle_event("toggle_group", %{"group" => group_key}, socket) do
    keys =
      Catalog.capability_groups()
      |> Enum.find(%{capabilities: []}, &(&1.key == group_key))
      |> Map.fetch!(:capabilities)
      |> Enum.map(& &1.key)

    all_on? = Enum.all?(keys, &(socket.assigns.capabilities[&1] == true))
    capabilities = Enum.reduce(keys, socket.assigns.capabilities, &Map.put(&2, &1, not all_on?))
    {:noreply, assign(socket, :capabilities, capabilities)}
  end

  def handle_event("save_capabilities", _params, socket) do
    with {:ok, onboarding} <-
           UserOnboardings.put_capabilities(
             socket.assigns.onboarding,
             socket.assigns.capabilities
           ),
         {:ok, onboarding} <- UserOnboardings.advance(onboarding, "profile") do
      {:noreply,
       socket
       |> assign(:onboarding, onboarding)
       |> push_patch(to: ~p"/onboarding/profile")}
    else
      {:error, _reason} -> {:noreply, save_failed(socket)}
    end
  end

  # ---- events: profile ---------------------------------------------------------

  def handle_event("save_profile", _params, socket) do
    with {:ok, onboarding} <-
           UserOnboardings.put_profile(socket.assigns.onboarding, build_profile(socket)),
         {:ok, onboarding} <- UserOnboardings.advance(onboarding, "integrations") do
      {:noreply,
       socket
       |> assign(:onboarding, onboarding)
       |> push_patch(to: ~p"/onboarding/integrations")}
    else
      {:error, _reason} -> {:noreply, save_failed(socket)}
    end
  end

  # ---- events: integrations ----------------------------------------------------

  def handle_event("connect_toolkit", %{"toolkit" => toolkit}, socket) do
    %{current_org: org, project: project, current_user: user} = socket.assigns

    cond do
      is_nil(org) or is_nil(project) ->
        {:noreply,
         put_flash(socket, :error, gettext("Create an Agent Swarm first to connect accounts."))}

      not can_connect?(socket) ->
        {:noreply,
         put_flash(socket, :error, gettext("Only this swarm's owners can connect accounts."))}

      true ->
        # Composio hosts the whole consent flow; the Connect Link returns the
        # browser to this step via callback_url once the account is connected.
        attrs = %{"callback_url" => oauth_redirect_after(socket)}

        case ProjectComposioConnections.start_connection(org.id, project.id, toolkit, attrs,
               actor_user_id: user.id,
               actor_label: user.email || user.id
             ) do
          {:ok, %{"redirect_url" => url}} when is_binary(url) and url != "" ->
            {:noreply, redirect(socket, external: url)}

          {:ok, _payload} ->
            {:noreply, put_flash(socket, :error, connect_error_message(:no_redirect_url))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, connect_error_message(reason))}
        end
    end
  end

  def handle_event("integrations_continue", _params, socket) do
    case UserOnboardings.complete(socket.assigns.onboarding) do
      {:ok, _onboarding} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You're all set."))
         |> redirect(to: ~p"/")}

      {:error, _reason} ->
        {:noreply, save_failed(socket)}
    end
  end

  def handle_event("skip_onboarding", _params, socket) do
    case UserOnboardings.skip(socket.assigns.onboarding) do
      {:ok, _onboarding} ->
        {:noreply, redirect(socket, to: ~p"/")}

      {:error, _reason} ->
        {:noreply, save_failed(socket)}
    end
  end

  # ---- data loading ---------------------------------------------------------------

  defp load_integrations(%{assigns: %{integrations_loaded: true}} = socket), do: socket

  defp load_integrations(socket) do
    org = socket.assigns.current_org
    user = socket.assigns.current_user
    project = default_project(org, user)

    {configured?, connections, im_connects, unavailable?} =
      if org && project do
        configured? = ProjectComposioConnections.configured?(org.id)

        im_connects =
          case ProjectIMConnects.list_project_connects(org.id, project.id) do
            {:ok, connects} -> connects
            {:error, _reason} -> []
          end

        if configured? do
          case ProjectComposioConnections.list_connections(org.id, project.id) do
            {:ok, connections} -> {true, connections, im_connects, false}
            {:error, :not_configured} -> {false, [], im_connects, false}
            {:error, _reason} -> {true, [], im_connects, true}
          end
        else
          {false, [], im_connects, false}
        end
      else
        {false, [], [], false}
      end

    socket
    |> assign(:project, project)
    |> assign(:can_connect, can_connect?(user, project))
    |> assign(:composio_configured, configured?)
    |> assign(:connections, connections)
    |> assign(:im_connects, im_connects)
    |> assign(:integrations_unavailable, unavailable?)
    |> assign(:integrations_loaded, true)
  end

  # The swarm this user's onboarding acts on: the same default-swarm
  # resolution the dashboard uses (owned project first, then any membership,
  # then the org-first-project fallback reserved for org owners/admins —
  # never "any org project"). A plain org member with no project grants gets
  # `nil` and sees no integrations instead of connecting accounts into
  # someone else's swarm.
  defp default_project(nil, _user), do: nil

  defp default_project(org, user), do: Projects.default_project_for_user(org.id, user.id)

  # A user entering first-run onboarding gets a swarm of their OWN when they
  # don't already own one: the integrations step needs a project for its
  # connections to land in. Idempotent (an owned swarm short-circuits) and
  # best-effort: a failed create leaves the integrations step empty rather
  # than blocking onboarding.
  defp ensure_default_swarm(org, user) do
    case Projects.ensure_owned_project(org.id, user.id, default_swarm_name(user)) do
      {:ok, _project} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "onboarding_default_swarm_failed org_id=#{org.id} user_id=#{user.id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp default_swarm_name(user) do
    case user.name do
      name when is_binary(name) and name != "" ->
        gettext("%{name}'s Swarm", name: name)

      _no_name ->
        gettext("My Swarm")
    end
  end

  defp org_role(nil, _user_id), do: nil

  defp org_role(org, user_id) do
    case Memberships.org_role(org.id, user_id) do
      {:ok, role} -> role
      _ -> nil
    end
  end

  defp org_members(nil, _user_id), do: []

  defp org_members(org, user_id) do
    org.id
    |> Memberships.list_org_members()
    |> Enum.reject(&(&1.user_id == user_id))
    |> Enum.take(@max_contacts)
  end

  # Connected platforms in the Catalog's provider vocabulary ("google",
  # "github", …) — Composio toolkit slugs for Google services collapse onto
  # "google" so the profile plans and starter-task templates keep matching.
  defp connected_providers(connections) do
    connections
    |> Enum.filter(&ProjectComposioConnections.connection_active?/1)
    |> Enum.map(&catalog_provider(ProjectComposioConnections.connection_toolkit(&1)))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp catalog_provider(slug) when slug in ["gmail", "googlecalendar", "googledrive"],
    do: "google"

  defp catalog_provider(slug), do: slug

  defp connection_for(connections, toolkit) do
    Enum.find(connections, fn account ->
      ProjectComposioConnections.connection_toolkit(account) == toolkit and
        ProjectComposioConnections.connection_active?(account)
    end)
  end

  defp build_profile(socket) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org

    %{
      "identity" => %{
        "name" => user.name,
        "email" => user.email,
        "role" => socket.assigns.current_org_role,
        "org" => org && org.name
      },
      "key_contacts" =>
        Enum.map(socket.assigns.org_members, fn member ->
          %{
            "name" => member.user.name,
            "email" => member.user.email,
            "role" => member.role
          }
        end),
      "work_patterns" => plan_state(socket, "google"),
      "communication_style" => plan_state(socket, "google"),
      "writing_style" => plan_state(socket, "google"),
      "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # A behavioral section is a forward-looking plan: "learning" once its source is
  # actually connected, otherwise "planned" (waiting on the connection). We never
  # claim to have learned anything we have no data for.
  defp plan_state(socket, provider) do
    connected = MapSet.member?(connected_providers(socket.assigns.connections), provider)
    %{"status" => if(connected, do: "learning", else: "planned"), "source" => provider}
  end

  defp save_failed(socket),
    do: put_flash(socket, :error, gettext("Could not save. Please try again."))

  # Connecting integrations is a SWARM-scoped action (Composio connections and
  # IM connects bind to the project), so the gate is the effective project
  # role, not the org role: a swarm owner who is only a regular org member may
  # connect their own swarm's accounts. `Memberships.project_role/2` already
  # merges the explicit ACL with the implied admin org owners/admins hold.
  defp can_connect?(%Phoenix.LiveView.Socket{} = socket),
    do: can_connect?(socket.assigns.current_user, socket.assigns.project)

  defp can_connect?(_user, nil), do: false

  defp can_connect?(user, project),
    do: match?({:ok, "admin"}, Memberships.project_role(project.id, user.id))

  # Precomputed per-toolkit row state for the integrations step. Composio is
  # org-wide (one API key), so readiness is a single flag, not per-platform.
  defp toolkit_rows(connections, configured?, can_connect?) do
    Enum.map(ProjectComposioConnections.toolkits(), fn toolkit ->
      connection = connection_for(connections, toolkit)

      state =
        cond do
          connection -> :connected
          configured? and can_connect? -> :connectable
          configured? -> :ask_admin
          true -> :unconfigured
        end

      %{toolkit: toolkit, state: state}
    end)
  end

  defp oauth_redirect_after(socket) do
    case socket.assigns[:current_url] do
      url when is_binary(url) and url != "" ->
        url |> URI.parse() |> Map.put(:query, nil) |> Map.put(:fragment, nil) |> URI.to_string()

      _ ->
        nil
    end
  end

  defp connect_error_message(:group_not_ready),
    do: gettext("The runtime is not ready yet. Retry shortly.")

  defp connect_error_message(:not_configured),
    do: gettext("Composio isn't configured for your organization yet.")

  defp connect_error_message({:bad_request, _}),
    do: gettext("The platform rejected the connection request.")

  defp connect_error_message(reason) when reason in [:unavailable, :timeout],
    do: gettext("Salix is unavailable right now. Retry shortly.")

  defp connect_error_message(_reason),
    do: gettext("Could not connect the account. Please try again.")

  defp step_path("capabilities"), do: ~p"/onboarding"
  defp step_path("profile"), do: ~p"/onboarding/profile"
  defp step_path("integrations"), do: ~p"/onboarding/integrations"

  defp prev_path(:profile), do: ~p"/onboarding"
  defp prev_path(:integrations), do: ~p"/onboarding/profile"
  defp prev_path(_step), do: nil

  defp step_index(step), do: Enum.find_index(@steps, &(&1 == Atom.to_string(step))) || 0
  defp step_indexes, do: 0..(length(@steps) - 1)

  defp group_on?(capabilities, group),
    do: Enum.any?(group.capabilities, &(capabilities[&1.key] == true))

  # ---- render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col">
      <div class="mb-6 flex items-center justify-center gap-1.5" aria-hidden="true">
        <span
          :for={index <- step_indexes()}
          class={[
            "h-1.5 rounded-full transition-all",
            index == step_index(@step) && "w-6 bg-neutral-800",
            index != step_index(@step) && "w-1.5 bg-neutral-300"
          ]}
        >
        </span>
      </div>

      <.capabilities_step :if={@step == :capabilities} capabilities={@capabilities} />
      <.profile_step
        :if={@step == :profile}
        current_user={@current_user}
        current_org={@current_org}
        current_org_role={@current_org_role}
        org_members={@org_members}
        connected_providers={connected_providers(@connections)}
      />
      <.integrations_step
        :if={@step == :integrations}
        current_org={@current_org}
        project={@project}
        toolkit_rows={toolkit_rows(@connections, @composio_configured, @can_connect)}
        composio_configured={@composio_configured}
        im_connects={@im_connects}
        unavailable={@integrations_unavailable}
        can_connect={@can_connect}
      />

      <div class="mt-6 flex items-center justify-between pb-8">
        <div class="flex items-center gap-3">
          <.button :if={prev_path(@step)} variant="ghost" patch={prev_path(@step)}>
            <.icon name="arrow-left" class="h-3.5 w-3.5" />
            {gettext("Back")}
          </.button>
          <button
            phx-click="skip_onboarding"
            data-confirm={gettext("Skip onboarding? You can revisit these settings later.")}
            class="text-xs text-neutral-400 hover:text-neutral-600"
          >
            {gettext("Skip onboarding")}
          </button>
        </div>

        <div class="flex items-center gap-2">
          <.button :if={@step == :capabilities} variant="primary" phx-click="save_capabilities">
            {gettext("Continue")}
            <.icon name="chevron-right" class="h-3.5 w-3.5" />
          </.button>
          <.button :if={@step == :profile} variant="primary" phx-click="save_profile">
            {gettext("Continue")}
            <.icon name="chevron-right" class="h-3.5 w-3.5" />
          </.button>
          <.button :if={@step == :integrations} variant="secondary" phx-click="integrations_continue">
            {gettext("Skip for now")}
          </.button>
          <.button :if={@step == :integrations} variant="primary" phx-click="integrations_continue">
            {gettext("Continue")}
            <.icon name="chevron-right" class="h-3.5 w-3.5" />
          </.button>
        </div>
      </div>
    </div>
    """
  end

  # ---- step 1: capabilities ----

  attr(:capabilities, :map, required: true)

  defp capabilities_step(assigns) do
    ~H"""
    <div class="rounded-xl border border-neutral-200 bg-white shadow-subtle">
      <div class="border-b border-neutral-200 px-6 py-5">
        <h1 class="text-lg font-semibold">{gettext("What may your agent do for you?")}</h1>
        <p class="mt-1 text-sm text-neutral-500">
          {gettext("Toggle any on or off — you can change these later.")}
        </p>
      </div>

      <div class="divide-y divide-neutral-200/70 px-6">
        <section :for={group <- Catalog.capability_groups()} class="py-4">
          <div class="flex items-center justify-between gap-3">
            <div class="flex min-w-0 items-center gap-2.5">
              <.icon name={group.icon} class="h-4 w-4 shrink-0 text-neutral-500" />
              <div class="min-w-0">
                <div class="text-[13px] font-semibold text-neutral-900">{group.title}</div>
                <div class="truncate text-xs text-neutral-500">{group.description}</div>
              </div>
            </div>
            <.toggle
              name={"group-" <> group.key}
              checked={group_on?(@capabilities, group)}
              phx-click="toggle_group"
              phx-value-group={group.key}
            />
          </div>

          <div class="mt-1.5 pl-1">
            <label
              :for={capability <- group.capabilities}
              class="flex cursor-pointer items-start gap-3 rounded-md px-2 py-2 hover:bg-neutral-50"
            >
              <input
                type="checkbox"
                checked={@capabilities[capability.key] == true}
                phx-click="toggle_capability"
                phx-value-key={capability.key}
                class="mt-0.5 h-4 w-4 rounded border-neutral-300 text-brand-500 focus:ring-brand-500"
              />
              <span class="min-w-0">
                <span class={[
                  "block text-sm",
                  (@capabilities[capability.key] == true && "text-neutral-800") || "text-neutral-500"
                ]}>
                  {capability.label}
                </span>
                <span class="block text-xs text-neutral-400">{capability.description}</span>
              </span>
            </label>
          </div>
        </section>
      </div>
      <div class="h-5"></div>
    </div>
    """
  end

  # ---- step 2: profile ----

  attr(:current_user, :any, required: true)
  attr(:current_org, :any, required: true)
  attr(:current_org_role, :string, default: nil)
  attr(:org_members, :list, default: [])
  attr(:connected_providers, :any, default: MapSet.new())

  defp profile_step(assigns) do
    assigns =
      assign(assigns, :google_connected?, MapSet.member?(assigns.connected_providers, "google"))

    ~H"""
    <div class="rounded-xl border border-neutral-200 bg-white shadow-subtle">
      <div class="border-b border-neutral-200 px-6 py-5">
        <h1 class="text-lg font-semibold">{profile_heading(@current_user)}</h1>
        <p class="mt-1 text-sm text-neutral-500">
          {gettext("Here's the model your agent starts from. It sharpens as you work together.")}
        </p>
      </div>

      <div class="space-y-5 px-6 py-5">
        <section>
          <h2 class="text-sm font-semibold text-neutral-900">{gettext("Professional Identity")}</h2>
          <ul class="mt-2 space-y-1.5 text-sm text-neutral-700">
            <li class="flex items-start gap-2">
              <.icon name="check" class="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand-600" />
              <span>{identity_line(@current_user, @current_org_role, @current_org)}</span>
            </li>
            <li :if={@current_user.email} class="flex items-start gap-2">
              <.icon name="check" class="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand-600" />
              <span>{gettext("Signs in as %{email}", email: @current_user.email)}</span>
            </li>
            <li :if={@current_org} class="flex items-start gap-2">
              <.icon name="check" class="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand-600" />
              <span>
                {ngettext(
                  "Works with %{count} teammate in %{org}",
                  "Works with %{count} teammates in %{org}",
                  length(@org_members),
                  count: length(@org_members),
                  org: @current_org.name
                )}
              </span>
            </li>
          </ul>
        </section>

        <section>
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold text-neutral-900">{gettext("Key Contacts Sample")}</h2>
          </div>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext(
              "The teammates in your organization your agent can already address by name."
            )}
          </p>
          <div :if={@org_members != []} class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div
              :for={member <- @org_members}
              class="rounded-md bg-neutral-100 px-3 py-2.5"
            >
              <div class="flex items-center gap-2.5">
                <div class="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-100 text-[11px] font-semibold text-brand-700">
                  {member_initial(member)}
                </div>
                <div class="min-w-0">
                  <div class="truncate text-sm font-medium text-neutral-800">
                    {member_label(member)}
                  </div>
                  <div class="truncate text-xs text-neutral-500">{member.user.email}</div>
                </div>
                <.badge color="neutral" class="ml-auto shrink-0">{member.role}</.badge>
              </div>
            </div>
          </div>
          <p :if={@org_members == []} class="mt-3 text-xs text-neutral-400">
            {gettext("No teammates yet — contacts appear here as your organization grows.")}
          </p>
        </section>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <.plan_section
            title={gettext("Work Patterns")}
            connected={@google_connected?}
            connected_desc={
              gettext("Learns your meeting cadence and focus hours from your Google calendar and mail.")
            }
            pending_desc={
              gettext("Will learn your meeting cadence and focus hours once you connect Google.")
            }
          />
          <.plan_section
            title={gettext("Communication Style")}
            connected={@google_connected?}
            connected_desc={
              gettext("Learns how direct and detailed you like messages from how you write in Gmail.")
            }
            pending_desc={
              gettext("Will learn how direct and detailed you like messages once you connect Google.")
            }
          />
          <.plan_section
            title={gettext("Writing Style Reference")}
            connected={@google_connected?}
            connected_desc={
              gettext("Learns the phrases and sign-offs you use from your sent mail, so drafts sound like you.")
            }
            pending_desc={
              gettext("Will learn the phrases and sign-offs you use once you connect Google.")
            }
          />
        </div>

        <p class="flex items-center gap-1.5 text-xs text-neutral-400">
          <.icon name="sparkles" class="h-3.5 w-3.5" />
          {gettext("You can edit this later in your agent's memory.")}
        </p>
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:connected, :boolean, default: false)
  attr(:connected_desc, :string, required: true)
  attr(:pending_desc, :string, required: true)

  # A behavioral section framed against reality: once its source is connected it
  # is genuinely "Learning"; before that it is an honest plan ("When connected"),
  # never a claim to have observed something we have no data for.
  defp plan_section(assigns) do
    ~H"""
    <div class="rounded-md bg-neutral-100 px-3 py-3">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-xs font-semibold text-neutral-900">{@title}</h3>
        <.badge color={if @connected, do: "amber", else: "neutral"}>
          {if @connected, do: gettext("Learning"), else: gettext("When connected")}
        </.badge>
      </div>
      <p class="mt-1.5 text-xs text-neutral-500">
        {if @connected, do: @connected_desc, else: @pending_desc}
      </p>
    </div>
    """
  end

  # ---- step 3: integrations ----

  attr(:current_org, :any, default: nil)
  attr(:project, :any, default: nil)
  attr(:toolkit_rows, :list, default: [])
  attr(:composio_configured, :boolean, default: false)
  attr(:im_connects, :list, default: [])
  attr(:unavailable, :boolean, default: false)
  attr(:can_connect, :boolean, default: false)

  defp integrations_step(assigns) do
    ~H"""
    <div class="rounded-xl border border-neutral-200 bg-white shadow-subtle">
      <div class="border-b border-neutral-200 px-6 py-5">
        <h1 class="text-lg font-semibold">{gettext("Supercharge your agent.")}</h1>
        <p class="mt-1 text-sm text-neutral-500">
          {gettext("Connections help your agent do more work — all optional.")}
        </p>
      </div>

      <div class="space-y-4 px-6 py-5">
        <div
          :if={@unavailable}
          class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
        >
          {gettext("The runtime is unreachable right now — connection status may be incomplete. You can continue and connect later.")}
        </div>

        <.empty_state
          :if={is_nil(@current_org) or is_nil(@project)}
          icon="plug"
          title={gettext("No Agent Swarm yet")}
          description={
            gettext("Integrations attach to an Agent Swarm. You can connect accounts later from its Connections tab.")
          }
        />

        <div :if={@current_org && @project} class="divide-y divide-neutral-100 rounded-lg border border-neutral-200">
          <div
            :for={row <- @toolkit_rows}
            class="flex items-center justify-between gap-3 px-4 py-3"
          >
            <div class="flex min-w-0 items-center gap-3">
              <.brand_logo name={row.toolkit} class="h-5 w-5" />
              <div class="min-w-0">
                <div class="text-sm font-medium text-neutral-900">
                  {Catalog.provider_label(row.toolkit)}
                </div>
                <div class="truncate text-xs text-neutral-500">
                  {Catalog.provider_description(row.toolkit)}
                </div>
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-2">
              <.status_pill :if={row.state == :connected} status="connected" label={gettext("Connected")} />
              <.button
                :if={row.state == :connectable}
                variant="secondary"
                size="sm"
                phx-click="connect_toolkit"
                phx-value-toolkit={row.toolkit}
              >
                {gettext("Connect")}
              </.button>
              <span :if={row.state == :ask_admin} class="text-xs text-neutral-400">
                {gettext("Ask a swarm owner")}
              </span>
              <.button :if={row.state == :unconfigured} variant="secondary" size="sm" disabled>
                {gettext("Connect")}
              </.button>
            </div>
          </div>
        </div>

        <div
          :if={@current_org && @project && @can_connect && not @composio_configured}
          class="text-xs text-neutral-400"
        >
          {gettext("Connections need a Composio API key configured once for your organization.")}
          <.link
            navigate={~p"/orgs/#{@current_org.slug}/settings/composio"}
            class="text-brand-600 hover:underline"
          >
            {gettext("Configure in Settings")}
          </.link>
        </div>

        <div :if={@current_org && @project}>
          <h2 class="text-xs font-semibold uppercase tracking-wide text-neutral-400">
            {gettext("Messaging")}
          </h2>
          <div class="mt-2 divide-y divide-neutral-100 rounded-lg border border-neutral-200">
            <div
              :for={provider <- ProjectIMConnects.providers()}
              class="flex items-center justify-between gap-3 px-4 py-3"
            >
              <div class="flex min-w-0 items-center gap-3">
                <.brand_logo name={provider} class="h-5 w-5" />
                <div class="min-w-0">
                  <div class="text-sm font-medium text-neutral-900">{im_provider_label(provider)}</div>
                  <div class="truncate text-xs text-neutral-500">
                    {gettext("Reach your agent from where your team chats.")}
                  </div>
                </div>
              </div>
              <div class="flex shrink-0 items-center gap-2">
                <%= if im_connected?(@im_connects, provider) do %>
                  <.status_pill status="connected" label={gettext("Connected")} />
                <% else %>
                  <.link
                    navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/integrations"}
                    class="text-xs text-brand-600 hover:underline"
                  >
                    {gettext("Set up in Agent Swarm")}
                  </.link>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp im_provider_label("slack"), do: gettext("Slack Bot")
  defp im_provider_label("feishu"), do: gettext("Feishu")
  defp im_provider_label(other), do: String.capitalize(other)

  defp im_connected?(im_connects, provider) do
    Enum.any?(im_connects, fn connect ->
      connect["provider"] == provider and connect["status"] in ["active", "enabled", nil]
    end)
  end

  defp profile_heading(%{name: name}) when is_binary(name) and name != "", do: name
  defp profile_heading(%{email: email}) when is_binary(email), do: email
  defp profile_heading(_user), do: gettext("Your profile")

  defp identity_line(user, role, org) do
    name = profile_heading(user)
    role_label = role_label(role)

    case org do
      %{name: org_name} ->
        gettext("%{name} — %{role} at %{org}", name: name, role: role_label, org: org_name)

      _ ->
        name
    end
  end

  defp role_label("owner"), do: gettext("Owner")
  defp role_label("admin"), do: gettext("Admin")
  defp role_label("member"), do: gettext("Member")
  defp role_label(_role), do: gettext("Member")

  defp member_label(member) do
    case member.user do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> gettext("Teammate")
    end
  end

  defp member_initial(member) do
    member |> member_label() |> String.first() |> String.upcase()
  end
end
