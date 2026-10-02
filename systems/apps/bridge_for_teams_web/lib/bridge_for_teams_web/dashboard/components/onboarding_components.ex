defmodule BridgeForTeamsWeb.Dashboard.OnboardingComponents do
  @moduledoc """
  Function components for the first-run onboarding flow, rendered from the
  `@onboarding` assign built by `BridgeForTeamsWeb.Dashboard.Onboarding`:

    * `onboarding_ui/1` — welcome modal + guided-tour overlay. Rendered once,
      from the app layout.
    * `checklist_widget/1` — the floating quick-setup checklist (expanded,
      collapsed pill, or all-done card), fixed to the shell's bottom-right.
      "Skip setup" ends onboarding for good.

  All `phx-click` events here are `"onboarding-*"`, handled by the shared
  `handle_event` hook — no page LiveView needs to know about them.
  """
  use Phoenix.Component

  use Gettext, backend: BridgeForTeamsWeb.Gettext

  import BridgeForTeamsWeb.Dashboard.CoreComponents, only: [icon: 1]

  @doc "Welcome modal and tour overlay. Layout-level."
  attr(:onboarding, :map, required: true)

  def onboarding_ui(assigns) do
    ~H"""
    <.welcome_modal :if={@onboarding.show_welcome?} onboarding={@onboarding} />
    <.tour :if={@onboarding.tour} tour={@onboarding.tour} />
    """
  end

  @doc """
  The floating quick-setup widget, fixed to the bottom-right of the shell:
  expanded checklist, collapsed pill, or nothing (when neither is visible).
  The bottom-left corner is left free for flashes and the OAuth-reminder toast.
  """
  attr(:onboarding, :map, required: true)

  def checklist_widget(assigns) do
    ~H"""
    <div
      :if={@onboarding.show_checklist? or @onboarding.show_collapsed?}
      class="fixed bottom-4 right-4 z-40"
    >
      <.checklist :if={@onboarding.show_checklist?} onboarding={@onboarding} />
      <.collapsed_row :if={@onboarding.show_collapsed?} onboarding={@onboarding} />
    </div>
    """
  end

  # ---- Welcome modal ----

  attr(:onboarding, :map, required: true)

  defp welcome_modal(assigns) do
    ~H"""
    <div id="onboarding-welcome" class="fixed inset-0 z-[52]">
      <div class="fixed inset-0 bg-neutral-900/35 backdrop-blur-sm" aria-hidden="true" />
      <div class="fixed inset-0 flex items-center justify-center p-4">
        <div
          class="w-full max-w-[460px] rounded-xl border border-neutral-200 bg-white shadow-2xl"
          role="dialog"
          aria-modal="true"
          aria-label={gettext("Welcome")}
        >
          <div class="px-6 pb-5 pt-6">
            <div class="flex items-center gap-2">
              <div class="flex h-[22px] w-[22px] items-center justify-center rounded-md bg-brand-500">
                <.icon name="bolt" class="h-3.5 w-3.5 text-white" />
              </div>
              <span class="text-[13px] font-medium text-neutral-600">Bridge For Teams</span>
            </div>
            <h2 class="mt-3.5 text-xl font-semibold tracking-tight">
              {gettext("Welcome, %{name}", name: display_name(@onboarding.user))}
            </h2>
            <p class="mt-1 text-sm leading-[22px] text-neutral-500">
              {welcome_subtitle(@onboarding)}
            </p>
            <div class="mt-4 space-y-1.5">
              <div
                :for={{step, idx} <- Enum.with_index(@onboarding.steps, 1)}
                class="flex items-start gap-3 rounded-lg border border-neutral-100 px-3 py-2.5"
              >
                <div class="flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-full bg-brand-100 text-[11px] font-semibold text-brand-700">
                  {idx}
                </div>
                <div class="min-w-0">
                  <p class="text-sm font-medium text-neutral-900">{step_title(step)}</p>
                  <p class="mt-px text-xs leading-[17px] text-neutral-500">
                    {step_description(step, @onboarding.admin?)}
                  </p>
                </div>
              </div>
            </div>
          </div>
          <div class="flex items-center justify-end gap-2 border-t border-neutral-200 px-6 py-3.5">
            <button
              type="button"
              phx-click="onboarding-welcome-later"
              class="inline-flex h-8 items-center justify-center rounded-md border border-neutral-300 bg-white px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
            >
              {gettext("Maybe later")}
            </button>
            <button
              type="button"
              phx-click="onboarding-welcome-start"
              class="inline-flex h-8 items-center justify-center rounded-md border border-brand-600 bg-brand-500 px-3 text-sm font-medium text-white shadow-subtle hover:bg-brand-600"
            >
              {gettext("Start setup")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---- Sidebar checklist ----

  attr(:onboarding, :map, required: true)

  defp checklist(assigns) do
    ~H"""
    <div
      id="onboarding-checklist"
      class="w-96 rounded-xl border border-neutral-200 bg-white shadow-lg"
    >
      <div :if={!@onboarding.all_done?}>
        <div class="flex items-center justify-between px-3 pb-2 pt-2.5">
          <h4 class="text-[13px] font-semibold">{gettext("Quick setup")}</h4>
          <div class="flex items-center gap-1.5">
            <span class="text-xs text-neutral-500">{@onboarding.done_count}/{@onboarding.total}</span>
            <button
              type="button"
              phx-click="onboarding-toggle-collapse"
              class="flex h-[22px] w-[22px] items-center justify-center rounded-md text-neutral-400 hover:bg-neutral-100 hover:text-neutral-600"
              aria-label={gettext("Collapse")}
            >
              <.icon name="chevron-down" class="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
        <div class="px-3 pb-1">
          <div class="h-1 rounded-full bg-neutral-100">
            <div
              class="h-1 rounded-full bg-brand-500 transition-all duration-300"
              style={"width: #{progress_percent(@onboarding)}%"}
            >
            </div>
          </div>
        </div>
        <div class="space-y-0.5 p-1.5">
          <.checklist_step
            :for={{step, idx} <- Enum.with_index(@onboarding.steps, 1)}
            onboarding={@onboarding}
            step={step}
            index={idx}
          />
        </div>
        <div class="flex items-center justify-between border-t border-neutral-100 px-3 py-2">
          <button
            type="button"
            phx-click="onboarding-dismiss"
            class="text-xs text-neutral-400 hover:text-neutral-600 hover:underline"
          >
            {gettext("Skip setup")}
          </button>
          <span class="text-[11px] text-neutral-300">{gettext("Won't show again")}</span>
        </div>
      </div>

      <div :if={@onboarding.all_done?} class="flex flex-col items-center px-3 py-5 text-center">
        <div class="flex h-10 w-10 items-center justify-center rounded-full bg-green-600">
          <.icon name="check" class="h-5 w-5 text-white" />
        </div>
        <h4 class="mt-3 text-[15px] font-semibold">{gettext("Setup complete!")}</h4>
        <p class="mt-1 text-xs leading-[18px] text-neutral-500">{done_summary(@onboarding)}</p>
        <div class="mt-3.5 flex flex-wrap items-center justify-center gap-2">
          <%!-- The "Let Comma learn about your team" call to action opened the
               Slack history import, which the React Slack triage does not have
               yet. It returns with that page. --%>
          <button
            type="button"
            phx-click="onboarding-celebrate"
            class="inline-flex h-7 items-center justify-center rounded-md border border-brand-600 bg-brand-500 px-3.5 text-xs font-medium text-white shadow-subtle hover:bg-brand-600"
          >
            {gettext("Done")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:onboarding, :map, required: true)
  attr(:step, :string, required: true)
  attr(:index, :integer, required: true)

  defp checklist_step(assigns) do
    ob = assigns.onboarding
    step = assigns.step
    done? = ob.done[step]
    active? = not done? and step == (ob.active_step || first_undone(ob))
    blocked? = step == "connect" and not done? and not ob.oauth_configured

    assigns =
      assigns
      |> assign(:done?, done?)
      |> assign(:active?, active?)
      |> assign(:blocked?, blocked?)

    ~H"""
    <div class={[
      "flex items-start gap-2.5 rounded-lg p-2",
      @done? && "opacity-70",
      @blocked? && "border border-neutral-100 bg-neutral-50",
      !@blocked? && "hover:bg-neutral-50"
    ]}>
      <div
        :if={@done?}
        class="mt-px flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-green-600"
      >
        <.icon name="check" class="h-3 w-3 text-white" />
      </div>
      <div
        :if={!@done?}
        class={[
          "mt-px flex h-5 w-5 shrink-0 items-center justify-center rounded-full border text-[11px] font-semibold",
          @active? && "border-brand-500 bg-brand-500 text-white",
          !@active? && "border-neutral-300 bg-white text-neutral-500"
        ]}
      >
        {@index}
      </div>
      <div class="min-w-0 flex-1">
        <div class="flex items-start justify-between gap-2">
          <p class={[
            "min-w-0 flex-1 text-[13px] font-medium leading-[19px]",
            @done? && "text-neutral-400 line-through",
            !@done? && "text-neutral-900"
          ]}>
            {step_title(@step)}
          </p>
          <.step_action
            :if={!@done?}
            onboarding={@onboarding}
            step={@step}
            active?={@active?}
            blocked?={@blocked?}
          />
        </div>
        <p :if={@active? and !@blocked?} class="mt-0.5 text-xs leading-[17px] text-neutral-500">
          {step_description(@step, @onboarding.admin?)}
        </p>
        <p
          :if={@blocked?}
          class="mt-0.5 flex items-center gap-1 text-xs leading-[17px] text-amber-700"
        >
          <.icon name="clock" class="h-3 w-3 shrink-0" />
          {blocked_note(@onboarding)}
        </p>
      </div>
    </div>
    """
  end

  attr(:onboarding, :map, required: true)
  attr(:step, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:blocked?, :boolean, required: true)

  # The per-step action button. A blocked connect step turns into "remind the
  # admins" for members and a shortcut to the OAuth step for admins.
  defp step_action(assigns) do
    ob = assigns.onboarding

    {label, event, step_value, disabled?} =
      cond do
        assigns.blocked? and not ob.admin? and not is_nil(ob.state.oauth_reminded_at) ->
          {gettext("Reminded"), nil, nil, true}

        assigns.blocked? and not ob.admin? ->
          {gettext("Remind the admins"), "onboarding-remind-admins", nil, false}

        assigns.blocked? and ob.admin? ->
          {pgettext("onboarding", "Configure"), "onboarding-go-step", "oauth", false}

        true ->
          {go_label(assigns.step), "onboarding-go-step", assigns.step, false}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:event, event)
      |> assign(:step_value, step_value)
      |> assign(:disabled?, disabled?)

    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-step={@step_value}
      disabled={@disabled?}
      class={[
        "inline-flex h-6 shrink-0 items-center justify-center whitespace-nowrap rounded-md border px-2 text-xs font-medium",
        @disabled? && "border-neutral-200 bg-neutral-50 text-neutral-400",
        !@disabled? && @active? && "border-brand-600 bg-brand-500 text-white hover:bg-brand-600",
        !@disabled? && !@active? && "border-neutral-300 bg-white text-neutral-700 hover:bg-neutral-50"
      ]}
    >
      {@label}
    </button>
    """
  end

  # ---- Collapsed row ----

  attr(:onboarding, :map, required: true)

  defp collapsed_row(assigns) do
    circumference = 2 * :math.pi() * 8

    assigns =
      assign(
        assigns,
        :ring_dash,
        "#{Float.round(circumference * assigns.onboarding.done_count / max(assigns.onboarding.total, 1), 2)} #{Float.round(circumference, 2)}"
      )

    ~H"""
    <button
      id="onboarding-collapsed"
      type="button"
      phx-click="onboarding-toggle-collapse"
      class="flex w-auto items-center gap-2 rounded-lg border border-neutral-200 bg-white px-3 py-2 shadow-lg hover:bg-neutral-50"
    >
      <svg class="h-5 w-5 shrink-0 -rotate-90" viewBox="0 0 20 20">
        <circle cx="10" cy="10" r="8" fill="none" stroke="#f1f1f2" stroke-width="3" />
        <circle
          cx="10"
          cy="10"
          r="8"
          fill="none"
          stroke="#205bff"
          stroke-width="3"
          stroke-linecap="round"
          stroke-dasharray={@ring_dash}
        />
      </svg>
      <span class="min-w-0 flex-1 truncate text-left text-[13px] font-medium text-neutral-900">
        {gettext("Quick setup")}
      </span>
      <span class="text-xs text-neutral-500">{@onboarding.done_count}/{@onboarding.total}</span>
    </button>
    """
  end

  # ---- Guided tour ----

  attr(:tour, :map, required: true)

  # The spotlight + tooltip skeleton. Candidates render hidden; the
  # `OnboardingTour` client hook shows the first one whose target selector
  # matches the DOM and positions the fixed overlay around it.
  defp tour(assigns) do
    ~H"""
    <div id="onboarding-tour" phx-hook="OnboardingTour">
      <div
        data-tour-spotlight
        class="onboarding-spotlight pointer-events-none fixed z-[70] hidden rounded-[10px] border-2 border-brand-500"
      >
        <div class="onboarding-pulse absolute -inset-[3px] rounded-xl"></div>
      </div>
      <div
        :for={c <- @tour.candidates}
        data-tour-candidate
        data-key={c.key}
        data-target={c.target}
        data-placement={c.placement}
        class="fixed z-[76] hidden w-[296px] rounded-[10px] border border-neutral-200 bg-white px-3.5 py-3 shadow-2xl"
      >
        <div class="flex items-center justify-between">
          <span class="text-[11px] font-semibold tracking-wide text-brand-600">{@tour.label}</span>
          <button
            type="button"
            phx-click="onboarding-exit-tour"
            class="flex h-5 w-5 items-center justify-center rounded text-neutral-400 hover:bg-neutral-100 hover:text-neutral-600"
            aria-label={gettext("Exit tour")}
          >
            <.icon name="x-mark" class="h-3 w-3" />
          </button>
        </div>
        <p class="mt-1.5 text-sm font-semibold text-neutral-900">{c.title}</p>
        <p class="mt-1 text-[13px] leading-5 text-neutral-600">{c.body}</p>
        <div class="mt-2.5 flex items-center justify-between">
          <button
            type="button"
            phx-click="onboarding-skip-step"
            class="text-xs text-neutral-500 hover:text-neutral-700 hover:underline"
          >
            {gettext("Skip this step")}
          </button>
          <span class="text-[11px] text-neutral-400">{gettext("Complete the action on the page")}</span>
        </div>
      </div>
    </div>
    """
  end

  # ---- Global admin alert: members waiting for OAuth ----

  @doc """
  Persistent top-right alert for org admins while members are waiting for an
  OAuth client to be configured. Clicking the link opens Settings → OAuth apps;
  the × hides it for the rest of the browser session (`SessionDismissible`
  hook). Disappears on its own once a client is configured.
  """
  attr(:alert, :map, required: true)

  def oauth_reminder_toast(assigns) do
    ~H"""
    <div
      id="oauth-reminder-toast"
      phx-hook="SessionDismissible"
      data-dismiss-key={"bft-oauth-reminder-#{@alert.org.id}"}
      class="fixed bottom-5 left-64 z-[45] hidden w-80 rounded-lg border border-neutral-200 bg-white p-3 shadow-xl"
    >
      <div class="flex items-start gap-2.5">
        <div class="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-amber-100">
          <.icon name="clock" class="h-4 w-4 text-amber-600" />
        </div>
        <div class="min-w-0 flex-1">
          <p class="text-[13px] font-medium leading-[19px] text-neutral-900">
            {ngettext(
              "%{count} member is waiting for OAuth clients to be configured.",
              "%{count} members are waiting for OAuth clients to be configured.",
              @alert.count
            )}
          </p>
          <.link
            href={"/orgs/#{@alert.org.slug}/settings/integrations"}
            class="mt-1 inline-block text-xs font-medium text-brand-600 hover:underline"
          >
            {gettext("Go to Settings → Integrations")} →
          </.link>
        </div>
        <button
          type="button"
          data-dismiss
          class="flex h-5 w-5 shrink-0 items-center justify-center rounded text-neutral-400 hover:bg-neutral-100 hover:text-neutral-600"
          aria-label={gettext("Close")}
        >
          <.icon name="x-mark" class="h-3 w-3" />
        </button>
      </div>
    </div>
    """
  end

  # ---- copy helpers ----

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email), do: email
  defp display_name(_), do: ""

  defp welcome_subtitle(%{admin?: true, total: total}),
    do:
      gettext("Complete the initial setup in %{total} steps to put your team's agents to work.",
        total: total
      )

  defp welcome_subtitle(%{total: total}),
    do: gettext("Complete setup in %{total} steps to put your agent to work.", total: total)

  defp step_title("swarm"), do: gettext("Create an Agent Swarm")
  defp step_title("oauth"), do: gettext("Configure OAuth clients")
  defp step_title("connect"), do: gettext("Connect a third-party account")
  defp step_title(other), do: other

  defp step_description("swarm", true), do: gettext("Set up your first agent cluster.")
  defp step_description("swarm", false), do: gettext("Each member can create one agent cluster.")

  defp step_description("oauth", _),
    do: gettext("Add a client ID for GitHub, Google, Linear, Notion, or Slack in Settings.")

  defp step_description("connect", _),
    do: gettext("Authorize agents to act on your behalf on the connected platforms.")

  defp step_description(_, _), do: ""

  defp go_label("swarm"), do: pgettext("onboarding", "Create")
  defp go_label("oauth"), do: pgettext("onboarding", "Configure")
  defp go_label(_), do: pgettext("onboarding", "Connect")

  defp blocked_note(%{admin?: true}), do: gettext("Requires “Configure OAuth clients” first")

  defp blocked_note(%{state: %{oauth_reminded_at: %DateTime{}}}),
    do: gettext("Admins reminded — waiting for configuration")

  defp blocked_note(_), do: gettext("Waiting for an admin to configure OAuth")

  defp done_summary(%{admin?: true}),
    do:
      gettext(
        "Agent Swarm created, OAuth configured, and an account connected. Your agent team is ready."
      )

  defp done_summary(_),
    do: gettext("Agent Swarm created and an account connected. Your agent is ready.")

  defp first_undone(ob), do: Enum.find(ob.steps, &(!ob.done[&1]))

  defp progress_percent(%{total: 0}), do: 0
  defp progress_percent(ob), do: round(ob.done_count / ob.total * 100)
end
