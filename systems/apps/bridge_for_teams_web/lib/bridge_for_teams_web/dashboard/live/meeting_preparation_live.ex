defmodule BridgeForTeamsWeb.Dashboard.MeetingPreparationLive do
  use BridgeForTeamsWeb.Dashboard, :live_view
  alias BridgeForTeams.{MeetingPreparation, Memberships, Orgs}
  alias Phoenix.LiveView.JS
  import BridgeForTeamsWeb.Dashboard.MeetingHistoryComponents

  @impl true
  def mount(%{"org" => slug}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, role} when role in ["owner", "admin"] <- Memberships.org_role(org.id, user.id),
         {:ok, projects} <- MeetingPreparation.projects(org, user) do
      {:ok,
       assign(socket,
         page_title: gettext("Meetings"),
         active_nav: :meetings,
         current_org: org,
         current_org_role: role,
         orgs: Orgs.list_orgs_for_user(user.id),
         breadcrumbs: [],
         projects: projects.projects,
         projects_truncated: projects.truncated,
         selected_project: nil,
         history: nil,
         history_loading: false,
         history_error: nil,
         history_cursor: nil,
         selected_record: nil,
         overview: nil,
         error: nil,
         loading: false,
         catalog: nil,
         catalog_loading: false,
         catalog_error: nil,
         form_values: %{},
         saving: false,
         selected_event: nil,
         detail: nil,
         series_page: nil,
         series_loading: false,
         series_error: nil
       )}
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
    project =
      if params["project"],
        do: Enum.find(socket.assigns.projects, &(&1.id == params["project"])),
        else: List.first(socket.assigns.projects)

    socket =
      assign(socket,
        selected_project: project,
        history: nil,
        history_error: nil,
        history_loading: false,
        history_cursor: params["cursor"],
        selected_record: nil,
        selected_event: nil,
        detail: nil,
        overview: nil,
        catalog: nil,
        error: nil,
        catalog_error: nil,
        series_page: nil
      )

    {:noreply, socket |> load_overview() |> load_history()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{saving: true}} = socket)
      when event in ["save", "disable"], do: {:noreply, socket}

  def handle_event("select-project", _params, %{assigns: %{saving: true}} = socket),
    do: {:noreply, socket}

  def handle_event("select-project", %{"project" => id}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, socket.assigns.live_action, id))}

  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> load_overview() |> load_history()}

  def handle_event("select-record", %{"id" => id}, socket) do
    record =
      Enum.find((socket.assigns.history || %{})["meetings"] || [], &(&1["meeting_id"] == id))

    {:noreply, assign(socket, selected_record: record)}
  end

  def handle_event("close-record", _params, socket),
    do: {:noreply, assign(socket, selected_record: nil)}

  def handle_event("change-settings", %{"settings" => values}, socket) do
    changed_connect = values["connect_id"] != socket.assigns.form_values["connect_id"]

    changed_calendar =
      values["series_calendar_key"] != socket.assigns.form_values["series_calendar_key"]

    values =
      if changed_connect, do: Map.put(values, "personal_preparation", "false"), else: values

    socket = assign(socket, form_values: values)

    socket =
      if changed_connect or changed_calendar,
        do: assign(socket, series_page: nil, series_loading: false),
        else: socket

    socket = if changed_connect, do: load_catalog(assign(socket, catalog: nil)), else: socket
    {:noreply, socket}
  end

  def handle_event("reload-catalog", _params, socket), do: {:noreply, load_catalog(socket)}

  def handle_event("more-channels", _params, %{assigns: %{catalog: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("more-channels", _params, socket) do
    attrs = %{
      "connect_id" => socket.assigns.form_values["connect_id"],
      "cursor" => socket.assigns.catalog["next_cursor"]
    }

    {:noreply, start_operation(socket, :channels, "channels", attrs)}
  end

  def handle_event("browse-series", _params, socket) do
    calendar =
      selected_catalog_calendar(socket, socket.assigns.form_values["series_calendar_key"])

    if calendar do
      {:noreply,
       socket
       |> assign(series_loading: true, series_error: nil)
       |> start_operation(:series, "series", Map.take(calendar, ~w(account_id calendar_id)))}
    else
      {:noreply, assign(socket, series_error: gettext("Select a calendar first."))}
    end
  end

  def handle_event("more-series", _params, %{assigns: %{series_page: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("more-series", _params, socket) do
    attrs =
      socket.assigns.series_page["calendar"]
      |> Map.put("cursor", socket.assigns.series_page["next_cursor"])

    {:noreply,
     socket
     |> assign(series_loading: true)
     |> start_operation(:series, "series", attrs)}
  end

  def handle_event("save", %{"settings" => values}, socket) do
    socket = assign(socket, form_values: values)
    calendars = (socket.assigns.catalog || %{})["calendars"] || []
    selected = Enum.filter(calendars, &(calendar_key(&1) in List.wrap(values["calendar_keys"])))

    series =
      if values["scope"] == "series", do: selected_series(socket, values["series_key"]), else: []

    case {selected, series, Integer.parse(values["lead"] || "")} do
      {[], _, _} ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one calendar."))}

      {_, nil, _} ->
        {:noreply, put_flash(socket, :error, gettext("Select a meeting or series."))}

      {_, _, {lead, ""}} ->
        attrs = %{
          "enabled" => true,
          "connect_id" => values["connect_id"],
          "channel_id" => values["channel_id"],
          "calendar_selections" => selected,
          "preparation_lead_minutes" => lead,
          "research_enabled" => values["research"] == "true",
          "calendar_writeback" => values["writeback"] == "true",
          "autojoin" => values["autojoin"] == "true",
          "personal_preparation" => values["personal_preparation"] == "true",
          "series" => series
        }

        {:noreply, socket |> assign(saving: true) |> start_operation(:save, "save", attrs)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Choose a preparation time."))}
    end
  end

  def handle_event("disable", _params, socket),
    do:
      {:noreply,
       socket |> assign(saving: true) |> start_operation(:save, "save", %{"enabled" => false})}

  def handle_event("show-meeting", %{"id" => id}, socket) do
    event = Enum.find(events(socket.assigns.overview), &(&1["meeting_plan_id"] == id))

    if event do
      {:noreply,
       socket
       |> assign(selected_event: event, detail: nil)
       |> start_operation(:detail, "detail", %{"meeting_plan_id" => id})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-detail", _params, socket),
    do: {:noreply, assign(socket, selected_event: nil, detail: nil)}

  @impl true
  def handle_async({operation, project_id, attrs}, {:ok, result}, socket) do
    if socket.assigns.selected_project && socket.assigns.selected_project.id == project_id do
      {:noreply, settle_operation(socket, operation, attrs, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({operation, project_id, attrs}, {:exit, _reason}, socket),
    do: handle_async({operation, project_id, attrs}, {:ok, {:error, :unavailable}}, socket)

  defp load_history(%{assigns: %{live_action: :past, selected_project: project}} = socket)
       when not is_nil(project) do
    if connected?(socket) do
      socket
      |> assign(history: nil, selected_record: nil, history_loading: true, history_error: nil)
      |> start_operation(:history, "history", %{"cursor" => socket.assigns.history_cursor})
    else
      socket
    end
  end

  defp load_history(socket), do: socket

  defp load_overview(%{assigns: %{selected_project: nil}} = socket), do: socket

  defp load_overview(socket) do
    if connected?(socket),
      do:
        socket
        |> assign(loading: true, error: nil)
        |> start_operation(:overview, "overview", %{}),
      else: socket
  end

  defp start_operation(socket, operation, action, attrs) do
    org = socket.assigns.current_org
    user = socket.assigns.current_user
    project_id = socket.assigns.selected_project.id

    start_async(socket, {operation, project_id, attrs}, fn ->
      MeetingPreparation.run(org, user, project_id, action, attrs)
    end)
  end

  defp settle_operation(socket, :history, attrs, result) do
    if socket.assigns.live_action == :past and attrs["cursor"] == socket.assigns.history_cursor do
      case result do
        {:ok, history} ->
          assign(socket,
            history: history,
            history_loading: false,
            history_error: nil,
            selected_record: nil
          )

        {:error, :meeting_history_scope_unavailable} ->
          assign(socket,
            history: nil,
            history_loading: false,
            selected_record: nil,
            history_error:
              gettext(
                "History needs a configured public team channel. Private channels are not shown because Dashboard logins do not verify Slack membership."
              )
          )

        {:error, _} ->
          assign(socket,
            history: nil,
            history_loading: false,
            selected_record: nil,
            history_error:
              gettext(
                "Meeting history is unavailable. Refresh to try again. This does not mean there are no meeting records."
              )
          )
      end
    else
      socket
    end
  end

  defp settle_operation(socket, :overview, _attrs, {:ok, overview}) do
    socket = assign(socket, overview: overview, loading: false, error: nil)

    if socket.assigns.live_action == :settings do
      socket |> assign(form_values: form_values(overview), series_page: nil) |> load_catalog()
    else
      socket
    end
  end

  defp settle_operation(socket, :overview, _attrs, {:error, reason}),
    do: assign(socket, overview: nil, loading: false, error: error_message(reason))

  defp settle_operation(socket, :catalog, attrs, {:ok, catalog}) do
    if attrs["connect_id"] == socket.assigns.form_values["connect_id"] do
      assign(socket, catalog: catalog, catalog_loading: false, catalog_error: nil)
    else
      socket
    end
  end

  defp settle_operation(socket, :catalog, attrs, {:error, reason}) do
    if attrs["connect_id"] == socket.assigns.form_values["connect_id"],
      do: assign(socket, catalog_loading: false, catalog_error: error_message(reason)),
      else: socket
  end

  defp settle_operation(socket, :channels, attrs, {:ok, page}) do
    if attrs["connect_id"] == socket.assigns.form_values["connect_id"] && socket.assigns.catalog do
      catalog = socket.assigns.catalog
      channels = Enum.uniq_by((catalog["channels"] || []) ++ page["channels"], & &1["id"])
      # The picker keeps at most 500 channels in one interactive page.
      assign(socket,
        catalog:
          Map.merge(catalog, %{
            "channels" => Enum.take(channels, 500),
            "next_cursor" => if(length(channels) < 500, do: page["next_cursor"])
          })
      )
    else
      socket
    end
  end

  defp settle_operation(socket, :channels, _attrs, {:error, reason}),
    do: put_flash(socket, :error, error_message(reason))

  defp settle_operation(socket, :series, attrs, {:ok, page}) do
    if current_series_calendar?(socket, attrs),
      do:
        assign(socket,
          series_loading: false,
          series_error: nil,
          series_page: Map.put(page, "calendar", Map.take(attrs, ~w(account_id calendar_id)))
        ),
      else: socket
  end

  defp settle_operation(socket, :series, attrs, {:error, reason}),
    do:
      if(current_series_calendar?(socket, attrs),
        do: assign(socket, series_loading: false, series_error: error_message(reason)),
        else: socket
      )

  defp settle_operation(socket, :save, _attrs, {:ok, _settings}) do
    socket
    |> assign(saving: false)
    |> put_flash(
      :info,
      gettext("Settings saved. Calendar synchronization will apply them shortly.")
    )
    |> push_patch(to: page_path(socket, :index))
  end

  defp settle_operation(socket, :save, _attrs, {:error, reason}),
    do: socket |> assign(saving: false) |> put_flash(:error, error_message(reason))

  defp settle_operation(socket, :detail, attrs, result) do
    if socket.assigns.selected_event &&
         socket.assigns.selected_event["meeting_plan_id"] == attrs["meeting_plan_id"],
       do: assign(socket, detail: result),
       else: socket
  end

  defp current_series_calendar?(socket, attrs),
    do: calendar_key(attrs) == socket.assigns.form_values["series_calendar_key"]

  defp load_catalog(socket) do
    connect_id = socket.assigns.form_values["connect_id"]

    if is_binary(connect_id) and connect_id != "" do
      socket
      |> assign(catalog_loading: true, catalog_error: nil)
      |> start_operation(:catalog, "catalog", %{"connect_id" => connect_id})
    else
      assign(socket, catalog_loading: false)
    end
  end

  defp form_values(overview) do
    settings = overview["settings"]
    connected_bot = Enum.find(overview["connects"], &(bot_connection_state(&1) == :connected))

    %{
      "connect_id" =>
        settings["connect_id"] || get_in(connected_bot || %{}, ["connect_id"]) ||
          "",
      "calendar_keys" => Enum.map(settings["calendar_selections"] || [], &calendar_key/1),
      "channel_id" => settings["channel_id"] || "",
      "lead" => to_string(settings["preparation_lead_minutes"] || 10),
      "research" => to_string(settings["research_enabled"] != false),
      "writeback" => to_string(settings["calendar_writeback"] == true),
      "autojoin" => to_string(settings["mode"] == "join"),
      "personal_preparation" =>
        to_string(is_binary(settings["connect_id"]) and settings["personal_preparation"] != false),
      "scope" => if(settings["series"] in [nil, []], do: "all", else: "series"),
      "series_key" =>
        case settings["series"] do
          [first | _] -> series_key(first)
          _ -> ""
        end
    }
  end

  defp selected_catalog_calendar(socket, key),
    do: Enum.find((socket.assigns.catalog || %{})["calendars"] || [], &(calendar_key(&1) == key))

  defp selected_series(socket, key) do
    available = series_options_data(socket.assigns.series_page, socket.assigns.overview)

    case Enum.find(available, &(series_key(&1) == key)) do
      nil -> nil
      series -> [series]
    end
  end

  defp series_options_data(page, overview) do
    saved = get_in(overview || %{}, ["settings", "series"]) || []
    current = if page, do: Enum.map(page["meetings"], &Map.merge(&1, page["calendar"])), else: []
    Enum.uniq_by(saved ++ current, &series_key/1)
  end

  defp selected_bot(overview, values),
    do: Enum.find(overview["connects"], &(&1["connect_id"] == values["connect_id"])) || %{}

  defp personal_scope_status(source) do
    case source["oauth_bot_scopes"] do
      %{"status" => "known", "scopes" => scopes} ->
        case Enum.reject(~w(users:read.email im:write chat:write), &(&1 in scopes)) do
          [] -> {:ready, []}
          missing -> {:missing, missing}
        end

      _ ->
        {:unknown, []}
    end
  end

  defp personal_scope_message(source) do
    case personal_scope_status(source) do
      {:ready, _} ->
        gettext("This bot has the Slack permissions needed for attendee DMs.")

      {:missing, missing} ->
        gettext("Reconnect this bot with the missing Slack permissions: %{scopes}.",
          scopes: Enum.join(missing, ", ")
        )

      {:unknown, _} ->
        gettext(
          "This bot's Slack permissions are unknown. Reconnect it before enabling attendee DMs."
        )
    end
  end

  defp bot_name(source),
    do:
      source_name(
        source["app_name"],
        source_name(source["bot_username"], gettext("Bot name unavailable"))
      )

  defp channel_label(value), do: "#" <> String.trim_leading(value, "#")

  defp bot_groups(connects) do
    grouped = Enum.group_by(connects, &bot_connection_state/1)

    for {state, label} <- [
          {:connected, gettext("Slack connected")},
          {:unconnected, gettext("Slack not connected")},
          {:unavailable, gettext("Connection status incomplete")}
        ],
        sources = Map.get(grouped, state, []),
        sources != [] do
      %{state: state, label: label, sources: sources}
    end
  end

  defp bot_connection_state(source) do
    cond do
      source["disabled_at"] != nil -> :unconnected
      source["oauth_completed_at"] == nil -> :unconnected
      source_name(source["workspace_id"]) == "" -> :unavailable
      true -> :connected
    end
  end

  defp bot_preparation_label(source, settings) do
    cond do
      settings["connect_id"] != source["connect_id"] -> gettext("Preparation not configured")
      settings["enabled"] == true -> gettext("Preparation enabled")
      true -> gettext("Preparation paused")
    end
  end

  defp slack_source_meta(source) do
    workspace = source_name(source["workspace_name"], gettext("Workspace unavailable"))
    app_name = source_name(source["app_name"])
    username = source_name(source["bot_username"])

    if app_name != "" and username != "" and app_name != username,
      do: "@#{username} · #{workspace}",
      else: workspace
  end

  defp source_name(value, fallback \\ "")
  defp source_name(value, _fallback) when is_binary(value) and value != "", do: value
  defp source_name(_value, fallback), do: fallback

  defp calendar_key(calendar),
    do: Jason.encode!([calendar["account_id"], calendar["calendar_id"]])

  defp series_key(series),
    do: Jason.encode!([series["account_id"], series["calendar_id"], series["event_id"]])

  defp events(nil), do: []
  defp events(overview), do: get_in(overview, ["calendar", "events"]) || []

  defp page_path(socket, action, project_id \\ nil) do
    project_id =
      project_id || (socket.assigns.selected_project && socket.assigns.selected_project.id) || ""

    suffix =
      case action do
        :settings -> "/settings"
        :past -> "/past"
        _ -> ""
      end

    "/orgs/#{socket.assigns.current_org.slug}/meetings#{suffix}?project=#{URI.encode_www_form(project_id)}"
  end

  defp event_status(event, settings) do
    plan = event["plan"] || %{}
    prep = plan["preparation"] || %{}

    cond do
      plan["settings_revision"] != settings["settings_revision"] ->
        {gettext("Updating"), "neutral",
         gettext("Waiting for the latest settings to be applied.")}

      plan["status"] != "planned" ->
        {gettext("Needs attention"), "warning",
         gettext("The meeting could not be prepared. Refresh to check its current state.")}

      prep["card_status"] == "sent" ->
        {gettext("Queued for delivery"), "success",
         gettext(
           "The notice was submitted for delivery; recipient receipt is not confirmed here."
         )}

      prep["card_status"] == "abandoned" ->
        {gettext("Not sent"), "warning",
         gettext("The notice window closed or the meeting changed.")}

      prep["report_available"] ->
        {gettext("Ready"), "success",
         gettext("Shared preparation is ready for the selected channel.")}

      prep["deadline_status"] == "diagnostic_only" ->
        {gettext("Needs attention"), "warning",
         gettext("Preparation did not finish within its window.")}

      prep["research_started"] ->
        {gettext("Preparing"), "neutral", gettext("Reading authorized public sources.")}

      true ->
        {gettext("Scheduled"), "neutral", gettext("Preparation will start before the meeting.")}
    end
  end

  defp error_message(:meeting_personal_scopes_missing),
    do:
      gettext(
        "This bot is missing Slack permissions for attendee DMs. Reconnect it, then try again."
      )

  defp error_message(:meeting_personal_scopes_unknown),
    do:
      gettext(
        "This bot's Slack permissions are unknown. Reconnect it before enabling attendee DMs."
      )

  defp error_message(:forbidden),
    do: gettext("Only organization owners and admins can manage meeting preparation.")

  defp error_message(:calendar_enrollment_no_active_account),
    do: gettext("Connect a Google Calendar account for this Agent Swarm first.")

  defp error_message(:meeting_calendar_connect_unavailable),
    do: gettext("Reconnect Slack, then try again.")

  defp error_message(:invalid_meeting_preparation_settings),
    do: gettext("Check the selected calendars, meeting and channel, then save again.")

  defp error_message(:meeting_calendar_capacity_exceeded),
    do:
      gettext(
        "The meeting service has reached its configured capacity. Contact your administrator."
      )

  defp error_message(_reason),
    do:
      gettext(
        "Meeting preparation is temporarily unavailable. Your saved settings have not been replaced by this page."
      )

  @impl true
  def render(assigns) do
    ~H"""
    <div id="meeting-preparation" phx-hook="BrowserLocalTime" class="mx-auto max-w-6xl space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p class="mb-1 text-xs font-medium uppercase tracking-widest text-neutral-400">{gettext("Meetings")}</p>
          <h1 class="text-2xl font-semibold tracking-tight text-neutral-900">{gettext("Meetings")}</h1>
          <p class="mt-2 max-w-2xl text-sm leading-6 text-neutral-500">{gettext("Prepare for upcoming meetings and find recordings and Canvas from past meetings.")}</p>
        </div>
        <div :if={@selected_project} class="flex items-center gap-2">
          <.button variant="ghost" phx-click="refresh" disabled={@loading || @history_loading || @saving}>{gettext("Refresh")}</.button>
          <.link patch={page_path_socket(@current_org, @selected_project, :settings)} class="inline-flex items-center gap-2 rounded-lg bg-neutral-900 px-4 py-2 text-sm font-medium text-white hover:bg-neutral-700">
            <.icon name="cog" class="size-4" />{gettext("Preparation settings")}
          </.link>
        </div>
      </div>

      <div class="flex flex-wrap items-end justify-between gap-4 border-b border-neutral-200">
        <nav class="flex gap-6" aria-label={gettext("Meeting sections")}>
          <.link patch={page_path_socket(@current_org, @selected_project, :index)} class={["border-b-2 pb-3 text-sm font-medium", if(@live_action in [:index, :settings], do: "border-neutral-900 text-neutral-900", else: "border-transparent text-neutral-500")]}>{gettext("Upcoming")}</.link>
          <.link patch={page_path_socket(@current_org, @selected_project, :past)} class={["border-b-2 pb-3 text-sm font-medium", if(@live_action == :past, do: "border-neutral-900 text-neutral-900", else: "border-transparent text-neutral-500")]}>{gettext("Past meetings")}</.link>
        </nav>
        <form :if={@projects != []} id="meeting-preparation-project" phx-change="select-project" class="mb-2 min-w-48">
          <.select name="project" value={@selected_project && @selected_project.id} options={Enum.map(@projects, &{&1.name, &1.id})} disabled={@saving} aria-label={gettext("Agent Swarm")} />
        </form>
      </div>
      <p :if={@projects_truncated} class="text-xs text-neutral-500">{gettext("Showing the first 50 Agent Swarms.")}</p>

      <.empty_state :if={@projects == []} icon="calendar" title={gettext("No Agent Swarm yet")} description={gettext("Create an Agent Swarm and connect its calendar and Slack workspace to get started.")} />
      <p :if={@error} role="alert" class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">{@error}</p>
      <p :if={@loading && @live_action != :past} role="status" class="py-10 text-sm text-neutral-500">{gettext("Loading meeting preparation…")}</p>

      <div :if={@overview && !@loading && @live_action in [:index, :past]} class="space-y-5">
        <div class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-neutral-200 bg-white px-5 py-4">
          <div class="flex items-center gap-3">
            <span class={["inline-block size-2 rounded-full", if(@overview["settings"]["enabled"], do: "bg-emerald-500", else: "bg-neutral-300")]}></span>
            <div class="text-sm">
              <p class="font-medium">{if @overview["settings"]["enabled"], do: gettext("Team preparation enabled"), else: gettext("Team preparation is not enabled")}</p>
              <p class="mt-1 text-xs text-neutral-500">{settings_summary(@overview["settings"])}</p>
            </div>
          </div>
          <span :if={@overview["settings"]["channel"]} class="rounded-md bg-neutral-100 px-2.5 py-1 text-xs font-medium">{channel_label(@overview["settings"]["channel"])}</span>
        </div>
        <p :if={!@overview["runtime_enabled"]} class="rounded-lg bg-amber-50 p-4 text-sm text-amber-800">{gettext("The meeting service is not enabled for this deployment. Settings can be saved, but preparation will not run until an administrator enables it.")}</p>
        <div :if={@live_action == :index} class={if @selected_event, do: "grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(280px,0.8fr)]", else: "space-y-4"}>
          <section class="min-w-0">
            <div class="mb-3 flex items-center justify-between text-xs text-neutral-500"><span>{gettext("Upcoming 24 hours")}</span><span>{gettext("Times shown in your local timezone")}</span></div>
            <div :if={events(@overview) != []} class="divide-y divide-neutral-100 rounded-xl border border-neutral-200 bg-white">
              <button :for={event <- events(@overview)} type="button" phx-click="show-meeting" phx-value-id={event["meeting_plan_id"]} class="flex w-full flex-wrap items-center gap-4 p-5 text-left transition hover:bg-neutral-50 focus-visible:outline-offset-2">
                <time data-local-time-ms={event["start_ms"]} data-local-time-format="month-day-time" class="w-28 shrink-0 text-sm font-medium tabular-nums">{utc_time(event["start_ms"])}</time>
                <div class="min-w-0 flex-1"><p class="break-words text-sm font-medium text-neutral-900">{event["title"]}</p><p class="mt-1 text-xs leading-5 text-neutral-500">{elem(event_status(event, @overview["settings"]), 2)}</p></div>
                <span class={status_class(elem(event_status(event, @overview["settings"]), 1))}>{elem(event_status(event, @overview["settings"]), 0)}</span>
              </button>
            </div>
            <div :if={events(@overview) == []} class="rounded-xl border border-dashed border-neutral-300 px-6 py-12 text-center">
              <.icon name="calendar" class="mx-auto mb-4 size-8 text-neutral-300" />
              <h2 class="text-sm font-medium">{gettext("No meetings in this preparation window")}</h2>
              <p class="mx-auto mt-2 max-w-md text-sm leading-6 text-neutral-500">{gettext("Only selected calendars and meeting series are included. If a meeting is missing, check its calendar account and selection in Preparation settings.")}</p>
              <.link patch={page_path_socket(@current_org, @selected_project, :settings)} class="mt-5 inline-block text-sm font-medium underline underline-offset-4">{gettext("Check calendar coverage")}</.link>
            </div>
            <p :if={get_in(@overview, ["calendar", "health"]) in ["degraded", "unavailable", "pending"]} class="mt-3 text-xs leading-5 text-amber-700">{gettext("Calendar status is incomplete or awaiting synchronization. An empty list does not confirm that there are no meetings.")}</p>
            <p :if={get_in(@overview, ["calendar", "projection", "truncated"])} class="mt-3 text-xs text-amber-700">{gettext("More meetings exist than this page can show. This view is limited to 20 meetings.")}</p>
          </section>
          <section :if={@selected_event} class="min-w-0 rounded-xl border border-neutral-200 bg-white p-6">
            <div class="flex items-start justify-between gap-3"><h2 class="break-words text-base font-semibold">{@selected_event["title"]}</h2><button phx-click="close-detail" aria-label={gettext("Close")} class="text-neutral-400 hover:text-neutral-900">×</button></div>
            <p class="mt-2 text-xs text-neutral-500">{elem(event_status(@selected_event, @overview["settings"]), 2)}</p>
            <h3 class="mt-6 text-xs font-medium uppercase tracking-wider text-neutral-400">{gettext("Shared preparation")}</h3>
            <p :if={is_nil(@detail)} class="mt-3 text-sm text-neutral-500">{gettext("Loading…")}</p>
            <p :if={match?({:ok, %{"report" => report}} when is_binary(report), @detail)} class="mt-3 whitespace-pre-wrap break-words text-sm leading-7 text-neutral-700">{elem(@detail, 1)["report"]}</p>
            <p :if={match?({:ok, %{"report" => nil}}, @detail)} class="mt-3 text-sm leading-6 text-neutral-500">{gettext("No shared report has been saved yet. Open the calendar event to read the invitation and agenda.")}</p>
            <p :if={match?({:error, _}, @detail)} class="mt-3 text-sm text-amber-700">{gettext("This meeting changed or its report is unavailable. Refresh the meeting list.")}</p>
            <p class="mt-6 border-t border-neutral-100 pt-4 text-xs leading-5 text-neutral-400">{gettext("This page shows team content only. Personal reports are not displayed.")}</p>
          </section>
        </div>
      </div>

      <.meeting_history
        :if={@live_action == :past && @selected_project}
        history={@history}
        loading={@history_loading}
        error={@history_error}
        selected={@selected_record}
        cursor={@history_cursor}
        path={page_path_socket(@current_org, @selected_project, :past)}
      />

      <section :if={@overview && !@loading && @live_action == :settings} class="max-w-4xl rounded-xl border border-neutral-200 bg-white">
        <div class="border-b border-neutral-100 px-6 py-5"><h2 class="text-base font-semibold">{gettext("Team preparation settings")}</h2><p class="mt-1 text-sm text-neutral-500">{gettext("Saved per Agent Swarm. Connecting an account alone does not enable preparation.")}</p></div>
        <form id="meeting-preparation-form" phx-change="change-settings" phx-submit="save" class="space-y-6 p-5 sm:p-6">
          <fieldset disabled={@saving} class="space-y-6">
            <fieldset id="meeting-connect-id" class="max-w-md">
              <legend id="meeting-bot-picker-label" class="mb-2 text-xs font-medium text-neutral-600">{gettext("Slack Bot")}</legend>
              <details id="meeting-bot-picker" class="group relative" phx-mounted={JS.ignore_attributes("open")} phx-click-away={JS.remove_attribute("open", to: "#meeting-bot-picker")} phx-window-keydown={JS.remove_attribute("open", to: "#meeting-bot-picker")} phx-key="escape">
                <summary aria-labelledby="meeting-bot-picker-label" class="grid min-h-16 cursor-pointer list-none grid-cols-[2rem_minmax(0,1fr)_1rem] items-center gap-3 rounded-lg border border-neutral-300 bg-white px-3 py-2.5 marker:hidden hover:border-neutral-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 group-open:border-brand-300 group-open:ring-2 group-open:ring-brand-100">
                  <span class="grid size-8 place-items-center rounded-lg bg-brand-600 text-white"><.icon name="chat-bubble" class="size-4" /></span>
                  <span class="min-w-0">
                    <strong class="block truncate text-sm font-semibold text-neutral-900">{bot_name(selected_bot(@overview, @form_values))}</strong>
                    <span class="mt-0.5 block truncate text-xs text-neutral-500">{slack_source_meta(selected_bot(@overview, @form_values))}</span>
                    <span class="mt-1 block text-xs text-neutral-600">{bot_preparation_label(selected_bot(@overview, @form_values), @overview["settings"])}</span>
                  </span>
                  <.icon name="chevron-down" class="size-4 text-neutral-400 transition-transform group-open:rotate-180" />
                </summary>
                <div class="absolute left-0 top-[calc(100%+0.375rem)] z-40 w-full rounded-lg border border-neutral-200 bg-white p-1.5 shadow-popover">
                  <div :for={group <- bot_groups(@overview["connects"])} role="group" aria-labelledby={"meeting-bot-group-#{group.state}"}>
                    <div id={"meeting-bot-group-#{group.state}"} class="flex items-center justify-between px-2 py-2 text-xs font-medium text-neutral-500"><span>{group.label}</span><span>{length(group.sources)}</span></div>
                    <label :for={source <- group.sources} class="relative block cursor-pointer" phx-click={JS.remove_attribute("open", to: "#meeting-bot-picker")}>
                      <input type="radio" name="settings[connect_id]" value={source["connect_id"]} checked={source["connect_id"] == @form_values["connect_id"]} class="peer sr-only" />
                      <span class="grid grid-cols-[2rem_minmax(0,1fr)_1rem] items-start gap-3 rounded-md px-2 py-2.5 hover:bg-neutral-50 peer-checked:bg-brand-50 peer-focus-visible:ring-2 peer-focus-visible:ring-brand-500">
                        <span class="grid size-8 place-items-center rounded-lg bg-neutral-100 text-neutral-500"><.icon name="chat-bubble" class="size-4" /></span>
                        <span class="min-w-0">
                          <span class="block truncate text-sm font-medium text-neutral-900">{bot_name(source)}</span>
                          <span class="mt-0.5 block truncate text-xs text-neutral-500">{slack_source_meta(source)}</span>
                          <span class="mt-1 block text-xs text-neutral-600">{bot_preparation_label(source, @overview["settings"])}</span>
                        </span>
                        <.icon :if={source["connect_id"] == @form_values["connect_id"]} name="check" class="mt-1 size-4 text-brand-600" />
                      </span>
                    </label>
                  </div>
                  <p :if={@overview["connects"] == []} class="p-3 text-sm text-neutral-500">{gettext("No Slack bot connected.")}</p>
                </div>
              </details>
            </fieldset>
            <section>
              <h3 class="text-sm font-semibold">{gettext("Calendars to include")}</h3><p class="mt-1 text-xs leading-5 text-neutral-500">{gettext("Select up to 10 calendars across connected accounts. Their meeting details will be shared with the channel you choose below.")}</p>
              <p :if={@catalog_loading} class="mt-4 text-sm text-neutral-500">{gettext("Loading calendars and channels…")}</p>
              <p :if={@catalog_error} role="alert" class="mt-4 text-sm text-amber-700">{@catalog_error}</p>
              <input type="hidden" name="settings[calendar_keys][]" value="" />
              <div :if={@catalog} class="mt-4 space-y-4">
                <div :for={{account, calendars} <- Enum.group_by(@catalog["calendars"], & &1["account_name"])} class="rounded-lg border border-neutral-200">
                  <div class="flex items-center gap-2 border-b border-neutral-100 bg-neutral-50 px-4 py-2.5 text-xs text-neutral-500"><.icon name="calendar" class="size-4" /><span class="truncate">Google Calendar · {account}</span></div>
                  <div class="divide-y divide-neutral-100">
                    <label :for={calendar <- calendars} class={["flex cursor-pointer items-center gap-3 px-4 py-3 text-sm hover:bg-neutral-50", calendar_key(calendar) in List.wrap(@form_values["calendar_keys"]) && "bg-brand-50/50"]}>
                      <input type="checkbox" name="settings[calendar_keys][]" value={calendar_key(calendar)} checked={calendar_key(calendar) in List.wrap(@form_values["calendar_keys"])} class="rounded border-neutral-300 accent-neutral-900" />
                      <span class="min-w-0 break-words font-medium text-neutral-800" title={calendar["calendar_id"]}>{calendar["name"]}</span>
                    </label>
                  </div>
                </div>
              </div>
              <div class="mt-3 flex flex-wrap gap-4 text-xs font-medium">
                <.link navigate={~p"/orgs/#{@current_org.slug}/projects/#{@selected_project.id}/connections"} target="_blank" rel="noopener noreferrer" class="underline underline-offset-4">{gettext("Connect another calendar account")}</.link>
                <button type="button" phx-click="reload-catalog" disabled={@catalog_loading} class="underline underline-offset-4">{gettext("Reload connections")}</button>
              </div>
            </section>
            <section class="space-y-3">
              <.select id="meeting-scope" name="settings[scope]" value={@form_values["scope"]} options={[{gettext("All meetings in selected calendars"), "all"}, {gettext("Only one meeting or recurring series"), "series"}]} label={gettext("Meeting scope")} />
              <div :if={@form_values["scope"] == "series" && @catalog} class="space-y-3 rounded-lg bg-neutral-50 p-4">
                <.select id="meeting-series-calendar-key" name="settings[series_calendar_key]" value={@form_values["series_calendar_key"] || ""} options={[{gettext("Select a calendar"), ""} | Enum.map(Enum.filter(@catalog["calendars"], &(calendar_key(&1) in List.wrap(@form_values["calendar_keys"]))), &{&1["name"], calendar_key(&1)})]} label={gettext("Find a meeting in the next 14 days")} />
                <.button type="button" size="sm" phx-click="browse-series" disabled={@series_loading}>{if @series_loading, do: gettext("Loading…"), else: gettext("Browse meetings")}</.button>
                <p :if={@series_error} class="text-xs text-amber-700">{@series_error}</p>
                <.select id="meeting-series-key" name="settings[series_key]" value={@form_values["series_key"] || ""} options={[{gettext("Select a meeting or series"), ""} | Enum.map(series_options_data(@series_page, @overview), &{&1["title"] || &1["event_id"], series_key(&1)})]} label={gettext("Meeting or series")} />
                <button :if={@series_page && @series_page["next_cursor"] not in [nil, ""]} type="button" phx-click="more-series" class="text-xs underline">{gettext("Next meetings page")}</button>
                <p class="text-xs leading-5 text-neutral-500">{gettext("A recurring selection applies to future occurrences of that series. Only meetings with a supported Google Meet link are listed.")}</p>
              </div>
            </section>
            <section class="space-y-3 border-t border-neutral-100 pt-6">
              <h3 class="text-sm font-semibold">{gettext("Preparation content")}</h3>
              <p class="text-xs leading-5 text-neutral-500">{gettext("Every notice includes the meeting time and links. Research does not read private channels, DMs or email.")}</p>
              <input type="hidden" name="settings[research]" value="false" />
              <label class="flex items-start gap-3 text-sm"><input type="checkbox" name="settings[research]" value="true" checked={@form_values["research"] == "true"} class="mt-1 accent-neutral-900" /><span>{gettext("Include previous follow-ups and relevant public discussions")}<span class="mt-1 block text-xs text-neutral-500">{gettext("Turn this off to send only the meeting time and links.")}</span></span></label>
            </section>
            <section class="space-y-4 border-t border-neutral-100 pt-6">
              <h3 class="text-sm font-semibold">{gettext("Delivery")}</h3>
              <div class="grid gap-4 sm:grid-cols-2">
                <.select id="meeting-lead" name="settings[lead]" value={@form_values["lead"]} options={Enum.map([10, 15, 30, 60], &{gettext("%{minutes} minutes before", minutes: &1), to_string(&1)})} label={gettext("Send preparation")} />
                <.select id="meeting-channel-id" name="settings[channel_id]" value={@form_values["channel_id"]} options={channel_options(@catalog, @overview)} label={gettext("Team channel")} />
              </div>
              <button :if={@catalog && @catalog["next_cursor"] not in [nil, ""]} type="button" phx-click="more-channels" class="text-xs underline">{gettext("Load more channels")}</button>
              <p class="text-xs leading-5 text-neutral-500">{gettext("Only channels the bot has joined can receive preparation. Research starts 20 minutes before the selected delivery time.")}</p>
                <div id="meeting-attendee-notifications" class="rounded-lg border border-neutral-200 p-4">
                  <input type="hidden" name="settings[personal_preparation]" value="false" />
                  <label class="flex items-start gap-3">
                    <input id="meeting-attendee-dms" type="checkbox" name="settings[personal_preparation]" value="true" checked={@form_values["personal_preparation"] == "true"} disabled={personal_scope_status(selected_bot(@overview, @form_values)) != {:ready, []} and @form_values["personal_preparation"] != "true"} class="mt-1 accent-neutral-900" />
                    <span>{gettext("Send private reminders to all attendees")}<span class="mt-1 block text-xs leading-5 text-neutral-500">{gettext("Uses this bot to message attendees matched to Slack accounts. Personal opt-outs are respected.")}</span></span>
                  </label>
                  <p id="meeting-attendee-scope-status" class="mt-3 text-xs leading-5 text-neutral-500">{personal_scope_message(selected_bot(@overview, @form_values))}</p>
                  <.link :if={personal_scope_status(selected_bot(@overview, @form_values)) != {:ready, []}} navigate={~p"/orgs/#{@current_org.slug}/projects/#{@selected_project.id}/connections"} target="_blank" rel="noopener noreferrer" class="mt-2 inline-block text-xs underline underline-offset-4">{gettext("Manage Slack connections")}</.link>
                </div>
            </section>
            <details class="border-t border-neutral-100 pt-5">
              <summary class="cursor-pointer text-sm font-medium">{gettext("Additional meeting actions")}</summary>
              <div class="mt-4 space-y-4 text-sm">
                <input type="hidden" name="settings[writeback]" value="false" />
                <label class="flex items-start gap-3"><input type="checkbox" name="settings[writeback]" value="true" checked={@form_values["writeback"] == "true"} class="mt-1 accent-neutral-900" /><span>{gettext("Also write preparation to the calendar event")}<span class="mt-1 block text-xs text-neutral-500">{gettext("Requires organizer access. Existing event details are preserved.")}</span></span></label>
                <input type="hidden" name="settings[autojoin]" value="false" />
                <label class="flex items-start gap-3"><input type="checkbox" name="settings[autojoin]" value="true" checked={@form_values["autojoin"] == "true"} class="mt-1 accent-neutral-900" /><span>{gettext("Automatically join and record the meeting")}<span class="mt-1 block text-xs text-neutral-500">{gettext("Preparation can run without the bot joining the meeting.")}</span></span></label>
              </div>
            </details>
          </fieldset>
          <div class="flex flex-wrap items-center justify-between gap-3 border-t border-neutral-100 pt-5">
            <.button :if={@overview["settings"]["enabled"]} type="button" variant="ghost" phx-click="disable" disabled={@saving}>{gettext("Pause preparation")}</.button>
            <.button type="submit" variant="primary" disabled={@saving || @catalog_loading || is_nil(@catalog)}>{if @saving, do: gettext("Saving…"), else: gettext("Save and enable")}</.button>
          </div>
          <p class="text-xs leading-5 text-neutral-400">{gettext("Changes apply to future work. Messages already submitted for delivery cannot be recalled here.")}</p>
        </form>
      </section>
    </div>
    """
  end

  defp page_path_socket(org, project, action) do
    suffix =
      case action do
        :settings -> "/settings"
        :past -> "/past"
        _ -> ""
      end

    "/orgs/#{org.slug}/meetings#{suffix}" <> if(project, do: "?project=#{project.id}", else: "")
  end

  defp settings_summary(%{"enabled" => true} = settings) do
    gettext("%{count} calendars · %{minutes} minutes before · %{scope}",
      count: length(settings["calendars"] || []),
      minutes: settings["preparation_lead_minutes"] || 10,
      scope:
        if(settings["series"] in [nil, []],
          do: gettext("All selected meetings"),
          else: gettext("Selected series")
        )
    )
  end

  defp settings_summary(_settings),
    do: gettext("Choose calendar sources and a team channel to begin.")

  defp channel_options(catalog, overview) do
    saved = overview["settings"]

    existing =
      if is_binary(saved["channel_id"]),
        do: [{channel_label(saved["channel"] || saved["channel_id"]), saved["channel_id"]}],
        else: []

    channels =
      Enum.map((catalog || %{})["channels"] || [], &{channel_label(&1["name"]), &1["id"]})

    [{gettext("Select a channel"), ""} | Enum.uniq_by(existing ++ channels, &elem(&1, 1))]
  end

  defp status_class("success"),
    do: "shrink-0 rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-medium text-emerald-700"

  defp status_class("warning"),
    do: "shrink-0 rounded-full bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-700"

  defp status_class(_),
    do: "shrink-0 rounded-full bg-neutral-100 px-2.5 py-1 text-xs font-medium text-neutral-600"

  defp utc_time(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%m-%d %H:%M UTC")

  defp utc_time(_), do: "—"
end
