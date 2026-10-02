defmodule BridgeForTeamsWeb.Dashboard.Onboarding do
  @moduledoc """
  LiveView layer for the first-run onboarding flow (welcome modal, sidebar
  quick-setup checklist, guided tour). Mounted on the `:authenticated`
  live_session so the flow follows the user across pages:

    * `on_mount/4` attaches a `handle_params` hook that derives the
      `@onboarding` assign after every mount/patch (pages assign
      `:current_org`/`:current_org_role` in their own `mount`, which runs
      first), and a `handle_event` hook that owns every `"onboarding-*"` event
      so individual pages never have to.
    * The layout renders the overlays from `@onboarding`
      (`OnboardingComponents.onboarding_ui/1`) and the floating checklist
      (`OnboardingComponents.checklist_widget/1`, fixed bottom-right).
      Skipping the checklist ("Skip setup") ends onboarding for good — nothing
      resurfaces on Home or anywhere else.
    * Pages that mutate step data mid-page call `rebuild/2`
      (Settings → OAuth save/remove) or `observe_connections/2` (the
      connections tab) so the checklist reflects the change immediately.

  Step completion itself is derived in `BridgeForTeams.Onboarding` — see that
  moduledoc for the storage/derivation contract.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Memberships, Onboarding}

  @admin_roles ~w(owner admin)

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:onboarding, nil)
     |> assign(:oauth_reminder_alert, nil)
     |> attach_hook(:bft_onboarding_params, :handle_params, &handle_params_hook/3)
     |> attach_hook(:bft_onboarding_events, :handle_event, &handle_event_hook/3)}
  end

  defp handle_params_hook(_params, _uri, socket), do: {:cont, rebuild(socket)}

  @doc """
  Recompute the `@onboarding` assign (checklist/welcome/tour) and the
  `@oauth_reminder_alert` assign (the global "members are waiting for OAuth"
  admin toast) from current data. Pages call this after mutating something a
  checklist step derives from. Options: `:refresh_oauth` — drop the cached
  org-OAuth-configured answer first.
  """
  @spec rebuild(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def rebuild(socket, opts \\ []) do
    assigns = socket.assigns
    org = assigns[:current_org]
    user = assigns[:current_user]
    page = page_context(socket.view, assigns[:live_action])

    role =
      if org && user, do: assigns[:current_org_role] || fetch_role(org, user), else: nil

    if Keyword.get(opts, :refresh_oauth, false) && org do
      Onboarding.invalidate_oauth_cache(org.id)
    end

    socket
    |> assign(:onboarding, build_onboarding(org, user, role, page))
    |> assign(:oauth_reminder_alert, build_reminder_alert(org, role))
  end

  defp build_onboarding(org, user, role, page) do
    with true <- not is_nil(org) and not is_nil(user),
         steps when steps != [] <- Onboarding.steps_for_role(role),
         state = Onboarding.get_state(org.id, user.id),
         true <- is_nil(state.celebrated_at),
         true <- is_nil(state.dismissed_at) do
      snap = Onboarding.snapshot(org, user.id, role, state: state)
      build(snap, org, user, role, page)
    else
      _ -> nil
    end
  end

  # The global admin alert while members wait for OAuth clients. Independent of
  # the admin's own onboarding progress (they may have finished or skipped it).
  # Settings → Integrations (React) lists the waiting members itself.
  defp build_reminder_alert(org, role) when not is_nil(org) and role in @admin_roles do
    if Onboarding.oauth_configured?(org.id) do
      nil
    else
      case Onboarding.pending_oauth_reminders(org.id) do
        [] -> nil
        reminders -> %{count: length(reminders), org: org}
      end
    end
  end

  defp build_reminder_alert(_org, _role), do: nil

  @doc """
  Mark the connect step done when a non-empty connections list is shown to the
  user, then refresh the checklist. Called by the connections tab after load.
  """
  @spec observe_connections(Phoenix.LiveView.Socket.t(), list()) :: Phoenix.LiveView.Socket.t()
  def observe_connections(socket, connections) do
    with [_ | _] <- connections,
         %{id: org_id} <- socket.assigns[:current_org],
         %{id: user_id} <- socket.assigns[:current_user] do
      :ok = Onboarding.observe_connected(org_id, user_id)
      rebuild(socket)
    else
      _ -> socket
    end
  end

  defp fetch_role(org, user) do
    case Memberships.org_role(org.id, user.id) do
      {:ok, role} -> role
      _ -> nil
    end
  end

  defp build(snap, org, user, role, page) do
    state = snap.state
    welcome? = is_nil(state.welcome_seen_at)
    checklist_on? = not welcome?

    %{
      org: org,
      user: user,
      role: role,
      admin?: role in @admin_roles,
      page: page,
      state: state,
      steps: snap.steps,
      done: snap.done,
      active_step: snap.active_step,
      first_project: snap.first_project,
      done_count: snap.done_count,
      total: snap.total,
      all_done?: snap.all_done?,
      oauth_configured: snap.oauth_configured,
      show_welcome?: welcome?,
      show_checklist?: checklist_on? and not state.collapsed,
      show_collapsed?: checklist_on? and state.collapsed,
      tour: if(checklist_on?, do: tour(snap, page, role), else: nil)
    }
  end

  # ---- page context ----

  defp page_context(view, live_action) do
    case {view, live_action} do
      {BridgeForTeamsWeb.Dashboard.ProjectLive.Show, :connections} -> :swarm_connections
      {BridgeForTeamsWeb.Dashboard.ProjectLive.Show, _} -> :swarm
      _ -> :other
    end
  end

  # ---- events ----

  defp handle_event_hook("onboarding-" <> action, params, socket) do
    case socket.assigns[:onboarding] do
      nil -> {:halt, socket}
      onboarding -> {:halt, handle_action(action, params, socket, onboarding)}
    end
  end

  defp handle_event_hook(_event, _params, socket), do: {:cont, socket}

  defp handle_action("welcome-start", _params, socket, ob) do
    step = Onboarding.first_undone(ob.steps, ob.done)
    {:ok, _} = Onboarding.mark_welcome_seen(ob.org.id, ob.user.id, active_step: step)
    rebuild(socket)
  end

  defp handle_action("welcome-later", _params, socket, ob) do
    {:ok, _} = Onboarding.mark_welcome_seen(ob.org.id, ob.user.id, collapsed: true)
    rebuild(socket)
  end

  defp handle_action("toggle-collapse", _params, socket, ob) do
    {:ok, _} = Onboarding.set_collapsed(ob.org.id, ob.user.id, not ob.state.collapsed)
    rebuild(socket)
  end

  # No flash: the checklist visibly disappears, so a toast just adds noise.
  defp handle_action("dismiss", _params, socket, ob) do
    {:ok, _} = Onboarding.dismiss(ob.org.id, ob.user.id)
    rebuild(socket)
  end

  defp handle_action("celebrate", _params, socket, ob) do
    {:ok, _} = Onboarding.celebrate(ob.org.id, ob.user.id)
    rebuild(socket)
  end

  defp handle_action("go-step", %{"step" => step}, socket, ob) when is_binary(step) do
    if step in ob.steps do
      # `resume/3` clears dismissed + collapsed and points the tour at the step.
      {:ok, _} = Onboarding.resume(ob.org.id, ob.user.id, step)

      socket
      |> rebuild()
      |> navigate_to_step(step, ob)
    else
      socket
    end
  end

  # Skipping a step waives it: it is recorded as skipped and counts as done.
  # The rebuild advances the tour past it (`effective_active_step`), and ends
  # the tour when nothing undone remains.
  defp handle_action("skip-step", _params, socket, ob) do
    if is_binary(ob.active_step) do
      {:ok, _} = Onboarding.skip_step(ob.org.id, ob.user.id, ob.active_step)
      rebuild(socket)
    else
      socket
    end
  end

  defp handle_action("exit-tour", _params, socket, ob) do
    {:ok, _} = Onboarding.set_active_step(ob.org.id, ob.user.id, nil)
    rebuild(socket)
  end

  defp handle_action("remind-admins", _params, socket, ob) do
    if ob.state.oauth_reminded_at do
      put_flash(
        socket,
        :info,
        gettext("The admins were already notified — hang tight while they configure OAuth.")
      )
    else
      {:ok, _} = Onboarding.remind_admins(ob.org.id, ob.user.id)

      socket
      |> put_flash(
        :info,
        gettext("Your org admins were asked to configure OAuth under Settings → Integrations.")
      )
      |> rebuild()
    end
  end

  defp handle_action(_action, _params, socket, _ob), do: socket

  # Bring the user to the page where the step happens (no-op when already there).
  defp navigate_to_step(socket, step, ob) do
    slug = ob.org.slug

    target =
      case step do
        # React pages: redirect for a full page load.
        "swarm" ->
          {:redirect, "/orgs/#{slug}/projects"}

        "oauth" ->
          {:redirect, "/orgs/#{slug}/settings/integrations"}

        "connect" ->
          cond do
            is_nil(ob.first_project) ->
              {:redirect, "/orgs/#{slug}/projects"}

            ob.page != :swarm_connections ->
              "/orgs/#{slug}/projects/#{ob.first_project.id}/connections"

            true ->
              nil
          end
      end

    case target do
      nil -> socket
      {:redirect, path} -> redirect(socket, to: path)
      path -> push_navigate(socket, to: path)
    end
  end

  # ---- guided tour ----

  # Derive the tour spotlight candidates for the active step on the current
  # page. Each candidate carries a CSS target; the client hook shows the first
  # candidate whose target exists in the DOM (e.g. the "fill the form" tooltip
  # wins over the "click New Agent Swarm" one once the modal is open).
  defp tour(%{active_step: nil}, _page, _role), do: nil

  defp tour(snap, page, role) do
    label =
      gettext("Step %{n} of %{total}",
        n: Enum.find_index(snap.steps, &(&1 == snap.active_step)) + 1,
        total: snap.total
      )

    case candidates(snap.active_step, page, role, snap) do
      [] -> nil
      candidates -> %{label: label, candidates: candidates}
    end
  end

  defp candidates("swarm", _page, _role, _snap) do
    [
      %{
        key: "swarm-nav",
        target: "[data-tour='nav-swarms']",
        placement: "right",
        title: gettext("Create an Agent Swarm"),
        body:
          gettext(
            "Open Agent Swarms in the sidebar. Your agents, tasks, and third-party connections all live inside a Swarm."
          )
      }
    ]
  end

  defp candidates("oauth", _page, _role, _snap) do
    [
      %{
        key: "oauth-nav",
        target: "[data-tour='nav-settings']",
        placement: "right",
        title: gettext("Configure OAuth clients"),
        body:
          gettext(
            "Go to Settings → Integrations. Members can only connect a platform in an Agent Swarm after a client ID is configured."
          )
      }
    ]
  end

  defp candidates("connect", :swarm_connections, role, snap) do
    cond do
      snap.oauth_configured ->
        [
          %{
            key: "conn-connect",
            target: "[id^='oauth-provider-']",
            placement: "right",
            title: gettext("Connect a third-party account"),
            body:
              gettext(
                "Pick a platform, click “Connect”, and finish the authorization on the provider's page."
              )
          }
        ]

      role == "member" ->
        [
          %{
            key: "conn-blocked",
            target: "[data-tour='conn-empty']",
            placement: "top",
            title: gettext("Waiting for an admin"),
            body:
              gettext(
                "Your organization has no OAuth clients configured yet. Click “Remind the admins” — once configured, the platforms appear here."
              )
          }
        ]

      true ->
        [
          %{
            key: "conn-blocked-admin",
            target: "[data-tour='conn-empty']",
            placement: "top",
            title: gettext("One step missing"),
            body:
              gettext(
                "No OAuth client is configured yet. Finish step 2 (Settings → OAuth apps) first, then platforms appear here."
              )
          }
        ]
    end
  end

  defp candidates("connect", :swarm, _role, _snap) do
    [
      %{
        key: "conn-tab",
        target: "a[href$='/connections']",
        placement: "bottom",
        title: gettext("Connect a third-party account"),
        body: gettext("Open the “Connections” tab.")
      }
    ]
  end

  defp candidates("connect", _page, _role, _snap) do
    [
      %{
        key: "conn-nav",
        target: "[data-tour='nav-swarms']",
        placement: "right",
        title: gettext("Connect a third-party account"),
        body: gettext("Head back to Agent Swarms and open your Swarm.")
      }
    ]
  end

  defp candidates(_step, _page, _role, _snap), do: []
end
