defmodule BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup do
  @moduledoc """
  Product UI for initializing an Agent's project context from Slack.

  The overview renders only a compact status and entry point. The focused task
  projects the existing durable import run into source, scope, processing,
  review, and completion steps; protocol evidence stays inside the secondary
  audit disclosure.
  """

  use BridgeForTeamsWeb.Dashboard, :html

  @active_states ~w(created acquiring acquired deriving)
  @preview_states ~w(preview_ready)
  @finished_states ~w(committed rolled_back canceled failed_terminal stale_source)
  @preview_source_limit 3
  @source_excerpt_graphemes 280

  attr(:org, :map, required: true)
  attr(:agents, :any, required: true)

  def agent_required(assigns) do
    unavailable? = match?({:error, _reason}, assigns.agents)
    assigns = assign(assigns, :unavailable?, unavailable?)

    ~H"""
    <section id="slack-context-agent-required" class="mx-auto w-full max-w-2xl rounded-xl border border-amber-200 bg-amber-50 p-6">
      <h1 class="text-lg font-semibold text-amber-950">
        {if @unavailable?, do: gettext("Agent list is temporarily unavailable"), else: gettext("Choose an Agent before initializing context")}
      </h1>
      <p class="mt-2 text-sm leading-6 text-amber-900">
        {if @unavailable?, do: gettext("Comma could not verify which Agent owns this project context. Try again from Triage."), else: gettext("This focused setup must stay attached to one explicit Agent. Return to Triage and choose the Agent you want to initialize.")}
      </p>
      <.button patch={~p"/orgs/#{@org.slug}/triage"} class="mt-4" variant="primary">
        {gettext("Back to Triage")}
      </.button>
    </section>
    """
  end

  attr(:runs, :any, default: nil)
  attr(:active_run, :any, default: nil)
  attr(:selected_connect, :map, default: nil)
  attr(:source_view, :map, required: true)
  attr(:readiness, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:org, :map, required: true)
  attr(:agent, :map, required: true)

  def summary(assigns) do
    latest_run = newest_run(assigns.runs)
    active_run = active_context_run(assigns.active_run)

    state =
      summary_state(assigns.runs, assigns.active_run, latest_run, active_run, assigns.source_view)

    run = primary_run(state, latest_run, active_run)
    connect = connect_for_run(assigns.source_view, run)
    setup_connect = connect || assigns.selected_connect

    assigns =
      assigns
      |> assign(:run, run)
      |> assign(:connect, connect)
      |> assign(:state, state)
      |> assign(:active_context?, not is_nil(active_run))
      |> assign(:latest_attempt_notice, later_terminal_attempt_notice(latest_run, active_run))
      |> assign(
        :context_path,
        context_path(assigns.org, assigns.agent, setup_connect, nil, nil)
      )
      |> assign(:knowledge_path, knowledge_path(assigns.org, assigns.agent))
      |> assign(
        :update_path,
        context_path(assigns.org, assigns.agent, setup_connect, "update", "source")
      )
      |> assign(
        :refresh_path,
        context_path(assigns.org, assigns.agent, setup_connect, "reconnect", "source")
      )

    ~H"""
    <section
      id="slack-context-summary"
      data-state={@state}
      class="rounded-xl border border-neutral-200 bg-white p-5 shadow-subtle"
    >
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-sm font-semibold text-neutral-950">{gettext("Project context")}</h2>
            <.status state={@state} grounding?={@readiness.grounding?} />
          </div>
          <p class="mt-1 max-w-2xl text-sm leading-6 text-neutral-600">
            {summary_copy(@state, @readiness.grounding?)}
          </p>
        </div>

        <div class="flex shrink-0 flex-wrap items-center gap-2">
          <.button
            :if={@state in [:processing, :review] or (@state == :uninitialized and @can_manage)}
            patch={@context_path}
            variant="primary"
          >
            {summary_action(@state, @readiness.grounding?)}
          </.button>
          <.button
            :if={@state in [:ready, :disconnected, :refresh] or (@active_context? and @state in [:processing, :review, :unavailable])}
            patch={@knowledge_path}
          >
            {gettext("View knowledge")}
          </.button>
          <.button :if={@state == :ready and @can_manage} patch={@update_path} variant="primary">
            {gettext("Update context")}
          </.button>
          <.button :if={@state == :refresh and @can_manage} patch={@refresh_path} variant="primary">
            {gettext("Refresh context")}
          </.button>
          <.button
            :if={@state == :disconnected and @can_manage}
            navigate={project_integrations_path(@org, @agent)}
            variant="primary"
          >
            {gettext("Reconnect Slack")}
          </.button>
          <.button :if={@state == :needs_update and @can_manage} patch={@update_path} variant="primary">
            {gettext("Set up again")}
          </.button>
          <.button :if={@state == :unavailable} type="button" phx-click="refresh-slack-context">
            {gettext("Retry")}
          </.button>
        </div>
      </div>

      <dl :if={@run && @state in [:ready, :disconnected, :refresh, :unavailable]} class="mt-4 grid gap-3 border-t border-neutral-100 pt-4 text-xs sm:grid-cols-4">
        <.summary_item label={gettext("Source")} value={source_label(@connect, @run, @state)} />
        <.summary_item label={gettext("Channels")} value={channel_count(@run)} />
        <.summary_item label={gettext("Time range")} value={range_days(@run)} />
        <.summary_item label={gettext("Last updated")} value={updated_label(@run)} />
      </dl>

      <p :if={@state == :disconnected} class="mt-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
        {gettext("Slack is disconnected. Existing project context remains available and is not deleted.")}
      </p>
      <p :if={@active_context? and @state in [:processing, :review]} class="mt-4 rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-xs leading-5 text-brand-900">
        {gettext("Existing project context remains available while this update is in progress.")}
      </p>
      <p :if={@latest_attempt_notice} class="mt-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
        {@latest_attempt_notice}
      </p>
      <p :if={not @can_manage and @state in [:uninitialized, :disconnected, :refresh, :needs_update]} class="mt-4 text-xs leading-5 text-neutral-500">
        {gettext("An organization owner or admin can change this context setup.")}
      </p>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp summary_item(assigns) do
    ~H"""
    <div>
      <dt class="text-neutral-500">{@label}</dt>
      <dd class="mt-1 truncate font-medium text-neutral-900">{@value}</dd>
    </div>
    """
  end

  attr(:state, :atom, required: true)
  attr(:grounding?, :boolean, default: true)

  defp status(assigns) do
    {label, class} = status_presentation(assigns.state, assigns.grounding?)
    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-[0.6875rem] font-medium", @class]}>
      {@label}
    </span>
    """
  end

  attr(:readiness, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:selected_connect, :map, default: nil)
  attr(:source_view, :map, required: true)
  attr(:channels, :any, default: nil)
  attr(:runs, :any, default: nil)
  attr(:active_run, :any, default: nil)
  attr(:history, :any, default: nil)
  attr(:history_previous?, :boolean, default: false)
  attr(:preview, :any, default: nil)
  attr(:form, :map, required: true)
  attr(:scope_confirmed?, :boolean, required: true)
  attr(:confirmed?, :boolean, required: true)
  attr(:selected_artifact_ids, :list, default: [])
  attr(:client_request_id, :string, required: true)
  attr(:org, :map, required: true)
  attr(:agent, :map, required: true)
  attr(:filters, :map, required: true)

  def task(assigns) do
    latest_run = newest_run(assigns.runs)
    active_run = active_context_run(assigns.active_run)
    mode = context_mode(assigns.filters)
    step = flow_step(assigns.runs, assigns.active_run, latest_run, active_run, assigns.filters)
    run = task_run(step, latest_run, active_run)
    run_connect = connect_for_run(assigns.source_view, run)
    connect = if step in [:source, :range], do: assigns.selected_connect, else: run_connect
    audit_run = latest_run || active_run

    assigns =
      assigns
      |> assign(:run, run)
      |> assign(:audit_run, audit_run)
      |> assign(:mode, mode)
      |> assign(:step, step)
      |> assign(:connect, connect)
      |> assign(:primary_state, context_state(run, assigns.source_view))
      |> assign(:active_context?, not is_nil(active_run))
      |> assign(:latest_attempt_notice, later_terminal_attempt_notice(latest_run, active_run))
      |> assign(:eligible_channels, eligible_channels(assigns.channels))
      |> assign(:history_runs, history_runs(assigns.history))
      |> assign(:history_next?, history_next?(assigns.history))
      |> assign(
        :source_path,
        context_path(assigns.org, assigns.agent, assigns.selected_connect, mode, "source")
      )
      |> assign(
        :range_path,
        context_path(assigns.org, assigns.agent, assigns.selected_connect, mode, "range")
      )
      |> assign(
        :triage_path,
        ~p"/orgs/#{assigns.org.slug}/triage?#{%{"agent" => assigns.agent[:agent_id]}}"
      )
      |> assign(:knowledge_path, knowledge_path(assigns.org, assigns.agent))

    ~H"""
    <section id="slack-context-task" class="mx-auto flex min-h-0 w-full max-w-3xl flex-1 flex-col">
      <div class="flex shrink-0 flex-wrap items-center justify-between gap-3 border-b border-neutral-200 pb-4">
        <div>
          <p class="text-sm font-semibold text-neutral-950">
            {if @mode == "reconnect", do: gettext("Refresh project context"), else: gettext("Let Comma learn about your team")}
          </p>
          <p class="mt-0.5 text-xs text-neutral-500">
            {task_persistence_copy(@step)}
          </p>
          <p id="slack-context-target" class="mt-1 flex flex-wrap items-center gap-x-2 text-xs text-neutral-600">
            <span>{gettext("Agent %{name}", name: context_agent_label(@agent))}</span>
            <span aria-hidden="true" class="text-neutral-300">·</span>
            <span>{gettext("Project %{name}", name: context_project_label(@agent))}</span>
          </p>
        </div>
        <.button patch={@triage_path} variant="ghost">{gettext("Back to Triage")}</.button>
      </div>

      <div class="min-h-0 flex-1 py-6 lg:pr-2">
        <header>
          <p class="text-xs font-semibold text-brand-700">{step_kicker(@step)}</p>
          <h1 id="slack-context-step-title" class="mt-1 text-2xl font-semibold tracking-tight text-neutral-950">
            {step_title(@step, @primary_state, @readiness.grounding?)}
          </h1>
          <p class="mt-2 max-w-2xl text-sm leading-6 text-neutral-600">
            {step_description(@step, @mode, @readiness.grounding?)}
          </p>
        </header>

        <.source_step
          :if={@step == :source}
          org={@org}
          agent={@agent}
          can_manage={@can_manage}
          connect={@connect}
          source_view={@source_view}
          range_path={@range_path}
        />
        <.range_step
          :if={@step == :range}
          readiness={@readiness}
          can_manage={@can_manage}
          connect={@connect}
          channels={@eligible_channels}
          channels_result={@channels}
          form={@form}
          scope_confirmed?={@scope_confirmed?}
          client_request_id={@client_request_id}
          source_path={@source_path}
          mode={@mode}
          agent={@agent}
        />
        <.processing_step
          :if={@step == :processing}
          run={@run}
          triage_path={@triage_path}
          active_context?={@active_context?}
          grounding?={@readiness.grounding?}
        />
        <.unavailable_step :if={@step == :unavailable} triage_path={@triage_path} />
        <.preview_step
          :if={@step == :preview}
          run={@run}
          preview={@preview}
          commit?={@readiness.commit? and @can_manage}
          can_manage={@can_manage}
          confirmed?={@confirmed?}
          selected_artifact_ids={@selected_artifact_ids}
          grounding?={@readiness.grounding?}
          restart_path={context_path(@org, @agent, @connect, "update", "range")}
        />
        <.complete_step
          :if={@step == :complete}
          run={@run}
          state={@primary_state}
          connect={@connect}
          can_manage={@can_manage}
          org={@org}
          agent={@agent}
          knowledge_path={@knowledge_path}
          update_path={context_path(@org, @agent, @connect, "update", "source")}
          refresh_path={context_path(@org, @agent, @connect, "reconnect", "source")}
          grounding?={@readiness.grounding?}
          latest_attempt_notice={@latest_attempt_notice}
        />

        <.advanced_audit
          :if={@audit_run}
          run={@audit_run}
          preview={@preview}
          grounding?={@readiness.grounding?}
          runs={@history_runs}
          current_run={@audit_run}
          previous?={@history_previous?}
          next?={@history_next?}
          can_manage={@can_manage}
        />
      </div>

      <footer class="shrink-0 border-t border-neutral-200 py-3 text-xs text-neutral-500">
        {gettext("This setup only reads the scope you confirm. It does not write to Slack, send replies, create tasks, change private Agent memory, or change continuous Triage listening.")}
      </footer>
    </section>
    """
  end

  attr(:org, :map, required: true)
  attr(:agent, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:connect, :map, default: nil)
  attr(:source_view, :map, required: true)
  attr(:range_path, :string, required: true)

  defp source_step(assigns) do
    assigns = assign(assigns, :sources, assigns.source_view.sources)

    ~H"""
    <div id="slack-context-source-step" class="mt-6 space-y-5">
      <div :if={@sources != []} class="space-y-2">
        <button
          :for={source <- @sources}
          type="button"
          phx-click="select-assistant"
          phx-value-connect={source.connect_id}
          aria-pressed={to_string(same_ref?(source.connect_id, @connect && @connect.connect_id))}
          class={[
            "flex w-full items-center gap-3 rounded-xl border px-4 py-3 text-left transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500",
            same_ref?(source.connect_id, @connect && @connect.connect_id) && "border-brand-300 bg-brand-50",
            not same_ref?(source.connect_id, @connect && @connect.connect_id) && "border-neutral-200 bg-white hover:border-neutral-300"
          ]}
        >
          <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-neutral-100 text-xs font-semibold text-neutral-600">SL</span>
          <span class="min-w-0 flex-1">
            <strong class="block truncate text-sm text-neutral-950">{source_title(source)}</strong>
            <span class="mt-0.5 block truncate text-xs text-neutral-500">{source_detail(source)}</span>
          </span>
          <span class="text-xs font-medium text-brand-700">
            {if same_ref?(source.connect_id, @connect && @connect.connect_id), do: gettext("Selected"), else: gettext("Choose")}
          </span>
        </button>
      </div>

      <div :if={@source_view.state == :unavailable} id="slack-context-source-unavailable" class="rounded-xl border border-amber-200 bg-amber-50 p-5">
        <h2 class="text-sm font-semibold text-amber-950">{gettext("Slack connection status is temporarily unavailable")}</h2>
        <p class="mt-1 text-sm leading-6 text-amber-900">
          {gettext("Comma could not verify the Slack source right now. Existing imported context is unchanged.")}
        </p>
        <.button type="button" phx-click="refresh-slack-context" class="mt-4">
          {gettext("Retry")}
        </.button>
      </div>

      <div :if={@source_view.state == :empty} class="rounded-xl border border-neutral-200 bg-neutral-50 p-5">
        <h2 class="text-sm font-semibold text-neutral-950">{gettext("Connect Slack first")}</h2>
        <p class="mt-1 text-sm leading-6 text-neutral-600">
          {gettext("This Agent does not have an available Slack source. Existing imported context, if any, is not deleted.")}
        </p>
        <.button navigate={project_integrations_path(@org, @agent)} class="mt-4" variant="primary">
          {gettext("Open Slack connection settings")}
        </.button>
      </div>

      <div :if={@source_view.state == :partial} id="slack-context-source-partial" class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
        <p>
          {gettext("Some Slack connection status is temporarily unavailable. Only the verified sources below can be selected.")}
        </p>
        <.button type="button" phx-click="refresh-slack-context" class="mt-2" size="sm">
          {gettext("Retry")}
        </.button>
      </div>

      <p :if={@connect} class="rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-xs leading-5 text-brand-900">
        {gettext("The next step can preselect channels that are already monitored, but you must still confirm this read scope explicitly.")}
      </p>

      <div class="flex items-center justify-end gap-2 pt-2">
        <.button :if={@connect && @can_manage} patch={@range_path} variant="primary">
          {gettext("Confirm and continue")}
        </.button>
        <.button :if={is_nil(@connect) or not @can_manage} type="button" variant="primary" disabled>
          {gettext("Confirm and continue")}
        </.button>
      </div>
      <p :if={not @can_manage} class="text-right text-xs leading-5 text-neutral-500">
        {gettext("An organization owner or admin must start context setup.")}
      </p>
    </div>
    """
  end

  attr(:readiness, :map, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:connect, :map, default: nil)
  attr(:channels, :list, required: true)
  attr(:channels_result, :any, required: true)
  attr(:form, :map, required: true)
  attr(:scope_confirmed?, :boolean, required: true)
  attr(:client_request_id, :string, required: true)
  attr(:source_path, :string, required: true)
  attr(:mode, :string, default: nil)
  attr(:agent, :map, required: true)

  defp range_step(assigns) do
    ready? =
      assigns.readiness.dry_run? and assigns.can_manage and not is_nil(assigns.connect) and
        not channels_unavailable?(assigns.channels_result) and assigns.form.channel_ids != [] and
        assigns.scope_confirmed?

    assigns = assign(assigns, :ready?, ready?)

    ~H"""
    <form
      id="slack-history-import-form"
      phx-change="validate-slack-history-import"
      phx-submit="start-slack-history-import"
      class="mt-6 space-y-6"
    >
      <input type="hidden" name="connect" value={@connect && @connect.connect_id} />
      <input type="hidden" name="client_request_id" value={@client_request_id} />

      <fieldset>
        <div class="flex flex-wrap items-end justify-between gap-2">
          <legend class="text-sm font-semibold text-neutral-950">{gettext("Slack channels")}</legend>
          <span class="text-xs text-neutral-500">
            {ngettext("%{count} selected", "%{count} selected", length(@form.channel_ids), count: length(@form.channel_ids))}
          </span>
        </div>
        <div :if={not channels_unavailable?(@channels_result) and @channels != []} class="mt-3 divide-y divide-neutral-100 rounded-xl border border-neutral-200 bg-white">
          <label :for={channel <- @channels} class="flex cursor-pointer items-center gap-3 px-4 py-3 hover:bg-neutral-50">
            <input
              type="checkbox"
              name="channel_ids[]"
              value={channel.id}
              checked={channel.id in @form.channel_ids}
              class="h-4 w-4 rounded accent-blue-600"
            />
            <span class="min-w-0 flex-1 truncate text-sm font-medium text-neutral-900">#{channel.name}</span>
            <span :if={monitored?(channel, @connect)} class="rounded bg-brand-50 px-2 py-0.5 text-[0.6875rem] font-medium text-brand-700">
              {gettext("Monitored")}
            </span>
          </label>
        </div>
        <div :if={channels_unavailable?(@channels_result)} id="slack-context-channels-unavailable" class="mt-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <p>{gettext("Comma could not load Slack channels right now. No channel selection was assumed.")}</p>
          <.button type="button" phx-click="refresh-slack-context" class="mt-3" size="sm">
            {gettext("Retry")}
          </.button>
        </div>
        <p :if={not channels_unavailable?(@channels_result) and @channels == []} class="mt-3 rounded-lg border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm text-neutral-600">
          {gettext("No eligible public Slack channels are available for this connection.")}
        </p>
      </fieldset>

      <fieldset>
        <legend class="text-sm font-semibold text-neutral-950">{gettext("Time range")}</legend>
        <div class="mt-3 grid gap-2 sm:grid-cols-3">
          <label :for={days <- [3, 7, 14]} class="flex cursor-pointer items-center gap-2 rounded-lg border border-neutral-200 px-3 py-2.5 text-sm hover:border-neutral-300">
            <input
              type="radio"
              name="range_days"
              value={days}
              checked={Integer.to_string(days) == @form.range_days}
              class="accent-blue-600"
            />
            <span>{ngettext("Last %{count} day", "Last %{count} days", days, count: days)}</span>
            <span :if={days == 7} class="ml-auto text-[0.6875rem] text-neutral-400">{gettext("Default")}</span>
          </label>
        </div>
      </fieldset>

      <label class="flex items-start gap-3 rounded-lg border border-neutral-200 bg-neutral-50 p-4">
        <input
          type="checkbox"
          name="scope_confirmed"
          value="true"
          checked={@scope_confirmed?}
          class="mt-0.5 h-4 w-4 rounded accent-blue-600"
        />
        <span id="slack-context-scope-confirmation" class="text-sm leading-5 text-neutral-700">
          {scope_confirmation(@form, @connect, @channels, @agent)}
        </span>
      </label>

      <p :if={@mode == "reconnect"} class="rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-xs leading-5 text-brand-900">
        {gettext("This refresh starts a new read from the scope you confirm. It does not continue the earlier import.")}
      </p>
      <p :if={not @readiness.dry_run?} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
        {gettext("Context setup is temporarily unavailable. Existing project context is unchanged.")}
      </p>
      <p :if={not @can_manage} class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-xs leading-5 text-neutral-600">
        {gettext("An organization owner or admin must confirm and start this context setup.")}
      </p>

      <div class="flex flex-wrap items-center justify-between gap-3 pt-1">
        <.button patch={@source_path} variant="ghost">{gettext("Back")}</.button>
        <.button type="submit" variant="primary" disabled={not @ready?}>
          {gettext("Start reading and organizing")}
        </.button>
      </div>
    </form>
    """
  end

  attr(:run, :map, required: true)
  attr(:triage_path, :string, required: true)
  attr(:active_context?, :boolean, required: true)
  attr(:grounding?, :boolean, required: true)

  defp processing_step(assigns) do
    ~H"""
    <div id="slack-context-processing" class="mt-6 space-y-5">
      <div class="rounded-xl border border-neutral-200 bg-white p-5 shadow-subtle">
        <div class="flex items-start gap-3">
          <span class="mt-1 h-2.5 w-2.5 shrink-0 animate-pulse rounded-full bg-brand-500"></span>
          <div>
            <h2 class="text-sm font-semibold text-neutral-950">{processing_title(@run)}</h2>
            <p class="mt-1 text-sm leading-6 text-neutral-600">{processing_copy(@run)}</p>
          </div>
        </div>

        <div class="mt-5 grid gap-2 sm:grid-cols-3">
          <.process_stage label={gettext("Read Slack")} state={read_stage(@run)} detail={run_scope(@run)} />
          <.process_stage label={gettext("Organize team knowledge")} state={organize_stage(@run)} detail={gettext("People, projects, and decisions")} />
          <.process_stage
            label={gettext("Wait for your review")}
            state={:waiting}
            detail={if @grounding?, do: gettext("Not enabled yet"), else: gettext("Not saved yet")}
          />
        </div>
      </div>

      <p class="rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-xs leading-5 text-brand-900">
        {processing_persistence_copy(@active_context?, @grounding?)}
      </p>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <.button patch={@triage_path} variant="ghost">{gettext("Return to Triage")}</.button>
        <.button type="button" phx-click="refresh-slack-history">{gettext("Refresh status")}</.button>
      </div>
    </div>
    """
  end

  attr(:triage_path, :string, required: true)

  defp unavailable_step(assigns) do
    ~H"""
    <div id="slack-context-unavailable" class="mt-6 rounded-xl border border-amber-200 bg-amber-50 p-5">
      <h2 class="text-sm font-semibold text-amber-950">
        {gettext("Project context status is temporarily unavailable")}
      </h2>
      <p class="mt-1 text-sm leading-6 text-amber-900">
        {gettext("Comma could not verify the current import status. Existing knowledge is unchanged; retry before starting or confirming anything.")}
      </p>
      <div class="mt-4 flex flex-wrap items-center gap-2">
        <.button type="button" phx-click="refresh-slack-context" variant="primary">
          {gettext("Retry")}
        </.button>
        <.button patch={@triage_path} variant="ghost">{gettext("Back to Triage")}</.button>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:state, :atom, required: true)
  attr(:detail, :string, required: true)

  defp process_stage(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border px-4 py-3",
      @state == :done && "border-emerald-200 bg-emerald-50",
      @state == :active && "border-brand-200 bg-brand-50",
      @state == :waiting && "border-neutral-200 bg-neutral-50"
    ]}>
      <strong class="block text-xs text-neutral-900">{@label}</strong>
      <span class="mt-1 block text-xs text-neutral-500">{@detail}</span>
    </div>
    """
  end

  attr(:run, :map, required: true)
  attr(:preview, :any, required: true)
  attr(:commit?, :boolean, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:confirmed?, :boolean, required: true)
  attr(:selected_artifact_ids, :list, required: true)
  attr(:grounding?, :boolean, required: true)
  attr(:restart_path, :string, required: true)

  defp preview_step(assigns) do
    groups = preview_groups(assigns.preview)
    total_count = Enum.sum(Enum.map(groups, &length(&1.items)))

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:total_count, total_count)
      |> assign(:selected_count, length(assigns.selected_artifact_ids))

    ~H"""
    <div id="slack-context-preview" class="mt-6 space-y-5">
      <div :if={not preview_ok?(@preview)} class="rounded-xl border border-amber-200 bg-amber-50 p-5">
        <h2 class="text-sm font-semibold text-amber-950">{gettext("Comma could not prepare a review")}</h2>
        <p class="mt-1 text-sm leading-6 text-amber-900">
          {gettext("Nothing was enabled. Choose the range again to start a fresh read.")}
        </p>
        <div class="mt-4">
          <.button patch={@restart_path} variant="primary">{gettext("Choose range and try again")}</.button>
        </div>
      </div>
      <p :if={preview_ok?(@preview) and @can_manage and not @commit?} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
        {if @grounding?, do: gettext("The review is ready, but enabling project context is temporarily unavailable."), else: gettext("The review is ready, but saving project knowledge is temporarily unavailable.")}
      </p>
      <p :if={preview_ok?(@preview) and not @can_manage} class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm text-neutral-600">
        {if @grounding?, do: gettext("An organization owner or admin must confirm and enable this project context."), else: gettext("An organization owner or admin must confirm and save this project knowledge.")}
      </p>

      <form
        :if={preview_ok?(@preview) and @commit?}
        id="slack-history-commit-form"
        phx-change="validate-slack-history-commit"
        phx-submit="commit-slack-history"
        class="space-y-5"
      >
        <input type="hidden" name="run_id" value={@run.id} />
        <input type="hidden" name="expected_generation" value={@run.generation} />
        <input type="hidden" name="snapshot_id" value={@run.snapshot_id} />
        <input type="hidden" name="derivation_id" value={@run.derivation_id} />
        <input type="hidden" name="review_revision_id" value={@run.review_revision_id} />

        <div id="slack-context-selection-summary" class="grid gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-xs sm:grid-cols-3">
          <.selection_count value={@total_count} label={gettext("Suggestions")} />
          <.selection_count value={@selected_count} label={gettext("selected")} tone="brand" />
          <.selection_count value={@total_count - @selected_count} label={gettext("excluded")} />
        </div>

        <.preview_group_list
          groups={@groups}
          selected_artifact_ids={@selected_artifact_ids}
          selectable?={true}
          channels={@run.channels}
          grounding?={@grounding?}
        />

        <div class="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
          <label class="flex items-start gap-3">
            <input type="checkbox" name="confirmed" value="true" checked={@confirmed?} class="mt-0.5 h-4 w-4 rounded accent-blue-600" />
            <span class="text-sm leading-5 text-neutral-700">
              {if @grounding?, do: gettext("I reviewed these suggestions and want to enable the selected knowledge as this Agent's project context."), else: gettext("I reviewed these suggestions and want to save the selected knowledge to this Agent's project Knowledge.")}
            </span>
          </label>
          <p :if={@selected_count == 0} class="mt-3 text-xs leading-5 text-amber-800">
            {gettext("Choose at least one suggestion to continue.")}
          </p>
          <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
            <.button patch={@restart_path} variant="ghost">{gettext("Start over with a different range")}</.button>
            <.button type="submit" variant="primary" disabled={not @confirmed? or @selected_count == 0}>
              {if @grounding?, do: gettext("Confirm and enable %{count}", count: @selected_count), else: gettext("Confirm and save %{count} to Knowledge", count: @selected_count)}
            </.button>
          </div>
        </div>
      </form>

      <.preview_group_list
        :if={preview_ok?(@preview) and not @commit?}
        groups={@groups}
        selected_artifact_ids={Enum.flat_map(@groups, &Enum.map(&1.items, fn item -> item.artifact_id end))}
        selectable?={false}
        channels={@run.channels}
        grounding?={@grounding?}
      />
    </div>
    """
  end

  attr(:value, :integer, required: true)
  attr(:label, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp selection_count(assigns) do
    ~H"""
    <div>
      <strong class={[@tone == "brand" && "text-brand-700", @tone != "brand" && "text-neutral-950", "block text-base"]}>
        {@value}
      </strong>
      <span class="mt-0.5 block text-neutral-500">{@label}</span>
    </div>
    """
  end

  attr(:groups, :list, required: true)
  attr(:selected_artifact_ids, :list, required: true)
  attr(:selectable?, :boolean, required: true)
  attr(:channels, :list, default: [])
  attr(:grounding?, :boolean, required: true)

  defp preview_group_list(assigns) do
    ~H"""
    <div class="space-y-4">
      <section :for={group <- @groups} id={"slack-context-preview-#{group.id}"} class="rounded-xl border border-neutral-200 bg-white">
        <header class="flex items-center justify-between border-b border-neutral-100 px-4 py-3">
          <h2 class="text-sm font-semibold text-neutral-950">{group.label}</h2>
          <span class="text-xs text-neutral-500">{length(group.items)}</span>
        </header>
        <div :if={group.items != []} class="divide-y divide-neutral-100">
          <div
            :for={item <- group.items}
            class={[
              "flex items-start gap-3 px-4 py-3",
              @selectable? and item.artifact_id not in @selected_artifact_ids && "bg-neutral-50/70 opacity-60"
            ]}
          >
            <input
              :if={@selectable?}
              id={"slack-context-artifact-#{item.artifact_id}"}
              type="checkbox"
              name="artifact_ids[]"
              value={item.artifact_id}
              checked={item.artifact_id in @selected_artifact_ids}
              class="mt-0.5 h-4 w-4 shrink-0 rounded accent-blue-600"
            />
            <div class="min-w-0 flex-1">
              <label
                for={@selectable? && "slack-context-artifact-#{item.artifact_id}"}
                class={[@selectable? && "cursor-pointer"]}
              >
                <span class="block text-[11px] font-medium uppercase tracking-wide text-neutral-400">
                  {gettext("Current suggestion")}
                </span>
                <strong class="mt-1 block text-sm text-neutral-950">{artifact_title(item)}</strong>
              </label>
              <span :if={@selectable?} class="mt-2 block text-xs font-medium text-brand-700">
                {if item.artifact_id in @selected_artifact_ids, do: gettext("Included"), else: gettext("Excluded")}
              </span>
              <details :if={item.sources != []} class="group mt-3 rounded-lg border border-neutral-200 bg-neutral-50 px-3 py-2">
                <summary class="cursor-pointer list-none text-xs font-medium text-neutral-700">
                  <span>
                {ngettext("%{count} Slack reference", "%{count} Slack references", length(item.sources), count: length(item.sources))}
                  </span>
                  <span aria-hidden="true" class="float-right text-neutral-400 group-open:rotate-180">⌄</span>
                </summary>
                <div class="mt-3 space-y-3 border-t border-neutral-200 pt-3">
                  <p class="text-xs leading-5 text-neutral-500">
                    {source_provenance_copy(@grounding?)}
                  </p>
                  <blockquote :for={source <- preview_sources(item.sources)} class="border-l-2 border-neutral-300 pl-3">
                    <p class="text-xs leading-5 text-neutral-700">{source_excerpt(source)}</p>
                    <footer class="mt-1 text-[11px] text-neutral-400">{source_location(source, @channels)}</footer>
                  </blockquote>
                  <p :if={hidden_source_count(item.sources) > 0} class="text-xs leading-5 text-neutral-500">
                    {ngettext(
                      "%{count} more Slack reference is available in the audit.",
                      "%{count} more Slack references are available in the audit.",
                      hidden_source_count(item.sources),
                      count: hidden_source_count(item.sources)
                    )}
                  </p>
                </div>
              </details>
            </div>
          </div>
        </div>
        <p :if={group.items == []} class="px-4 py-3 text-sm text-neutral-500">
          {gettext("No suggestions in this group.")}
        </p>
      </section>
    </div>
    """
  end

  attr(:run, :map, required: true)
  attr(:state, :atom, required: true)
  attr(:connect, :map, default: nil)
  attr(:can_manage, :boolean, required: true)
  attr(:org, :map, required: true)
  attr(:agent, :map, required: true)
  attr(:knowledge_path, :string, required: true)
  attr(:update_path, :string, required: true)
  attr(:refresh_path, :string, required: true)
  attr(:grounding?, :boolean, required: true)
  attr(:latest_attempt_notice, :string, default: nil)

  defp complete_step(assigns) do
    ~H"""
    <div id="slack-context-complete" class="mt-6 space-y-5">
      <div class="rounded-xl border border-neutral-200 bg-white p-5 shadow-subtle">
        <div class="flex items-start gap-3">
          <span class={[
            "grid h-8 w-8 shrink-0 place-items-center rounded-full",
            @state in [:ready, :disconnected, :refresh] && "bg-emerald-100 text-emerald-700",
            @state in [:needs_update, :unavailable] && "bg-amber-100 text-amber-800"
          ]}>
            <.icon name={if @state in [:needs_update, :unavailable], do: "clock", else: "check"} class="h-4 w-4" />
          </span>
          <div>
            <h2 class="text-base font-semibold text-neutral-950">{complete_title(@state, @grounding?)}</h2>
            <p class="mt-1 text-sm leading-6 text-neutral-600">{complete_copy(@state, @grounding?)}</p>
          </div>
        </div>

        <dl :if={@state != :unavailable} class="mt-5 grid gap-3 border-t border-neutral-100 pt-4 text-xs sm:grid-cols-4">
          <.summary_item label={gettext("Source")} value={source_label(@connect, @run, @state)} />
          <.summary_item label={gettext("Channels")} value={channel_count(@run)} />
          <.summary_item label={gettext("Time range")} value={range_days(@run)} />
          <.summary_item label={gettext("Last updated")} value={updated_label(@run)} />
        </dl>
      </div>

      <p :if={@state == :disconnected} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm leading-6 text-amber-900">
        {disconnected_notice(@grounding?)}
      </p>
      <p :if={@state == :refresh} class="rounded-md border border-brand-200 bg-brand-50 px-3 py-2 text-sm leading-6 text-brand-900">
        {refresh_notice(@grounding?)}
      </p>
      <p :if={@latest_attempt_notice} class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm leading-6 text-amber-900">
        {@latest_attempt_notice}
      </p>

      <div class="flex flex-wrap items-center gap-2">
        <.button patch={@knowledge_path}>{gettext("View knowledge")}</.button>
        <.button :if={@state == :ready and @can_manage} patch={@update_path} variant="primary">{gettext("Update context")}</.button>
        <.button :if={@state == :refresh and @can_manage} patch={@refresh_path} variant="primary">{gettext("Start fresh refresh")}</.button>
        <.button :if={@state == :disconnected and @can_manage} navigate={project_integrations_path(@org, @agent)} variant="primary">
          {gettext("Reconnect Slack")}
        </.button>
        <.button :if={@state == :needs_update and @can_manage} patch={@update_path} variant="primary">{gettext("Set up again")}</.button>
        <.button :if={@state == :unavailable} type="button" phx-click="refresh-slack-context">{gettext("Retry")}</.button>
      </div>
    </div>
    """
  end

  attr(:run, :map, required: true)
  attr(:preview, :any, default: nil)
  attr(:grounding?, :boolean, required: true)
  attr(:runs, :list, required: true)
  attr(:current_run, :map, required: true)
  attr(:previous?, :boolean, required: true)
  attr(:next?, :boolean, required: true)
  attr(:can_manage, :boolean, required: true)

  defp advanced_audit(assigns) do
    assigns = assign(assigns, :other_runs, history_except(assigns.runs, assigns.current_run))

    ~H"""
    <details id="slack-context-audit" class="mt-8 border-t border-neutral-200 pt-4">
      <summary class="cursor-pointer text-xs font-semibold text-neutral-600 hover:text-neutral-900">
        {gettext("Advanced audit and recovery")}
      </summary>
      <p class="mt-2 text-xs leading-5 text-neutral-500">
        {gettext("Technical run evidence, model versions, rollback, and older batches live here.")}
      </p>

      <dl class="mt-4 grid gap-x-8 gap-y-3 text-xs sm:grid-cols-2">
        <.audit_row label={gettext("Import run")} value={full_id(@run.id)} />
        <.audit_row label={gettext("State / generation")} value={"#{@run.state} · g#{@run.generation}"} />
        <.audit_row label={gettext("Workspace / connect")} value={"#{@run.source_workspace_id} · #{full_id(@run.connect_id)}"} />
        <.audit_row label={gettext("Frozen UTC range")} value={utc_range(@run)} />
        <.audit_row label={gettext("Snapshot")} value={full_id(@run.snapshot_id)} />
        <.audit_row label={gettext("Derivation")} value={full_id(@run.derivation_id)} />
        <.audit_row label={gettext("Review revision")} value={full_id(@run.review_revision_id)} />
        <.audit_row label={gettext("Publication")} value={full_id(@run.publication_id)} />
        <.audit_row label={gettext("Runtime grounding")} value={if @grounding?, do: gettext("Enabled"), else: gettext("Disabled")} />
        <.audit_row label={gettext("Lifecycle state")} value={lifecycle_label(@run.context_bundle)} />
        <.audit_row :if={preview_ok?(@preview)} label={gettext("Model revision")} value={derivation_model(preview_value(@preview).derivation)} />
        <.audit_row :if={preview_ok?(@preview)} label={gettext("Prompt / policy / schema")} value={derivation_contract(preview_value(@preview).derivation)} />
      </dl>

      <div :if={preview_ok?(@preview)} class="mt-5 space-y-2">
        <details :for={item <- preview_value(@preview).items} class="rounded-lg border border-neutral-200 px-3 py-2 text-xs">
          <summary class="cursor-pointer font-medium text-neutral-800">{artifact_title(item)}</summary>
          <ul class="mt-2 space-y-1 font-mono text-[0.6875rem] text-neutral-600">
            <li :for={source <- item.sources} class="break-all">{source_ref(source)}</li>
          </ul>
        </details>
      </div>

      <section :if={@other_runs != [] or @previous? or @next?} id="slack-history-import-ledger" class="mt-6 border-t border-neutral-100 pt-4">
        <h3 class="text-xs font-semibold text-neutral-700">{gettext("Import batches")}</h3>
        <div class="mt-3 space-y-2">
          <article :for={run <- @other_runs} id={"slack-history-publication-#{run.id}"} class="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-neutral-200 px-3 py-2">
            <div class="min-w-0">
              <strong class="block truncate text-xs text-neutral-900">{run_scope(run)}</strong>
              <span class="mt-0.5 block font-mono text-[0.6875rem] text-neutral-500">{run.id}</span>
            </div>
            <form :if={run.state == "committed" and @can_manage} id={"slack-history-rollback-form-#{run.id}"} phx-submit="rollback-slack-history">
              <input type="hidden" name="run_id" value={run.id} />
              <.button type="submit" size="sm" variant="danger">{gettext("Roll back")}</.button>
            </form>
          </article>
        </div>
        <div :if={@previous? or @next?} class="mt-3 flex items-center justify-between gap-2">
          <.button :if={@previous?} id="slack-history-newer-page" type="button" size="sm" phx-click="newer-slack-history">{gettext("Newer batches")}</.button>
          <span :if={not @previous?}></span>
          <.button :if={@next?} id="slack-history-older-page" type="button" size="sm" phx-click="older-slack-history">{gettext("Older batches")}</.button>
        </div>
      </section>

      <form :if={@run.state == "committed" and @can_manage} id={"slack-history-rollback-form-#{@run.id}"} phx-submit="rollback-slack-history" class="mt-5 border-t border-neutral-100 pt-4">
        <input type="hidden" name="run_id" value={@run.id} />
        <.button type="submit" size="sm" variant="danger">{gettext("Roll back this import")}</.button>
      </form>
    </details>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp audit_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 border-b border-neutral-100 pb-2">
      <dt class="text-neutral-500">{@label}</dt>
      <dd class="max-w-[65%] break-words text-right font-medium text-neutral-800">{@value}</dd>
    </div>
    """
  end

  defp newest_run({:ok, [run | _]}), do: run
  defp newest_run(_runs), do: nil

  defp active_context_run({:ok, run}), do: run
  defp active_context_run(_result), do: nil

  defp history_runs({:ok, %{runs: runs}}) when is_list(runs), do: runs
  defp history_runs(_history), do: []

  defp history_next?({:ok, %{next_cursor: cursor}}), do: is_binary(cursor)
  defp history_next?(_history), do: false

  defp history_except(runs, %{id: current_id}), do: Enum.reject(runs, &(&1.id == current_id))
  defp history_except(runs, _current), do: runs

  @doc false
  def eligible_channels({:ok, %{channels: channels}}) when is_list(channels) do
    Enum.filter(channels, fn channel ->
      channel[:private?] == false and channel[:shared?] == false and channel[:member?] == true
    end)
  end

  def eligible_channels(_channels), do: []

  defp channels_unavailable?({:error, _reason}), do: true
  defp channels_unavailable?(_channels), do: false

  defp active?(%{state: "paused", paused_reason: "bound_reached"}), do: false
  defp active?(%{state: state}), do: state in @active_states or state == "paused"
  defp active?(_run), do: false

  defp flow_step(runs, active_result, latest_run, active_run, filters) do
    mode = context_mode(filters)
    requested_step = filters["step"]

    cond do
      unavailable_result?(runs) or unavailable_result?(active_result) -> :unavailable
      active?(latest_run) -> :processing
      mode in ["update", "reconnect"] and requested_step == "range" -> :range
      mode in ["update", "reconnect"] -> :source
      latest_run && latest_run.state in @preview_states -> :preview
      is_nil(latest_run) and is_nil(active_run) and requested_step == "range" -> :range
      is_nil(latest_run) and is_nil(active_run) -> :source
      not is_nil(active_run) -> :complete
      latest_run.state in @finished_states or latest_run.state == "paused" -> :complete
      true -> :source
    end
  end

  defp unavailable_result?({:error, _reason}), do: true
  defp unavailable_result?(_result), do: false

  defp task_run(step, latest_run, _active_run) when step in [:processing, :preview],
    do: latest_run

  defp task_run(:complete, latest_run, active_run), do: active_run || latest_run
  defp task_run(_step, _latest_run, _active_run), do: nil

  defp primary_run(state, latest_run, _active_run) when state in [:processing, :review],
    do: latest_run

  defp primary_run(state, _latest_run, active_run)
       when state in [:ready, :disconnected, :refresh],
       do: active_run

  defp primary_run(:needs_update, latest_run, active_run), do: active_run || latest_run
  defp primary_run(:unavailable, _latest_run, active_run), do: active_run
  defp primary_run(_state, _latest_run, _active_run), do: nil

  defp context_mode(%{"mode" => mode}) when mode in ["update", "reconnect"], do: mode
  defp context_mode(_filters), do: nil

  defp summary_state(runs, active_result, latest_run, active_run, source_view) do
    cond do
      unavailable_result?(runs) or unavailable_result?(active_result) -> :unavailable
      active?(latest_run) -> :processing
      latest_run && latest_run.state in @preview_states -> :review
      not is_nil(active_run) -> context_state(active_run, source_view)
      is_nil(latest_run) -> :uninitialized
      true -> :needs_update
    end
  end

  defp context_state(%{state: "committed"} = run, source_view) do
    connect = connect_for_run(source_view, run)

    cond do
      not lifecycle_ready?(run.context_bundle) ->
        :needs_update

      not is_nil(connect) and not same_ref?(run.connect_generation, connect[:connect_generation]) ->
        :refresh

      not is_nil(connect) ->
        :ready

      source_view.state in [:unavailable, :partial] ->
        :unavailable

      verified_source_available?(source_view) ->
        :ready

      true ->
        :disconnected
    end
  end

  defp context_state(_run, _source_view), do: :needs_update

  defp connect_for_run(%{sources: sources}, run) when is_list(sources) and is_map(run) do
    verified_sources = Enum.filter(sources, &verified_source?/1)
    workspace_id = Map.get(run, :source_workspace_id)
    connect_id = Map.get(run, :connect_id)

    Enum.find(verified_sources, fn source ->
      present_ref?(workspace_id) and same_ref?(source[:workspace_id], workspace_id)
    end) ||
      Enum.find(verified_sources, fn source ->
        not present_ref?(workspace_id) and same_ref?(source[:connect_id], connect_id)
      end)
  end

  defp connect_for_run(_source_view, _run), do: nil

  defp verified_source_available?(%{sources: sources}) when is_list(sources),
    do: Enum.any?(sources, &verified_source?/1)

  defp verified_source_available?(_source_view), do: false

  defp verified_source?(source),
    do:
      source[:posture_complete?] != false and source[:source_ready?] == true and
        Enum.all?(
          [:connect_id, :connect_generation, :workspace_id, :app_id],
          &present_ref?(source[&1])
        )

  defp present_ref?(value), do: is_binary(value) and String.trim(value) != ""

  defp later_terminal_attempt_notice(%{id: latest_id} = latest, %{id: active_id})
       when latest_id != active_id do
    case latest do
      %{state: "rolled_back"} ->
        gettext(
          "The latest imported context was rolled back. Other reviewed context remains available."
        )

      %{state: "canceled"} ->
        gettext("The latest update was canceled. Existing project context remains unchanged.")

      %{state: state} when state in ["failed_terminal", "stale_source"] ->
        gettext("The latest update did not finish. Existing project context remains unchanged.")

      %{state: "paused", paused_reason: "bound_reached"} ->
        gettext("The latest update did not finish. Existing project context remains unchanged.")

      _other ->
        nil
    end
  end

  defp later_terminal_attempt_notice(_latest, _active), do: nil

  defp lifecycle_ready?(%{lifecycle_state: "registered", subject_index_state: "complete"}),
    do: true

  defp lifecycle_ready?(_bundle), do: false

  defp lifecycle_label(%{lifecycle_state: lifecycle, subject_index_state: subject_index}),
    do: "#{lifecycle} · #{subject_index}"

  defp lifecycle_label(_bundle), do: gettext("Unavailable")

  defp status_presentation(:uninitialized, _grounding?),
    do: {gettext("Not initialized"), "bg-neutral-100 text-neutral-600"}

  defp status_presentation(:processing, _grounding?),
    do: {gettext("In progress"), "bg-brand-50 text-brand-700"}

  defp status_presentation(:review, _grounding?),
    do: {gettext("Ready to review"), "bg-amber-50 text-amber-800"}

  defp status_presentation(:ready, true),
    do: {gettext("Ready"), "bg-emerald-50 text-emerald-700"}

  defp status_presentation(:ready, false),
    do: {gettext("Saved in Knowledge"), "bg-emerald-50 text-emerald-700"}

  defp status_presentation(:disconnected, true),
    do: {gettext("Ready · Slack disconnected"), "bg-amber-50 text-amber-800"}

  defp status_presentation(:disconnected, false),
    do: {gettext("Saved · Slack disconnected"), "bg-amber-50 text-amber-800"}

  defp status_presentation(:refresh, _grounding?),
    do: {gettext("Refresh available"), "bg-brand-50 text-brand-700"}

  defp status_presentation(:needs_update, _grounding?),
    do: {gettext("Needs update"), "bg-amber-50 text-amber-800"}

  defp status_presentation(:unavailable, _grounding?),
    do: {gettext("Temporarily unavailable"), "bg-amber-50 text-amber-800"}

  defp summary_copy(:uninitialized, _grounding?),
    do: gettext("Initialize recent team context so this Agent does not start cold.")

  defp summary_copy(:processing, _grounding?),
    do: gettext("Comma is reading Slack and organizing team knowledge in the background.")

  defp summary_copy(:review, _grounding?),
    do: gettext("Suggested people, projects, decisions, and context are ready for your review.")

  defp summary_copy(:ready, true),
    do: gettext("Reviewed Slack context is available to this Agent.")

  defp summary_copy(:ready, false),
    do:
      gettext(
        "Reviewed Slack context is saved in Knowledge. Agent use is not enabled in this environment."
      )

  defp summary_copy(:disconnected, _grounding?),
    do: gettext("Existing context stays available even though Slack is disconnected.")

  defp summary_copy(:refresh, _grounding?),
    do: gettext("Slack was reconnected. A fresh optional update is available.")

  defp summary_copy(:needs_update, _grounding?),
    do:
      gettext("The previous setup did not produce active context. Start a fresh read when ready.")

  defp summary_copy(:unavailable, _grounding?),
    do: gettext("Comma could not verify project context status. Existing knowledge is unchanged.")

  defp summary_action(:uninitialized, _grounding?), do: gettext("Let Comma learn about your team")
  defp summary_action(:processing, _grounding?), do: gettext("View progress")
  defp summary_action(:review, true), do: gettext("Review and enable")
  defp summary_action(:review, false), do: gettext("Review and save")

  defp step_kicker(:source), do: gettext("Step 1 of 5")
  defp step_kicker(:range), do: gettext("Step 2 of 5")
  defp step_kicker(:processing), do: gettext("Step 3 of 5")
  defp step_kicker(:preview), do: gettext("Step 4 of 5")
  defp step_kicker(:complete), do: gettext("Step 5 of 5")
  defp step_kicker(:unavailable), do: gettext("Status")

  defp step_title(:source, _state, _grounding?), do: gettext("Confirm Slack source")
  defp step_title(:range, _state, _grounding?), do: gettext("Choose channels and time range")

  defp step_title(:processing, _state, _grounding?),
    do: gettext("Comma is reading and organizing")

  defp step_title(:preview, _state, true), do: gettext("Review the knowledge Comma will use")
  defp step_title(:preview, _state, false), do: gettext("Review the knowledge Comma found")

  defp step_title(:complete, state, grounding?), do: complete_title(state, grounding?)

  defp step_title(:unavailable, _state, _grounding?),
    do: gettext("Project context status is temporarily unavailable")

  defp step_description(:source, "reconnect", true),
    do:
      gettext(
        "This is a fresh optional update. Existing context remains available until you review and enable the new result."
      )

  defp step_description(:source, "reconnect", false),
    do:
      gettext(
        "This is a fresh optional update. Existing knowledge remains saved until you review and save the new result."
      )

  defp step_description(:source, _mode, _grounding?),
    do: gettext("Choose the connected Slack workspace Comma should read for this Agent.")

  defp step_description(:range, _mode, _grounding?),
    do:
      gettext(
        "Monitored channels may be preselected, but nothing starts until you confirm this exact scope."
      )

  defp step_description(:processing, _mode, _grounding?),
    do:
      gettext(
        "The task continues in the background. You can leave and resume it from Triage later."
      )

  defp step_description(:preview, _mode, _grounding?),
    do: gettext("Nothing new is saved until you explicitly confirm this review.")

  defp step_description(:complete, _mode, _grounding?),
    do:
      gettext(
        "Knowledge results live in Knowledge; technical evidence and rollback stay in the audit below."
      )

  defp step_description(:unavailable, _mode, _grounding?),
    do: gettext("Existing knowledge is unchanged while Comma retries this status check.")

  defp complete_title(:ready, true), do: gettext("Project context is ready")
  defp complete_title(:ready, false), do: gettext("Project context is saved in Knowledge")
  defp complete_title(:disconnected, true), do: gettext("Project context is ready")

  defp complete_title(:disconnected, false),
    do: gettext("Project context is saved in Knowledge")

  defp complete_title(:refresh, _grounding?), do: gettext("A fresh update is available")

  defp complete_title(:needs_update, _grounding?),
    do: gettext("Project context needs an update")

  defp complete_title(:unavailable, _grounding?),
    do: gettext("Project context status is temporarily unavailable")

  defp complete_title(_state, true), do: gettext("Project context is ready")
  defp complete_title(_state, false), do: gettext("Project context is saved in Knowledge")

  defp complete_copy(:ready, true),
    do: gettext("Comma can now use the reviewed team context for this Agent.")

  defp complete_copy(:ready, false),
    do:
      gettext(
        "Reviewed context is saved in Knowledge. Agent use is not enabled in this environment."
      )

  defp complete_copy(:disconnected, _grounding?),
    do: gettext("Comma keeps the reviewed context even while its Slack source is disconnected.")

  defp complete_copy(:refresh, true),
    do: gettext("Your current context remains active until you review and enable a fresh update.")

  defp complete_copy(:refresh, false),
    do: gettext("Your current knowledge remains saved until you review and save a fresh update.")

  defp complete_copy(:needs_update, _grounding?),
    do:
      gettext(
        "No new context is active from the latest attempt. You can start again with a fresh scope."
      )

  defp complete_copy(:unavailable, _grounding?),
    do: gettext("Existing knowledge is unchanged while Comma retries this status check.")

  defp complete_copy(_state, grounding?), do: complete_copy(:ready, grounding?)

  defp processing_title(%{state: "created"}), do: gettext("Preparing the Slack read")
  defp processing_title(%{state: "acquiring"}), do: gettext("Reading Slack")
  defp processing_title(%{state: "acquired"}), do: gettext("Slack reading is complete")
  defp processing_title(%{state: "deriving"}), do: gettext("Organizing team knowledge")
  defp processing_title(%{state: "paused"}), do: gettext("Waiting to continue safely")
  defp processing_title(_run), do: gettext("Reading and organizing")

  defp processing_copy(%{state: "paused", paused_reason: "rate_limited"}),
    do: gettext("Slack asked Comma to slow down. The task will continue from its saved place.")

  defp processing_copy(%{state: "paused"}),
    do: gettext("The task is paused safely and can continue without starting over.")

  defp processing_copy(%{state: state}) when state in ["acquired", "deriving"],
    do:
      gettext(
        "Comma finished reading the selected window and is organizing suggestions for review."
      )

  defp processing_copy(_run),
    do: gettext("Comma is reading the selected Slack window. It is safe to leave this page.")

  defp processing_persistence_copy(true, true),
    do:
      gettext(
        "Existing project context remains available. No new knowledge is enabled until you review and confirm the result."
      )

  defp processing_persistence_copy(false, true),
    do: gettext("No new knowledge is enabled until you review and confirm the result.")

  defp processing_persistence_copy(true, false),
    do:
      gettext(
        "Existing project knowledge remains saved. No new knowledge is saved until you review and confirm the result."
      )

  defp processing_persistence_copy(false, false),
    do: gettext("No new knowledge is saved until you review and confirm the result.")

  defp disconnected_notice(true),
    do:
      gettext(
        "Slack is disconnected. The context already enabled for this Agent remains available; reconnecting does not replace it automatically."
      )

  defp disconnected_notice(false),
    do:
      gettext(
        "Slack is disconnected. The knowledge already saved for this Agent remains available; reconnecting does not replace it automatically."
      )

  defp refresh_notice(true),
    do:
      gettext(
        "Slack was reconnected. You can keep the current context or start a fresh read and review the new result before enabling it."
      )

  defp refresh_notice(false),
    do:
      gettext(
        "Slack was reconnected. You can keep the saved knowledge or start a fresh read and review the new result before saving it."
      )

  defp read_stage(%{state: state}) when state in ["acquired", "deriving"], do: :done
  defp read_stage(_run), do: :active

  defp task_persistence_copy(step) when step in [:source, :range],
    do: gettext("Nothing starts until you confirm the scope")

  defp task_persistence_copy(_step),
    do: gettext("Saved as this task progresses · safe to continue later")

  defp organize_stage(%{state: state}) when state in ["acquired", "deriving"], do: :active
  defp organize_stage(_run), do: :waiting

  defp preview_groups({:ok, %{items: items}}) when is_list(items) do
    [
      %{id: "people", label: gettext("People"), kinds: ["person", "people"]},
      %{id: "project", label: gettext("Project"), kinds: ["project"]},
      %{id: "decision", label: gettext("Decision"), kinds: ["decision"]},
      %{id: "context", label: gettext("Context"), kinds: ["context"]}
    ]
    |> Enum.map(fn group ->
      Map.put(group, :items, Enum.filter(items, &(normalize_kind(&1.kind) in group.kinds)))
    end)
  end

  defp preview_groups(_preview), do: []

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: String.downcase(kind)
  defp normalize_kind(_kind), do: "context"

  defp artifact_title(item) do
    payload = item.payload || %{}

    Enum.find_value(["name", "content", :name, :content], item.stable_key, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp source_excerpt(source) do
    payload = source[:payload] || %{}

    case Map.get(payload, "text") || Map.get(payload, :text) do
      text when is_binary(text) and text != "" -> truncate_source_excerpt(text)
      _other -> gettext("Slack message text is unavailable.")
    end
  end

  defp preview_sources(sources), do: Enum.take(sources, @preview_source_limit)
  defp hidden_source_count(sources), do: max(length(sources) - @preview_source_limit, 0)

  defp truncate_source_excerpt(text) do
    text = String.trim(text)

    if String.length(text) > @source_excerpt_graphemes do
      String.slice(text, 0, @source_excerpt_graphemes) <> "…"
    else
      text
    end
  end

  defp source_provenance_copy(true),
    do:
      gettext(
        "These Slack messages explain this suggestion. Only the reviewed suggestion is enabled as project context."
      )

  defp source_provenance_copy(false),
    do:
      gettext(
        "These Slack messages explain this suggestion. Only the reviewed suggestion is saved to Knowledge."
      )

  defp source_location(source, channels) do
    channel_id = source[:channel_id]

    channel =
      Enum.find_value(channels, gettext("Slack channel"), fn candidate ->
        candidate_id = Map.get(candidate, :channel_id)
        candidate_name = Map.get(candidate, :channel_name)

        if same_ref?(candidate_id, channel_id) and present_ref?(candidate_name),
          do: "##{candidate_name}"
      end)

    gettext("%{channel} · %{time}",
      channel: channel,
      time: slack_timestamp_label(source[:message_ts])
    )
  end

  defp slack_timestamp_label(message_ts) when is_binary(message_ts) do
    with [seconds | _rest] <- String.split(message_ts, ".", parts: 2),
         {unix, ""} <- Integer.parse(seconds),
         {:ok, timestamp} <- DateTime.from_unix(unix) do
      Calendar.strftime(timestamp, "%Y-%m-%d %H:%M UTC")
    else
      _other -> gettext("Unknown time")
    end
  end

  defp slack_timestamp_label(_message_ts), do: gettext("Unknown time")

  defp scope_confirmation(form, connect, channels, agent) do
    selected_names =
      channels
      |> Enum.filter(&(&1.id in form.channel_ids))
      |> Enum.map_join(", ", &"##{&1.name}")

    source = source_title(connect || %{})
    scope = if selected_names == "", do: gettext("the selected channels"), else: selected_names

    gettext(
      "Confirm reading %{scope} from %{source} for Agent %{agent} in project %{project} over the last %{days} days. Continuous listening will not change.",
      scope: scope,
      source: source,
      agent: context_agent_label(agent),
      project: context_project_label(agent),
      days: form.range_days
    )
  end

  defp context_agent_label(%{agent_name: name, project_name: project})
       when is_binary(name) and name != "" and is_binary(project) and project != "" do
    if String.downcase(String.trim(name)) == "router", do: project, else: name
  end

  defp context_agent_label(%{agent_name: name}) when is_binary(name) and name != "", do: name
  defp context_agent_label(agent), do: context_project_label(agent)

  defp context_project_label(%{project_name: name}) when is_binary(name) and name != "", do: name
  defp context_project_label(_agent), do: gettext("Unknown project")

  defp monitored?(channel, connect) do
    Enum.any?(connect[:configured_channels] || [], fn configured ->
      configured[:enabled] == true and same_ref?(configured[:channel_id], channel.id)
    end)
  end

  defp source_title(connect),
    do:
      connect[:workspace_name] || connect[:app_name] || connect[:bot_username] ||
        gettext("Slack workspace")

  defp source_detail(connect) do
    [connect[:app_name], connect[:bot_username], connect[:project_name]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp source_label(connect, _run, _state) when is_map(connect), do: source_title(connect)

  defp source_label(_connect, %{source_workspace_id: workspace_id}, :unavailable)
       when is_binary(workspace_id) and workspace_id != "" do
    gettext("Slack · %{workspace} · status unavailable", workspace: workspace_id)
  end

  defp source_label(_connect, %{source_workspace_id: workspace_id}, :ready)
       when is_binary(workspace_id) and workspace_id != "" do
    gettext("Slack · %{workspace}", workspace: workspace_id)
  end

  defp source_label(_connect, %{source_workspace_id: workspace_id}, _state)
       when is_binary(workspace_id) and workspace_id != "" do
    gettext("Slack · %{workspace} · disconnected", workspace: workspace_id)
  end

  defp source_label(_connect, _run, :unavailable), do: gettext("Slack · status unavailable")
  defp source_label(_connect, _run, _state), do: gettext("Slack · disconnected")

  defp channel_count(run),
    do:
      ngettext("%{count} channel", "%{count} channels", length(run.channels),
        count: length(run.channels)
      )

  defp range_days(run) do
    days = max(DateTime.diff(run.range_end, run.range_start, :day), 1)
    ngettext("Last %{count} day", "Last %{count} days", days, count: days)
  end

  defp updated_label(%{updated_at: %DateTime{} = updated_at}),
    do: Calendar.strftime(updated_at, "%Y-%m-%d %H:%M UTC")

  defp updated_label(_run), do: gettext("Unavailable")

  defp run_scope(run), do: "#{channel_count(run)} · #{range_days(run)}"

  defp context_path(org, agent, connect, mode, step) do
    params =
      %{
        "agent" => agent[:agent_id],
        "connect" => connect && connect[:connect_id],
        "mode" => mode,
        "step" => step
      }
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    ~p"/orgs/#{org.slug}/triage/context?#{params}"
  end

  defp knowledge_path(org, agent),
    do: ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => agent[:agent_id]}}"

  defp project_integrations_path(org, agent),
    do: ~p"/orgs/#{org.slug}/projects/#{agent[:project_id]}/integrations"

  defp preview_ok?({:ok, _preview}), do: true
  defp preview_ok?(_preview), do: false
  defp preview_value({:ok, preview}), do: preview

  defp utc_range(run),
    do:
      "#{Calendar.strftime(run.range_start, "%Y-%m-%d %H:%M")} → #{Calendar.strftime(run.range_end, "%Y-%m-%d %H:%M")}"

  defp source_ref(source) do
    scope = source.thread_ts || "channel"

    "slack://#{source.workspace_id}/#{source.channel_id}/#{scope}/#{source.message_ts}" <>
      " · object=#{source.object_id} · version=#{source.observable_version}"
  end

  defp derivation_model(derivation),
    do: "#{derivation.model_provider}/#{derivation.model_id} · #{derivation.model_revision}"

  defp derivation_contract(derivation),
    do:
      "#{derivation.prompt_template_id}@#{derivation.prompt_revision} · #{derivation.policy_revision} · #{derivation.schema_revision}"

  defp full_id(nil), do: "—"
  defp full_id(value) when is_binary(value), do: value
  defp full_id(value), do: to_string(value)

  defp same_ref?(left, right) when not is_nil(left) and not is_nil(right),
    do: to_string(left) == to_string(right)

  defp same_ref?(_left, _right), do: false
end
