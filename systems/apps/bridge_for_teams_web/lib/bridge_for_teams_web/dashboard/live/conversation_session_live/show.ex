defmodule BridgeForTeamsWeb.Dashboard.ConversationSessionLive.Show do
  @moduledoc "Inspect one task participant's runtime session activity."
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Conversations, Memberships, Orgs, Projects}
  alias BridgeForTeamsWeb.Dashboard.ConversationLive.Show, as: TaskView
  alias BridgeForTeamsWeb.ResponseSanitizer

  @page_size 50
  @task_message_limit 100

  @impl true
  def mount(
        %{
          "org" => slug,
          "id" => project_id,
          "conversation_id" => conversation_id,
          "participant" => participant_id
        },
        _session,
        socket
      ) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id,
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         {:ok, _role} <- Memberships.project_role(project.id, user.id),
         {:ok, conversation} <- Conversations.get_project_conversation(project, conversation_id),
         {:ok, participants} <-
           Conversations.list_project_conversation_participants(project, conversation_id),
         conversation = Map.put(conversation, "participants", participants),
         {:ok, target} <-
           Conversations.debug_trace_target(conversation, participant_id: participant_id) do
      {:ok,
       socket
       |> assign(
         orgs: orgs,
         current_org: org,
         current_org_role: org_role,
         project: project,
         conversation: conversation,
         participant: participant(conversation, target.participant_id),
         target: target,
         records: [],
         runtime_kind: nil,
         timeline: [],
         tool_evidence: nil,
         task_messages: [],
         task_messages_status: :closed,
         records_status: :loading,
         loading_older: false,
         has_more: false,
         next_before: nil,
         history_truncated: false,
         archived_through: 0,
         active_nav: :projects,
         page_title: gettext("Session activity"),
         breadcrumbs: []
       )
       |> load_records(nil)}
    else
      _ ->
        {:ok,
         socket
         |> assign(:orgs, orgs)
         |> put_flash(:error, gettext("Session record not found."))
         |> push_navigate(to: ~p"/orgs/#{slug}/projects/#{project_id}/tasks/#{conversation_id}")}
    end
  end

  @impl true
  def handle_async({:records, before}, {:ok, {:ok, result}}, socket) do
    result = ResponseSanitizer.sanitize(result)
    page = result["records"] || []
    records = if before, do: merge_records(page, socket.assigns.records), else: page
    runtime_kind = result["runtime_kind"] || socket.assigns.runtime_kind
    next_before = result["next_before"]

    {:noreply,
     assign(socket,
       records: records,
       runtime_kind: runtime_kind,
       timeline: timeline(runtime_kind, records),
       tool_evidence: nil,
       records_status: :ok,
       loading_older: false,
       has_more: result["has_more"] == true and is_binary(next_before),
       next_before: next_before,
       # The hot boundary is not the start of history: archived records
       # exist beyond it and the UI must say so instead of "fully loaded".
       history_truncated: result["history_truncated"] == true,
       archived_through: result["archived_through"] || 0
     )}
  end

  def handle_async({:records, nil}, _, socket),
    do: {:noreply, assign(socket, records_status: :error, loading_older: false)}

  def handle_async({:records, _before}, _, socket),
    do: {:noreply, assign(socket, :loading_older, false)}

  @impl true
  def handle_event("show_tool_evidence", %{"id" => id}, socket) do
    if can_read_project?(socket) do
      item = Enum.find(socket.assigns.timeline, &(&1.id == id))

      evidence =
        if item && item.tool_data do
          %{
            id: id,
            input: full_detail(item.tool_data.input),
            output: full_detail(item.tool_data.output),
            failure: item.tool_data[:failure] == true,
            page: result_page(item.tool_data.output)
          }
        end

      {:noreply, assign(socket, :tool_evidence, evidence)}
    else
      {:noreply, clear_review_context(socket)}
    end
  end

  def handle_event("hide_tool_evidence", _, socket),
    do: {:noreply, assign(socket, :tool_evidence, nil)}

  def handle_event("show_task_messages", _params, socket) do
    if can_read_project?(socket) do
      # One explicit, bounded snapshot of this mounted Task only. No render-
      # time read, polling or client-supplied scope; reopening fetches anew.
      case Conversations.get_project_conversation_with_messages(
             socket.assigns.project,
             socket.assigns.conversation["conversation_id"],
             limit: @task_message_limit,
             tail: @task_message_limit
           ) do
        {:ok, %{messages: messages}} ->
          {:noreply, assign(socket, task_messages: messages, task_messages_status: :ok)}

        {:error, _reason} ->
          {:noreply, assign(socket, task_messages: [], task_messages_status: :error)}
      end
    else
      {:noreply, clear_review_context(socket)}
    end
  end

  def handle_event("hide_task_messages", _params, socket),
    do: {:noreply, assign(socket, task_messages: [], task_messages_status: :closed)}

  def handle_event("load_older", _, socket) do
    case socket.assigns do
      %{has_more: true, loading_older: false, next_before: before} when is_binary(before) ->
        {:noreply, socket |> assign(:loading_older, true) |> load_records(before)}

      _ ->
        {:noreply, socket}
    end
  end

  defp can_read_project?(socket) do
    with {:ok, _} <-
           Memberships.org_role(socket.assigns.current_org.id, socket.assigns.current_user.id),
         {:ok, _} <-
           Memberships.project_role(socket.assigns.project.id, socket.assigns.current_user.id) do
      true
    else
      _ -> false
    end
  end

  defp clear_review_context(socket) do
    assign(socket,
      records: [],
      timeline: [],
      tool_evidence: nil,
      task_messages: [],
      task_messages_status: :closed,
      records_status: :error,
      has_more: false,
      next_before: nil
    )
  end

  defp load_records(socket, before) do
    socket = if before, do: socket, else: assign(socket, :records_status, :loading)

    if connected?(socket) do
      %{agent_id: agent_id, session_id: session_id} = socket.assigns.target

      start_async(socket, {:records, before}, fn ->
        Conversations.get_session_records(agent_id, session_id,
          limit: @page_size,
          before: before
        )
      end)
    else
      socket
    end
  end

  defp participant(%{"participants" => participants}, id) when is_list(participants),
    do: Enum.find(participants, %{}, &(&1["participant_id"] == id))

  defp participant(_, _), do: %{}

  defp participant_label(participant),
    do:
      participant["agent_name"] || participant["display_name"] || participant["role_label"] ||
        participant["participant_id"] || gettext("Agent")

  defp timeline("external", records) when is_list(records) do
    Enum.flat_map(records, &external_operation_entry/1)
  end

  defp timeline("internal", records) when is_list(records) do
    # An asynchronous tool's initial role=tool record only acknowledges running.
    # Its later runtime completion owns the returned result. Reconcile after
    # merging pages, including when the request is on an older page.
    records = Enum.map(records, &normalize_tool_completion/1)

    tool_results =
      records
      |> Enum.filter(&(&1["role"] == "tool" and present?(&1["tool_call_id"])))
      |> Map.new(&{&1["tool_call_id"], &1})

    requested_tool_ids =
      records
      |> Enum.flat_map(&tool_calls/1)
      |> MapSet.new(& &1["id"])

    Enum.flat_map(records, fn
      %{"role" => "assistant"} = record ->
        assistant_entries(record, tool_results)

      %{"role" => "tool", "tool_call_id" => id} = record ->
        if MapSet.member?(requested_tool_ids, id) or Map.get(tool_results, id) != record,
          do: [],
          else: [tool_call_entry(%{"id" => id}, record, record)]

      record ->
        [message_entry(record)]
    end)
  end

  defp timeline(_, _), do: []

  defp normalize_tool_completion(
         %{
           "role" => "runtime",
           "type" => "tool_call_failed",
           "source_tool_call_id" => id
         } = record
       )
       when is_binary(id) do
    # The durable envelope owns the terminal type/id. Keep the already-visible
    # failure summary, not the private repair diagnostic inside content.
    Map.merge(record, %{
      "role" => "tool",
      "tool_call_id" => id,
      "tool_name" => get_in(record, ["source_refs", "tool_name"]),
      "status" => "error",
      "error" => true,
      "output" => %{
        "status" => "error",
        "summary" => record["summary"],
        "detail_visibility" => gettext("Private failure details are not shown.")
      }
    })
  end

  defp normalize_tool_completion(
         %{
           "role" => "runtime",
           "type" => "tool_call_completed",
           "source_tool_call_id" => id
         } = record
       )
       when is_binary(id) do
    output = sanitize_tool_value(record["content"])
    payload = if is_map(output), do: output, else: %{}

    Map.merge(record, %{
      "role" => "tool",
      "tool_call_id" => id,
      "tool_name" => get_in(payload, ["source_refs", "tool_name"]),
      "status" => payload["status"] || record["status"],
      "error" => payload["error"],
      "output" => output
    })
  end

  defp normalize_tool_completion(record), do: record

  defp assistant_entries(record, tool_results) do
    messages = if present?(record["content"]), do: [message_entry(record)], else: []

    tools =
      record
      |> tool_calls()
      |> Enum.map(&tool_call_entry(&1, Map.get(tool_results, &1["id"]), record))

    reasoning_entries(record) ++ messages ++ tools
  end

  defp reasoning_entries(record) do
    case reasoning_summary(record) do
      value when value not in [nil, ""] ->
        [
          record_entry(
            Map.put(record, "id", "reasoning-#{record_id(record)}"),
            gettext("Thinking"),
            value,
            :reasoning
          )
        ]

      _ ->
        []
    end
  end

  defp reasoning_summary(%{"provider_meta" => %{"responses_items" => items}})
       when is_list(items) do
    summaries =
      items
      |> Enum.filter(&(&1["type"] == "reasoning"))
      |> Enum.flat_map(&List.wrap(&1["summary"]))
      |> Enum.filter(&(&1["type"] == "summary_text"))
      |> Enum.map(& &1["text"])
      |> Enum.filter(&present?/1)

    if summaries == [], do: nil, else: Enum.join(summaries, "\n")
  end

  defp reasoning_summary(_record), do: nil

  defp message_entry(%{"role" => "tool"} = record),
    do:
      record_entry(
        Map.put(record, "id", "tool-#{record["tool_call_id"] || record["id"]}"),
        record["tool_name"] || gettext("Tool result"),
        record["output"] || record["content"],
        operation_kind(record["tool_name"])
      )

  defp message_entry(%{"role" => "runtime"} = record),
    do:
      record_entry(
        record,
        record["type"] || gettext("Runtime event"),
        record["summary"] || record["content"],
        :runtime
      )

  defp message_entry(%{"role" => role} = record) do
    record_entry(
      record,
      message_name(role, record),
      record["content"] || record["summary"] || record["output"] || record,
      message_kind(role)
    )
  end

  defp message_entry(record) do
    record_entry(
      record,
      record["type"] || gettext("Session record"),
      record["summary"] || record["content"] || record,
      :runtime
    )
  end

  defp record_entry(record, name, value, kind) do
    status = record["status"] || if(record["error"] == true, do: "error")

    entry(
      record_id(record),
      name,
      value_summary(record["summary"] || value),
      result_detail(value),
      status,
      record["created_at"],
      record["duration_ms"],
      kind
    )
  end

  defp record_id(record),
    do:
      record["id"] || record["source_message_id"] || record["runtime_message_id"] ||
        :erlang.phash2(record)

  # Runtime role=user includes Router/Agent deliveries, not just human input.
  defp message_name("user", _record), do: gettext("Input")
  defp message_name("assistant", _record), do: gettext("Agent")
  defp message_name("summary", _record), do: gettext("Summary")
  defp message_name("system", _record), do: gettext("System")
  defp message_name("runtime", record), do: record["type"] || gettext("Runtime event")
  defp message_name(_role, _record), do: gettext("Message")

  defp message_kind("user"), do: :user
  defp message_kind("assistant"), do: :assistant
  defp message_kind("summary"), do: :summary
  defp message_kind("system"), do: :system
  defp message_kind("runtime"), do: :runtime
  defp message_kind(_), do: :message

  defp entry(id, name, summary, detail, status, time, duration, kind),
    do: %{
      id: "record-#{id || :erlang.phash2({name, status, time, duration})}",
      name: name || gettext("Session record"),
      summary: summary,
      detail: detail,
      status: status,
      time: format_time(time),
      duration: duration,
      kind: kind,
      tool_data: nil
    }

  defp merge_records(older, current) do
    Enum.uniq_by(older ++ current, fn record ->
      record["id"] || record["event_id"] || record["event_ref"] || :erlang.phash2(record)
    end)
  end

  defp tool_calls(%{"role" => "assistant", "tool_calls" => calls}) when is_list(calls) do
    calls
    |> Enum.filter(&(is_map(&1) and present?(&1["id"])))
    |> Enum.map(fn call ->
      args = call["args"] || call["arguments"] || %{}

      %{
        "id" => call["id"],
        "name" => if(is_map(args), do: args["tool"] || call["name"], else: call["name"]),
        "input" => if(is_map(args), do: args["params"] || args, else: args)
      }
    end)
  end

  defp tool_calls(_), do: []

  defp tool_call_entry(call, result, request) do
    full_input = sanitize_tool_value(call["input"])
    full_output = result && tool_output(result)
    input = full_input |> tool_input_summary() |> detail()
    output = result_detail(full_output)
    name = call["name"] || (result && result["tool_name"]) || gettext("Tool call")

    entry(
      "tool-#{call["id"]}",
      name,
      input,
      output,
      result && (result["status"] || if(result["error"] == true, do: "error")),
      (result && (result["completed_at"] || result["created_at"])) || request["created_at"],
      result && result["duration_ms"],
      operation_kind(name)
    )
    |> Map.put(:tool_data, %{
      input: full_input,
      output: full_output,
      failure: result && result["type"] == "tool_call_failed"
    })
  end

  defp external_operation_entry(
         %{
           "id" => record_id,
           "type" => "runtime.event",
           "data" => %{"event" => %{"type" => "operation"} = event}
         } = record
       ) do
    input = sanitize_tool_value(event["input"])
    output = sanitize_tool_value(event["output"])

    [
      entry(
        event["operation_id"] || record_id,
        event["name"] || gettext("Operation"),
        input |> tool_input_summary() |> detail(),
        result_detail(output),
        event["status"],
        record["created_at"],
        event["duration_ms"],
        operation_kind(event["name"])
      )
      |> Map.put(:tool_data, %{input: input, output: output})
    ]
  end

  defp external_operation_entry(_record), do: []

  defp tool_input_summary(input) when is_map(input) do
    input["path"] || input["command"] || input["query"] || input["pattern"] || input
  end

  defp tool_input_summary(input), do: input

  defp tool_output(result),
    do: sanitize_tool_value(result["output"] || result["content"])

  # Tool transports can serialize JSON inside content/result_page strings.
  # Apply the existing field redaction to those objects too. This is not a
  # promise to detect secrets embedded in arbitrary prose or partial JSON.
  defp sanitize_tool_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> sanitize_tool_value(decoded)
      _ -> value
    end
  end

  defp sanitize_tool_value(value) when is_map(value) do
    value
    |> ResponseSanitizer.sanitize()
    |> Map.new(fn {key, nested} -> {key, sanitize_tool_value(nested)} end)
  end

  defp sanitize_tool_value(value) when is_list(value), do: Enum.map(value, &sanitize_tool_value/1)
  defp sanitize_tool_value(value), do: value

  defp full_detail(nil), do: nil

  defp full_detail(value) when is_map(value) or is_list(value),
    do: Jason.encode!(value, pretty: true)

  defp full_detail(value), do: to_string(value)

  defp result_page(%{"result_page" => page}) when is_map(page), do: page
  defp result_page(_), do: nil

  defp operation_kind(name) do
    name = name |> to_string() |> String.downcase()

    cond do
      String.contains?(name, ["grep", "search", "query"]) -> :search
      String.contains?(name, ["read", "file", "fs."]) -> :file
      String.contains?(name, ["exec", "command", "shell", "bash"]) -> :command
      String.contains?(name, ["http", "web", "browser", "network"]) -> :network
      true -> :tool
    end
  end

  defp operation_icon(:search), do: "search"
  defp operation_icon(:file), do: "folder"
  defp operation_icon(:command), do: "bolt"
  defp operation_icon(:network), do: "globe"
  defp operation_icon(:runtime), do: "zap"
  defp operation_icon(:user), do: "chat-bubble"
  defp operation_icon(:assistant), do: "sparkles"
  defp operation_icon(:summary), do: "document-text"
  defp operation_icon(:reasoning), do: "sparkles"
  defp operation_icon(:system), do: "cog"
  defp operation_icon(:message), do: "chat-bubble"
  defp operation_icon(_), do: "cube"

  defp operation_icon_class(:search), do: "bg-blue-50 text-blue-600"
  defp operation_icon_class(:file), do: "bg-cyan-50 text-cyan-700"
  defp operation_icon_class(:command), do: "bg-amber-50 text-amber-700"
  defp operation_icon_class(:network), do: "bg-emerald-50 text-emerald-700"
  defp operation_icon_class(:runtime), do: "bg-violet-50 text-violet-700"
  defp operation_icon_class(:user), do: "bg-sky-50 text-sky-700"
  defp operation_icon_class(:assistant), do: "bg-fuchsia-50 text-fuchsia-700"
  defp operation_icon_class(:summary), do: "bg-indigo-50 text-indigo-700"
  defp operation_icon_class(:reasoning), do: "bg-purple-50 text-purple-700"
  defp operation_icon_class(:system), do: "bg-slate-100 text-slate-600"
  defp operation_icon_class(:message), do: "bg-sky-50 text-sky-700"
  defp operation_icon_class(_), do: "bg-neutral-100 text-neutral-600"

  defp detail_label(kind) when kind in [:search, :file, :command, :network, :tool],
    do: gettext("Result")

  defp detail_label(_kind), do: gettext("Details")

  defp present?(value), do: value not in [nil, ""]

  defp detail(nil), do: nil

  defp detail(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.slice(value, 0, 500)
    end
  end

  defp detail(value) when is_map(value) or is_list(value),
    do: value |> Jason.encode!() |> detail()

  defp detail(value), do: value |> to_string() |> detail()

  defp result_detail(nil), do: nil

  defp result_detail(value) when is_map(value) or is_list(value),
    do: value |> Jason.encode!() |> result_detail()

  defp result_detail(value) do
    value = value |> to_string() |> String.trim()

    cond do
      value == "" -> nil
      String.length(value) > 2_000 -> String.slice(value, 0, 2_000) <> "\n..."
      true -> value
    end
  end

  defp value_summary(nil), do: nil

  defp value_summary(value) do
    value
    |> result_detail()
    |> case do
      nil -> nil
      text -> text |> String.replace(~r/\s+/, " ") |> String.slice(0, 180)
    end
  end

  defp format_time(value) when is_integer(value) and value > 0 do
    # Inbound conversation messages retain milliseconds; runtime records use
    # seconds. Match the Dashboard.RelativeTime convention for these records.
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> nil
    end
  end

  defp format_time(value) when is_binary(value), do: value
  defp format_time(_), do: nil

  defp display_time(nil), do: gettext("Time unavailable")

  defp display_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M:%S")
      _ -> value
    end
  end

  defp duration(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)} s"
  defp duration(ms) when is_integer(ms) and ms > 0, do: "#{ms} ms"
  defp duration(_), do: nil

  defp task_message_sender(message) do
    type =
      case message["actor_type"] do
        "agent" -> gettext("Agent")
        "user" -> gettext("User")
        "provider_user" -> gettext("External user")
        "system" -> gettext("System")
        _ -> gettext("Sender")
      end

    identities =
      if message["actor_type"] in ["user", "provider_user"],
        do: [message["user_id"], message["role_label"]],
        else: [message["role_label"], message["agent_id"]]

    name =
      [message["display_name"] | identities]
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

    if name, do: type <> " · " <> name, else: type
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <header>
        <div class="min-w-0">
          <.link navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/tasks/#{@conversation["conversation_id"]}"} class="text-sm text-neutral-500 hover:text-neutral-900">
            <.icon name="arrow-left" class="h-4 w-4" /> {gettext("Task")}
          </.link>
          <h1 class="mt-3 text-lg font-semibold">{gettext("Session activity")}</h1>
          <p class="mt-1 truncate text-sm text-neutral-500">{participant_label(@participant)}</p>
          <button :if={@task_messages_status == :closed} type="button" phx-click="show_task_messages" phx-disable-with={gettext("Loading Task messages…")} aria-controls="session-task-context" aria-expanded="false" class="mt-3 text-sm font-medium text-blue-700 underline underline-offset-2">
            {gettext("Show Task messages")}
          </button>
          <button :if={@task_messages_status != :closed} type="button" phx-click="hide_task_messages" aria-controls="session-task-context" aria-expanded="true" class="mt-3 text-sm font-medium text-blue-700 underline underline-offset-2">
            {gettext("Hide Task messages")}
          </button>
        </div>
      </header>

      <div class={[@task_messages_status != :closed && "grid items-start gap-6 xl:grid-cols-2"]}>
      <section :if={@task_messages_status != :closed} id="session-task-context" aria-label={gettext("Task conversation snapshot")}>
        <h2 class="border-b border-neutral-200 pb-3 text-sm font-semibold">{gettext("Task conversation")}</h2>
        <p class="mt-3 text-xs leading-5 text-neutral-500">{gettext("Up to 100 latest committed messages, loaded when opened — not the full source thread. Earlier Task context may be outside this window. These messages are not an acceptance or delivery receipt.")}</p>
          <.empty_state :if={@task_messages_status == :error} icon="chat-bubble" title={gettext("Task messages unavailable")} description={gettext("Close and reopen to try again. Session activity remains available.")} />
        <p :if={@task_messages_status == :ok && @task_messages == []} class="py-6 text-sm text-neutral-500">{gettext("No Task messages in this snapshot.")}</p>
        <div :if={@task_messages_status == :ok && @task_messages != []} id="session-task-messages" class="mt-4 space-y-5">
          <article :for={message <- @task_messages} class="min-w-0 space-y-2 rounded-lg border border-neutral-200 bg-white p-3.5 text-sm text-neutral-800">
            <header class="flex flex-wrap items-center justify-between gap-2 border-b border-neutral-100 pb-2 text-xs">
              <span class="min-w-0 break-all font-medium text-neutral-700">{task_message_sender(message)}</span>
              <time class="text-neutral-400">{message["created_at"] |> format_time() |> display_time()}</time>
            </header>
            <TaskView.message_body message={message} org={@current_org} project={@project} conversation={@conversation} />
          </article>
        </div>
      </section>

      <section class={[@task_messages_status != :closed && "min-w-0 xl:sticky xl:top-4"]} aria-label={gettext("Session activity timeline")}>
        <h2 class="border-b border-neutral-200 pb-3 text-sm font-semibold">{gettext("Operation timeline")}</h2>

        <p :if={@records_status == :loading} class="py-12 text-center text-sm text-neutral-500">{gettext("Loading session activity…")}</p>
        <.empty_state :if={@records_status == :error} icon="bolt" title={gettext("Session activity unavailable")} description={gettext("The runtime session record could not be loaded.")} />
        <.empty_state :if={@records_status == :ok && @timeline == [] && !@has_more && !@history_truncated} icon="inbox" title={gettext("No session activity recorded")} description={gettext("This session has no records yet.")} />
        <.empty_state :if={@records_status == :ok && @timeline == [] && !@has_more && @history_truncated} icon="inbox" title={gettext("Activity archived")} description={gettext("All earlier activity has been archived and is not shown here.")} />

        <div
          :if={@records_status == :ok && (@timeline != [] || @has_more)}
          id="session-activity-scroll"
          phx-hook="SessionTimeline"
          data-page-key={@next_before || ""}
          data-has-more={to_string(@has_more)}
          data-loading={to_string(@loading_older)}
          tabindex="0"
          class="mt-4 h-[calc(100vh-16rem)] min-h-80 overflow-y-auto pr-3"
        >
          <p :if={@loading_older} class="pb-3 text-center text-xs text-neutral-400">{gettext("Loading earlier activity…")}</p>
          <p :if={!@has_more && @history_truncated} class="pb-3 text-center text-xs text-neutral-400">{gettext("Earlier activity has been archived and is not shown here.")}</p>
          <ol id="session-activity-timeline" class="divide-y divide-neutral-100 border-y border-neutral-200">
            <li :for={item <- @timeline} id={item.id}>
              <details class="group" open={@tool_evidence && @tool_evidence.id == item.id}>
                <summary class="flex min-h-8 cursor-pointer list-none items-center gap-1.5 px-1 hover:bg-neutral-50">
                  <span class={["flex h-5 w-5 shrink-0 items-center justify-center rounded", operation_icon_class(item.kind)]}>
                    <.icon name={operation_icon(item.kind)} class="h-3 w-3" />
                  </span>
                  <h3 class="w-20 shrink-0 truncate text-xs font-medium text-neutral-800 sm:w-28">{item.name}</h3>
                  <span class="min-w-0 flex-1 truncate text-[11px] text-neutral-500">{item.summary}</span>
                  <span :if={item.status not in [nil, ""]} class="hidden shrink-0 text-[11px] text-neutral-500 sm:inline">{item.status}</span>
                  <span :if={duration(item.duration)} class="hidden w-11 shrink-0 text-right text-[11px] text-neutral-400 sm:inline">{duration(item.duration)}</span>
                  <time title={item.time} class="hidden w-14 shrink-0 text-right text-[11px] tabular-nums text-neutral-400 md:block">{display_time(item.time)}</time>
                  <.icon :if={item.detail || item.tool_data} name="chevron-right" class="h-3 w-3 shrink-0 text-neutral-400 transition-transform group-open:rotate-90" />
                  <span :if={!item.detail && !item.tool_data} class="h-3 w-3 shrink-0"></span>
                </summary>
                <div :if={item.detail || item.tool_data} class="ml-7 border-t border-neutral-100 px-2.5 py-2">
                  <p :if={!@tool_evidence || @tool_evidence.id != item.id} class="mb-1 text-[11px] font-medium text-neutral-500">{if item.tool_data, do: gettext("Result preview · up to 2,000 characters"), else: detail_label(item.kind)}</p>
                  <pre :if={item.detail && (!@tool_evidence || @tool_evidence.id != item.id)} class="max-h-64 overflow-auto whitespace-pre-wrap break-words font-sans text-[11px] leading-4 text-neutral-600">{item.detail}</pre>
                  <button :if={item.tool_data && (!@tool_evidence || @tool_evidence.id != item.id)} type="button" phx-click="show_tool_evidence" phx-value-id={item.id} class="mt-2 text-xs font-medium text-blue-700 underline underline-offset-2 hover:text-blue-900">
                    {gettext("View stored input and result")}
                  </button>
                  <section :if={@tool_evidence && @tool_evidence.id == item.id} id="session-tool-evidence" class="mt-3 space-y-3 rounded border border-neutral-200 bg-neutral-50 p-3" aria-label={gettext("Stored tool evidence")}>
                    <div class="flex items-start justify-between gap-3">
                      <p class="text-[11px] text-neutral-500">{if @tool_evidence.failure, do: gettext("Failed call summary. Private failure details are not shown; known secret input fields are redacted."), else: gettext("Stored values without preview truncation. Known secret fields are redacted; free text is not guaranteed secret-free.")}</p>
                      <button type="button" phx-click="hide_tool_evidence" class="shrink-0 text-xs text-neutral-600 underline">{gettext("Close")}</button>
                    </div>
                    <p :if={@tool_evidence.page} class="rounded border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900">
                      {gettext("Stored result page — not the full tool result. Check offset, total_chars and next_offset below; other pages may appear in later tool calls.")}
                    </p>
                    <div>
                      <h4 class="mb-1 text-xs font-semibold">{gettext("Input")}</h4>
                      <pre id="session-tool-evidence-input" class="whitespace-pre-wrap break-words text-[11px] leading-5 text-neutral-700">{@tool_evidence.input || gettext("Input is not present in the loaded records.")}</pre>
                    </div>
                    <div>
                      <h4 class="mb-1 text-xs font-semibold">{if @tool_evidence.failure, do: gettext("Failure summary"), else: gettext("Stored result")}</h4>
                      <pre id="session-tool-evidence-result" class="whitespace-pre-wrap break-words text-[11px] leading-5 text-neutral-700">{@tool_evidence.output || gettext("No result is present in the loaded records.")}</pre>
                    </div>
                  </section>
                </div>
              </details>
            </li>
          </ol>
        </div>
      </section>
      </div>
    </div>
    """
  end
end
