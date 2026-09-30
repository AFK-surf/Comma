defmodule BridgeForTeamsWeb.Dashboard.NewHomeLive do
  @moduledoc """
  The "New Home" tab (`/new-home`): the agent's proactive workspace.

  One column: the General Tasks list, then the "Space
  widget" wall — a draggable, resizable bento grid of
  `BridgeForTeams.WorkspaceItems` grouped by category — email drafts awaiting
  review, meeting recaps, a portfolio overview, team activity, engineering
  activity, and key metrics.
  Items the user accepted during onboarding land here too. The whole board is
  scoped to one project (`:board_project`, the board's Agent Swarm). Nothing
  on the board is fabricated: rows appear only as the agent genuinely produces
  them (delegated tasks, projected meetings, scheduled routines) or from the
  background dashboard projection. The page reads local Bridge projection rows
  only.

  The assistant chat is a real Salix agent conversation
  (`BridgeForTeams.AssistantChats`), initialized off the mount path so Salix
  latency never blocks first paint; replies arrive via a light polling loop.
  It lives in a persistent right rail on the shell's gray layer — the same
  hierarchy as the app sidebar, beside the raised board panel — whose composer
  is also the "Start a task" surface: a task-intent send enters the
  Router-backed assistant thread, where the Router decides whether to create a
  durable Task Conversation (`chat[create_task]`). The rail resizes by dragging its
  left gutter (RailResize, 280–450px, stored client-side). Clicking a board
  task opens its chat as a floating window over the rail (drawer kind
  "task_chat") while the rail itself stays on the assistant conversation.
  `:chat_focus` addresses that floating task panel only through its delegated
  conversation; tasks worked in the assistant thread show it scrolled to their
  hand-off message. Reviewable categories still open their result drawer first —
  "Follow up in chat" swaps it for the chat window. `/new-home/chat`
  (live_action `:chat`) stacks the assistant conversation over the whole
  content area as an iOS-style sheet — the expanded view, and the chat surface
  below `lg` where the rail is hidden.

  Owned by slice "orgs-shell".
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  require Logger

  alias BridgeForTeams.{
    WorkspaceItems,
    Artifacts,
    AssistantChats,
    Conversations,
    DashboardProjection,
    DashboardPrefs,
    Environments,
    Memberships,
    Observability,
    Orgs,
    Projects,
    Reports,
    RoutineSchedules,
    Skills,
    TaskDelegation,
    UserOnboardings,
    Workspace
  }

  import BridgeForTeamsWeb.Dashboard.BrandLogos, only: [brand_logo: 1]
  import BridgeForTeamsWeb.Dashboard.DeviceProvisioning

  alias BridgeForTeams.Salix.EventRelay
  alias BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog
  alias BridgeForTeamsWeb.Dashboard.NewHomeLive.{ArtifactBlocks, SkillMentions}
  alias BridgeForTeamsWeb.Dashboard.RelativeTime

  @chat_refresh_ms 3_000
  # Agent runtime events arrive in bursts (a streaming reply emits many);
  # coalesce them into at most one refresh per window.
  @agent_event_debounce_ms 200
  # The chat status line ("Thinking", "Running <tool>") lives on relayed
  # activity events alone; if the terminal idle is lost (relay restart, dropped
  # broadcast) the poll retires anything older than this. Comfortably past
  # env.exec's 120s default timeout, so an ordinary long tool run isn't
  # blanked mid-flight.
  @chat_activity_ttl_ms 150_000
  @chat_context_marker "[[dashboard-context]]"
  # Markers the thread renderer uses to keep protocol text out of the UI —
  # the agent still receives the full message.
  @task_run_marker "[[bft-task-run]]"
  @protocol_marker "[[bft-protocol]]"
  @default_session_title "Comma assistant"
  # Conversations created before the rename keep their stored default —
  # display (and the naming gate) treat them as the current default.
  @legacy_session_titles ["New Home Assistant", "My Space Assistant"]
  @widget_order ~w(reports metrics meetings general issues email_drafts meeting_recaps portfolio team_activity engineering inbox informed calendar routines custom devices)
  # macOS-style widget dashboard sizes: 1x1 / 2x1 / 2x2 grid spans.
  @widget_sizes ~w(small medium large)
  # Devices come from the live Salix registry over :erpc; a slow cadence keeps
  # the widget fresh without the 2s hammering the project Devices tab needs.
  @devices_refresh_ms 30_000
  @impl true
  def mount(_params, _session, socket) do
    mount_start = System.monotonic_time()
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)
    current_org = List.first(orgs)
    swarms = list_swarms(current_org, user)
    project = resolve_board_project(current_org, user, swarms)

    if connected?(socket) do
      subscribe_agent_events(current_org)
    end

    layout = stored_layout(user, current_org, project)
    widget_prefs = stored_widget_prefs(user, current_org, project)

    socket =
      socket
      |> assign(:page_title, gettext("My Space"))
      |> assign(:content_chrome, :bare)
      |> assign(:active_nav, :new_home)
      |> assign(:breadcrumbs, [{gettext("My Space"), nil}])
      |> assign(:orgs, orgs)
      |> assign(:current_org, current_org)
      |> assign(:current_org_role, org_role(current_org, user.id))
      |> assign(:board_project, project)
      |> assign(:devices, :loading)
      |> assign(:can_manage_devices, can_manage_devices?(project, user))
      |> assign(:env_form, nil)
      |> assign(:env_provisioners, [])
      |> assign(:home_layout, layout)
      |> assign(:widget_prefs, widget_prefs)
      |> assign(:task_groups, load_task_groups(user.id, project, layout))
      # Report-offer schedule creations in flight (task ids): the guard against
      # double-creating a series schedule from rapid Run clicks while the
      # async Salix create hasn't answered yet.
      |> assign(:report_schedule_pending, MapSet.new())
      |> then(&assign(&1, :suggestions, load_suggestions(&1.assigns)))
      |> assign(:drawer, nil)
      |> assign(:tasks_expanded, false)
      |> assign(:chat_state, :loading)
      |> assign(:chat_project, nil)
      |> assign(:chat_agent, nil)
      |> assign(:chat_conversation_id, nil)
      |> assign(:chat_title, nil)
      |> assign(:chat_messages, [])
      |> assign(:chat_text, "")
      # The rail's focused task conversation: nil = the assistant thread.
      # `:focus_messages` render only while focused; the assistant thread keeps
      # polling underneath (board updates ride it), so unfocusing is instant.
      |> assign(:chat_focus, nil)
      |> assign(:focus_messages, [])
      |> assign(:focus_conversation, nil)
      |> assign(:focus_participants, [])
      |> assign(:focus_state, :idle)
      |> assign(:chat_activities, %{})
      |> assign(:assistant_chat_sessions, [])
      |> assign(:mention_skills, [])
      |> assign(:chat_seen_ids, nil)
      |> assign(:agent_event_refresh_queued, false)
      |> assign(:chat_refresh_epoch, 0)
      |> allow_upload(:attachments,
        # The formats the agent runtime can actually consume — the agent's
        # read limit is 10MB, so the upload cap matches it.
        accept: AssistantChats.attachment_upload_extensions(),
        max_entries: 8,
        max_file_size: 10_000_000
      )

    socket =
      if connected?(socket) do
        send(self(), :init_chat)
        send(self(), :load_devices)
        subscribe_projection(project)
        enqueue_projection_refresh(project)
        socket
      else
        socket
      end

    duration = System.monotonic_time() - mount_start
    BridgeForTeams.Telemetry.emit_operation(:mount, :ok, duration)

    :telemetry.execute(
      [:bridge_for_teams, :new_home, :mount],
      %{duration: duration},
      %{project_id: project && project.id, org_id: current_org && current_org.id}
    )

    {:ok, socket}
  end

  @impl true
  # /new-home/widgets used to open the widget sheet; the wall lives inline on
  # the board now, so stale tabs and bookmarks patch back to /new-home.
  def handle_params(_params, _uri, %{assigns: %{live_action: :widgets}} = socket) do
    {:noreply, push_patch(socket, to: ~p"/new-home", replace: true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:chat_expanded, socket.assigns.live_action == :chat)
     # The sheet stacks inside the same page — no breadcrumb trail appears.
     |> assign(:breadcrumbs, [{gettext("My Space"), nil}])}
  end

  # ---- chat lifecycle ---------------------------------------------------------

  @impl true
  def handle_info(:init_chat, socket) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org

    case AssistantChats.ensure_chat(user.id, org && org.id, socket.assigns.board_project,
           initial_message: chat_context_message(socket),
           context_digest: chat_context_digest(socket)
         ) do
      {:ok, %{binding: binding, project: project, agent: agent}} ->
        socket =
          socket
          |> assign(:chat_state, :ready)
          |> assign(:chat_project, project)
          |> assign(:chat_agent, agent)
          |> assign(:chat_conversation_id, binding.conversation_id)
          |> assign(:chat_title, session_title(project, binding.conversation_id))
          |> assign(
            :assistant_chat_sessions,
            Conversations.conversation_session_ids(project, agent, binding.conversation_id)
          )
          # A (re)connect drops anything event-sourced before it (threads we
          # may no longer show) and re-seeds the status surface from the
          # runtime — so a page refresh mid-turn still shows the live line.
          |> seed_chat_activities(agent)
          |> refresh_chat_messages()

        schedule_chat_refresh(socket)
        # Skills feed the composer's /-mention menu; listing them is two more
        # Salix calls, so they load behind :ready rather than gating it.
        send(self(), :load_mention_skills)
        {:noreply, socket}

      {:error, reason} when reason in [:no_project, :no_agent] ->
        {:noreply, assign(socket, :chat_state, reason)}

      {:error, _reason} ->
        {:noreply, assign(socket, :chat_state, :unavailable)}
    end
  end

  def handle_info(:load_mention_skills, socket) do
    {:noreply, assign(socket, :mention_skills, load_mention_skills(socket))}
  end

  # Devices load off the mount path — listing them is an :erpc round-trip to
  # the Salix registry — and re-arm their own refresh tick.
  def handle_info(:load_devices, socket) do
    Process.send_after(self(), :load_devices, @devices_refresh_ms)
    fresh = load_devices(socket.assigns.board_project)
    {:noreply, assign(socket, :devices, merge_devices(socket.assigns.devices, fresh))}
  end

  def handle_info({:dashboard_projection_refreshed, project_id}, socket) do
    if socket.assigns.board_project && socket.assigns.board_project.id == project_id do
      {:noreply,
       socket
       |> then(&assign(&1, :suggestions, load_suggestions(&1.assigns)))
       |> refresh_task_groups()}
    else
      {:noreply, socket}
    end
  end

  # The self-perpetuating poll. Each tick carries the chat's refresh epoch so a
  # superseded loop's next tick is a stale no-op rather than a second
  # concurrent poll.
  def handle_info({:refresh_chat, epoch}, socket) do
    socket =
      if epoch == socket.assigns.chat_refresh_epoch and socket.assigns.chat_state == :ready do
        schedule_chat_refresh(socket)
        poll_chat(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  # A one-shot refresh (tests / manual triggers): do the poll work without
  # arming the loop, so it can't spawn a competing timer.
  def handle_info(:refresh_chat, socket) do
    {:noreply, poll_chat(socket)}
  end

  # An agent dispatched an exec on one of this org's devices: the event
  # carries the fresh entry, so patch the widget label in place — no Salix read.
  def handle_info(
        {:agent_event, _org_id, _agent_id, {:exec_activity, connector_run_id, entry}},
        socket
      ) do
    case socket.assigns.devices do
      devices when is_list(devices) ->
        updated =
          Enum.map(devices, fn device ->
            if device.connector_run_id == connector_run_id,
              do: %{device | last_exec: newer_exec_entry(device.last_exec, entry)},
              else: device
          end)

        {:noreply, assign(socket, :devices, updated)}

      _not_loaded ->
        {:noreply, socket}
    end
  end

  # A live activity signal (thinking / typing / tool execution — see
  # `SalixAgent.ActivityEvent`): drive the chat status line immediately, then
  # queue the same debounced refresh every runtime event triggers.
  def handle_info({:agent_event, _org_id, _agent_id, {:activity, activity}}, socket)
      when is_map(activity) do
    {:noreply,
     socket
     |> apply_chat_activity(activity)
     |> queue_agent_event_refresh()}
  end

  # A relayed Salix runtime event for this org (`EventRelay`): one of its
  # agents produced output or settled. Refresh now instead of waiting out the
  # 3s poll — but debounced, since a streaming reply emits an event per delta.
  def handle_info({:agent_event, _org_id, _agent_id, _event}, socket) do
    {:noreply, queue_agent_event_refresh(socket)}
  end

  def handle_info(:agent_event_refresh, socket) do
    socket = assign(socket, :agent_event_refresh_queued, false)

    socket =
      if socket.assigns.chat_state == :ready do
        # Runtime events are coalesced before this point. Refresh the visible
        # conversations and enqueue the canonical Conversation projection;
        # Messages themselves carry no board commands.
        socket
        |> refresh_chat_messages()
        |> refresh_session_title()
        |> refresh_focus_thread()
        |> enqueue_agent_projection_refresh()
        |> refresh_task_groups()
      else
        # No chat yet ⇒ no poll loop either; the event is the only liveness
        # signal, so enqueue the projection and reload local rows.
        socket
        |> enqueue_agent_projection_refresh()
        |> refresh_task_groups()
      end

    {:noreply, socket}
  end

  # ---- async results: drawer VFS hydration

  # The drawer's VFS artifact read. Results are tagged with the task id the
  # read was started for: a late reply for a drawer the user already swapped or
  # closed is dropped (LiveView itself prunes results from superseded reads).
  # On success the bytes land where the drawer renders them — the
  # category-appropriate payload field for the interactive kinds, the parsed
  # artifact document for everything else; on failure the drawer says so
  # quietly and keeps the index/payload copy.
  @impl true
  def handle_async(:drawer_artifact, {:ok, {task_id, result}}, socket) do
    case socket.assigns.drawer do
      %{task: %{id: ^task_id}} = drawer ->
        {:noreply, assign(socket, :drawer, apply_drawer_artifact(drawer, result))}

      _other_drawer ->
        {:noreply, socket}
    end
  end

  def handle_async(:drawer_artifact, {:exit, _reason}, socket) do
    case socket.assigns.drawer do
      %{artifact: :loading} = drawer ->
        {:noreply, assign(socket, :drawer, %{drawer | artifact: :error})}

      _other_drawer ->
        {:noreply, socket}
    end
  end

  # The drawer's "How your agent did it" session log — a conversation read
  # over `:erpc`, so it loads behind the open exactly like the VFS artifact
  # (the drawer renders immediately without it). Tagged with the task id so a
  # late reply for a drawer the user already swapped or closed is dropped; a
  # failed read simply leaves the section empty (nothing is fabricated).
  def handle_async(:drawer_log, {:ok, {task_id, log}}, socket) do
    case socket.assigns.drawer do
      %{task: %{id: ^task_id}} = drawer ->
        {:noreply, assign(socket, :drawer, %{drawer | log: log})}

      _other_drawer ->
        {:noreply, socket}
    end
  end

  def handle_async(:drawer_log, {:exit, _reason}, socket), do: {:noreply, socket}

  # The focused task conversation's first read. Tagged with the conversation
  # id so a late reply for a focus the user already left (or re-aimed) drops.
  def handle_async(:focus_thread, {:ok, {conversation_id, result}}, socket) do
    case {socket.assigns.chat_focus, result} do
      {%{conversation_id: ^conversation_id},
       {:ok, %{conversation: conversation, messages: messages, participants: participants}}} ->
        {:noreply,
         socket
         |> assign(:focus_messages, Enum.reject(messages, &context_message?/1))
         |> assign(:focus_conversation, conversation)
         |> assign(:focus_participants, participants)
         |> assign(:focus_state, :ok)}

      {%{conversation_id: ^conversation_id}, {:error, _reason}} ->
        {:noreply, assign(socket, :focus_state, :error)}

      _stale ->
        {:noreply, socket}
    end
  end

  def handle_async(:focus_thread, {:exit, _reason}, socket) do
    if socket.assigns.chat_focus,
      do: {:noreply, assign(socket, :focus_state, :error)},
      else: {:noreply, socket}
  end

  # A report offer's recurring-schedule creation (two Salix `:erpc` calls —
  # create + prompt stamp) answers here, off the event/render path. Success
  # records the schedule id on the offer row (the idempotency guard for later
  # Runs); failure only logs — the offer stays schedule-less, and the next Run
  # click retries (`ensure_report_schedule/2` runs on every click).
  def handle_async({:report_schedule, task_id}, result, socket) do
    socket =
      assign(
        socket,
        :report_schedule_pending,
        MapSet.delete(socket.assigns.report_schedule_pending, task_id)
      )

    case result do
      {:ok, {:ok, %{} = schedule}} ->
        record_report_schedule(socket, task_id, schedule)
        {:noreply, refresh_task_groups(socket)}

      {:ok, {:error, reason}} ->
        Logger.warning(
          "report_offer_schedule_failed task_id=#{task_id} reason=#{inspect(reason)}"
        )

        {:noreply, socket}

      {:exit, reason} ->
        Logger.warning(
          "report_offer_schedule_failed task_id=#{task_id} reason=#{inspect(reason)}"
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_chat_message", %{"chat" => %{"text" => text} = chat}, socket) do
    text = text |> to_string() |> String.trim()

    if socket.assigns.chat_state != :ready do
      {:noreply, socket}
    else
      # Attachments land in the agent's workspace VFS so its file tools can
      # read them; the message references them by path.
      attachments =
        consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
          with {:ok, binary} <- File.read(tmp_path),
               {:ok, vfs_path} <-
                 AssistantChats.upload_attachment(
                   socket.assigns.chat_agent,
                   entry.client_name,
                   binary
                 ) do
            {:ok, %{name: entry.client_name, path: vfs_path}}
          else
            _ -> {:ok, nil}
          end
        end)
        |> Enum.reject(&is_nil/1)

      message = compose_chat_message(text, attachments)

      create_task? = chat["create_task"] == "true"

      # /-mentioned skills come from the client, filtered against the
      # server-loaded list — forged locations never reach the protocol.
      mentioned = SkillMentions.parse(chat["skills"], socket.assigns.mention_skills)

      # Everything after the protocol marker is for the agent only — the
      # thread renderer shows just the user's own words. Session naming rides
      # along only while the session still carries its default name.
      protocol_sections =
        [
          SkillMentions.instructions(mentioned),
          create_task? && task_creation_instructions(),
          create_task? && socket.assigns.chat_title in [nil, @default_session_title] &&
            session_naming_instructions()
        ]
        |> Enum.filter(&is_binary/1)

      outgoing =
        case protocol_sections do
          [] ->
            message

          sections ->
            message <> "\n\n" <> @protocol_marker <> "\n" <> Enum.join(sections, "\n\n")
        end

      # A task-filing send always addresses the assistant thread; the router
      # decides whether to create a durable task conversation. A follow-up from
      # the task drawer addresses that focused task conversation.
      focus = if create_task?, do: nil, else: socket.assigns.chat_focus

      with true <- message != "",
           {:ok, socket, _send_result} <- deliver_chat_message(socket, focus, outgoing) do
        # A task-filing send lands in the assistant thread. Task creation and
        # the task card come back through the router's im_api.internal.task.create +
        # conversation_ref reply, so the board refreshes on the next chat poll.
        socket =
          if create_task?,
            do: unfocus_chat(socket),
            else: socket

        {:noreply, socket}
      else
        false -> {:noreply, socket}
        {:error, socket} -> {:noreply, socket}
      end
    end
  end

  # Keeps the server-rendered input value in sync while attachments trigger
  # form re-renders — otherwise a blur mid-patch wipes what the user typed.
  def handle_event("validate_chat", %{"chat" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :chat_text, text)}
  end

  def handle_event("validate_chat", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # ---- events: task board actions -------------------------------------------------

  # Hand a board task to the assistant: the first click posts the task (with
  # its payload context) into the chat and marks it in progress. Once handed
  # (any status past accepted), clicking the row again just opens the
  # conversation — it never re-posts the hand-off.
  def handle_event("run_task", %{"id" => id}, socket) do
    task = find_board_task(socket, id)

    cond do
      is_nil(task) ->
        {:noreply, socket}

      task.status not in ["suggested", "accepted"] ->
        # An already-handed report offer may still be missing its recurring
        # schedule (the async create failed while Salix was unreachable) —
        # every Run click retries it, so a transient failure never loses the
        # series for good. A no-op for anything else. The click opens the
        # task's chat as a floating window over the rail: the task's own
        # conversation when it has one, else the assistant thread scrolled to
        # its hand-off message. The rail itself remains the assistant thread.
        {:noreply,
         socket
         |> ensure_report_schedule(task)
         |> focus_or_reveal_task_chat(task)
         |> assign(:drawer, %{kind: "task_chat", task: task})}

      socket.assigns.chat_state != :ready ->
        {:noreply,
         put_flash(socket, :error, gettext("Your agent isn't connected yet — try again shortly."))}

      true ->
        case TaskDelegation.dispatch(task, audit_opts(socket)) do
          {:ok, task} ->
            socket = focus_task_chat(socket, task)

            # A report offer also materializes its recurring series schedule
            # asynchronously (recorded on the row when the create answers).
            socket = ensure_report_schedule(socket, task)

            # Task creation already appended the canonical command Message.
            # Keep the drawer focused there without sending a second hand-off.
            {:noreply,
             socket
             |> refresh_task_groups()
             |> assign(:drawer, %{kind: "task_chat", task: task})}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not start this task."))}
        end
    end
  end

  # Collapse the chat sheet back onto the board (× button and scrim click —
  # Escape routes through "escape_pressed" below). The drawer overlays the
  # sheet's controls, so these clicks can't fire while a drawer is stacked on
  # top.
  def handle_event("collapse_chat", _params, socket) do
    if socket.assigns.chat_expanded do
      {:noreply, push_patch(socket, to: ~p"/new-home")}
    else
      {:noreply, socket}
    end
  end

  # THE page-level Escape handler — the page's only phx-window-keydown
  # binding, so one keypress can never close two stacked overlays and nothing
  # hinges on the DOM order the bindings would dispatch in. Topmost layer
  # first: the drawer, then the chat sheet. Deliberate closes (× button,
  # scrim click) go through "close_drawer"/"collapse_chat" and always work;
  # Escape alone must never throw away typing — an editing drawer's edits
  # live only in the DOM (see drawer_edits_in_dom?/1), so it ignores Escape.
  def handle_event("escape_pressed", _params, socket) do
    cond do
      drawer_edits_in_dom?(socket.assigns.drawer) ->
        {:noreply, socket}

      socket.assigns.drawer ->
        socket =
          case socket.assigns.drawer do
            %{kind: "task_chat"} -> unfocus_chat(socket)
            _drawer -> socket
          end

        {:noreply, assign(socket, :drawer, nil)}

      socket.assigns.chat_expanded ->
        {:noreply, push_patch(socket, to: ~p"/new-home")}

      true ->
        {:noreply, socket}
    end
  end

  # The rail header's back button: leave the focused task conversation and
  # return to the assistant thread (which kept polling underneath).
  def handle_event("unfocus_chat", _params, socket) do
    {:noreply, unfocus_chat(socket)}
  end

  # macOS-style widget sizing on the wall grid — General never gets a size.
  # Stored per swarm on the (user, org) prefs row, same shape as the
  # layout: `%{project_id => %{category => size}}`.
  def handle_event("set_widget_size", %{"category" => category, "size" => size}, socket)
      when size in @widget_sizes do
    user = socket.assigns.current_user
    org = socket.assigns.current_org
    project = socket.assigns.board_project

    if category in (@widget_order -- ["general"]) do
      prefs = put_in(socket.assigns.widget_prefs, [Access.key("sizes", %{}), category], size)

      if org && project do
        row = DashboardPrefs.get(user.id, org.id)
        sizes = ((row && row.widget_sizes) || %{}) |> Map.put(project.id, prefs["sizes"])
        _ = DashboardPrefs.put_widget_sizes(user.id, org.id, sizes)
      end

      {:noreply, assign(socket, :widget_prefs, prefs)}
    else
      {:noreply, socket}
    end
  end

  # "Mark as Complete" on the working list — the RowExit hook animates the
  # row out client-side, then pushes this.
  def handle_event("complete_task", %{"id" => id}, socket) do
    case find_board_task(socket, id) do
      nil ->
        {:noreply, socket}

      task ->
        _ = update_workspace_item(socket, task, %{"status" => "done"})
        {:noreply, refresh_task_groups(socket)}
    end
  end

  def handle_event("expand_tasks", _params, socket) do
    {:noreply, assign(socket, :tasks_expanded, true)}
  end

  # ---- events: suggestions -------------------------------------------------------

  def handle_event("open_suggestion", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.suggestions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      suggestion ->
        {:noreply, assign(socket, :drawer, %{kind: "suggestion", suggestion: suggestion})}
    end
  end

  # "Go ahead" — accepting moves the suggestion item into its target
  # category as an accepted task (one item, one conversation — no duplicate
  # card) and wakes the agent in the item's task conversation so it actually
  # performs the proposed action.
  def handle_event("accept_suggestion", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %{} = suggestion <- Enum.find(socket.assigns.suggestions, &(&1.id == id)),
         %{} = project <- socket.assigns.board_project,
         {:ok, item} <- WorkspaceItems.get_task(user.id, id, project_id: project.id),
         {:ok, item} <-
           Conversations.update_workspace_item(project, item, %{
             "category" => suggestion.category,
             "status" => "accepted"
           }) do
      dispatch_accepted_suggestion(project, item, user)

      socket = socket |> assign(:drawer, nil) |> refresh_task_groups()
      {:noreply, assign(socket, :suggestions, load_suggestions(socket.assigns))}
    else
      _other -> {:noreply, socket}
    end
  end

  # "Remove" — archives the suggestion item; the row is the durable record.
  def handle_event("dismiss_suggestion", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %{} = _suggestion <- Enum.find(socket.assigns.suggestions, &(&1.id == id)),
         %{} = project <- socket.assigns.board_project,
         {:ok, item} <- WorkspaceItems.get_task(user.id, id, project_id: project.id) do
      _ = Conversations.archive_workspace_item(project, item)

      socket = socket |> assign(:drawer, nil) |> refresh_task_groups()
      {:noreply, assign(socket, :suggestions, load_suggestions(socket.assigns))}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("retry_chat", _params, socket) do
    send(self(), :init_chat)
    {:noreply, assign(socket, :chat_state, :loading)}
  end

  # ---- events: widget board -----------------------------------------------------

  # Pushed by the DashGrid hook after a wall drag. The wall shows every
  # category except General — splice General back at its previous position so
  # the shared layout never loses it.
  def handle_event("reorder_dash_widgets", %{"order" => order}, socket) when is_list(order) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org
    project = socket.assigns.board_project
    order = order |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == "general"))

    general_idx =
      socket.assigns.home_layout |> effective_order() |> Enum.find_index(&(&1 == "general"))

    layout =
      if general_idx,
        do: List.insert_at(order, min(general_idx, length(order)), "general"),
        else: order

    if org && project do
      prefs = DashboardPrefs.get(user.id, org.id)
      home_layout = ((prefs && prefs.home_layout) || %{}) |> Map.put(project.id, layout)
      _ = DashboardPrefs.put_home_layout(user.id, org.id, home_layout)
    end

    {:noreply,
     socket
     |> assign(:home_layout, layout)
     |> assign(:task_groups, load_task_groups(user.id, project, layout))}
  end

  # "Reset layout" — back to the canonical order and default sizes for this
  # swarm, persisted so the default state survives a reload. The button
  # renders only while a customization exists, so it disappears with the
  # click.
  def handle_event("reset_wall_layout", _params, socket) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org
    project = socket.assigns.board_project

    if org && project do
      _ = DashboardPrefs.reset_project(user.id, org.id, project.id)
    end

    {:noreply,
     socket
     |> assign(:home_layout, [])
     |> assign(:widget_prefs, %{})
     |> assign(:task_groups, load_task_groups(user.id, project, []))}
  end

  # ---- events: side drawer --------------------------------------------------------

  # Completing is the user's call; archiving closes the loop — the task and
  # its linked agent conversation leave the board for good (soft archive).
  def handle_event("archive_task", %{"id" => id}, socket) do
    case find_board_task(socket, id) do
      nil ->
        {:noreply, socket}

      task ->
        _ = archive_workspace_item(socket, task)

        # An archived task leaves the board — a rail still focused on its
        # conversation would dangle, so it returns to the assistant thread.
        socket =
          if match?(%{task_id: id} when id == task.id, socket.assigns.chat_focus),
            do: unfocus_chat(socket),
            else: socket

        {:noreply,
         socket
         |> assign(:drawer, nil)
         |> refresh_task_groups()
         |> put_flash(:info, gettext("Completed and archived."))}
    end
  end

  def handle_event("open_drawer", %{"kind" => kind, "id" => task_id}, socket)
      when kind in ["email_preview", "email_edit", "recap", "meeting", "result"] do
    task = find_board_task(socket, task_id)

    if task do
      # The drawer opens immediately from index data — NOTHING here reads over
      # `:erpc`. Both remote pieces arrive via `start_async`: the VFS artifact
      # bytes (`handle_async(:drawer_artifact, ...)`) and the session log
      # (`handle_async(:drawer_log, ...)`), so a slow or unreachable Salix
      # never blocks the open. Report site URLs must already be present in the
      # local row payload; the page no longer resolves site names through Salix.
      socket =
        assign(socket, :drawer, %{
          kind: kind,
          task: task,
          view: "preview",
          log: [],
          document: nil,
          artifact: if(hydratable_artifact?(socket, task), do: :loading, else: :none)
        })

      # The drawer opens over the chat rail. Review drawers hydrate their
      # result/log in place; the persistent rail remains on the assistant
      # conversation.
      {:noreply,
       socket
       |> start_drawer_hydration(task)
       |> start_drawer_log(task)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_conversation_ref", %{"id" => conversation_id}, socket) do
    case resolve_conversation_ref_task(socket, conversation_id) do
      %{task: task, socket: socket} ->
        {:noreply,
         socket
         |> focus_or_reveal_task_chat(task)
         |> assign(:drawer, %{kind: "task_chat", task: task})}

      nil ->
        {:noreply, socket}
    end
  end

  # Reviewing is the primary action: the agent already ran the task — the
  # user confirms the result.
  def handle_event("review_done", %{"id" => id}, socket) do
    case find_board_task(socket, id) do
      nil ->
        {:noreply, socket}

      task ->
        _ = accept_workspace_item_review(socket, task)

        {:noreply,
         socket
         |> assign(:drawer, nil)
         |> refresh_task_groups()
         |> put_flash(:info, gettext("Marked as reviewed."))}
    end
  end

  def handle_event("close_drawer", _params, socket) do
    socket =
      case socket.assigns.drawer do
        %{kind: "task_chat"} -> unfocus_chat(socket)
        _drawer -> socket
      end

    {:noreply, assign(socket, :drawer, nil)}
  end

  def handle_event("drawer_recap_view", %{"view" => view}, socket)
      when view in ["preview", "markdown"] do
    case socket.assigns.drawer do
      %{} = drawer -> {:noreply, assign(socket, :drawer, %{drawer | view: view})}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drawer_edit_draft", _params, socket) do
    case socket.assigns.drawer do
      %{task: task} = drawer ->
        {:noreply, assign(socket, :drawer, %{drawer | kind: "email_edit", task: task})}

      _ ->
        {:noreply, socket}
    end
  end

  # Save the plain-text draft; `action=send` also opens the mail product with
  # the edited draft prefilled (a new Gmail compose window), which is where the
  # actual send happens.
  def handle_event("save_draft", %{"draft" => params}, socket) do
    case socket.assigns.drawer do
      %{task: task} ->
        body = to_string(params["body"] || "")

        payload =
          task.payload
          |> Map.put("to", to_string(params["to"] || ""))
          |> Map.put("subject", to_string(params["subject"] || ""))
          |> Map.put("body", body)
          |> Map.put("snippet", body |> String.split("\n", trim: true) |> List.first() || "")

        case update_workspace_item(socket, task, %{"payload" => payload}) do
          {:ok, task} ->
            # Flush the edited body back to the agent's workspace copy (when the
            # draft is VFS-backed) so what the user is about to send in Gmail
            # matches the artifact the agent keeps. Best-effort: a stale mirror
            # never blocks the send.
            write_back = write_back_artifact(socket, task, body)

            socket =
              socket
              |> assign(:drawer, %{socket.assigns.drawer | task: task})
              |> refresh_task_groups()

            {:noreply, draft_saved_flash(socket, params["action"], write_back)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save the draft."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ---- devices rail: add-device flow ----
  # Same contract as the Agent Swarm Devices tab (markup + form plumbing in
  # `BridgeForTeamsWeb.Dashboard.DeviceProvisioning`): only board-project
  # admins may request a device, and it lands on an online org runner.

  def handle_event("new_environment", _params, socket) do
    require_device_admin(socket, fn socket ->
      provisioners = online_mac_mini_provisioners(socket.assigns.current_org.id)

      {:noreply,
       socket
       |> assign(:env_provisioners, provisioners)
       |> assign(:env_form, env_form(env_form_defaults(provisioners)))}
    end)
  end

  def handle_event("close_env_form", _params, socket) do
    {:noreply, assign(socket, :env_form, nil)}
  end

  def handle_event("create_environment", %{"device" => attrs}, socket) do
    require_device_admin(socket, device_create_denied_audit(attrs), fn socket ->
      if nonblank?(attrs["provisioner_id"]),
        do: create_provisioned_environment(socket, attrs),
        else: {:noreply, put_flash(socket, :error, gettext("Select an online runner."))}
    end)
  end

  defp require_device_admin(socket, audit \\ nil, fun) do
    if socket.assigns.can_manage_devices do
      fun.(socket)
    else
      audit && audit.(socket)

      {:noreply,
       put_flash(socket, :error, gettext("Only Agent Swarm admins can manage devices."))}
    end
  end

  # A forged create from a non-admin leaves the same denied audit trail the
  # project Devices tab records for this action.
  defp device_create_denied_audit(attrs) do
    fn socket ->
      project = socket.assigns.board_project

      if project do
        _ =
          Observability.record_write_attempt(%{
            org_id: socket.assigns.current_org.id,
            actor_user_id: socket.assigns.current_user.id,
            actor_label: audit_actor_label(socket.assigns.current_user),
            action: "device.provision_requested",
            resource_type: "device_provision_request",
            resource_label: project.name,
            result: "denied",
            reason: :forbidden,
            request_id: Ecto.UUID.generate(),
            surface: "device",
            metadata: %{
              "project_id" => project.id,
              "salix_group_id" => project.salix_group_id,
              "surface" => "device",
              "provisioner_id_configured" => nonblank?(attrs["provisioner_id"])
            }
          })
      end

      :ok
    end
  end

  defp create_provisioned_environment(socket, attrs) do
    case Environments.create_device_provision_request(
           socket.assigns.board_project.id,
           attrs,
           audit_opts(socket)
         ) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> assign(:env_form, nil)
         |> put_flash(:info, "Device connection request created.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :env_form, env_form(attrs, changeset))}

      {:error, :provisioner_offline} ->
        {:noreply, put_flash(socket, :error, "Runner is offline.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not create the device connection.")}
    end
  end

  # Adding a device needs the board swarm's admin role — the same gate the
  # Agent Swarm Devices tab applies.
  defp can_manage_devices?(nil, _user), do: false

  defp can_manage_devices?(project, user) do
    match?({:ok, "admin"}, Memberships.project_role(project.id, user.id))
  end

  defp audit_opts(socket) do
    user = socket.assigns.current_user

    [
      actor_user_id: user.id,
      actor_label: audit_actor_label(user),
      request_id: Ecto.UUID.generate()
    ]
  end

  defp update_workspace_item(socket, task, attrs) do
    case socket.assigns.board_project do
      %{} = project -> Conversations.update_workspace_item(project, task, attrs)
      _missing_project -> WorkspaceItems.update_task(task, attrs)
    end
  end

  defp archive_workspace_item(socket, task) do
    case socket.assigns.board_project do
      %{} = project -> Conversations.archive_workspace_item(project, task)
      _missing_project -> WorkspaceItems.archive_task(task)
    end
  end

  defp accept_workspace_item_review(socket, task) do
    case socket.assigns.board_project do
      %{} = project -> Conversations.accept_workspace_item_review(project, task)
      _missing_project -> WorkspaceItems.update_task(task, %{"status" => "done"})
    end
  end

  defp audit_actor_label(user) do
    cond do
      nonblank?(user.email) -> String.trim(user.email)
      nonblank?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_), do: false

  # Deliver into the rail's addressed conversation — the focused task's when
  # `focus` names one, else the assistant thread. The optimistic echo lands in
  # whichever message list the rail is rendering. Task conversations live in
  # the same swarm as the assistant chat (the board project), so the send goes
  # through the same project handle.
  defp deliver_chat_message(socket, focus, message) do
    user = socket.assigns.current_user

    conversation_id =
      case focus do
        %{conversation_id: id} -> id
        nil -> socket.assigns.chat_conversation_id
      end

    case Conversations.send_project_conversation_message(
           socket.assigns.chat_project,
           conversation_id,
           message,
           actor_user_id: user.id,
           actor_label: user.email || user.id
         ) do
      {:ok, result} ->
        optimistic = %{
          "message_id" => "optimistic-#{System.unique_integer([:positive])}",
          "actor_type" => "user",
          "content" => [%{"type" => "text", "text" => message}]
        }

        socket =
          case focus do
            %{} ->
              assign(socket, :focus_messages, socket.assigns.focus_messages ++ [optimistic])

            nil ->
              assign(socket, :chat_messages, socket.assigns.chat_messages ++ [optimistic])
          end

        {:ok, assign(socket, :chat_text, ""), result}

      {:error, _reason} ->
        {:error, put_flash(socket, :error, gettext("Could not send the message."))}
    end
  end

  # ---- rail focus: a board task's own conversation --------------------------------

  # Point the rail at `task`'s conversation. Tasks without one (never handed
  # off, or recorded before provenance existed) leave the rail where it is —
  # for a fresh hand-off that's the assistant thread, which holds its card.
  # Refocusing the same conversation keeps the loaded thread.
  defp focus_task_chat(socket, task) do
    case task_conversation_id(task) do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        if match?(%{conversation_id: ^conversation_id}, socket.assigns.chat_focus) do
          socket
        else
          socket
          |> assign(:chat_focus, %{
            task_id: task.id,
            conversation_id: conversation_id,
            title: task.title,
            session_ids:
              Conversations.conversation_session_ids(
                socket.assigns.board_project,
                nil,
                conversation_id
              )
          })
          |> assign(:focus_messages, [])
          |> assign(:focus_conversation, nil)
          |> assign(:focus_participants, [])
          |> assign(:focus_state, :loading)
          |> start_focus_thread_read(conversation_id)
        end

      _no_conversation ->
        socket
    end
  end

  defp unfocus_chat(socket) do
    socket
    |> assign(:chat_focus, nil)
    |> assign(:focus_messages, [])
    |> assign(:focus_conversation, nil)
    |> assign(:focus_participants, [])
    |> assign(:focus_state, :idle)
  end

  # A clicked task with its own conversation focuses the task-chat drawer on it;
  # one whose work lives in the assistant thread asks the client to
  # scroll-and-flash its hand-off message (`bft:reveal-chat-message` window
  # listener in app.js) — visible feedback either way.
  defp focus_or_reveal_task_chat(socket, task) do
    case task_conversation_id(task) do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        focus_task_chat(socket, task)

      _no_conversation ->
        socket
        |> unfocus_chat()
        |> push_event("bft:reveal-chat-message", %{title: task.title})
    end
  end

  # First load of a focused conversation: a Salix `:erpc` read, so it runs
  # async off the click (the drawer-log pattern) — the 3s poll keeps it fresh
  # afterwards via `refresh_focus_thread/1`.
  defp start_focus_thread_read(socket, conversation_id) do
    case socket.assigns.board_project do
      %{} = project ->
        start_async(socket, :focus_thread, fn ->
          result =
            with {:ok, snapshot} <-
                   Conversations.get_project_conversation_with_messages(
                     project,
                     conversation_id,
                     limit: 100
                   ),
                 {:ok, participants} <-
                   Conversations.list_project_conversation_participants(
                     project,
                     conversation_id
                   ) do
              {:ok, Map.put(snapshot, :participants, participants)}
            end

          {conversation_id, result}
        end)

      _no_project ->
        assign(socket, :focus_state, :error)
    end
  end

  # The poll-path refresh of the focused conversation (sync, like the
  # assistant-thread refresh it runs beside). Best-effort: a failed read keeps
  # the last loaded thread.
  defp refresh_focus_thread(socket) do
    with %{conversation_id: conversation_id} <- socket.assigns.chat_focus,
         %{} = project <- socket.assigns.board_project,
         {:ok, %{conversation: conversation, messages: messages}} <-
           Conversations.get_project_conversation_with_messages(project, conversation_id,
             limit: 100
           ) do
      socket
      |> assign(:focus_messages, Enum.reject(messages, &context_message?/1))
      |> assign(:focus_conversation, conversation)
      |> assign(:focus_state, :ok)
    else
      _ -> socket
    end
  end

  defp compose_chat_message(text, []) do
    text
  end

  defp compose_chat_message(text, attachments) do
    files =
      Enum.map_join(attachments, "\n", fn %{name: name, path: path} ->
        "- #{name} (workspace file: #{path})"
      end)

    header = if text == "", do: gettext("I've attached some files:"), else: text
    header <> "\n\n" <> gettext("Attached files in your workspace:") <> "\n" <> files
  end

  # "How your agent did it": the agent's real messages from the task's
  # delegated conversation. No conversation, no log is fabricated. The read is
  # a Salix `:erpc` round-trip, so it
  # runs in a `start_async` task (`start_drawer_log/2`) — never inline in the
  # open_drawer event, which must render the drawer immediately.
  defp start_drawer_log(socket, task) do
    with conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           task_conversation_id(task),
         %{} = project <- socket.assigns.board_project do
      task_id = task.id

      start_async(socket, :drawer_log, fn ->
        {task_id, load_session_log(project, conversation_id)}
      end)
    else
      _ -> socket
    end
  end

  defp load_session_log(project, conversation_id) do
    case Conversations.list_project_conversation_messages(project, conversation_id, limit: 50) do
      {:ok, messages} -> Enum.filter(messages, &(&1["actor_type"] == "agent"))
      {:error, _reason} -> []
    end
  end

  defp task_conversation_id(task) do
    task.salix_conversation_id
  end

  # The Agent Swarms this user can reach in the current org — the set a pinned
  # selection is validated against. Empty (honest) when there is no org or the
  # user has no swarm grants.
  defp list_swarms(nil, _user), do: []
  defp list_swarms(org, user), do: Projects.list_projects_for_user(org.id, user.id)

  # The one Agent Swarm this mount's board is bound to: the user's pinned
  # selection when it still belongs to a swarm they can reach (a revoked
  # selection silently falls back), else the ownership-first default
  # (`Projects.default_project_for_user/2`). Nil is honest — the board and
  # chat show their empty states rather than borrowing another user's swarm.
  defp resolve_board_project(nil, _user, _swarms), do: nil

  defp resolve_board_project(org, user, swarms) do
    prefs = DashboardPrefs.get(user.id, org.id)
    selected_id = prefs && prefs.selected_project_id

    visible_selection = selected_id && Enum.find(swarms, &(&1.id == selected_id))

    visible_selection || Projects.default_project_for_user(org.id, user.id)
  end

  # The saved widget order for this (user, org, project) — [] when nothing is
  # stored (canonical order applies).
  defp stored_layout(user, org, project) do
    with %{} <- org,
         %{} <- project,
         %{home_layout: %{} = home_layout} <- DashboardPrefs.get(user.id, org.id),
         layout when is_list(layout) <- Map.get(home_layout, project.id) do
      layout
    else
      _ -> []
    end
  end

  # The saved dashboard widget sizes for this (user, org, project) — the LV
  # keeps them under a "sizes" key so per-category lookups stay one shape.
  defp stored_widget_prefs(user, org, project) do
    with %{} <- org,
         %{} <- project,
         %{widget_sizes: %{} = widget_sizes} <- DashboardPrefs.get(user.id, org.id),
         %{} = sizes <- Map.get(widget_sizes, project.id) do
      %{"sizes" => sizes}
    else
      _ -> %{}
    end
  end

  # A drawer task has a VFS artifact to pull when its payload names a
  # `vfs_path` and the board has a project to read it from. Drafts small
  # enough to ride in the payload carry no `vfs_path` and render as-is.
  defp hydratable_artifact?(socket, task) do
    path = task.payload["vfs_path"]
    is_binary(path) and path != "" and match?(%{}, socket.assigns.board_project)
  end

  # Kick the async read of a VFS-backed work product for the open drawer. When
  # the payload points at a `vfs_path`, the agent's workspace file is the
  # artifact of record — the result lands in
  # `handle_async(:drawer_artifact, ...)`, tagged with the task id so a
  # late reply for a drawer the user already left is dropped.
  defp start_drawer_hydration(socket, task) do
    with path when is_binary(path) and path != "" <- task.payload["vfs_path"],
         %{} = project <- socket.assigns.board_project do
      task_id = task.id
      opts = artifact_read_opts(task)

      start_async(socket, :drawer_artifact, fn ->
        {task_id, Workspace.read_file(project, path, opts)}
      end)
    else
      _ -> socket
    end
  end

  # The row's provenance names the agent whose VFS holds the artifact — a
  # delegated or swept run can live on any agent of the swarm, and reading the
  # project's FIRST agent (the unnamed default) would miss those files every
  # time. Rows without provenance keep the first-agent default.
  defp artifact_read_opts(%{salix_agent_id: agent_id})
       when is_binary(agent_id) and agent_id != "",
       do: [salix_agent_id: agent_id]

  defp artifact_read_opts(_task), do: []

  # Where the drawer's freshly read artifact bytes land. The interactive kinds
  # (email drafts, meeting recaps) keep their payload-field contract — the
  # reviewer edits those in place. Every other category is an artifact
  # document: flat frontmatter (index metadata, never review content) plus
  # markdown interleaved with fenced `bft:block` JSON, parsed here so
  # `drawer_result/1` can render prose and blocks natively.
  defp apply_drawer_artifact(drawer, {:ok, body}) when is_binary(body) do
    case drawer.task.category do
      category when category in ["email_drafts", "meeting_recaps"] ->
        payload = put_artifact_body(category, drawer.task.payload, body)
        %{drawer | task: %{drawer.task | payload: payload}, artifact: :ok}

      _artifact_category ->
        %{drawer | document: Artifacts.Document.parse(body), artifact: :ok}
    end
  end

  defp apply_drawer_artifact(drawer, _error), do: %{drawer | artifact: :error}

  defp put_artifact_body("email_drafts", payload, body) do
    Map.merge(payload, %{
      "body" => body,
      "snippet" => body |> String.split("\n", trim: true) |> List.first() || ""
    })
  end

  defp put_artifact_body("meeting_recaps", payload, body),
    do: Map.put(payload, "markdown", body)

  # Mirror the reviewer's edit back to the agent's workspace before the Gmail
  # handoff, so the saved artifact matches what the user sends. Only VFS-backed
  # drafts have somewhere to write to; everything else is a no-op. The write
  # targets the same provenance-named agent the drawer read from.
  defp write_back_artifact(socket, task, body) do
    with path when is_binary(path) and path != "" <- task.payload["vfs_path"],
         %{} = project <- socket.assigns.board_project do
      Workspace.write_file(project, path, body, artifact_read_opts(task))
    else
      _ -> :skip
    end
  end

  defp draft_saved_flash(socket, action, write_back) do
    cond do
      match?({:error, _reason}, write_back) ->
        # The board row saved, but the workspace mirror didn't — say so rather
        # than imply the agent's copy is in sync.
        put_flash(
          socket,
          :error,
          gettext("Draft saved, but your agent's copy couldn't be updated just now.")
        )

      # The GmailHandoff hook already opened the compose window inside the submit
      # gesture (popup blockers reject anything later).
      action == "send" ->
        put_flash(socket, :info, gettext("Draft opened in Gmail — hit send there."))

      true ->
        put_flash(socket, :info, gettext("Draft saved."))
    end
  end

  # Which drawer reviews a task's finished result.
  defp drawer_kind("email_drafts"), do: "email_preview"
  defp drawer_kind("meeting_recaps"), do: "recap"
  defp drawer_kind("meetings"), do: "meeting"
  defp drawer_kind(_category), do: "result"

  defp find_board_task(socket, task_id) do
    socket.assigns.task_groups
    |> Enum.flat_map(fn {_category, tasks} -> tasks end)
    |> Enum.find(&(&1.id == task_id))
  end

  defp find_board_task_by_conversation(socket, conversation_id) do
    socket.assigns.task_groups
    |> Enum.flat_map(fn {_category, tasks} -> tasks end)
    |> Enum.find(&(&1.salix_conversation_id == conversation_id))
  end

  defp resolve_conversation_ref_task(socket, conversation_id)
       when is_binary(conversation_id) and conversation_id != "" do
    case find_board_task_by_conversation(socket, conversation_id) do
      nil ->
        with %{} = project <- socket.assigns.board_project,
             {:ok, task} <-
               WorkspaceItems.get_task(socket.assigns.current_user.id, conversation_id,
                 project_id: project.id
               ) do
          socket = refresh_task_groups(socket)
          %{task: task, socket: socket}
        else
          _missing_or_not_workspace_item -> nil
        end

      task ->
        %{task: task, socket: socket}
    end
  end

  defp resolve_conversation_ref_task(_socket, _conversation_id), do: nil

  # Running a report offer creates the matching recurring series schedule —
  # the chat hand-off already gave the instant one-shot run; the schedule
  # keeps the series alive (`RoutineSchedules.materialize_definition/5` with
  # this user's assistant conversation, the same prompt the onboarding
  # materialize path stamps). The created id is recorded on the offer row's
  # payload, which doubles as the idempotency guard: an offer that already
  # records one never creates a second, however often it is re-run. Called on
  # EVERY Run click (including re-opens of an already-handed offer), so a
  # create that failed while Salix was down is retried by the next click.
  defp ensure_report_schedule(socket, %{category: "reports", payload: payload} = task) do
    if payload["offer"] == "report" and not is_binary(payload["salix_schedule_id"]) do
      create_report_schedule(socket, task)
    else
      socket
    end
  end

  defp ensure_report_schedule(socket, _task), do: socket

  # Kick the schedule create as a `start_async` task: it is two Salix `:erpc`
  # calls (create + prompt stamp), which must never block the LiveView's
  # event loop. `:report_schedule_pending` dedupes rapid clicks while a create
  # is in flight (LiveView drops superseded RESULTS but does not stop the
  # superseded task — two live creates would mean two schedules). The result
  # lands in `handle_async({:report_schedule, task_id}, ...)`; a failure is
  # logged there and the next Run retries.
  defp create_report_schedule(socket, task) do
    user = socket.assigns.current_user
    task_id = task.id

    with false <- MapSet.member?(socket.assigns.report_schedule_pending, task_id),
         %{} = project <- socket.assigns.board_project,
         %{} = definition <- report_definition(task.payload["kind"]),
         conversation_id when is_binary(conversation_id) <-
           socket.assigns.chat_conversation_id do
      user_id = user.id
      actor_label = user.email || user.id

      socket
      |> assign(
        :report_schedule_pending,
        MapSet.put(socket.assigns.report_schedule_pending, task_id)
      )
      |> start_async({:report_schedule, task_id}, fn ->
        RoutineSchedules.materialize_definition(
          project,
          definition,
          user_id,
          conversation_id,
          actor_user_id: user_id,
          actor_label: actor_label
        )
      end)
    else
      _in_flight_or_missing_context -> socket
    end
  end

  # Stamp the created schedule id onto the offer row so
  # `ensure_report_schedule/2` never creates a second schedule for this offer.
  defp record_report_schedule(socket, task_id, schedule) do
    with %{} = project <- socket.assigns.board_project,
         %{} = task <-
           socket.assigns.current_user.id
           |> WorkspaceItems.list_tasks(project_id: project.id, category: "reports")
           |> Enum.find(&(&1.id == task_id)),
         false <- is_binary(task.payload["salix_schedule_id"]) do
      Conversations.update_workspace_item(project, task, %{
        "payload" => Map.put(task.payload, "salix_schedule_id", schedule["id"])
      })

      :ok
    else
      _missing_or_already_recorded -> :ok
    end
  end

  # The catalog definition behind a report offer, matched by the offer's run
  # kind ("daily"/"weekly").
  defp report_definition(kind) do
    Enum.find(
      RoutineSchedules.capability_definitions(),
      &(&1.category == "reports" and Map.get(&1, :kind) == kind)
    )
  end

  defp schedule_chat_refresh(socket),
    do:
      Process.send_after(
        self(),
        {:refresh_chat, socket.assigns.chat_refresh_epoch},
        @chat_refresh_ms
      )

  # The poll refreshes only the assistant and focused conversations. Workspace
  # state comes from the canonical Conversation projection, never Message
  # parsing, so there is no multi-conversation Message scan here.
  defp poll_chat(socket) do
    if socket.assigns.chat_state == :ready do
      socket
      |> expire_chat_activity()
      |> refresh_chat_messages()
      |> refresh_session_title()
      |> refresh_focus_thread()
    else
      socket
    end
  end

  # Coalesce a burst of runtime events into at most one refresh per debounce
  # window (a streaming reply emits an event per delta).
  defp queue_agent_event_refresh(socket) do
    if socket.assigns.agent_event_refresh_queued do
      socket
    else
      Process.send_after(self(), :agent_event_refresh, @agent_event_debounce_ms)
      assign(socket, :agent_event_refresh_queued, true)
    end
  end

  # Live status for the chat surfaces, keyed by runtime session. The
  # assistant thread's sessions come from `Conversations.
  # conversation_session_ids/3`: a worker participant's persisted delivery
  # session, or the group's one canonical router session for a router agent. A
  # router session is shared by ALL of that router's conversations,
  # so its line means "the swarm's router is working" rather than "working on
  # this thread" — the agent-level granularity the activity SSE clients
  # accept too. The rail's focused task conversation tracks the sessions
  # persisted on its participants (delegated runs land in worker sessions).
  # `idle` clears its session's line; anything running replaces it, stamped
  # for the poll's staleness check.
  defp apply_chat_activity(socket, activity) do
    session_id = activity["session_id"]

    cond do
      session_id not in watched_chat_sessions(socket.assigns) ->
        socket

      activity["phase"] == "idle" or activity["status"] == "idle" ->
        assign(socket, :chat_activities, Map.delete(socket.assigns.chat_activities, session_id))

      true ->
        stamped = Map.put(activity, "received_at_ms", System.monotonic_time(:millisecond))

        assign(
          socket,
          :chat_activities,
          Map.put(socket.assigns.chat_activities, session_id, stamped)
        )
    end
  end

  # The status surface is event-sourced, so a fresh mount would stay blank
  # until the agent's next signal; seed it from the runtime's in-memory
  # activity surface instead (`Conversations.list_agent_activities/1` — the
  # same erpc seam as the rest of the chat). Best-effort, like the events.
  defp seed_chat_activities(socket, agent) do
    watched = socket.assigns.assistant_chat_sessions
    now = System.monotonic_time(:millisecond)

    seeded =
      agent
      |> Conversations.list_agent_activities()
      |> Enum.filter(&(&1["session_id"] in watched))
      |> Map.new(&{&1["session_id"], Map.put(&1, "received_at_ms", now)})

    assign(socket, :chat_activities, seeded)
  end

  defp watched_chat_sessions(assigns) do
    assigns.assistant_chat_sessions ++ focus_chat_sessions(assigns)
  end

  defp focus_chat_sessions(assigns) do
    case assigns.chat_focus do
      %{session_ids: session_ids} when is_list(session_ids) ->
        session_ids

      _assistant ->
        []
    end
  end

  # The assistant rail always shows the assistant thread, even while a task chat
  # drawer is open; the drawer owns the focused task conversation's line.
  defp assistant_chat_activity(assigns) do
    Enum.find_value(assigns.assistant_chat_sessions, &assigns.chat_activities[&1])
  end

  defp drawer_chat_activity(%{chat_focus: %{}} = assigns) do
    Enum.find_value(focus_chat_sessions(assigns), &assigns.chat_activities[&1])
  end

  defp drawer_chat_activity(assigns), do: assistant_chat_activity(assigns)

  # Safety valve: the status surface lives on relayed events, and a terminal
  # idle can be lost (relay restart, dropped broadcast). The poll retires
  # signals past the TTL — a tool run longer than that drops its line early,
  # which is the cheap side of the trade.
  defp expire_chat_activity(socket) do
    activities = socket.assigns.chat_activities

    if map_size(activities) == 0 do
      socket
    else
      now = System.monotonic_time(:millisecond)

      fresh =
        Map.filter(activities, fn {_session_id, %{"received_at_ms" => at}} ->
          now - at <= @chat_activity_ttl_ms
        end)

      assign(socket, :chat_activities, fresh)
    end
  end

  # Liveness upgrade: listen on the org's agent-event topic and ask the relay
  # to bridge Salix runtime events onto it. Best-effort — in split deployments
  # the relay reports `:unavailable` and the polling loop stays the only
  # refresh path. The topic subscription itself is unconditional so anything
  # already broadcasting org events reaches this LiveView.
  defp subscribe_agent_events(nil), do: :ok

  defp subscribe_agent_events(org) do
    Phoenix.PubSub.subscribe(BridgeForTeamsWeb.PubSub, EventRelay.topic(org.id))
    _ = EventRelay.watch(org.id)
    :ok
  end

  # The composer's /-mention menu. Best-effort: Salix down means no menu, the
  # composer itself is untouched. Only what the client menu needs travels to
  # the browser (descriptions trimmed — some SKILL.md bodies front-load prose).
  defp load_mention_skills(socket) do
    with org when not is_nil(org) <- socket.assigns.current_org,
         agent when not is_nil(agent) <- socket.assigns.chat_agent,
         {:ok, %{system: system, user: user}} <- Skills.list_skills(org, agent) do
      (system ++ user)
      |> Enum.map(fn skill ->
        %{
          "name" => skill["name"],
          "description" => String.slice(skill["description"] || "", 0, 280),
          "location" => skill["location"]
        }
      end)
    else
      _ -> []
    end
  end

  defp refresh_chat_messages(socket) do
    case Conversations.list_project_conversation_messages(
           socket.assigns.chat_project,
           socket.assigns.chat_conversation_id,
           limit: 100
         ) do
      {:ok, messages} ->
        socket
        |> assign(:chat_messages, Enum.reject(messages, &context_message?/1))
        |> observe_fresh_chat_messages(messages)
        |> refresh_missing_conversation_refs(messages)

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_missing_conversation_refs(socket, messages) do
    missing_ref? =
      messages
      |> Enum.flat_map(&message_conversation_refs/1)
      |> Enum.map(&conversation_ref_id/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.any?(fn conversation_id ->
        is_nil(find_task_in_groups(socket.assigns.task_groups, conversation_id))
      end)

    if missing_ref?, do: refresh_task_groups(socket), else: socket
  end

  # The first fetch is the baseline for optimistic Message observation.
  # Workspace state and title come from committed Conversation reads.
  defp observe_fresh_chat_messages(socket, messages) do
    ids = for %{"message_id" => id} <- messages, is_binary(id), into: MapSet.new(), do: id

    case socket.assigns.chat_seen_ids do
      nil ->
        assign(socket, :chat_seen_ids, ids)

      seen ->
        assign(socket, :chat_seen_ids, MapSet.union(seen, ids))
    end
  end

  # Title is committed independently from Messages. Runtime events and the
  # regular chat poll both reread it, so Message-before-title ordering cannot
  # strand the old header.
  defp refresh_session_title(socket) do
    assign(
      socket,
      :chat_title,
      session_title(socket.assigns.chat_project, socket.assigns.chat_conversation_id)
    )
  end

  defp refresh_task_groups(socket) do
    assign(
      socket,
      :task_groups,
      load_task_groups(
        socket.assigns.current_user.id,
        socket.assigns.board_project,
        socket.assigns.home_layout
      )
    )
  end

  # The first message is a machine-assembled context brief for the agent, not
  # something the user typed — keep it out of the visible thread.
  defp context_message?(message) do
    message |> message_text() |> String.starts_with?(@chat_context_marker)
  end

  # The context message is instructions + a board snapshot. The split matters:
  # the instruction block is the STABLE part whose sha256 (`chat_context_digest/1`)
  # is remembered on the chat binding — `AssistantChats.ensure_chat/4` re-sends
  # the context when it drifts (deploys, user rename) or when the chat session
  # compacted the old copy away. The board list changes constantly, so it stays
  # out of the digest — routine task churn must not re-trigger sends.
  defp chat_context_instructions(socket) do
    user = socket.assigns.current_user
    org = socket.assigns.current_org

    """
    #{@chat_context_marker} You are the My Space assistant on the Bridge For Teams dashboard.
    You work for #{user.name || user.email} (#{user.email})#{if org, do: ", #{org.name}"}.#{chat_user_brief(user)}
    You can see their dashboard, memory, connected OAuth platforms, and you can delegate tasks to peer agents.
    For a message whose current source is this assistant Chat, answer through its normal visible reply path using the current source conversation_id — a session-only answer is never seen. These Chat reply instructions do not set a return target for messages whose current source is a Task.
    Classify by intent, not keywords. Chat-only messages are social chat, clarification, or a direct conversational answer that needs no durable result, side effect, follow-up, or review. Any other user request is work: create a task conversation before doing the work only when it is distinct new work that does not already belong to an existing Task. When a request may continue or revise an existing Task, resolve and continue the exact Task before deciding instead of creating a replacement; follow the current Router Task-resolution and continuation guidance when trusted context does not already identify it exactly. Do not match by title alone. For work that needs a distinct new Task, do not answer the deliverable directly in chat first. Create an ordinary Task with im_api.internal.task.create, supplying agent_id, title and self-contained content. Put all needed execution context in a new Task's content because it does not inherit an existing Task's message history. Use call(tool="agent.list", params={...}) only when you need an agent id, then reply here briefly with content containing a text block and a generic conversation reference block: {"type":"conversation_ref","conversation_id":"<task conversation_id>","kind":"agent_task","title":"<the task's concise title>"}. Always include the title — the dashboard renders it on the task card.
    Do not directly create or update workspace items from this chat; the worker writes progress, artifacts, and results inside the exact existing or newly created Task conversation.
    Be concise. For work requests that need a distinct new Task, create the task conversation and show the task card here; do not complete the work inside the chat conversation.
    SCOPE: these routing rules apply ONLY to messages whose current source is this assistant Chat. Inside a Task, follow the current delivery context and role: as its Worker, complete delegated work there; as Router/delegator for a user follow-up, decide whether it belongs to the current Task or needs a separate self-contained Task, reading the current Task first when needed. A separate Task does not inherit the current Task's message history.
    """
  end

  # The onboarding profile handoff: identity, key contacts, and capability
  # grants ride the STABLE context block, so a profile change re-sends context
  # through the digest mechanism like any other instruction drift.
  defp chat_user_brief(user) do
    case UserOnboardings.agent_brief(user.id) do
      nil -> ""
      brief -> "\n" <> brief
    end
  end

  defp chat_context_message(socket) do
    tasks =
      socket.assigns.task_groups
      |> Enum.flat_map(fn {_category, tasks} -> tasks end)
      |> Enum.take(10)
      |> Enum.map_join("\n", &task_board_context_line/1)

    chat_context_instructions(socket) <> "Their current task board:\n#{tasks}\n"
  end

  defp chat_context_digest(socket) do
    :crypto.hash(:sha256, chat_context_instructions(socket)) |> Base.encode16(case: :lower)
  end

  defp task_board_context_line(task) do
    base = "- [#{task.kind}/#{task.platform}] #{task.title}"

    case task.salix_conversation_id do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        base <> " (conversation_id: #{conversation_id})"

      _not_materialized ->
        base
    end
  end

  # ---- widgets ------------------------------------------------------------------

  # Postgres-only: the board's task index never blocks on Salix.
  defp load_task_groups(_user_id, nil, _layout), do: []

  defp load_task_groups(user_id, project, layout) do
    grouped = Map.new(WorkspaceItems.tasks_by_category(user_id, project_id: project.id))

    layout
    |> effective_order()
    |> Enum.flat_map(fn category ->
      case grouped[category] do
        nil -> []
        tasks -> [{category, tasks}]
      end
    end)
  end

  # Report runs collapse to one card row per series — the latest run fronts the
  # series and carries its run count; every other category renders one row per
  # task. Tasks arrive newest-first (`WorkspaceItems.list_tasks/2`), so the first
  # row seen per series is the latest run.
  defp widget_entries("reports", tasks) do
    counts = Enum.frequencies_by(tasks, &report_series_key/1)

    tasks
    |> Enum.uniq_by(&report_series_key/1)
    |> Enum.map(&{&1, Map.fetch!(counts, report_series_key(&1))})
  end

  defp widget_entries(_category, tasks), do: Enum.map(tasks, &{&1, 1})

  # A report row's series identity: the schedule that produces the runs
  # (`salix_schedule_id`), falling back to the run path's series slug
  # (`payload["series"]`). Offers are pre-run intent, not runs — they always
  # stand alone, as do rows with neither marker.
  defp report_series_key(task) do
    series = task.payload["series"]

    cond do
      is_binary(task.payload["offer"]) ->
        {:task, task.id}

      is_binary(task.salix_schedule_id) and task.salix_schedule_id != "" ->
        {:schedule, task.salix_schedule_id}

      is_binary(series) and series != "" ->
        {:series, series}

      true ->
        {:task, task.id}
    end
  end

  # The other runs of the drawer task's report series, newest first (the
  # board's index order) — recomputed at render time so a board refresh that
  # lands a new run updates the open drawer's history too. Non-report drawers
  # (and suggestion drawers, which carry no task) have no history.
  defp drawer_series_runs(groups, %{task: %{category: "reports"} = task}) do
    key = report_series_key(task)

    case List.keyfind(groups, "reports", 0) do
      {"reports", tasks} ->
        Enum.filter(tasks, &(&1.id != task.id and report_series_key(&1) == key))

      nil ->
        []
    end
  end

  defp drawer_series_runs(_groups, _drawer), do: []

  # The user's saved order first (unknown keys dropped), then any categories
  # they haven't arranged yet in canonical order.
  defp effective_order(layout) do
    user_order = Enum.filter(layout, &(&1 in @widget_order))
    user_order ++ (@widget_order -- user_order)
  end

  # ---- devices rail -----------------------------------------------------------

  defp load_devices(nil), do: []

  defp load_devices(project) do
    {:ok, records} = Environments.list_projected_environments(project.id)

    records
    |> Enum.map(&device_view/1)
    |> Enum.sort_by(&{&1.status != "connected", String.downcase(&1.name || "")})
  end

  defp device_view(record) do
    %{
      id: record["device_id"],
      connector_run_id: record["connector_run_id"],
      name: record["name"],
      status: record["status"] || "unknown",
      last_seen_at: record["updated_at"],
      system: device_system_label(record),
      last_exec: record["last_exec"],
      cloud_vm?: cloud_vm_device?(record)
    }
  end

  # A refresh must never regress the last-exec label: the serving Salix node's
  # table is in-memory and may have missed (or lost, across a restart) an
  # entry the event path already delivered — keep the newer entry per device.
  defp merge_devices(previous, fresh) when is_list(previous) and is_list(fresh) do
    known = Map.new(previous, &{&1.id, &1.last_exec})

    Enum.map(fresh, fn device ->
      %{device | last_exec: newer_exec_entry(known[device.id], device.last_exec)}
    end)
  end

  defp merge_devices(_previous, fresh), do: fresh

  defp newer_exec_entry(%{"at" => left_at} = left, %{"at" => right_at}) when left_at > right_at,
    do: left

  defp newer_exec_entry(%{} = left, nil), do: left
  defp newer_exec_entry(_left, right), do: right

  # "install deps · 2m ago" — the ephemeral in-memory exec activity a Salix
  # node has seen since boot; nil hides the line.
  defp last_exec_label(%{"description" => desc} = entry)
       when is_binary(desc) and desc != "" do
    [desc, RelativeTime.label(entry["at"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp last_exec_label(_entry), do: nil

  # One quiet line of system info: "macOS 14.5 · studio.local" from the
  # connector's system_info report, falling back to the connect-time os/arch
  # fields — all the cloud VM's connector advertises. nil hides the line.
  defp device_system_label(record) do
    info = record["system_info"] || %{}

    os =
      [info["os_type"], info["os_release"] || info["os_version"]]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")

    parts =
      if os != "" or not blank?(info["hostname"]) do
        [os, info["hostname"]]
      else
        [record["os"], record["arch"]]
      end

    parts
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp blank?(value), do: value in [nil, ""]

  # The managed cloud VM uses a deterministic device id for its group.
  defp cloud_vm_device?(record) do
    is_binary(record["device_id"]) and String.starts_with?(record["device_id"], "dev-cloudvm-")
  end

  defp subscribe_projection(nil), do: :ok
  defp subscribe_projection(project), do: DashboardProjection.subscribe(project.id)

  defp enqueue_projection_refresh(nil), do: :ok

  defp enqueue_projection_refresh(project) do
    if DashboardProjection.stale_or_missing?(project) do
      DashboardProjection.enqueue_refresh(project)
    end

    :ok
  end

  defp enqueue_agent_projection_refresh(socket) do
    DashboardProjection.enqueue_refresh(socket.assigns.board_project)
    socket
  end

  defp org_role(nil, _user_id), do: nil

  defp org_role(org, user_id) do
    case Memberships.org_role(org.id, user_id) do
      {:ok, role} -> role
      _ -> nil
    end
  end

  # ---- message helpers (same shapes as ConversationLive) ----

  defp message_text(%{"content" => content}), do: content_text(content)
  defp message_text(_message), do: ""

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp content_text(%{"text" => text}) when is_binary(text), do: text
  defp content_text(%{"type" => "image_url"}), do: gettext("[image]")
  defp content_text(%{"type" => "conversation_ref"}), do: ""
  defp content_text(%{"type" => "conversation"}), do: ""
  defp content_text(content) when is_map(content), do: content |> Map.values() |> content_text()
  defp content_text(_content), do: ""

  defp user_message?(%{"actor_type" => actor_type})
       when actor_type in ["user", "provider_user"],
       do: true

  defp user_message?(_message), do: false

  # The sheet header shows the conversation's own title (best-effort — the
  # creation default covers a Salix read miss).
  defp session_title(project, conversation_id) do
    case Conversations.get_project_conversation(project, conversation_id) do
      {:ok, %{"title" => title}}
      when is_binary(title) and title != "" and title not in @legacy_session_titles ->
        title

      _legacy_or_missing ->
        @default_session_title
    end
  end

  # Machine-facing naming contract — untranslated, like the reporting contract.
  # Naming is a separate Conversation update, never a Message field.
  defp session_naming_instructions do
    "This session still has its default name. After sending your visible reply, call internal.update_conversation separately with the current conversation_id and a concise 3-6 word title based on what we're working on."
  end

  defp task_creation_instructions do
    """
    This user message is in the chat conversation. Treat the user's visible text as a candidate task request, not as an already-created task.

    Use the current source conversation_id for any visible reply to this chat.

    Classify by intent, not keywords. Chat-only messages are social chat, clarification, or a direct conversational answer that needs no durable result, side effect, follow-up, or review. Answer chat-only messages directly in this chat conversation without creating a task.

    Any other request is work. Work includes anything that needs an artifact, a durable result, an action, a state change, investigation, multi-step effort, async progress, or a result the user can later review. Create a task conversation only when the request is distinct new work that does not already belong to an existing Task. When a request may continue or revise an existing Task, resolve and continue the exact Task before deciding instead of creating a replacement; follow the current Router Task-resolution and continuation guidance when trusted context does not already identify it exactly. Do not match by title alone. For work that needs a distinct new Task, do not produce the deliverable directly in this chat first. Create an ordinary Task with im_api.internal.task.create, supplying agent_id, title and self-contained content. Use call(tool="agent.list", params={"limit": 100}) only if you need to discover an agent id. Put the complete work instruction plus any needed execution context in im_api.internal.task.create.content because a new Task does not inherit an existing Task's message history. For recurring work, content must describe only the work the worker should perform; never ask the worker to create, manage, or interpret a Schedule or say that the Task is recurring. Put recurrence only in im_api.internal.task.create.schedule. After im_api.internal.task.create succeeds, reply briefly by calling im_api.internal.send_message with content containing a visible text block and a generic conversation reference block using the returned conversation_id: [{"type":"text","text":"Created the task."},{"type":"conversation_ref","conversation_id":"<task conversation_id>","kind":"agent_task","title":"<the same concise title>"}]. Always include the title — the dashboard renders it on the task card. Do not put the task result in chat; the worker writes progress and results in the task conversation. This filing rule applies only to requests in this chat conversation. Inside a Task, follow the current delivery context and role: as its Worker, complete delegated work there; as Router/delegator for a user follow-up, decide whether it belongs to the current Task or needs a separate self-contained Task, reading the current Task first when needed. A separate Task does not inherit the current Task's message history.

    If the user's intent is unclear, ask a concise clarification in chat. Once the user gives enough information for work, follow the existing-versus-distinct Task rule above. If it is chat-only, do not create a task conversation.
    """
    |> String.trim()
  end

  defp task_status_pill(status) do
    case status do
      "done" -> {"ok", gettext("Done")}
      "in_progress" -> {"pending", gettext("In progress")}
      "ready_for_review" -> {"pending", gettext("Ready for review")}
      "escalated" -> {"failed", gettext("Blocked")}
      "failed" -> {"failed", gettext("Failed")}
      "cancelled" -> {"idle", gettext("Cancelled")}
      "accepted" -> {"idle", gettext("Queued")}
      _ -> {"idle", gettext("Suggested")}
    end
  end

  # ---- greeting / drawer helpers -------------------------------------------------

  defp greeting(user) do
    name = user.name || user.email || ""
    first = name |> String.split(" ", parts: 2) |> List.first()

    prefix =
      case NaiveDateTime.local_now().hour do
        h when h in 5..11 -> gettext("Good morning")
        h when h in 12..17 -> gettext("Good afternoon")
        _ -> gettext("Good evening")
      end

    if first == "", do: prefix, else: "#{prefix}, #{first}"
  end

  # The Tasks header states what is actually true of the list: work waiting
  # on the user is "for you to review"; work the agent holds is the agent's,
  # not the user's. One hardcoded "for you to review" line over a list of
  # in-progress agent work read as a false to-do count.
  defp tasks_subtitle(tasks) do
    review = Enum.count(tasks, &(&1.status == "ready_for_review"))
    working = Enum.count(tasks, &(&1.status in ["suggested", "accepted", "in_progress"]))

    cond do
      review > 0 and working > 0 ->
        gettext("%{review} for you to review · %{working} in progress with your agent.",
          review: review,
          working: working
        )

      review > 0 ->
        ngettext(
          "%{count} task for you to review.",
          "%{count} tasks for you to review.",
          review,
          count: review
        )

      working > 0 ->
        ngettext(
          "Your agent is working on %{count} task — nothing to review yet.",
          "Your agent is working on %{count} tasks — nothing to review yet.",
          working,
          count: working
        )

      tasks != [] ->
        gettext("All caught up.")

      true ->
        gettext("Work you and your agent take on shows up here.")
    end
  end

  # The board splits at render time: General Tasks sit under the composer,
  # every other category lands on the widget wall below.
  defp general_tasks(task_groups) do
    case List.keyfind(task_groups, "general", 0) do
      {"general", tasks} -> tasks
      nil -> []
    end
  end

  # The wall shows every category (except General) in the user's saved
  # order — including ones with no tasks yet, which render an empty preview.
  defp dashboard_groups(task_groups, layout) do
    grouped = Map.new(task_groups)

    layout
    |> effective_order()
    |> Enum.reject(&(&1 == "general"))
    |> Enum.map(&{&1, grouped[&1] || []})
  end

  defp widget_size(prefs, category),
    do: get_in(prefs, ["sizes", category]) || default_widget_size(category)

  # Defaults live in code, not in the stored prefs, so they can evolve.
  defp default_widget_size(_category), do: "medium"

  # Any saved order or size counts as a customization — the state the Reset
  # button offers to clear, so its visibility derives from exactly that.
  defp wall_customized?(layout, prefs),
    do: layout != [] or (prefs["sizes"] || %{}) != %{}

  # The working list folds past ten rows behind "Show more".
  defp tasks_visible_max, do: 10

  defp visible_general_tasks(task_groups, true = _expanded), do: general_tasks(task_groups)

  defp visible_general_tasks(task_groups, false = _expanded),
    do: task_groups |> general_tasks() |> Enum.take(tasks_visible_max())

  # The Suggestions block is an agent-managed block like the widgets: it
  # renders this user's live `suggestions`-category workspace items
  # (agent-authored, imported, or projected). No static fallback — a board
  # whose agent has proposed nothing shows no Suggestions section.
  defp load_suggestions(%{board_project: %{} = project} = assigns) do
    assigns.current_user.id
    |> WorkspaceItems.list_tasks(
      project_id: project.id,
      category: "suggestions",
      status: "suggested",
      limit: 6
    )
    |> Enum.map(&item_suggestion/1)
  end

  defp load_suggestions(_assigns), do: []

  defp item_suggestion(item) do
    %{
      id: item.id,
      title: item.title,
      description: item.description || "",
      category: item_suggestion_category(item),
      platform: item.platform || "comma"
    }
  end

  # The target category an accepted suggestion lands in (and whose icon the
  # row wears): the item's `payload["category"]` when it names a known
  # category, otherwise the generic list.
  defp item_suggestion_category(item) do
    with %{} <- item.payload,
         category when is_binary(category) <- item.payload["category"],
         true <- category in WorkspaceItems.categories() do
      category
    else
      _other -> "general"
    end
  end

  # Wake the agent in the suggestion's task conversation so it executes the
  # proposed action. Best-effort: an item without a conversation (or a send
  # failure) still leaves the acceptance recorded on the row.
  defp dispatch_accepted_suggestion(project, item, user) do
    with conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           item.salix_conversation_id,
         {:error, reason} <-
           Conversations.send_project_conversation_message(
             project,
             conversation_id,
             gettext("I accepted this suggestion — go ahead: %{title}", title: item.title),
             actor_user_id: user.id,
             actor_label: user.email || user.id
           ) do
      Logger.warning(
        "suggestion_accept_dispatch_failed item=#{item.id} conversation=#{conversation_id} reason=#{inspect(reason)}"
      )

      :ok
    else
      _sent_or_no_conversation -> :ok
    end
  end

  # "Wednesday, July 2" — day interpolated because Elixir's strftime has no
  # unpadded-day directive.
  defp header_date do
    today = Date.utc_today()
    "#{Calendar.strftime(today, "%A, %B")} #{today.day}"
  end

  # "Send from the app" = hand the (edited) draft to the mail product with
  # everything prefilled; the actual send happens there.
  defp gmail_compose_url(to, subject, body) do
    "https://mail.google.com/mail/?" <>
      URI.encode_query(%{
        "view" => "cm",
        "fs" => "1",
        "to" => to || "",
        "su" => subject || "",
        "body" => body || ""
      })
  end

  # Rows seeded before drafts carried a full body fall back to the snippet.
  defp draft_body(payload) do
    case payload["body"] do
      body when is_binary(body) and body != "" -> body
      _ -> payload["snippet"] || ""
    end
  end

  # Meeting recaps render from stored markdown when present, otherwise a
  # document is assembled from the structured payload (date/attendees/bullets).
  defp recap_markdown(task) do
    case task.payload["markdown"] do
      markdown when is_binary(markdown) and markdown != "" ->
        markdown

      _ ->
        bullets =
          task.payload["bullets"]
          |> List.wrap()
          |> Enum.map_join("\n", &("- " <> to_string(&1)))

        meta =
          [task.payload["date"], attendees_line(task.payload["attendees"])]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(" · ")

        """
        # #{task.title}

        #{meta}

        ## #{gettext("Highlights")}

        #{bullets}

        ## #{gettext("Next steps")}

        - #{gettext("Follow-ups are drafted in your inbox for anything that needs a reply.")}
        """
    end
  end

  defp attendees_line(nil), do: nil

  defp attendees_line(count),
    do: ngettext("%{count} attendee", "%{count} attendees", count, count: count)

  # ---- meeting record helpers ------------------------------------------------

  # Meeting rows normally carry the projection's structured summary map
  # (key_points/action_items); a worker reporting through the generic
  # artifact contract writes `summary` as a plain string instead. Every
  # meeting renderer goes through these two so both shapes render and
  # neither crashes the LiveView.
  defp meeting_summary_map(%{"summary" => %{} = summary}), do: summary
  defp meeting_summary_map(_payload), do: %{}

  defp meeting_summary_text(%{"summary" => summary})
       when is_binary(summary) and summary != "",
       do: summary

  defp meeting_summary_text(_payload), do: nil

  defp action_item_line(item) when is_map(item) do
    suffix =
      [item["owner"], item["deadline"]]
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" · ")

    description = to_string(item["description"] || "")
    if suffix == "", do: description, else: "#{description} (#{suffix})"
  end

  defp action_item_line(item), do: to_string(item)

  defp meeting_meta(payload) do
    captions = payload["captions_count"]

    [
      gettext("Slack · Google Meet"),
      meeting_date(payload),
      (is_integer(captions) and captions > 0) &&
        gettext("%{count} captions", count: captions)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp meeting_date(%{"start_at" => start_at}) when is_integer(start_at) do
    case DateTime.from_unix(start_at) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%b %-d")
      _ -> nil
    end
  end

  defp meeting_date(_payload), do: nil

  # What the bot is doing right now, for meetings that aren't summarized yet.
  defp meeting_status_line(payload) do
    case payload["meeting_status"] do
      status when status in ["provisioning", "joining"] ->
        gettext("Your agent is joining the call…")

      "active" ->
        gettext("Your agent is in the call, taking notes.")

      "processing" ->
        gettext("Call ended — writing the summary.")

      "failed" ->
        case to_string(payload["error"] || "") do
          "" -> gettext("The bot couldn't complete this meeting.")
          error -> gettext("Meeting failed: %{error}", error: error)
        end

      "cancelled" ->
        gettext("Meeting cancelled.")

      _done ->
        nil
    end
  end

  defp meeting_artifact_labels(payload) do
    payload["artifacts"]
    |> List.wrap()
    |> Enum.flat_map(fn
      "transcript" -> [gettext("Transcript")]
      "audio" -> [gettext("Recording")]
      _other -> []
    end)
  end

  # Where a general task came from (its meeting), or the owner/deadline note.
  defp general_task_subtitle(task) do
    cond do
      is_binary(task.description) and task.description != "" ->
        task.description

      is_binary(task.payload["origin_title"]) and task.payload["origin_title"] != "" ->
        gettext("From: %{title}", title: task.payload["origin_title"])

      true ->
        nil
    end
  end

  # ---- render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The page's only Escape binding — see "escape_pressed". --%>
    <div class="relative flex h-full gap-3" phx-window-keydown="escape_pressed" phx-key="escape">
      <div class={[
        "panel-raised t-stack-base h-full min-w-0 flex-1 overflow-y-auto xl:overflow-hidden",
        @chat_expanded && "is-stacked"
      ]}>
      <div class="mx-auto flex max-w-[1200px] flex-col px-8 pb-12 pt-12 xl:h-full xl:py-0">
        <div class="scrollbar-none w-full min-w-0 flex-1 xl:-mx-2 xl:h-full xl:overflow-y-auto xl:overscroll-contain xl:px-2 xl:pb-12 xl:pt-12">
          <header class="min-w-0">
            <h1 class="truncate text-2xl font-semibold tracking-[-0.16px] text-neutral-900">
              {greeting(@current_user)}
            </h1>
            <p class="mt-0.5 text-[13px] font-book text-neutral-500">{header_date()}</p>
          </header>

          <section class="mt-10">
            <h2 class="text-base font-semibold text-neutral-900">{gettext("Tasks")}</h2>
            <p class="mt-0.5 text-[13px] font-book text-neutral-500">
              {tasks_subtitle(general_tasks(@task_groups))}
            </p>

            <.empty_state
              :if={@task_groups == []}
              icon="sparkles"
              title={gettext("Nothing here yet")}
              description={
                gettext("Your agent adds work here as it learns your mail, meetings, and tools.")
              }
            >
              <:actions>
                <.button
                  variant="secondary"
                  size="sm"
                  phx-click={JS.focus(to: "#chat-form-rail-input")}
                >
                  {gettext("Start a task")}
                </.button>
              </:actions>
            </.empty_state>

            <div
              :if={general_tasks(@task_groups) != []}
              id="general-task-list"
              phx-hook="RowExit"
              class="-mx-2 mt-3 divide-y divide-neutral-100"
            >
              <.widget_item
                :for={task <- visible_general_tasks(@task_groups, @tasks_expanded)}
                category="general"
                task={task}
              />
            </div>
            <.button
              :if={length(general_tasks(@task_groups)) > tasks_visible_max() and !@tasks_expanded}
              variant="ghost"
              size="sm"
              phx-click="expand_tasks"
              class="mt-2"
            >
              <.icon name="chevron-down" class="h-3.5 w-3.5 text-neutral-400" />
              {gettext("Show more")}
              <span class="tabular-nums text-xs font-book text-neutral-400">
                {length(general_tasks(@task_groups)) - tasks_visible_max()}
              </span>
            </.button>
            <p
              :if={@task_groups != [] && general_tasks(@task_groups) == []}
              class="mt-3 text-sm font-book text-neutral-500"
            >
              {gettext("Nothing needs your review right now.")}
            </p>
          </section>

          <section :if={@suggestions != []} class="mt-10">
            <h2 class="text-base font-semibold text-neutral-900">{gettext("Suggestions")}</h2>
            <p class="mt-0.5 text-[13px] font-book text-neutral-500">
              {gettext("Proposed by your agent.")}
            </p>
            <div class="-mx-2 mt-3 divide-y divide-neutral-100">
              <button
                :for={suggestion <- @suggestions}
                type="button"
                phx-click="open_suggestion"
                phx-value-id={suggestion.id}
                class="group flex w-full items-center gap-3 rounded-md px-2 py-2 text-left hover:bg-neutral-100"
              >
                <span class="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-neutral-100 text-neutral-500 transition-colors duration-100 group-hover:bg-white">
                  <.icon name={Catalog.category_meta(suggestion.category).icon} class="h-4 w-4" />
                </span>
                <span class="min-w-0 flex-1 truncate text-[13px] font-medium text-neutral-800">
                  {suggestion.title}
                </span>
                <.icon
                  name="chevron-right"
                  class="h-4 w-4 shrink-0 text-neutral-300 opacity-0 transition-opacity duration-100 group-hover:opacity-100"
                />
              </button>
            </div>
          </section>

          <%!-- No reachable swarm means nothing can fill a widget — the wall
          only renders with a board project, keeping the empty board honest. --%>
          <section :if={@board_project} class="mt-10">
            <div class="flex items-end justify-between gap-4">
              <div class="min-w-0">
                <h2 class="text-base font-semibold text-neutral-900">
                  {gettext("Space widget")}
                </h2>
                <p class="mt-0.5 text-[13px] font-book text-neutral-500">
                  {gettext("Hold a card to drag it; pull the corner to resize.")}
                </p>
              </div>
              <.button
                :if={wall_customized?(@home_layout, @widget_prefs)}
                variant="ghost"
                size="sm"
                phx-click="reset_wall_layout"
                class="shrink-0"
              >
                {gettext("Reset layout")}
              </.button>
            </div>
            <%!-- Row flow, NOT grid-flow-dense: dense backfill divorces DOM
            order from visual position, so a drop "below this row" could land
            rows away. Predictable Notion-style insertion needs DOM order ==
            reading order; the occasional hole is the price. --%>
            <%!-- One breakpoint lower than the full-width wall carried: the
            chat rail takes ~350-390px of the row, so three columns only fit
            from 2xl and four never do. --%>
            <div
              id="dash-widget-grid"
              phx-hook="DashGrid"
              class="mt-3 grid auto-rows-[176px] grid-cols-2 gap-3 2xl:grid-cols-3"
            >
              <.dash_widget
                :for={
                  {category, tasks} <-
                    dashboard_groups(
                      @task_groups,
                      @home_layout
                    )
                }
                category={category}
                tasks={tasks}
                size={widget_size(@widget_prefs, category)}
                devices={@devices}
                can_add_device={@can_manage_devices}
              />
            </div>
          </section>
        </div>
      </div>
    </div>

    <.chat_rail
      title={rail_title(assigns)}
      thread_state={rail_thread_state(assigns)}
      composer_state={rail_composer_state(assigns)}
      messages={rail_thread_messages(assigns)}
      chat_activity={assistant_chat_activity(assigns)}
      chat_agent={@chat_agent}
      chat_text={@chat_text}
      current_org={@current_org}
      mention_skills={@mention_skills}
      uploads={@uploads}
      with_uploads={!@chat_expanded && !chat_panel?(@drawer)}
      task_groups={@task_groups}
    />

    <.link
      :if={!@chat_expanded}
      patch={~p"/new-home/chat"}
      aria-label={gettext("Open chat")}
      class="fixed bottom-4 right-4 z-20 grid h-11 w-11 place-items-center rounded-full bg-neutral-900 text-white shadow-floating lg:hidden"
    >
      <.icon name="chat-bubble" class="h-5 w-5" />
    </.link>

    <div
      :if={@chat_expanded}
      id="chat-sheet"
      class="absolute inset-0 z-30"
      phx-remove={hide_chat_sheet()}
      data-cancel={cancel_chat_sheet()}
    >
      <div
        class="absolute inset-0"
        phx-click={cancel_chat_sheet()}
        aria-hidden="true"
      >
      </div>
      <section
        class="t-sheet absolute inset-x-0 bottom-0 top-3 flex flex-col overflow-hidden rounded-xl bg-white shadow-popover ring-1 ring-neutral-900/5"
        role="dialog"
        aria-modal="true"
        aria-label={rail_title(assigns)}
      >
        <div class="flex h-12 shrink-0 items-center justify-between border-b border-neutral-100 px-4">
          <div class="flex min-w-0 items-center gap-1.5">
            <button
              :if={@chat_focus}
              phx-click="unfocus_chat"
              class="grid h-7 w-7 shrink-0 place-items-center rounded-md text-neutral-400 transition-colors duration-100 hover:bg-neutral-100 hover:text-neutral-700"
              aria-label={gettext("Back to assistant")}
            >
              <.icon name="arrow-left" class="h-4 w-4" />
            </button>
            <span class="truncate text-sm font-semibold text-neutral-900">
              {rail_title(assigns)}
            </span>
          </div>
          <button
            phx-click={cancel_chat_sheet()}
            class="grid h-7 w-7 place-items-center rounded-md text-neutral-400 transition-colors duration-100 hover:bg-neutral-100 hover:text-neutral-700"
            aria-label={gettext("Close")}
          >
            <.icon name="x-mark" class="h-4 w-4" />
          </button>
        </div>
        <div class="mx-auto flex w-full max-w-3xl min-h-0 flex-1 flex-col px-4">
          <.chat_thread
            chat_state={rail_thread_state(assigns)}
            chat_messages={rail_thread_messages(assigns)}
            chat_agent={@chat_agent}
            chat_activity={assistant_chat_activity(assigns)}
            current_org={@current_org}
            task_groups={@task_groups}
          />
          <.chat_composer
            id="chat-form-overlay"
            chat_state={rail_composer_state(assigns)}
            chat_text={@chat_text}
            mention_skills={@mention_skills}
            uploads={@uploads}
            with_uploads={@chat_expanded}
            autofocus={true}
            create_task={true}
          />
        </div>
      </section>
    </div>

    </div>

    <.add_device_modal
      :if={@env_form}
      form={@env_form}
      provisioners={@env_provisioners}
      org={@current_org}
    />

    <.drawer
      :if={@drawer}
      drawer={@drawer}
      series_runs={drawer_series_runs(@task_groups, @drawer)}
      thread_state={drawer_thread_state(assigns)}
      messages={drawer_thread_messages(assigns)}
      conversation={@focus_conversation}
      participants={@focus_participants}
      composer_state={drawer_composer_state(assigns)}
      chat_activity={drawer_chat_activity(assigns)}
      chat_agent={@chat_agent}
      chat_text={@chat_text}
      current_org={@current_org}
      mention_skills={@mention_skills}
      uploads={@uploads}
      with_uploads={!@chat_expanded && chat_panel?(@drawer)}
      task_groups={@task_groups}
    />
    """
  end

  defp hide_chat_sheet(js \\ %JS{}) do
    js
    |> JS.hide(
      to: "#chat-sheet .t-sheet",
      transition:
        {"ease-in duration-150", "translate-y-0 opacity-100", "translate-y-4 opacity-0"},
      time: 150
    )
    |> JS.hide(
      to: "#chat-sheet",
      transition: {"ease-in duration-150", "opacity-100", "opacity-0"},
      time: 150
    )
  end

  defp cancel_chat_sheet(js \\ %JS{}),
    do: js |> JS.exec("phx-remove", to: "#chat-sheet") |> JS.push("collapse_chat")

  # The single live_file_input follows the topmost visible composer: the
  # sheet overlay when expanded, else the floating task-chat panel, else the
  # rail.
  defp chat_panel?(%{kind: "task_chat"}), do: true
  defp chat_panel?(_drawer), do: false

  # ---- widget components ----

  attr(:class, :string, default: nil)

  # macOS Calendar-app treatment: today's real month and day are drawn into
  # the glyph, so the icon can never go stale. Uses Date.utc_today() like the
  # rest of this LiveView (no per-user timezone yet).
  defp calendar_date_icon(assigns) do
    today = Date.utc_today()

    assigns =
      assigns
      |> assign(:month, today |> Calendar.strftime("%b") |> String.upcase())
      |> assign(:day, today.day)

    ~H"""
    <svg viewBox="0 0 20 20" class={@class} aria-hidden="true">
      <rect x="0.5" y="0.5" width="19" height="19" rx="4.5" fill="white" stroke="#E5E5E5" />
      <text
        x="10"
        y="7"
        text-anchor="middle"
        font-size="4.8"
        font-weight="700"
        letter-spacing="0.3"
        fill="#DC2626"
      >{@month}</text>
      <text
        x="10"
        y="16.4"
        text-anchor="middle"
        font-size="10"
        font-weight="600"
        fill="#262626"
      >{@day}</text>
    </svg>
    """
  end

  attr(:category, :string, required: true)
  attr(:tasks, :list, required: true)
  attr(:size, :string, required: true)
  # The devices cell renders live registry rows, not tasks — every other
  # category ignores these two.
  attr(:devices, :any, default: nil)
  attr(:can_add_device, :boolean, default: false)

  # A wall card: macOS-style grid spans where each size earns a different
  # layout — small is a glance (hero fact, thumbnail, avatar cluster), medium
  # is the compact row list, large adds more rows.
  # data-dash-widget feeds the DashGrid drag hook.
  defp dash_widget(assigns) do
    assigns =
      assigns
      |> assign(:meta, Catalog.category_meta(assigns.category))

    ~H"""
    <div
      id={"dash-widget-" <> @category}
      data-dash-widget={@category}
      class={["group/dash min-w-0 select-none", dash_span_class(@size)]}
    >
      <%!-- Not <.card>: the dashboard needs a body that stretches to the grid
      cell so glances can anchor to the bottom edge — .card wraps content in a
      height-hugging div. Apple-widget anatomy: a whisper of an eyebrow, then
      the content IS the card. --%>
      <div class="relative flex h-full flex-col overflow-hidden rounded-xl border border-neutral-200 bg-white shadow-subtle">
        <div class="flex h-9 shrink-0 items-center justify-between pl-4 pr-2 pt-1.5">
          <%!-- Title icon matches the category's icon everywhere else, so a
          widget keeps its identity across surfaces. --%>
          <div class="flex min-w-0 items-center gap-2">
            <.calendar_date_icon :if={@category == "calendar"} class="h-4 w-4 shrink-0" />
            <.icon
              :if={@category != "calendar"}
              name={@meta.icon}
              variant="square"
              class="h-4 w-4 shrink-0 text-neutral-500"
            />
            <h3 class="min-w-0 truncate text-[13px] font-semibold text-neutral-700">
              {@meta.label}
            </h3>
          </div>
          <span class="flex items-center gap-0.5">
            <button
              :if={@category == "devices" && @can_add_device}
              type="button"
              phx-click="new_environment"
              title={gettext("Add device")}
              aria-label={gettext("Add device")}
              class="grid h-6 w-6 place-items-center rounded-md text-neutral-400 hover:bg-neutral-100 hover:text-neutral-600"
            >
              <.icon name="plus" class="h-3.5 w-3.5" />
            </button>
            <span class="flex items-center opacity-0 transition-opacity duration-100 group-hover/dash:opacity-100">
              <span
                data-drag-handle
                aria-hidden="true"
                title={gettext("Drag to rearrange")}
                class="grid h-6 w-6 cursor-grab place-items-center rounded-md text-neutral-400 hover:bg-neutral-100 hover:text-neutral-600"
              >
                <.icon name="drag-handle" class="h-3.5 w-3.5" />
              </span>
            </span>
          </span>
        </div>

        <div class="flex min-h-0 flex-1 flex-col px-4 pb-4 pt-1">
          <.dash_body
            category={@category}
            tasks={@tasks}
            size={@size}
            meta={@meta}
            devices={@devices}
          />
        </div>

        <%!-- Notion-style resize grip: drag to snap between 1x1 / 2x1 / 2x2.
        The DashGrid hook owns the gesture; sizes commit via set_widget_size. --%>
        <span
          data-resize-handle
          aria-hidden="true"
          title={gettext("Drag to resize")}
          class="absolute bottom-0 right-0 z-10 flex h-6 w-6 cursor-nwse-resize touch-none items-end justify-end p-1.5 opacity-0 transition-opacity duration-100 group-hover/dash:opacity-100"
        >
          <span class="h-2.5 w-2.5 rounded-br border-b-2 border-r-2 border-neutral-300"></span>
        </span>
      </div>
    </div>
    """
  end

  attr(:category, :string, required: true)
  attr(:tasks, :list, required: true)
  attr(:size, :string, required: true)
  attr(:meta, :map, required: true)
  attr(:devices, :any, default: nil)

  # Devices are live Salix registry rows, not agent tasks — the cell keeps the
  # rail card's states (:loading skeletons, :error, empty, rows) and clips to
  # the cell like every other widget. Must match before the ghost-rows clause:
  # the devices cell always carries `tasks: []`.
  defp dash_body(%{category: "devices"} = assigns) do
    ~H"""
    <div :if={@devices == :loading} class="mt-2 space-y-2" aria-hidden="true">
      <div class="t-skeleton h-3 w-2/3 rounded bg-neutral-200/80"></div>
      <div class="t-skeleton h-3 w-1/2 rounded bg-neutral-200/80"></div>
    </div>

    <p :if={@devices == :error} class="mt-1 text-xs font-book text-neutral-500">
      {gettext("Device list is unavailable right now.")}
    </p>

    <p :if={@devices == []} class="mt-1 text-xs font-book text-neutral-500">
      {gettext("No devices connected yet.")}
    </p>

    <div
      :if={is_list(@devices) and @devices != []}
      class="min-h-0 flex-1 space-y-2 overflow-hidden pt-1"
    >
      <div :for={device <- Enum.take(@devices, dash_device_cap(@size))} class="flex items-center gap-2">
        <.icon
          name={if device.cloud_vm?, do: "globe", else: "cube"}
          class="h-4 w-4 shrink-0 text-neutral-400"
        />
        <span class="min-w-0 flex-1">
          <span class="block truncate text-[13px] font-book text-neutral-600">
            {device.name || gettext("Unnamed device")}
          </span>
          <span :if={device.system} class="block truncate text-xs font-book text-neutral-400">
            {device.system}
          </span>
          <span
            :if={last_exec_label(device.last_exec)}
            class="block truncate text-xs font-book italic text-neutral-400"
          >
            {last_exec_label(device.last_exec)}
          </span>
        </span>
        <span
          :if={device.status != "connected" && RelativeTime.label(device.last_seen_at)}
          class="shrink-0 text-xs font-book text-neutral-400"
        >
          {RelativeTime.label(device.last_seen_at)}
        </span>
        <.status_pill status={device.status} />
      </div>
    </div>
    """
  end

  # Empty categories teach with ghost rows — a quiet preview of the shape of
  # what the agent will fill in, not just a shrug.
  defp dash_body(%{tasks: []} = assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col justify-center gap-3 px-1" aria-hidden="true">
      <div :for={width <- ["w-3/5", "w-2/5"]} class="flex items-center gap-2.5">
        <span class="h-6 w-6 shrink-0 rounded-full bg-neutral-100"></span>
        <span class="min-w-0 flex-1 space-y-1.5">
          <span class={["block h-1.5 rounded-full bg-neutral-100", width]}></span>
          <span class="block h-1.5 w-1/4 rounded-full bg-neutral-100/60"></span>
        </span>
      </div>
      <p class="text-xs font-book text-neutral-400">
        {gettext("Nothing here yet — your agent fills this in.")}
      </p>
    </div>
    """
  end

  # Small = a glance, not a list.
  defp dash_body(%{size: "small"} = assigns) do
    ~H"""
    <.dash_glance category={@category} tasks={@tasks} />
    """
  end

  # Metrics read as a stat board, not label:value rows. Medium splits like
  # Apple's Stocks widget — hero left, quiet stat grid right; large stacks
  # the hero over the full grid. Like every payload widget, the metrics
  # payload can sit on any of the category's tasks, not just the newest.
  defp dash_body(%{category: "metrics", size: "medium"} = assigns) do
    case find_metrics_task(assigns.tasks) do
      nil -> dash_rows(assigns)
      task -> dash_metrics_medium(assign(assigns, :task, task))
    end
  end

  defp dash_body(%{category: "metrics"} = assigns) do
    case find_metrics_task(assigns.tasks) do
      nil -> dash_rows(assigns)
      task -> dash_metrics_large(assign(assigns, :task, task))
    end
  end

  # Portfolio skips the task-title preamble (the header already names the
  # widget): company rows straight away, capped to the cell, with the real
  # health mix as a proportional strip at the bottom edge. The companies
  # payload can sit on any of the category's tasks, not just the first.
  defp dash_body(%{category: "portfolio"} = assigns) do
    case find_companies_task(assigns.tasks) do
      nil -> dash_rows(assigns)
      task -> dash_portfolio_body(assign(assigns, :task, task))
    end
  end

  # Engineering reads like the reference traffic list: repo name over its
  # commit-share meter, counts right-aligned in tabular figures.
  defp dash_body(%{category: "engineering"} = assigns) do
    case Enum.find(assigns.tasks, &match?(%{payload: %{"rows" => [_ | _]}}, &1)) do
      nil -> dash_rows(assigns)
      task -> dash_engineering_body(assign(assigns, :task, task))
    end
  end

  # Team activity renders payload items, not tasks — cap the ITEMS to the
  # cell or a single busy task overflows it.
  defp dash_body(%{category: "team_activity"} = assigns) do
    case Enum.find(assigns.tasks, &match?(%{payload: %{"items" => [_ | _]}}, &1)) do
      nil -> dash_rows(assigns)
      task -> dash_team_body(assign(assigns, :task, task))
    end
  end

  # Medium and large: the compact row list, capped so nothing spills.
  defp dash_body(assigns), do: dash_rows(assigns)

  defp dash_metrics_medium(assigns) do
    [hero | rest] = assigns.task.payload["metrics"]
    assigns = assigns |> assign(:hero, hero) |> assign(:rest, Enum.take(rest, 2))

    ~H"""
    <div class="flex min-h-0 flex-1 items-end gap-6">
      <div class="min-w-0 max-w-[48%] shrink-0">
        <div class="flex items-baseline gap-2">
          <span class="text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
            {@hero["value"]}
          </span>
          <span
            :if={@hero["delta"]}
            class={["tabular-nums text-xs font-medium", delta_class(@hero["delta"])]}
          >
            {@hero["delta"]}
          </span>
        </div>
        <div class="mt-1.5 truncate text-xs text-neutral-500">{@hero["label"]}</div>
      </div>
      <div :if={@rest != []} class="flex min-w-0 flex-1 divide-x divide-neutral-200 pb-0.5">
        <div :for={metric <- @rest} class="min-w-0 flex-1 px-4 first:pl-0 last:pr-0">
          <div class="truncate text-[10px] font-medium uppercase tracking-[0.08em] text-neutral-400">
            {metric["label"]}
          </div>
          <div class="mt-1 flex items-baseline gap-1.5">
            <span class="text-lg font-semibold leading-none tabular-nums text-neutral-900">
              {metric["value"]}
            </span>
            <span
              :if={metric["delta"]}
              class={["tabular-nums text-[11px] font-medium", delta_class(metric["delta"])]}
            >
              {metric["delta"]}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp dash_metrics_large(assigns) do
    [hero | rest] = assigns.task.payload["metrics"]

    assigns =
      assigns
      |> assign(:hero, hero)
      |> assign(:rest, Enum.take(rest, 3))
      |> assign(:note, assigns.task.payload["note"])

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div class="pt-2">
        <div class="flex items-baseline gap-2">
          <span class="text-[44px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
            {@hero["value"]}
          </span>
          <span
            :if={@hero["delta"]}
            class={["tabular-nums text-sm font-medium", delta_class(@hero["delta"])]}
          >
            {@hero["delta"]}
          </span>
        </div>
        <div class="mt-2 truncate text-xs text-neutral-500">{@hero["label"]}</div>
      </div>
      <div :if={@rest != []} class="mt-auto flex divide-x divide-neutral-200 border-t border-neutral-100 pt-4">
        <div :for={metric <- @rest} class="min-w-0 flex-1 px-4 first:pl-0 last:pr-0">
          <div class="truncate text-[10px] font-medium uppercase tracking-[0.08em] text-neutral-400">
            {metric["label"]}
          </div>
          <div class="mt-1.5 flex items-baseline gap-1.5">
            <span class="text-[22px] font-semibold leading-none tabular-nums tracking-[-0.5px] text-neutral-900">
              {metric["value"]}
            </span>
            <span
              :if={metric["delta"]}
              class={["tabular-nums text-[11px] font-medium", delta_class(metric["delta"])]}
            >
              {metric["delta"]}
            </span>
          </div>
        </div>
      </div>
      <p :if={@note} class="mt-3 truncate text-xs text-neutral-400">{@note}</p>
    </div>
    """
  end

  defp dash_team_body(assigns) do
    items = assigns.task.payload["items"]

    assigns =
      assigns
      |> assign(:items, Enum.take(items, if(assigns.size == "large", do: 6, else: 2)))
      |> assign(:note, if(assigns.size == "large", do: assigns.task.payload["note"]))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div class="-mx-2 min-h-0 flex-1 divide-y divide-neutral-100 overflow-hidden">
        <div :for={item <- @items} class="flex items-center gap-2.5 px-2 py-2">
          <span class="grid h-7 w-7 shrink-0 place-items-center rounded-full bg-brand-100 text-[10px] font-semibold text-brand-700">
            {item["who"] |> to_string() |> String.first() |> Kernel.||("?") |> String.upcase()}
          </span>
          <div class="min-w-0 flex-1">
            <div class="truncate text-[13px] font-medium text-neutral-900">{item["who"]}</div>
            <div class="truncate text-xs text-neutral-500">{item["what"]}</div>
          </div>
        </div>
      </div>
      <p :if={@note} class="mt-2 shrink-0 truncate text-xs text-neutral-400">{@note}</p>
    </div>
    """
  end

  defp dash_engineering_body(assigns) do
    rows = assigns.task.payload["rows"]

    assigns =
      assigns
      |> assign(:rows, Enum.take(rows, if(assigns.size == "large", do: 6, else: 3)))
      |> assign(:max, engineering_max(rows))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col justify-end gap-3 pb-1">
      <div :for={row <- @rows} class="min-w-0">
        <div class="flex items-baseline justify-between gap-3">
          <span class="truncate text-[13px] font-medium text-neutral-900">{row["name"]}</span>
          <span class="shrink-0 tabular-nums text-xs text-neutral-500">
            {gettext("%{prs} PRs · %{commits} commits", prs: row["prs"], commits: row["commits"])}
          </span>
        </div>
        <span
          class="mt-1.5 block h-[3px] rounded-full bg-neutral-300"
          style={"width: #{engineering_percent(row["commits"], @max)}%"}
        >
        </span>
      </div>
    </div>
    """
  end

  defp dash_portfolio_body(assigns) do
    companies = assigns.task.payload["companies"]

    assigns =
      assigns
      |> assign(:companies, Enum.take(companies, if(assigns.size == "large", do: 5, else: 2)))
      |> assign(:all_companies, companies)
      |> assign(:health, portfolio_health_segments(companies))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div class="-mx-2 min-h-0 flex-1 divide-y divide-neutral-100 overflow-hidden">
        <div :for={company <- @companies} class="flex items-center gap-2.5 px-2 py-2">
          <.company_logo company={company} class="h-7 w-7 rounded-md" ctx="dash" />
          <div class="min-w-0 flex-1">
            <div class="flex items-baseline gap-2">
              <span class="truncate text-[13px] font-medium text-neutral-900">
                {company["name"]}
              </span>
              <span class="shrink-0 text-xs text-neutral-500">{company["stage"]}</span>
            </div>
            <div class="truncate text-xs text-neutral-500">{company["update"]}</div>
          </div>
          <.health_mark health={company["health"]} />
        </div>
      </div>
      <div
        class="mt-2.5 flex h-2 shrink-0 gap-1 overflow-hidden rounded-full"
        title={portfolio_health_summary(@health)}
      >
        <span
          :for={{class, count} <- @health}
          :if={count > 0}
          class={["block h-full rounded-full", class]}
          style={"width: #{Float.round(count * 100 / length(@all_companies), 1)}%"}
        >
        </span>
      </div>
    </div>
    """
  end

  # Rows collapse report series exactly like the drawer does —
  # `widget_entries` fronts each series with its latest run and the run
  # count; every other category passes through one row per task.
  defp dash_rows(assigns) do
    assigns =
      assign(
        assigns,
        :capped,
        assigns.category
        |> widget_entries(assigns.tasks)
        |> Enum.take(dash_item_cap(assigns.size))
      )

    ~H"""
    <div class="-mx-2 min-h-0 flex-1 space-y-0.5 overflow-hidden">
      <.widget_item
        :for={{task, run_count} <- @capped}
        category={@category}
        task={task}
        run_count={run_count}
        ctx="dash"
      />
    </div>
    """
  end

  defp find_companies_task(tasks),
    do: Enum.find(tasks, &match?(%{payload: %{"companies" => [_ | _]}}, &1))

  defp find_metrics_task(tasks),
    do: Enum.find(tasks, &match?(%{payload: %{"metrics" => [_ | _]}}, &1))

  # Deltas are signed strings ("+12", "-3"); red for down, green for up —
  # never green-for-everything.
  defp delta_class(delta) do
    if delta |> to_string() |> String.starts_with?("-"),
      do: "text-red-600",
      else: "text-green-600"
  end

  attr(:category, :string, required: true)
  attr(:tasks, :list, required: true)

  # 1x1 glances lead with the artifact each category actually has: the hero
  # KPI, the newest site's live thumbnail, recipient/company identity marks —
  # never fabricated series.
  defp dash_glance(%{category: "metrics"} = assigns) do
    case find_metrics_task(assigns.tasks) do
      nil -> dash_glance_generic(assigns)
      task -> dash_metrics_glance(assign(assigns, :hero, hd(task.payload["metrics"])))
    end
  end

  # The site preview IS the widget — full-bleed under the eyebrow with the
  # title riding a white gradient, like a photo widget.
  defp dash_glance(%{category: "reports", tasks: [task | _]} = assigns) do
    assigns =
      assigns
      |> assign(:task, task)
      |> assign(:url, display_site_url(task.payload["url"]))

    ~H"""
    <.task_run
      task={@task}
      class="relative -mx-4 -mb-4 mt-1 block min-h-0 flex-1 overflow-hidden bg-neutral-50"
    >
      <iframe
        :if={@url}
        src={@url}
        title={@task.title}
        loading="lazy"
        tabindex="-1"
        aria-hidden="true"
        sandbox=""
        scrolling="no"
        class="pointer-events-none absolute left-0 top-0 h-[625%] w-[625%] origin-top-left scale-[0.16] border-0 bg-white"
      >
      </iframe>
      <span :if={!@url} class="absolute inset-0 grid place-items-center" aria-hidden="true">
        <.icon name="globe" class="h-5 w-5 text-neutral-300" />
      </span>
      <span class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-white via-white/90 to-transparent px-4 pb-3 pt-8">
        <span class="block truncate text-[13px] font-semibold text-neutral-900">
          {@task.title}
        </span>
        <span class="mt-0.5 flex items-center gap-1 text-xs text-neutral-400">
          <span class="shrink-0">{report_kind_label(@task.payload["kind"])}</span>
          <span :if={@task.payload["period"]} class="truncate">· {@task.payload["period"]}</span>
        </span>
      </span>
    </.task_run>
    """
  end

  defp dash_glance(%{category: "email_drafts"} = assigns) do
    # "Waiting" means the same thing the status dot means — reviewed drafts
    # stay on the board but stop counting.
    assigns =
      assign(assigns, :waiting, Enum.count(assigns.tasks, &(&1.status == "ready_for_review")))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col justify-end">
      <div class="flex -space-x-1.5">
        <.recipient_avatar
          :for={task <- Enum.take(@tasks, 4)}
          payload={task.payload}
          class="h-7 w-7 ring-2 ring-white"
        />
      </div>
      <div class="mt-3 text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
        {@waiting}
      </div>
      <div class="mt-1.5 truncate text-xs text-neutral-500">
        {ngettext("draft waiting for review", "drafts waiting for review", @waiting)}
      </div>
    </div>
    """
  end

  # Next meeting, calendar-widget style: the status bar carries the state
  # (amber in-flight, green summarized, neutral reviewed), the title leads.
  defp dash_glance(%{category: "meetings"} = assigns) do
    case Enum.find(assigns.tasks, &match?(%{payload: %{"meeting_id" => _}}, &1)) do
      nil -> dash_glance_generic(assigns)
      task -> dash_meeting_glance(assign(assigns, :task, task))
    end
  end

  # Latest recap: date-forward, like glancing at yesterday's calendar.
  defp dash_glance(%{category: "meeting_recaps"} = assigns) do
    case Enum.find(assigns.tasks, &match?(%{payload: %{"bullets" => [_ | _]}}, &1)) do
      nil -> dash_glance_generic(assigns)
      task -> dash_recap_glance(assign(assigns, :task, task))
    end
  end

  # Engineering pulse: total commits as the hero, the busiest repo's share
  # as the one honest meter we have.
  defp dash_glance(%{category: "engineering"} = assigns) do
    case Enum.find(assigns.tasks, &match?(%{payload: %{"rows" => [_ | _]}}, &1)) do
      nil ->
        dash_glance_generic(assigns)

      task ->
        rows = task.payload["rows"]
        total = rows |> Enum.map(&(&1["commits"] || 0)) |> Enum.sum()
        top = Enum.max_by(rows, &(&1["commits"] || 0))

        assigns =
          assigns
          |> assign(:total, total)
          |> assign(:repos, length(rows))
          |> assign(:top, top)
          |> assign(:top_percent, engineering_percent(top["commits"], max(total, 1)))

        ~H"""
        <div class="flex min-h-0 flex-1 flex-col justify-end">
          <div class="text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
            {@total}
          </div>
          <div class="mt-1.5 truncate text-xs text-neutral-500">
            {ngettext("commit · %{repos} repos", "commits · %{repos} repos", @total, repos: @repos)}
          </div>
          <div class="mt-3 min-w-0">
            <div class="flex items-baseline justify-between gap-3">
              <span class="min-w-0 truncate text-[11px] font-medium text-neutral-600">
                {@top["name"]}
              </span>
              <span class="shrink-0 tabular-nums text-[11px] text-neutral-400">
                {@top["commits"]}
              </span>
            </div>
            <span
              class="mt-1 block h-[3px] rounded-full bg-neutral-300"
              style={"width: #{@top_percent}%"}
            >
            </span>
          </div>
        </div>
        """
    end
  end

  # Who's active: initials cluster over the update count.
  defp dash_glance(%{category: "team_activity"} = assigns) do
    case Enum.find(assigns.tasks, &match?(%{payload: %{"items" => [_ | _]}}, &1)) do
      nil ->
        dash_glance_generic(assigns)

      task ->
        assigns = assign(assigns, :items, task.payload["items"])

        ~H"""
        <div class="flex min-h-0 flex-1 flex-col justify-end">
          <div class="flex -space-x-1.5">
            <span
              :for={item <- Enum.take(@items, 4)}
              class="grid h-7 w-7 place-items-center rounded-full bg-brand-100 text-[10px] font-semibold text-brand-700 ring-2 ring-white"
            >
              {item["who"] |> to_string() |> String.first() |> Kernel.||("?") |> String.upcase()}
            </span>
          </div>
          <div class="mt-3 text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
            {length(@items)}
          </div>
          <div class="mt-1.5 truncate text-xs text-neutral-500">
            {ngettext("workspace update", "workspace updates", length(@items))}
          </div>
        </div>
        """
    end
  end

  defp dash_glance(%{category: "portfolio"} = assigns) do
    case find_companies_task(assigns.tasks) do
      nil -> dash_glance_generic(assigns)
      task -> dash_portfolio_glance(assign(assigns, :task, task))
    end
  end

  # Generic glance: the newest item's identity over a quiet count.
  defp dash_glance(assigns), do: dash_glance_generic(assigns)

  defp dash_metrics_glance(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col justify-end">
      <div class="flex items-baseline gap-2">
        <span class="text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
          {@hero["value"]}
        </span>
        <span
          :if={@hero["delta"]}
          class={["tabular-nums text-xs font-medium", delta_class(@hero["delta"])]}
        >
          {@hero["delta"]}
        </span>
      </div>
      <div class="mt-1.5 truncate text-xs text-neutral-500">{@hero["label"]}</div>
    </div>
    """
  end

  defp dash_meeting_glance(assigns) do
    status_line = meeting_status_line(assigns.task.payload)

    assigns =
      assigns
      |> assign(:bar_class, meeting_bar_class(assigns.task, status_line))
      |> assign(:meta, status_line || meeting_date(assigns.task.payload))

    ~H"""
    <.task_run task={@task} class="flex min-h-0 flex-1 items-end">
      <span class="flex min-w-0 items-stretch gap-2.5">
        <span class={["w-[3px] shrink-0 rounded-full", @bar_class]} aria-hidden="true"></span>
        <span class="min-w-0">
          <span class="line-clamp-2 text-[15px] font-semibold leading-snug tracking-[-0.1px] text-neutral-900">
            {@task.title}
          </span>
          <span :if={@meta} class="mt-1 block truncate text-xs text-neutral-400">{@meta}</span>
        </span>
      </span>
    </.task_run>
    """
  end

  defp dash_recap_glance(assigns) do
    assigns =
      assign(assigns, :meta, [
        assigns.task.payload["date"],
        attendees_line(assigns.task.payload["attendees"])
      ])

    ~H"""
    <.task_run task={@task} class="flex min-h-0 flex-1 items-end">
      <span class="flex min-w-0 items-stretch gap-2.5">
        <span
          class={[
            "w-[3px] shrink-0 rounded-full",
            (@task.status == "done" && "bg-neutral-300") || "bg-green-500"
          ]}
          aria-hidden="true"
        >
        </span>
        <span class="min-w-0">
          <span class="line-clamp-2 text-[15px] font-semibold leading-snug tracking-[-0.1px] text-neutral-900">
            {@task.title}
          </span>
          <span class="mt-1 block truncate text-xs text-neutral-400">
            {@meta |> Enum.filter(& &1) |> Enum.join(" · ")}
          </span>
        </span>
      </span>
    </.task_run>
    """
  end

  defp dash_portfolio_glance(assigns) do
    companies = assigns.task.payload["companies"]

    assigns =
      assigns
      |> assign(:companies, companies)
      |> assign(:health, portfolio_health_segments(companies))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col justify-end">
      <div class="flex -space-x-1.5">
        <.company_logo
          :for={company <- Enum.take(@companies, 4)}
          company={company}
          class="h-7 w-7 rounded-md ring-2 ring-white"
          ctx="glance"
        />
      </div>
      <div class="mt-3 text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
        {length(@companies)}
      </div>
      <div class="mt-1.5 truncate text-xs text-neutral-500">
        {ngettext("company in the portfolio", "companies in the portfolio", length(@companies))}
      </div>
      <div
        class="mt-3 flex h-2 gap-1 overflow-hidden rounded-full"
        title={portfolio_health_summary(@health)}
      >
        <span
          :for={{class, count} <- @health}
          :if={count > 0}
          class={["block h-full rounded-full", class]}
          style={"width: #{Float.round(count * 100 / length(@companies), 1)}%"}
        >
        </span>
      </div>
    </div>
    """
  end

  defp dash_glance_generic(%{tasks: [task | _]} = assigns) do
    assigns = assign(assigns, :task, task)

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col justify-end">
      <div class="text-[40px] font-semibold leading-none tabular-nums tracking-[-1.5px] text-neutral-900">
        {length(@tasks)}
      </div>
      <div class="mt-2 line-clamp-2 text-[13px] font-medium leading-snug text-neutral-800">
        {@task.title}
      </div>
    </div>
    """
  end

  defp dash_span_class("small"), do: "col-span-1 row-span-1"
  defp dash_span_class("medium"), do: "col-span-2 row-span-1"
  defp dash_span_class("large"), do: "col-span-2 row-span-2"

  # Real health mix of the portfolio: on-track green, needs-attention amber,
  # anything else neutral — proportions only, no fabricated series.
  defp portfolio_health_segments(companies) do
    counts = Enum.frequencies_by(companies, &portfolio_health_status(&1["health"]))

    [
      {"bg-green-500", Map.get(counts, "ok", 0)},
      {"bg-amber-400", Map.get(counts, "pending", 0)},
      {"bg-neutral-200", Map.get(counts, "idle", 0)}
    ]
  end

  defp portfolio_health_summary(health) do
    [{_, ok}, {_, attention}, {_, other}] = health

    [
      ok > 0 && gettext("%{count} on track", count: ok),
      attention > 0 && gettext("%{count} need attention", count: attention),
      other > 0 && gettext("%{count} unknown", count: other)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # Two-line rows (title + caption) budget: 2 fit a medium cell, 5 a large.
  defp dash_item_cap("medium"), do: 2
  defp dash_item_cap(_size), do: 5

  # Device rows run up to three lines tall, so they fit fewer per cell than
  # task rows; small has no glance variant and shows the same row shape.
  defp dash_device_cap("large"), do: 6
  defp dash_device_cap(_size), do: 2

  attr(:category, :string, required: true)
  attr(:task, :map, required: true)
  # How many runs the row fronts (report series collapse to their latest run);
  # 1 everywhere else.
  attr(:run_count, :integer, default: 1)
  # Distinguishes surfaces that render the same rows at the same time (rail vs
  # widget dashboard) so generated ids — the portfolio SVG gradients — stay
  # unique in the DOM.
  attr(:ctx, :string, default: nil)

  # Typed renderers match on the payload shape they need; tasks without that
  # payload (e.g. accepted onboarding suggestions) fall through to the generic
  # title-row renderer at the bottom.
  # Report artifact: one row per series, fronted by its latest run and rendered
  # from index data only (title, kind/period, one-line summary, run count) —
  # never a live embed of the site. "Open site" appears only once the async
  # resolve produced a real URL; Review always opens the drawer, which pulls
  # the markdown body asynchronously.
  defp widget_item(%{category: "reports"} = assigns) do
    assigns = assign(assigns, :url, display_site_url(assigns.task.payload["url"]))

    ~H"""
    <div class="group relative flex items-center gap-3 rounded-md px-2 py-1.5 hover:bg-neutral-100">
      <span class="grid h-9 w-9 shrink-0 place-items-center rounded-md border border-neutral-200 bg-neutral-50">
        <.icon name="document-text" class="h-4 w-4 text-neutral-400" />
      </span>
      <.task_run task={@task} class="min-w-0 flex-1">
        <span class="block truncate text-[13px] font-medium text-neutral-800">
          {@task.title}
        </span>
        <span class="mt-0.5 flex items-center gap-1 text-xs text-neutral-400">
          <span class="shrink-0">{report_kind_label(@task.payload["kind"])}</span>
          <span :if={@task.payload["period"]} class="truncate">· {@task.payload["period"]}</span>
          <span :if={@run_count > 1} class="shrink-0 tabular-nums">
            · {gettext("%{count} runs", count: @run_count)}
          </span>
        </span>
        <span
          :if={is_binary(@task.payload["summary"]) and @task.payload["summary"] != ""}
          class="mt-0.5 block truncate text-xs text-neutral-500"
        >
          {@task.payload["summary"]}
        </span>
      </.task_run>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button :if={@url} size="sm" variant="secondary" href={@url} target="_blank" rel="noreferrer">
            <.icon name="globe" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Open site")}
          </.button>
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="result"
            phx-value-id={@task.id}
          >
            <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Review")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  # Message artifact: the recipient is the row's identity — initial avatar,
  # subject, then the platform + address caption.
  defp widget_item(%{category: "email_drafts", task: %{payload: %{"subject" => _}}} = assigns) do
    assigns = assign(assigns, :to, assigns.task.payload["to"])

    ~H"""
    <div class="group relative flex items-start justify-between gap-3 rounded-md px-2 py-2.5 hover:bg-neutral-100">
      <div class="flex min-w-0 items-start gap-2.5">
        <.recipient_avatar payload={@task.payload} class="h-7 w-7" />
        <.task_run task={@task}>
          <span class={[
            "block truncate text-[13px] font-medium",
            (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
          ]}>
            {@task.payload["subject"] || @task.title}
          </span>
          <span class="mt-0.5 flex items-center gap-1.5 text-xs text-neutral-400">
            <span class="grid h-4 w-4 shrink-0 place-items-center rounded border border-neutral-200 bg-white">
              <.brand_logo name="google" class="h-2.5 w-2.5" />
            </span>
            <span class="truncate">{gettext("To: %{to}", to: @to || "—")}</span>
          </span>
        </.task_run>
      </div>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="email_preview"
            phx-value-id={@task.id}
          >
            <.icon name="envelope" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Preview Draft")}
          </.button>
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="email_edit"
            phx-value-id={@task.id}
          >
            <.icon name="pencil" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Edit")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  defp widget_item(
         %{category: "meeting_recaps", task: %{payload: %{"bullets" => [_ | _]}}} = assigns
       ) do
    ~H"""
    <div class="group relative flex items-start justify-between gap-3 rounded-md px-2 py-2.5 hover:bg-neutral-100">
      <div class="flex min-w-0 items-start gap-2.5">
        <span
          class={[
            "w-[3px] shrink-0 self-stretch rounded-full",
            (@task.status == "done" && "bg-neutral-300") || "bg-green-500"
          ]}
          aria-hidden="true"
        >
        </span>
        <.task_run task={@task}>
          <span class={[
            "block truncate text-[13px] font-medium",
            (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
          ]}>
            {@task.title}
          </span>
          <span class="block truncate text-xs text-neutral-400">{recap_meta(@task.payload)}</span>
        </.task_run>
      </div>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="recap"
            phx-value-id={@task.id}
          >
            <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Preview")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  defp widget_item(
         %{category: "portfolio", task: %{payload: %{"companies" => [_ | _]}}} = assigns
       ) do
    ~H"""
    <div>
      <div class="divide-y divide-neutral-100">
        <div
          :for={company <- @task.payload["companies"] || []}
          class="flex items-center gap-2.5 px-2 py-2"
        >
          <.company_logo company={company} class="h-7 w-7 rounded-md" ctx={@ctx} />
          <div class="min-w-0 flex-1">
            <div class="flex items-baseline gap-2">
              <span class="truncate text-[13px] font-medium text-neutral-900">
                {company["name"]}
              </span>
              <span class="shrink-0 text-xs text-neutral-500">{company["stage"]}</span>
            </div>
            <div class="truncate text-xs text-neutral-500">{company["update"]}</div>
          </div>
          <.health_mark health={company["health"]} />
        </div>
      </div>
      <p :if={@task.payload["note"]} class="mt-2 text-xs text-neutral-400">
        {@task.payload["note"]}
      </p>
    </div>
    """
  end

  defp widget_item(
         %{category: "team_activity", task: %{payload: %{"items" => [_ | _]}}} = assigns
       ) do
    ~H"""
    <div>
      <div class="space-y-2">
        <div
          :for={item <- @task.payload["items"] || []}
          class="flex items-start gap-2.5 rounded-md px-2 py-1"
        >
          <div class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-brand-100 text-[10px] font-semibold text-brand-700">
            {item["who"] |> to_string() |> String.first() |> String.upcase()}
          </div>
          <div class="min-w-0">
            <div class="text-xs font-medium text-neutral-800">{item["who"]}</div>
            <div class="text-xs text-neutral-500">{item["what"]}</div>
          </div>
        </div>
      </div>
      <p :if={@task.payload["note"]} class="mt-2 text-xs text-neutral-400">
        {@task.payload["note"]}
      </p>
    </div>
    """
  end

  # Series artifact: each repo row carries an inline meter — commit share of
  # the busiest repo, computed from the real payload.
  defp widget_item(%{category: "engineering", task: %{payload: %{"rows" => [_ | _]}}} = assigns) do
    assigns = assign(assigns, :max_commits, engineering_max(assigns.task.payload["rows"]))

    ~H"""
    <div>
      <div class="divide-y divide-neutral-100">
        <div
          :for={row <- @task.payload["rows"] || []}
          class="flex items-center justify-between gap-3 px-2 py-1.5 text-xs"
        >
          <span class="truncate font-medium text-neutral-700">{row["name"]}</span>
          <span class="flex shrink-0 items-center gap-2">
            <span class="block h-1 w-16 overflow-hidden rounded-full bg-neutral-100">
              <span
                class="block h-full rounded-full bg-brand-400"
                style={"width: #{engineering_percent(row["commits"], @max_commits)}%"}
              >
              </span>
            </span>
            <span class="tabular-nums text-neutral-500">
              {gettext("%{prs} PRs · %{commits} commits", prs: row["prs"], commits: row["commits"])}
            </span>
          </span>
        </div>
      </div>
      <p class="mt-2 text-xs text-neutral-400">
        {Catalog.platform_label(@task.platform)} · {gettext("Live from connected repos")}
      </p>
    </div>
    """
  end

  # A bot-attended meeting record: what happened on the call, and where the
  # bot is when the call is still live.
  defp widget_item(%{category: "meetings", task: %{payload: %{"meeting_id" => _}}} = assigns) do
    status_line = meeting_status_line(assigns.task.payload)

    assigns =
      assigns
      |> assign(:status_line, status_line)
      |> assign(:bar_class, meeting_bar_class(assigns.task, status_line))

    ~H"""
    <div class="group relative flex items-start justify-between gap-3 rounded-md px-2 py-2.5 hover:bg-neutral-100">
      <div class="flex min-w-0 items-start gap-2.5">
        <span class={["w-[3px] shrink-0 self-stretch rounded-full", @bar_class]} aria-hidden="true">
        </span>
        <.task_run task={@task}>
          <span class={[
            "block truncate text-[13px] font-medium",
            (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
          ]}>
            {@task.title}
          </span>
          <span :if={@status_line} class="block truncate text-xs text-neutral-400">
            {@status_line}
          </span>
          <.meeting_meta_line :if={!@status_line} payload={@task.payload} />
        </.task_run>
      </div>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="meeting"
            phx-value-id={@task.id}
          >
            <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Preview")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  # A finished General task stays in the working list as one compact row.
  # Artifact details belong in the review drawer; rendering metrics/hero blocks
  # inline makes the Tasks list read like a widget dashboard.
  defp widget_item(%{category: "general", task: %{payload: %{} = payload}} = assigns)
       when is_map_key(payload, "hero") or is_map_key(payload, "summary") do
    ~H"""
    <div
      data-task-row={@task.id}
      class="group relative flex items-center justify-between gap-3 rounded-md px-2 py-1.5 hover:bg-neutral-100"
    >
      <button
        type="button"
        phx-click="run_task"
        phx-value-id={@task.id}
        title={gettext("Open task")}
        class="min-w-0 flex-1 py-1 text-left"
      >
        <span class={[
          "block truncate text-[13px] font-medium",
          (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
        ]}>
          {@task.title}
        </span>
      </button>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="result"
            phx-value-id={@task.id}
          >
            <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Review")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-brand-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  # Generic artifact row: any non-General category whose payload carries the artifact
  # doorbell shape — a one-line `summary` and/or a `hero` block for the card
  # (metrics' live kpis, an engineering run's table, ...). Title and summary
  # open the result drawer like every other row; the hero renders natively
  # below via the compact `ArtifactBlocks` treatment (which carries its own
  # horizontal padding, matching the widget-row `px-2`). This clause MUST sit
  # above the category-"general" working-list clause: delegated composer tasks
  # and sweeper-indexed /.salix/artifacts/ rows are category "general" and
  # only reach their document (Review drawer / full view) through this row.
  defp widget_item(%{task: %{payload: %{} = payload}} = assigns)
       when is_map_key(payload, "hero") or is_map_key(payload, "summary") do
    assigns =
      assigns
      |> assign(:hero, if(match?(%{}, payload["hero"]), do: payload["hero"]))
      |> assign(:summary, if(is_binary(payload["summary"]), do: payload["summary"]))

    ~H"""
    <div class="rounded-md py-1.5">
      <div class="group relative flex items-center justify-between gap-3 rounded-md px-2 py-1 hover:bg-neutral-100">
        <.task_run task={@task} class="min-w-0 flex-1">
          <span class={[
            "block truncate text-[13px] font-medium",
            (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
          ]}>
            {@task.title}
          </span>
          <span
            :if={@summary && @summary != ""}
            class="mt-0.5 block truncate text-xs text-neutral-500"
          >
            {@summary}
          </span>
        </.task_run>
        <div class="flex h-7 shrink-0 items-center gap-2 self-center">
          <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
            <.button
              size="sm"
              variant="secondary"
              phx-click="open_drawer"
              phx-value-kind="result"
              phx-value-id={@task.id}
            >
              <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
              {gettext("Review")}
            </.button>
          </span>
          <span
            :if={@task.status == "done"}
            class="h-1.5 w-1.5 shrink-0 rounded-full bg-brand-500"
            title={gettext("Completed")}
          >
          </span>
        </div>
      </div>
      <div :if={@hero} class="mt-1.5">
        <ArtifactBlocks.block block={@hero} variant={:compact} />
      </div>
    </div>
    """
  end

  # General Tasks: the working list — check it off yourself, then archive to
  # close the loop (the linked conversation leaves the board with it).
  # The working list under the composer. Clicking a row opens the backing
  # conversation in the chat rail. No status labels — a completed task shows
  # only a quiet blue dot; hover reveals icon-chip actions (Complete animates
  # the row via RowExit; Delete is the red one).
  defp widget_item(%{category: "general"} = assigns) do
    assigns = assign(assigns, :subtitle, general_task_subtitle(assigns.task))

    ~H"""
    <div
      data-task-row={@task.id}
      class="group relative flex items-center justify-between gap-3 rounded-md px-2 py-1.5 hover:bg-neutral-100"
    >
      <button
        type="button"
        phx-click="run_task"
        phx-value-id={@task.id}
        title={gettext("Open task")}
        class="min-w-0 flex-1 py-1 text-left"
      >
        <span class={[
          "block truncate text-[13px] font-medium",
          (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
        ]}>
          {@task.title}
        </span>
        <span :if={@subtitle} class="block truncate text-xs text-neutral-400">
          {@subtitle}
        </span>
      </button>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            :if={@task.status != "done"}
            size="sm"
            variant="secondary"
            data-exit-action="complete_task"
            data-task-id={@task.id}
          >
            <.icon name="check" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Mark as Complete")}
          </.button>
          <.button
            size="sm"
            variant="secondary"
            data-exit-action="archive_task"
            data-task-id={@task.id}
            class="text-red-600 hover:text-red-700"
          >
            <.icon name="trash" class="h-3.5 w-3.5" />
            {gettext("Delete task")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  # Routines lead with a type glyph so the list scans by shape: triage → inbox,
  # sweep → newspaper, review → chart, briefing → sparkles. Titles are free
  # text, so the type is keyword-inferred and every row must land on a glyph —
  # unknown shapes fall back to the category's clock.
  defp widget_item(%{category: "routines"} = assigns) do
    assigns = assign(assigns, :type_icon, routine_type_icon(assigns.task))

    ~H"""
    <div class="group relative flex items-center justify-between gap-3 rounded-md px-2 py-1.5 hover:bg-neutral-100">
      <div class="flex min-w-0 items-center gap-2.5">
        <span class="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-neutral-100 transition-colors duration-100 group-hover:bg-neutral-200/60">
          <.icon name={@type_icon} class="h-3.5 w-3.5 text-neutral-400" />
        </span>
        <.task_run task={@task}>
          <span class={[
            "block truncate text-[13px] font-medium",
            (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
          ]}>
            {@task.title}
          </span>
          <span :if={@task.description} class="block truncate text-xs text-neutral-400">
            {@task.description}
          </span>
        </.task_run>
      </div>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="result"
            phx-value-id={@task.id}
          >
            <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Review")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  defp widget_item(assigns) do
    ~H"""
    <div class="group relative flex items-center justify-between gap-3 rounded-md px-2 py-1.5 hover:bg-neutral-100">
      <div class="flex min-w-0 items-start gap-2.5">
        <.task_run task={@task}>
          <span class={[
            "block truncate text-[13px] font-medium",
            (@task.status == "done" && "text-neutral-400") || "text-neutral-800"
          ]}>
            {@task.title}
          </span>
          <span :if={@task.description} class="block truncate text-xs text-neutral-400">
            {@task.description}
          </span>
        </.task_run>
      </div>
      <div class="flex h-7 shrink-0 items-center gap-2 self-center">
        <span class="absolute inset-y-1 right-1.5 z-10 hidden items-center gap-1 rounded-md bg-neutral-100 pl-2 group-hover:flex">
          <.button
            size="sm"
            variant="secondary"
            phx-click="open_drawer"
            phx-value-kind="result"
            phx-value-id={@task.id}
          >
            <.icon name="document-text" class="h-3.5 w-3.5 text-neutral-500" />
            {gettext("Review")}
          </.button>
        </span>
        <span
          :if={@task.status == "done"}
          class="h-1.5 w-1.5 shrink-0 rounded-full bg-green-500"
          title={gettext("Completed")}
        >
        </span>
      </div>
    </div>
    """
  end

  # Routine titles/descriptions are free text in either UI language, so the
  # keyword lists carry both English and Chinese forms. Must be total: the
  # final clause guarantees a glyph for rows nothing else matches.
  defp routine_type_icon(task) do
    text = String.downcase("#{task.title} #{task.description}")

    cond do
      String.contains?(text, ["inbox", "mail", "triage", "邮件", "收件"]) -> "inbox"
      String.contains?(text, ["news", "informed", "新闻", "资讯"]) -> "newspaper"
      String.contains?(text, ["review", "pipeline", "复盘", "周报"]) -> "chart-bar"
      String.contains?(text, ["briefing", "digest", "简报", "晨间"]) -> "sparkles"
      String.contains?(text, ["wrap-up", "wrap up", "收尾"]) -> "check"
      true -> "clock"
    end
  end

  defp report_kind_label("daily"), do: gettext("Daily")
  defp report_kind_label("weekly"), do: gettext("Weekly")
  defp report_kind_label(_kind), do: gettext("Report")

  # Legacy shim: Salix now carries `sites_port` in synthesized local site URLs
  # (`SalixAgent.SiteId.site_url/2`), but task payloads stored before that
  # kept port-less `*.localhost` URLs — re-attach the port for those. New
  # URLs (host already carries a port) and real https domains pass through.
  #
  # Scheme allowlist first: `payload["url"]` can originate in an
  # agent-authored Conversation update, and this value reaches `href` on the
  # card button and the drawer's "Open site"
  # links. Anything but http/https renders NO link — `<.link>` raises on
  # `javascript:` (one poisoned row would crash every subsequent render of
  # the dashboard), and the drawer's raw `<a>` would hand the click straight
  # to a `javascript:`/`data:` URI.
  defp display_site_url(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)
    salix_port = Application.get_env(:salix_web, :port)

    cond do
      uri.scheme not in ["http", "https"] ->
        nil

      uri.scheme == "http" and is_binary(uri.host) and
        String.ends_with?(uri.host, ".localhost") and
        not String.contains?(url, uri.host <> ":") and
        is_integer(salix_port) and salix_port not in [0, 80] ->
        URI.to_string(%{uri | port: salix_port})

      true ->
        url
    end
  end

  defp display_site_url(_url), do: nil

  # "Ada Lovelace <ada@x.com>" / "ada@x.com" / "LP distribution list" → "A"
  defp recipient_initial(to) when is_binary(to) and to != "" do
    to |> String.trim() |> String.first() |> String.upcase()
  end

  defp recipient_initial(_to), do: "@"

  # Live meeting → amber (in flight); summarized awaiting review → green;
  # reviewed/done → quiet neutral. Mirrors the calendar-event bar treatment.
  defp meeting_bar_class(%{status: "done"}, _status_line), do: "bg-neutral-300"
  defp meeting_bar_class(_task, status_line) when is_binary(status_line), do: "bg-amber-400"
  defp meeting_bar_class(_task, _status_line), do: "bg-green-500"

  defp engineering_max(rows) when is_list(rows) do
    rows |> Enum.map(&(&1["commits"] || 0)) |> Enum.max(fn -> 1 end) |> max(1)
  end

  defp engineering_max(_rows), do: 1

  defp engineering_percent(commits, max_commits),
    do: round((commits || 0) / max_commits * 100)

  # ---- side drawer (multi-capability: email drafts, recap previews) ----

  # Drawer kinds that edit client-side only: their form has no phx-change, so
  # the user's typing lives solely in the DOM and closing on Escape would
  # silently discard it (the task-chat window's composer may hold an unsent
  # follow-up). Every new editable drawer kind belongs in this list —
  # "escape_pressed" derives its guard from here.
  @dom_edit_drawer_kinds ~w(email_edit task_chat)

  defp drawer_edits_in_dom?(%{kind: kind}), do: kind in @dom_edit_drawer_kinds
  defp drawer_edits_in_dom?(_drawer), do: false

  attr(:drawer, :map, required: true)
  # The drawer task's sibling report runs (index rows, newest first) — the
  # result drawer lists them as a swap-in run history.
  attr(:series_runs, :list, default: [])
  # The "task_chat" kind renders the focused task thread as a floating window
  # over the persistent assistant rail.
  attr(:thread_state, :any, default: :loading)
  attr(:messages, :list, default: [])
  attr(:conversation, :any, default: nil)
  attr(:participants, :list, default: [])
  attr(:chat_activity, :any, default: nil)
  attr(:composer_state, :any, default: :loading)
  attr(:chat_agent, :any, default: nil)
  attr(:chat_text, :string, default: "")
  attr(:current_org, :any, default: nil)
  attr(:mention_skills, :list, default: [])
  attr(:uploads, :any, default: nil)
  attr(:with_uploads, :boolean, default: false)
  attr(:task_groups, :list, default: [])

  defp drawer(assigns) do
    ~H"""
    <div
      id="home-drawer"
      class="fixed inset-0 z-40"
      phx-remove={hide_drawer()}
      data-cancel={cancel_drawer()}
    >
      <div
        class="t-drawer-overlay absolute inset-0 bg-neutral-900/20"
        phx-click={cancel_drawer()}
        aria-hidden="true"
      >
      </div>
      <div class="t-drawer-panel absolute bottom-2 right-2 top-2 flex w-full max-w-[480px] flex-col overflow-hidden rounded-xl bg-white shadow-popover">
        <.drawer_task_chat
          :if={@drawer.kind == "task_chat"}
          task={@drawer.task}
          thread_state={@thread_state}
          messages={@messages}
          conversation={@conversation}
          participants={@participants}
          chat_activity={@chat_activity}
          composer_state={@composer_state}
          chat_agent={@chat_agent}
          chat_text={@chat_text}
          current_org={@current_org}
          mention_skills={@mention_skills}
          uploads={@uploads}
          with_uploads={@with_uploads}
          task_groups={@task_groups}
        />
        <.drawer_email_preview
          :if={@drawer.kind == "email_preview"}
          task={@drawer.task}
          log={@drawer.log}
        />
        <.drawer_email_edit :if={@drawer.kind == "email_edit"} task={@drawer.task} />
        <.drawer_recap
          :if={@drawer.kind == "recap"}
          task={@drawer.task}
          view={@drawer.view}
          log={@drawer.log}
        />
        <.drawer_meeting :if={@drawer.kind == "meeting"} task={@drawer.task} log={@drawer.log} />
        <.drawer_result
          :if={@drawer.kind == "result"}
          task={@drawer.task}
          log={@drawer.log}
          artifact={Map.get(@drawer, :artifact, :none)}
          document={Map.get(@drawer, :document)}
          series_runs={@series_runs}
        />
        <.drawer_suggestion :if={@drawer.kind == "suggestion"} suggestion={@drawer.suggestion} />
      </div>
    </div>
    """
  end

  defp hide_drawer(js \\ %JS{}) do
    js
    |> JS.hide(
      to: "#home-drawer .t-drawer-panel",
      transition:
        {"ease-in duration-150", "translate-x-0 opacity-100", "translate-x-4 opacity-0"},
      time: 150
    )
    |> JS.hide(
      to: "#home-drawer .t-drawer-overlay",
      transition: {"ease-in duration-150", "opacity-100", "opacity-0"},
      time: 150
    )
    |> JS.hide(
      to: "#home-drawer",
      transition: {"ease-in duration-150", "opacity-100", "opacity-0"},
      time: 150
    )
  end

  defp cancel_drawer(js \\ %JS{}),
    do: js |> JS.exec("phx-remove", to: "#home-drawer") |> JS.push("close_drawer")

  attr(:icon, :string, required: true)
  attr(:title, :string, required: true)

  defp drawer_header(assigns) do
    ~H"""
    <div class="flex h-12 shrink-0 items-center justify-between border-b border-neutral-200 px-4">
      <div class="flex min-w-0 items-center gap-2">
        <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-brand-50 text-brand-600">
          <.icon name={@icon} class="h-4 w-4" />
        </span>
        <span class="truncate text-sm font-semibold">{@title}</span>
      </div>
      <button
        phx-click={cancel_drawer()}
        class="grid h-7 w-7 place-items-center rounded-md text-neutral-400 transition-colors duration-100 hover:bg-neutral-100 hover:text-neutral-700"
        aria-label={gettext("Close")}
      >
        <.icon name="x-mark" class="h-4 w-4" />
      </button>
    </div>
    """
  end

  attr(:task, :map, required: true)
  attr(:thread_state, :any, required: true)
  attr(:messages, :list, required: true)
  attr(:conversation, :any, default: nil)
  attr(:participants, :list, default: [])
  attr(:chat_activity, :any, default: nil)
  attr(:composer_state, :any, required: true)
  attr(:chat_agent, :any, default: nil)
  attr(:chat_text, :string, default: "")
  attr(:current_org, :any, default: nil)
  attr(:mention_skills, :list, default: [])
  attr(:uploads, :any, default: nil)
  attr(:with_uploads, :boolean, default: false)
  attr(:task_groups, :list, default: [])

  # The task's chat as a floating window: the task's own conversation (or the
  # assistant thread its hand-off lives in) plus a follow-up composer. Closing
  # it returns to the assistant rail.
  defp drawer_task_chat(assigns) do
    ~H"""
    <.drawer_header icon="chat-bubble" title={@task.title} />


    <div class="flex min-h-0 flex-1 flex-col">
      <.chat_thread
        chat_state={@thread_state}
        chat_messages={@messages}
        chat_agent={@chat_agent}
        chat_activity={@chat_activity}
        current_org={@current_org}
        task_groups={@task_groups}
      />
      <.chat_composer
        id="chat-form-panel"
        chat_state={@composer_state}
        chat_text={@chat_text}
        mention_skills={@mention_skills}
        uploads={@uploads}
        with_uploads={@with_uploads}
        autofocus={true}
      />
    </div>
    """
  end

  attr(:task, :map, required: true)
  attr(:log, :list, default: [])

  defp drawer_email_preview(assigns) do
    ~H"""
    <.drawer_header icon="envelope" title={gettext("Draft preview")} />

    <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
      <dl class="space-y-2 border-b border-neutral-100 pb-3 text-sm">
        <div class="flex gap-2">
          <dt class="w-14 shrink-0 text-neutral-400">{gettext("To")}</dt>
          <dd class="min-w-0 truncate text-neutral-800">{@task.payload["to"] || "—"}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-14 shrink-0 text-neutral-400">{gettext("Subject")}</dt>
          <dd class="min-w-0 font-medium text-neutral-900">{@task.payload["subject"] || "—"}</dd>
        </div>
      </dl>
      <pre class="mt-3 whitespace-pre-wrap font-sans text-sm leading-relaxed text-neutral-700">{draft_body(@task.payload)}</pre>
      <.session_log_section log={@log} />
    </div>

    <.drawer_review_footer task={@task}>
      <.button variant="secondary" size="sm" phx-click="drawer_edit_draft">
        {gettext("Edit")}
      </.button>
      <.button
        variant="primary"
        size="sm"
        href={
          gmail_compose_url(
            @task.payload["to"],
            @task.payload["subject"],
            draft_body(@task.payload)
          )
        }
        target="_blank"
        rel="noreferrer"
      >
        {gettext("Open in Gmail")}
      </.button>
    </.drawer_review_footer>
    """
  end

  attr(:task, :map, required: true)

  defp drawer_email_edit(assigns) do
    ~H"""
    <.drawer_header icon="envelope" title={gettext("Edit draft")} />

    <form
      id="drawer-draft-form"
      phx-submit="save_draft"
      phx-hook="GmailHandoff"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="min-h-0 flex-1 space-y-3 overflow-y-auto px-4 py-4">
        <div>
          <label class="mb-1 block text-xs font-medium text-neutral-500">{gettext("To")}</label>
          <input
            type="text"
            name="draft[to]"
            value={@task.payload["to"]}
            class="block h-8 w-full rounded-md border border-neutral-300 px-2.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>
        <div>
          <label class="mb-1 block text-xs font-medium text-neutral-500">
            {gettext("Subject")}
          </label>
          <input
            type="text"
            name="draft[subject]"
            value={@task.payload["subject"]}
            class="block h-8 w-full rounded-md border border-neutral-300 px-2.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>
        <div class="flex min-h-[16rem] flex-col">
          <label class="mb-1 block text-xs font-medium text-neutral-500">{gettext("Body")}</label>
          <textarea
            name="draft[body]"
            rows="14"
            class="block w-full flex-1 resize-y rounded-md border border-neutral-300 px-2.5 py-2 text-sm leading-relaxed focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          >{draft_body(@task.payload)}</textarea>
        </div>
      </div>

      <div class="flex shrink-0 items-center justify-between gap-2 border-t border-neutral-200 p-3">
        <span class="text-xs text-neutral-400">
          {gettext("Send opens Gmail with this draft prefilled.")}
        </span>
        <div class="flex items-center gap-2">
          <.button variant="secondary" size="sm" type="submit" name="draft[action]" value="save">
            {gettext("Save draft")}
          </.button>
          <.button variant="primary" size="sm" type="submit" name="draft[action]" value="send">
            <.icon name="envelope" class="h-3.5 w-3.5" />
            {gettext("Send")}
          </.button>
        </div>
      </div>
    </form>
    """
  end

  attr(:task, :map, required: true)
  attr(:view, :string, default: "preview")
  attr(:log, :list, default: [])

  defp drawer_recap(assigns) do
    assigns = assign(assigns, :markdown, recap_markdown(assigns.task))

    ~H"""
    <.drawer_header icon="calendar" title={@task.title} />

    <div class="flex shrink-0 items-center justify-between gap-2 border-b border-neutral-100 px-4 py-2">
      <div class="t-seg grid grid-cols-2 rounded-md bg-neutral-100 p-0.5" data-view={@view}>
        <button
          phx-click="drawer_recap_view"
          phx-value-view="preview"
          class={[
            "relative z-10 rounded px-2 py-1 text-xs font-medium transition-colors duration-100",
            (@view == "preview" && "text-neutral-900") || "text-neutral-500 hover:text-neutral-800"
          ]}
        >
          {gettext("Preview")}
        </button>
        <button
          phx-click="drawer_recap_view"
          phx-value-view="markdown"
          class={[
            "relative z-10 rounded px-2 py-1 text-xs font-medium transition-colors duration-100",
            (@view == "markdown" && "text-neutral-900") || "text-neutral-500 hover:text-neutral-800"
          ]}
        >
          {gettext("Markdown")}
        </button>
      </div>
      <div class="flex items-center gap-1">
        <a
          href={"data:text/markdown;charset=utf-8," <> URI.encode(@markdown)}
          download={recap_filename(@task)}
          class="rounded-md px-2 py-1 text-xs font-medium text-neutral-500 hover:bg-neutral-100 hover:text-neutral-800"
        >
          {gettext("Download .md")}
        </a>
        <button
          phx-click={JS.dispatch("bft:print-drawer", to: "#drawer-print-content")}
          class="rounded-md px-2 py-1 text-xs font-medium text-neutral-500 hover:bg-neutral-100 hover:text-neutral-800"
        >
          {gettext("PDF")}
        </button>
      </div>
    </div>

    <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
      <div id="drawer-print-content" data-print-title={@task.title}>
        <.markdown :if={@view == "preview"} text={@markdown} />
        <pre
          :if={@view == "markdown"}
          class="whitespace-pre-wrap rounded-md bg-neutral-50 p-3 font-mono text-xs leading-relaxed text-neutral-700"
        >{@markdown}</pre>
      </div>
      <.session_log_section log={@log} />
    </div>

    <.drawer_review_footer task={@task}>
      <span class="text-xs text-neutral-400">{recap_meta(@task.payload)}</span>
    </.drawer_review_footer>
    """
  end

  # ---- meeting drawer: the bot-attended call's record -------------------------

  attr(:task, :map, required: true)
  attr(:log, :list, default: [])

  defp drawer_meeting(assigns) do
    payload = assigns.task.payload

    summary = meeting_summary_map(payload)

    assigns =
      assigns
      |> assign(:status_line, meeting_status_line(payload))
      |> assign(:summary_text, meeting_summary_text(payload))
      |> assign(:key_points, summary |> Map.get("key_points") |> List.wrap())
      |> assign(:action_items, summary |> Map.get("action_items") |> List.wrap())
      |> assign(:artifact_labels, meeting_artifact_labels(payload))

    ~H"""
    <.drawer_header icon="users" title={@task.title} />

    <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
      <div class="mb-3 flex items-center gap-2">
        <.task_pill task={@task} />
        <span class="text-xs text-neutral-400">{meeting_meta(@task.payload)}</span>
      </div>

      <p :if={@status_line} class="mb-3 text-sm text-neutral-600">{@status_line}</p>

      <p :if={@summary_text} class="mb-3 text-sm leading-relaxed text-neutral-700">
        {@summary_text}
      </p>

      <div :if={@key_points != []}>
        <h3 class="text-xs font-semibold text-neutral-500">{gettext("Key points")}</h3>
        <ul class="mt-2 space-y-1.5">
          <li :for={point <- @key_points} class="flex items-start gap-1.5 text-sm text-neutral-700">
            <.icon name="check" class="mt-1 h-3 w-3 shrink-0 text-neutral-400" />
            <span>{point}</span>
          </li>
        </ul>
      </div>

      <div :if={@action_items != []} class="mt-5">
        <h3 class="text-xs font-semibold text-neutral-500">{gettext("Action items")}</h3>
        <ul class="mt-2 space-y-1.5">
          <li :for={item <- @action_items} class="text-sm text-neutral-700">
            {action_item_line(item)}
          </li>
        </ul>
        <p class="mt-2 text-xs text-neutral-400">
          {gettext("These are on your General tasks list — check them off there.")}
        </p>
      </div>

      <div :if={@artifact_labels != []} class="mt-5">
        <h3 class="text-xs font-semibold text-neutral-500">{gettext("Artifacts")}</h3>
        <div class="mt-2 flex items-center gap-2">
          <span
            :for={label <- @artifact_labels}
            class="inline-flex items-center gap-1.5 rounded-md bg-neutral-100 px-2 py-1 text-xs font-medium text-neutral-600"
          >
            <.icon name="document-text" class="h-3.5 w-3.5" />
            {label}
          </span>
        </div>
        <p class="mt-2 text-xs text-neutral-400">
          {gettext("Shared back to the Slack thread that started the meeting.")}
        </p>
      </div>

      <.session_log_section log={@log} />
    </div>

    <.drawer_review_footer task={@task} />
    """
  end

  # ---- result drawer: the finished artifact + how the agent did it ----

  attr(:task, :map, required: true)
  attr(:log, :list, default: [])
  # The drawer's async VFS read (`handle_async(:drawer_artifact, ...)`):
  # `:loading` while the artifact body is in flight, `:error` when the read
  # failed, `:ok` once the payload carries the live copy, `:none` when there is
  # nothing to hydrate.
  attr(:artifact, :atom, default: :none)
  # The parsed artifact document (`BridgeForTeams.Artifacts.Document`) once the
  # async VFS read landed — `nil` before that (and for payload-only rows).
  attr(:document, :any, default: nil)
  # The other runs of the same report series (index rows, newest first) — each
  # swaps the drawer to that run via the ordinary `open_drawer` path.
  attr(:series_runs, :list, default: [])

  # The finished artifact, rendered as its document: sanitized-MDEx markdown
  # segments interleaved with native `ArtifactBlocks` (full variant). Until
  # the file lands — or when the row has no `vfs_path` / the read failed — the
  # index summary is the honest quiet state. Reports additionally keep their
  # period pill, series run history, and the published-site link.
  defp drawer_result(assigns) do
    assigns = assign(assigns, :url, display_site_url(assigns.task.payload["url"]))

    ~H"""
    <.drawer_header
      icon={Catalog.category_meta(@task.category).icon}
      title={@task.title}
    />

    <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
      <div class="mb-3 flex items-center gap-2">
        <.task_pill task={@task} />
        <span :if={@task.payload["period"]} class="text-xs text-neutral-400">
          {@task.payload["period"]}
        </span>
      </div>

      <p :if={@task.description} class="mb-3 text-sm text-neutral-600">{@task.description}</p>

      <p :if={@artifact == :loading} class="mb-3 text-xs text-neutral-400">
        {gettext("Loading the full content…")}
      </p>
      <p :if={@artifact == :error} class="mb-3 text-xs text-neutral-400">
        {gettext("Content unavailable right now.")}
      </p>

      <%= if @document do %>
        <div class="space-y-3">
          <%= for segment <- @document.segments do %>
            <%= case segment do %>
              <% {:markdown, text} -> %>
                <.markdown text={text} />
              <% block_segment -> %>
                <ArtifactBlocks.block block={block_segment} variant={:full} />
            <% end %>
          <% end %>
        </div>
      <% else %>
        <p class="text-sm text-neutral-500">
          {@task.payload["summary"] || gettext("The result is on your board.")}
        </p>
      <% end %>

      <div class="mt-3 flex items-center gap-4">
        <.link
          navigate={~p"/new-home/artifacts/#{@task.id}"}
          class="inline-flex items-center gap-1 text-xs font-medium text-brand-600 hover:underline"
        >
          {gettext("Open full view")}
          <.icon name="arrow-up-right" class="h-3 w-3" />
        </.link>
        <a
          :if={@url}
          href={@url}
          target="_blank"
          rel="noreferrer"
          class="text-xs font-medium text-brand-600 hover:underline"
        >
          {gettext("Open site")}
        </a>
      </div>

      <div :if={@series_runs != []} class="mt-5 border-t border-neutral-100 pt-3">
        <h3 class="text-xs font-semibold text-neutral-500">{gettext("Earlier runs")}</h3>
        <div class="-mx-2 mt-1">
          <button
            :for={run <- @series_runs}
            type="button"
            phx-click="open_drawer"
            phx-value-kind="result"
            phx-value-id={run.id}
            class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left hover:bg-neutral-100"
          >
            <span class="min-w-0 flex-1 truncate text-sm text-neutral-800">
              {report_run_label(run)}
            </span>
            <span
              :if={run.status == "ready_for_review"}
              class="h-1.5 w-1.5 shrink-0 rounded-full bg-brand-500"
              title={gettext("New")}
            >
            </span>
          </button>
        </div>
      </div>

      <.session_log_section log={@log} />
    </div>

    <.drawer_review_footer task={@task} />
    """
  end

  # A run's line in the series history: the agent's stated period when set,
  # else the run date — parsed from the run file's path when it follows the
  # reports convention, falling back to the row's creation time.
  defp report_run_label(task) do
    period = task.payload["period"]

    if is_binary(period) and period != "" do
      period
    else
      Calendar.strftime(report_run_date(task), "%b %d, %Y")
    end
  end

  defp report_run_date(task) do
    case Reports.parse_run_path(task.payload["vfs_path"] || task.vfs_path) do
      {:ok, %{date: date}} -> date
      :error -> task.created_at
    end
  end

  # ---- suggestion drawer: what the agent would do + Add task / Remove ----

  attr(:suggestion, :map, required: true)

  defp drawer_suggestion(assigns) do
    ~H"""
    <.drawer_header
      icon={Catalog.category_meta(@suggestion.category).icon}
      title={gettext("Details")}
    />

    <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
      <div class="flex items-center gap-3">
        <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-neutral-100 text-neutral-500">
          <.icon name={Catalog.category_meta(@suggestion.category).icon} class="h-4 w-4" />
        </span>
        <h2 class="min-w-0 text-base font-semibold text-neutral-900">{@suggestion.title}</h2>
      </div>

      <h3 class="mt-5 text-xs font-semibold text-neutral-500">{gettext("Instructions")}</h3>
      <p class="mt-2 rounded-lg bg-neutral-50 px-3 py-2.5 text-sm leading-relaxed text-neutral-700">
        {@suggestion.description}
      </p>

      <dl class="mt-5 space-y-2 text-sm">
        <div class="flex gap-2">
          <dt class="w-20 shrink-0 text-neutral-400">{gettext("Source")}</dt>
          <dd class="text-neutral-800">{Catalog.platform_label(@suggestion.platform)}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="w-20 shrink-0 text-neutral-400">{gettext("Category")}</dt>
          <dd class="text-neutral-800">{Catalog.category_meta(@suggestion.category).label}</dd>
        </div>
      </dl>
    </div>

    <div class="shrink-0 space-y-2 border-t border-neutral-200 p-3">
      <.button
        variant="primary"
        phx-click="accept_suggestion"
        phx-value-id={@suggestion.id}
        class="w-full justify-center"
      >
        {gettext("Add task")}
      </.button>
      <.button
        variant="secondary"
        phx-click="dismiss_suggestion"
        phx-value-id={@suggestion.id}
        class="w-full justify-center"
      >
        {gettext("Remove")}
      </.button>
    </div>
    """
  end

  # "How your agent did it" — the real messages from the task's agent session.
  attr(:log, :list, default: [])

  defp session_log_section(assigns) do
    ~H"""
    <div :if={@log != []} class="mt-5 border-t border-neutral-100 pt-3">
      <h3 class="text-xs font-semibold text-neutral-500">{gettext("How your agent did it")}</h3>
      <ol class="mt-2 space-y-2.5 border-l border-neutral-200 pl-3">
        <li :for={message <- @log} class="text-xs leading-relaxed text-neutral-600">
          {message_text(message)}
        </li>
      </ol>
    </div>
    """
  end

  # Review is the primary act: confirm the finished result (or follow up).
  attr(:task, :map, required: true)
  slot(:inner_block)

  defp drawer_review_footer(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center justify-between gap-2 border-t border-neutral-200 p-3">
      <button
        phx-click="run_task"
        phx-value-id={@task.id}
        class="text-xs font-medium text-neutral-500 transition-colors duration-100 hover:text-neutral-800"
      >
        {gettext("Follow up in chat")}
      </button>
      <div class="flex items-center gap-2">
        {render_slot(@inner_block)}
        <.button
          :if={@task.category == "general"}
          variant="secondary"
          size="sm"
          phx-click="archive_task"
          phx-value-id={@task.id}
        >
          {gettext("Archive")}
        </.button>
        <.button
          :if={@task.status != "done"}
          variant="secondary"
          size="sm"
          phx-click="review_done"
          phx-value-id={@task.id}
        >
          <.icon name="check" class="h-3.5 w-3.5" />
          {gettext("Mark reviewed")}
        </.button>
        <span
          :if={@task.status == "done"}
          class="inline-flex items-center gap-1.5 text-xs font-medium text-neutral-500"
        >
          <.icon name="check" class="t-check-draw h-3.5 w-3.5" />
          {gettext("Reviewed")}
        </span>
      </div>
    </div>
    """
  end

  defp recap_filename(task) do
    task.title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\p{Han}]+/u, "-")
    |> String.trim("-")
    |> Kernel.<>(".md")
  end

  # ---- email recipient avatars ----

  attr(:payload, :map, required: true)
  attr(:class, :string, default: "h-7 w-7")

  # Message identity: the recipient's contact photo when the payload carries
  # one (Gmail contacts do), otherwise their initial. The photo gets the
  # subtle outline every raster asset wears so it holds up on any background.
  defp recipient_avatar(%{payload: %{"avatar" => avatar}} = assigns)
       when is_binary(avatar) and avatar != "" do
    ~H"""
    <img
      src={@payload["avatar"]}
      alt=""
      loading="lazy"
      class={[
        "shrink-0 rounded-full object-cover outline outline-1 -outline-offset-1 outline-neutral-900/10",
        @class
      ]}
    />
    """
  end

  defp recipient_avatar(assigns) do
    ~H"""
    <span class={[
      "grid shrink-0 place-items-center rounded-full bg-brand-100 text-[10px] font-semibold text-brand-700",
      @class
    ]}>
      {recipient_initial(@payload["to"])}
    </span>
    """
  end

  # ---- portfolio company logomarks ----

  attr(:company, :map, required: true)
  attr(:class, :string, default: "h-9 w-9 rounded-lg")
  attr(:ctx, :string, default: nil)

  defp company_logo(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center justify-center overflow-hidden shadow-subtle",
      @class
    ]}>
      {Phoenix.HTML.raw(company_logo_svg(@company["name"], @ctx))}
    </span>
    """
  end

  # Real portfolio companies carry no logo asset pipeline yet — every company
  # renders the same honest initial-based logomark. The gradient id carries
  # the company name (and the rendering surface: rail vs dashboard vs glance)
  # so two logomarks in one document never collide.
  defp company_logo_svg(name, ctx) do
    slug = name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
    gid = gradient_id("lg-#{slug}", ctx)

    initial =
      name |> to_string() |> String.first() |> Kernel.||("?") |> String.upcase()

    ~s"""
    <svg width="100%" height="100%" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="#{gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#64748b"/><stop offset="1" stop-color="#334155"/></linearGradient></defs><rect width="36" height="36" fill="url(##{gid})"/><text x="18" y="24" text-anchor="middle" font-family="Inter, system-ui, sans-serif" font-size="16" font-weight="600" fill="#fff">#{Plug.HTML.html_escape(initial)}</text></svg>
    """
  end

  # The rail and the widget dashboard can show the same logomark at once —
  # the surface suffix keeps SVG gradient ids unique in the DOM.
  defp gradient_id(base, nil), do: base
  defp gradient_id(base, ctx), do: "#{base}-#{ctx}"

  attr(:payload, :map, required: true)

  # "Jul 1 · [Slack][Google] · 214 captions" — the platforms the meeting
  # actually flows through (Slack thread → Google Meet call) as real marks,
  # with the caption count as a quiet chip.
  defp meeting_meta_line(assigns) do
    assigns =
      assigns
      |> assign(:date, meeting_date(assigns.payload))
      |> assign(:captions, assigns.payload["captions_count"])

    ~H"""
    <span class="mt-0.5 flex items-center gap-1.5 text-xs text-neutral-400">
      <span :if={@date} class="shrink-0">{@date}</span>
      <span :if={@date} aria-hidden="true">·</span>
      <span class="flex shrink-0 items-center gap-1" title={gettext("Slack · Google Meet")}>
        <span class="grid h-4 w-4 place-items-center rounded border border-neutral-200 bg-white">
          <.brand_logo name="slack" class="h-2.5 w-2.5" />
        </span>
        <span class="grid h-4 w-4 place-items-center rounded border border-neutral-200 bg-white">
          <.brand_logo name="google" class="h-2.5 w-2.5" />
        </span>
      </span>
      <span
        :if={is_integer(@captions) and @captions > 0}
        class="truncate rounded bg-neutral-100 px-1.5 py-0.5 text-neutral-500"
      >
        {gettext("%{count} captions", count: @captions)}
      </span>
    </span>
    """
  end

  # Clicking a task opens its finished result for review — the agent already
  # ran it; the user confirms the outcome.
  attr(:task, :map, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp task_run(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_drawer"
      phx-value-kind={drawer_kind(@task.category)}
      phx-value-id={@task.id}
      title={gettext("Review result")}
      class={["min-w-0 text-left", @class]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:task, :map, required: true)

  defp task_pill(assigns) do
    {status, label} = task_status_pill(assigns.task.status)
    assigns = assign(assigns, status: status, label: label)

    ~H"""
    <.status_pill status={@status} label={@label} />
    """
  end

  defp recap_meta(payload) do
    date = payload["date"] || ""
    attendees = payload["attendees"]

    if attendees do
      gettext("%{date} · %{count} attendees", date: date, count: attendees)
    else
      date
    end
  end

  defp portfolio_health_status("ok"), do: "ok"
  defp portfolio_health_status("attention"), do: "pending"
  defp portfolio_health_status(_health), do: "idle"

  attr(:health, :string, default: nil)

  # Board dots carry exactly two meanings: amber = needs you (提醒), green =
  # done (完成). Portfolio health therefore only dots "needs attention" —
  # on-track/unknown stay quiet text.
  defp health_mark(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium text-neutral-500">
      <span
        :if={@health == "attention"}
        class="h-1.5 w-1.5 rounded-full bg-amber-400"
        aria-hidden="true"
      >
      </span>
      {portfolio_health_label(@health)}
    </span>
    """
  end

  defp portfolio_health_label("ok"), do: gettext("On track")
  defp portfolio_health_label("attention"), do: gettext("Needs attention")
  defp portfolio_health_label(_health), do: gettext("Unknown")

  # ---- chat rail ----

  attr(:chat_state, :any, required: true)
  attr(:chat_messages, :list, default: [])
  attr(:chat_agent, :any, default: nil)
  attr(:chat_activity, :any, default: nil)
  attr(:current_org, :any, default: nil)
  attr(:task_groups, :list, default: [])

  # What the rail and expanded sheet show: always the assistant conversation.
  defp rail_thread_messages(assigns), do: assigns.chat_messages

  defp rail_thread_state(assigns), do: assigns.chat_state

  defp rail_title(assigns), do: assigns.chat_title || gettext("New chat")

  defp rail_composer_state(assigns), do: assigns.chat_state

  # The task-chat drawer borrows the chat-state vocabulary so the shared thread
  # and composer components can render a focused task conversation without
  # replacing the assistant rail.
  defp drawer_thread_messages(%{chat_focus: %{}} = assigns), do: assigns.focus_messages
  defp drawer_thread_messages(assigns), do: assigns.chat_messages

  defp drawer_thread_state(%{chat_focus: %{}} = assigns) do
    case assigns.focus_state do
      :loading -> :loading
      _ok_or_error -> :ready
    end
  end

  defp drawer_thread_state(assigns), do: assigns.chat_state

  defp drawer_composer_state(%{chat_focus: %{}} = assigns) do
    case {assigns.chat_state, assigns.focus_state} do
      {:ready, state} when state in [:ok, :error] -> :ready
      {:ready, :loading} -> :loading
      {chat_state, _} -> chat_state
    end
  end

  defp drawer_composer_state(assigns), do: assigns.chat_state

  attr(:chat_focus, :any, default: nil)
  attr(:title, :string, required: true)
  attr(:thread_state, :any, required: true)
  attr(:composer_state, :any, required: true)
  attr(:messages, :list, required: true)
  attr(:chat_activity, :any, default: nil)
  attr(:chat_agent, :any, default: nil)
  attr(:chat_text, :string, default: "")
  attr(:current_org, :any, default: nil)
  attr(:mention_skills, :list, default: [])
  attr(:uploads, :any, default: nil)
  attr(:with_uploads, :boolean, default: false)
  attr(:task_groups, :list, default: [])

  # The persistent chat rail: chrome-level like the app sidebar (gray layer,
  # borderless), beside the raised board panel. It always shows the assistant
  # conversation; task conversations render in a floating drawer panel. Hidden
  # below `lg` — the floating chat button and the sheet are the narrow-viewport
  # assistant chat surface. RailResize owns the left-gutter grip: drag between
  # 280 and 450px, stored client-side and re-applied in updated() (patches strip
  # JS-set styles).
  defp chat_rail(assigns) do
    ~H"""
    <aside
      id="chat-rail"
      phx-hook="RailResize"
      class="relative hidden w-[var(--bft-rail-w,340px)] min-w-[280px] max-w-[450px] shrink-0 flex-col lg:flex"
      aria-label={gettext("Chat")}
    >
      <div
        data-rail-resize
        title={gettext("Drag to resize")}
        class="group/resize absolute -left-2 bottom-2 top-2 z-10 hidden w-3 cursor-col-resize touch-none lg:block"
        aria-hidden="true"
      >
        <div class="mx-auto h-full w-px bg-transparent transition-colors duration-100 group-hover/resize:bg-neutral-300 group-active/resize:bg-neutral-400">
        </div>
      </div>
      <div class="flex h-10 shrink-0 items-center justify-between pl-1 pr-0.5">
        <div class="flex min-w-0 items-center gap-1">
          <button
            :if={@chat_focus}
            phx-click="unfocus_chat"
            class="grid h-7 w-7 shrink-0 place-items-center rounded-md text-neutral-400 transition-colors duration-100 hover:bg-neutral-200/60 hover:text-neutral-700"
            aria-label={gettext("Back to assistant")}
            title={gettext("Back to assistant")}
          >
            <.icon name="arrow-left" class="h-4 w-4" />
          </button>
          <span class="truncate text-[13px] font-semibold text-neutral-800">{@title}</span>
        </div>
        <.link
          patch={~p"/new-home/chat"}
          class="grid h-7 w-7 shrink-0 place-items-center rounded-md text-neutral-400 transition-colors duration-100 hover:bg-neutral-200/60 hover:text-neutral-700"
          aria-label={gettext("Expand chat")}
          title={gettext("Expand chat")}
        >
          <.icon name="arrows-expand" class="h-4 w-4" />
        </.link>
      </div>
      <.chat_thread
        chat_state={@thread_state}
        chat_messages={@messages}
        chat_agent={@chat_agent}
        chat_activity={@chat_activity}
        current_org={@current_org}
        task_groups={@task_groups}
      />
      <.chat_composer
        id="chat-form-rail"
        chat_state={@composer_state}
        chat_text={@chat_text}
        mention_skills={@mention_skills}
        uploads={@uploads}
        with_uploads={@with_uploads}
        create_task={true}
      />
    </aside>
    """
  end

  attr(:chat_state, :any, required: true)
  attr(:chat_messages, :list, default: [])
  attr(:chat_agent, :any, default: nil)
  attr(:chat_activity, :any, default: nil)
  attr(:current_org, :any, default: nil)
  attr(:task_groups, :list, default: [])

  defp chat_thread(assigns) do
    ~H"""
    <div
      data-chat-thread
      class="flex min-h-0 flex-1 flex-col-reverse overflow-y-auto overscroll-contain px-3 py-3"
    >
      <div class="space-y-3">
        <div :if={@chat_state == :loading} class="space-y-2 py-2">
          <div class="t-skeleton h-3 w-2/3 rounded bg-neutral-200/80"></div>
          <div class="t-skeleton h-3 w-1/2 rounded bg-neutral-200/80"></div>
          <p class="pt-1 text-xs text-neutral-400">{gettext("Connecting to your agent…")}</p>
        </div>

        <div :if={@chat_state in [:no_project, :no_agent]} class="py-4 text-center">
          <.icon name="chat-bubble" class="mx-auto h-5 w-5 text-neutral-300" />
          <p class="mt-2 text-sm font-medium text-neutral-700">
            {gettext("No agent to chat with yet")}
          </p>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("Create an Agent Swarm with an agent, then come back.")}
          </p>
          <.button
            :if={@current_org}
            variant="secondary"
            size="sm"
            navigate={~p"/orgs/#{@current_org.slug}/projects"}
            class="mt-3"
          >
            {gettext("Open Agent Swarms")}
          </.button>
        </div>

        <div :if={@chat_state == :unavailable} class="py-4 text-center">
          <p class="text-sm font-medium text-neutral-700">{gettext("Assistant unavailable")}</p>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("The runtime is unreachable right now.")}
          </p>
          <.button variant="secondary" size="sm" phx-click="retry_chat" class="mt-3">
            {gettext("Retry")}
          </.button>
        </div>

        <div :if={@chat_state == :ready and @chat_messages == []} class="py-4 text-center">
          <.icon name="sparkles" class="mx-auto h-5 w-5 text-neutral-300" />
          <p class="mt-2 text-sm font-medium text-neutral-700">
            {gettext("Ask your agent anything")}
          </p>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("It sees your dashboard and can create tasks, draft mail, and dig through your tools.")}
          </p>
        </div>

        <div
          :for={message <- @chat_messages}
          class={["flex", (user_message?(message) && "justify-end") || "justify-start"]}
        >
          <.user_bubble :if={user_message?(message)} message={message} />
          <%!-- Agent replies read as the document, not a bubble: full width,
          no background, no author label (Claude-style thread). --%>
          <div :if={!user_message?(message)} class="w-full min-w-0">
            <.agent_message message={message} task_groups={@task_groups} />
          </div>
        </div>

        <div :if={@chat_activity} class="flex justify-start">
          <div class="flex max-w-[85%] items-center gap-2 rounded-lg rounded-bl-sm border border-neutral-100 bg-neutral-50 px-3 py-2">
            <span class="t-skeleton h-1.5 w-1.5 shrink-0 rounded-full bg-neutral-400" aria-hidden="true">
            </span>
            <span class="text-xs font-book text-neutral-500">
              {chat_activity_label(@chat_activity)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The runtime's activity text is English; the fixed phases translate here,
  # while an execution summary — which may be the model-authored exec label
  # ("Checking logs") — passes through as-is. A thinking activity may
  # carry the model's latest reasoning line as its summary; show it after the
  # translated prefix.
  defp chat_activity_label(activity) do
    cond do
      activity["phase"] == "thinking" ->
        case activity["summary"] do
          summary when is_binary(summary) and summary not in ["", "Thinking"] ->
            gettext("Thinking") <> " · " <> summary

          _bare ->
            gettext("Thinking")
        end

      activity["phase"] == "messaging" ->
        gettext("Typing")

      activity["status"] == "failed" ->
        gettext("Hit a wall")

      is_binary(activity["summary"]) and activity["summary"] != "" ->
        activity["summary"]

      true ->
        gettext("Working")
    end
  end

  attr(:message, :map, required: true)
  attr(:task_groups, :list, default: [])

  defp agent_message(assigns) do
    assigns =
      assigns
      |> assign(:text, agent_display_text(assigns.message))
      |> assign(:refs, conversation_ref_views(assigns.message, assigns.task_groups))

    ~H"""
    <div class="space-y-2">
      <.markdown :if={@text != ""} text={@text} />
      <.conversation_ref_card :for={ref <- @refs} ref={ref} />
    </div>
    """
  end

  attr(:ref, :map, required: true)

  defp conversation_ref_card(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_conversation_ref"
      phx-value-id={@ref.id}
      class="group/conversation-ref flex w-full items-start gap-2.5 rounded-lg border border-neutral-200 bg-white px-3 py-2 text-left shadow-subtle transition-colors duration-100 hover:border-neutral-300 hover:bg-neutral-50"
    >
      <span class="mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-md bg-neutral-100 text-neutral-500 transition-colors duration-100 group-hover/conversation-ref:bg-neutral-200/70">
        <.icon name={@ref.icon} class="h-4 w-4" />
      </span>
      <span class="min-w-0 flex-1">
        <span :if={@ref.label} class="block text-[11px] font-book text-neutral-400">
          {@ref.label}
        </span>
        <span class="block truncate text-[13px] font-medium text-neutral-800">{@ref.title}</span>
        <span :if={@ref.subtitle} class="block truncate text-xs text-neutral-400">
          {@ref.subtitle}
        </span>
      </span>
      <.icon
        name="chevron-right"
        class="mt-2 h-3.5 w-3.5 shrink-0 text-neutral-300 transition-colors duration-100 group-hover/conversation-ref:text-neutral-500"
      />
    </button>
    """
  end

  attr(:message, :map, required: true)

  # A user message: protocol text never reaches the UI. Task hand-offs render
  # as a compact task card; composer messages show only the user's own words.
  defp user_bubble(assigns) do
    assigns = assign(assigns, :view, user_message_view(assigns.message))

    ~H"""
    <div
      :if={elem(@view, 0) == :task_run}
      data-user-message
      class="flex max-w-[85%] items-center gap-2.5 rounded-lg rounded-br-sm border border-neutral-200 bg-neutral-50 px-3 py-2"
    >
      <.icon name="document-text" class="h-4 w-4 shrink-0 text-neutral-400" />
      <div class="min-w-0">
        <div class="text-[11px] font-book text-neutral-400">
          {gettext("Task handed to your agent")}
        </div>
        <div class="truncate text-[13px] font-medium text-neutral-800">{elem(@view, 1)}</div>
      </div>
    </div>
    <%!-- The interpolation stays flush with the tags: whitespace-pre-wrap
    would render the template's own newline + indentation as a blank first
    line inside the bubble. --%>
    <div
      :if={elem(@view, 0) == :text}
      data-user-message
      class="max-w-[85%] whitespace-pre-wrap rounded-xl rounded-br-md bg-neutral-350 px-3 py-2 text-sm text-neutral-900"
    >{elem(@view, 1)}</div>
    """
  end

  # Agent replies can carry bft:* protocol fences (board updates, session
  # titles) — they act on the dashboard and stay out of the visible reply.
  defp agent_display_text(message) do
    message
    |> message_text()
    |> String.replace(~r/```bft:[a-z_]+\s*\n.*?```/s, "")
    |> String.trim()
  end

  defp conversation_ref_views(message, task_groups) do
    message
    |> message_conversation_refs()
    |> Enum.map(&conversation_ref_view(&1, task_groups))
    |> Enum.reject(&is_nil/1)
  end

  defp message_conversation_refs(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &content_conversation_refs/1)
  end

  defp message_conversation_refs(%{"content" => %{} = content}),
    do: content_conversation_refs(content)

  defp message_conversation_refs(_message), do: []

  defp content_conversation_refs(%{"type" => type} = content)
       when type in ["conversation_ref", "conversation"],
       do: [content]

  defp content_conversation_refs(%{"conversation_ref" => %{} = ref}), do: [ref]
  defp content_conversation_refs(_content), do: []

  defp conversation_ref_view(ref, task_groups) do
    with id when is_binary(id) and id != "" <- conversation_ref_id(ref) do
      task = find_task_in_groups(task_groups, id)
      kind = conversation_ref_kind(ref)

      # A ref without any resolvable name renders a single honest line
      # ("Task conversation") instead of the redundant "Task / Task" pair a
      # generic label + generic title fallback would produce.
      title = conversation_ref_title(ref) || (task && task.title)

      %{
        id: id,
        icon: (task && Catalog.category_meta(task.category).icon) || "document-text",
        label: title && conversation_ref_label(kind, task),
        title: title || gettext("Task conversation"),
        subtitle: conversation_ref_subtitle(ref, task)
      }
    else
      _missing_id -> nil
    end
  end

  defp conversation_ref_id(ref) do
    [
      ref["conversation_id"],
      ref["target_conversation_id"],
      ref["id"],
      get_in(ref, ["conversation", "conversation_id"]),
      get_in(ref, ["conversation", "id"])
    ]
    |> Enum.find_value(&present_string/1)
  end

  defp conversation_ref_kind(ref) do
    [
      ref["kind"],
      ref["conversation_kind"],
      get_in(ref, ["conversation", "kind"])
    ]
    |> Enum.find_value(&present_string/1)
  end

  defp conversation_ref_title(ref) do
    [
      ref["title"],
      ref["conversation_title"],
      ref["name"],
      get_in(ref, ["conversation", "title"])
    ]
    |> Enum.find_value(&present_string/1)
  end

  defp conversation_ref_subtitle(ref, task) do
    [
      ref["subtitle"],
      ref["description"],
      get_in(ref, ["conversation", "description"]),
      task && task_ref_subtitle(task)
    ]
    |> Enum.find_value(&present_string/1)
  end

  defp conversation_ref_label(_kind, _task), do: gettext("Task")

  defp task_ref_subtitle(task) do
    {_state, status} = task_status_pill(task.status)

    [status, Catalog.platform_label(task.platform)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp find_task_in_groups(task_groups, conversation_id) do
    task_groups
    |> Enum.flat_map(fn {_category, tasks} -> tasks end)
    |> Enum.find(&(&1.salix_conversation_id == conversation_id))
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  # {:task_run, title} for task hand-offs; {:text, words} with any trailing
  # protocol block stripped otherwise. The unmarked clauses cover messages
  # sent before the markers existed.
  defp user_message_view(message) do
    text = message_text(message)

    cond do
      String.starts_with?(text, @task_run_marker) ->
        title =
          text
          |> String.split("\n", parts: 2)
          |> hd()
          |> String.replace_prefix(@task_run_marker, "")
          |> String.trim()

        {:task_run, title}

      String.starts_with?(text, "Work on this task from my New Home board.") ->
        title =
          case Regex.run(~r/Task: (.+)/, text) do
            [_full, title] -> title |> String.split(" general ·") |> hd() |> String.trim()
            _no_match -> gettext("Task")
          end

        {:task_run, title}

      # A delegated conversation opens with `TaskDelegation.prompt/1` — the
      # focused rail shows that machine-facing contract as the hand-off card.
      String.starts_with?(text, "Work on this task from the user's New Home board.") ->
        title =
          case Regex.run(~r/Task: (.+)/, text) do
            [_full, title] -> String.trim(title)
            _no_match -> gettext("Task")
          end

        {:task_run, title}

      true ->
        display =
          text
          |> String.split(@protocol_marker, parts: 2)
          |> hd()
          |> String.split("\n\nWhen the work is finished, include this fenced block", parts: 2)
          |> hd()
          |> String.trim()

        {:text, display}
    end
  end

  attr(:id, :string, required: true)
  attr(:chat_state, :any, required: true)
  attr(:chat_text, :string, default: "")
  attr(:mention_skills, :list, default: [])
  attr(:uploads, :any, default: nil)
  attr(:with_uploads, :boolean, default: false)
  # The always-mounted rail composer must not steal focus on page load — only
  # the sheet overlay autofocuses (it opens as a deliberate chat gesture).
  attr(:autofocus, :boolean, default: false)
  # On the assistant thread a send asks the router agent to create a durable
  # task conversation when the request is work; focused task threads are plain
  # follow-ups.
  attr(:create_task, :boolean, default: false)
  attr(:placeholder, :string, default: nil)

  # The chat composer: + attach, a multiline editor that grows with the
  # message (Enter sends, Shift+Enter breaks), dark round send. SkillComposer
  # owns the editor (/-skill mention chips, clears at submit) and mirrors it
  # into the hidden inputs. `chat[create_task]` and the placeholder live
  # OUTSIDE the ignore boundary — they flip when the rail's focus changes, and
  # the hook mirrors the placeholder onto the editor.
  defp chat_composer(assigns) do
    assigns = assign_new(assigns, :placeholder_text, fn -> composer_placeholder(assigns) end)

    ~H"""
    <form
      id={@id}
      phx-submit="send_chat_message"
      phx-change="validate_chat"
      phx-hook="SkillComposer"
      data-ready={to_string(@chat_state == :ready)}
      data-skills={Jason.encode!(@mention_skills)}
      data-autofocus={to_string(@autofocus)}
      data-multiline="true"
      data-placeholder-text={@placeholder_text}
      class="shrink-0 p-2"
    >
      <input type="hidden" name="chat[create_task]" value={to_string(@create_task)} />
      <.upload_previews :if={@with_uploads} uploads={@uploads} class="mb-2 px-1" />

      <div
        phx-drop-target={@with_uploads && @uploads && @uploads.attachments.ref}
        class="flex items-end gap-1 rounded-[20px] border border-neutral-200 bg-white py-1 pl-1 pr-1 shadow-subtle transition-colors duration-150 focus-within:border-neutral-350"
      >
        <.attach_menu
          :if={@with_uploads}
          id={"#{@id}-attach"}
          uploads={@uploads}
          placement="top"
        />
        <div id={"#{@id}-editor-wrap"} phx-update="ignore" class="min-w-0 flex-1">
          <div
            id={"#{@id}-input"}
            contenteditable={to_string(@chat_state == :ready)}
            role="textbox"
            aria-multiline="true"
            aria-label={@placeholder_text}
            data-placeholder={@placeholder_text}
            spellcheck="true"
            class="skill-editor max-h-40 w-full overflow-y-auto bg-transparent px-1.5 py-[7px] text-sm leading-[18px] text-neutral-900 focus:outline-none"
          >{@chat_text}</div>
          <input type="hidden" name="chat[text]" value={@chat_text} data-skill-text />
          <input type="hidden" name="chat[skills]" value="[]" data-skill-json />
        </div>
        <button
          type="submit"
          disabled={@chat_state != :ready}
          class="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-neutral-900 text-white transition-transform duration-150 ease-out active:scale-95 disabled:opacity-30"
          aria-label={gettext("Send")}
        >
          <.icon name="arrow-up" class="h-4 w-4" />
        </button>
      </div>
    </form>
    """
  end

  # The composer names its job: filing a task on the assistant thread,
  # following up on a focused one.
  defp composer_placeholder(%{placeholder: placeholder}) when is_binary(placeholder),
    do: placeholder

  defp composer_placeholder(%{create_task: true}), do: gettext("Start a task…")
  defp composer_placeholder(_assigns), do: gettext("Message your agent…")

  defp image_entry?(entry), do: String.starts_with?(entry.client_type || "", "image/")

  attr(:uploads, :any, required: true)
  attr(:class, :any, default: nil)

  # Pending attachments above the composer input: images as square thumbnails,
  # other files as icon cards, each with a hover-revealed × in its top-right
  # corner (Claude-style). Entries are client-side previews — the actual
  # upload happens when the message is sent. Rejected entries (too large,
  # wrong type — drag & drop bypasses the picker filter) show a red ring and
  # reason; config-level errors (too many files) get a line below.
  defp upload_previews(assigns) do
    ~H"""
    <div
      :if={
        @uploads &&
          (@uploads.attachments.entries != [] or upload_errors(@uploads.attachments) != [])
      }
      class={@class}
    >
      <div class="flex flex-wrap gap-2">
        <div :for={entry <- @uploads.attachments.entries} class="group/upload relative">
          <.live_img_preview
            :if={image_entry?(entry)}
            entry={entry}
            class={[
              "h-14 w-14 rounded-lg object-cover",
              entry_errors(@uploads, entry) == [] && "ring-1 ring-neutral-200",
              entry_errors(@uploads, entry) != [] && "ring-2 ring-red-400"
            ]}
          />
          <div
            :if={!image_entry?(entry)}
            class={[
              "flex h-14 w-44 items-center gap-2.5 rounded-lg bg-white px-2.5",
              entry_errors(@uploads, entry) == [] && "ring-1 ring-neutral-200",
              entry_errors(@uploads, entry) != [] && "ring-2 ring-red-400"
            ]}
          >
            <div class="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-neutral-100">
              <.icon name="document-text" class="h-4 w-4 text-neutral-500" />
            </div>
            <div class="min-w-0">
              <p class="truncate text-xs font-medium text-neutral-800">{entry.client_name}</p>
              <p
                :if={entry_errors(@uploads, entry) == []}
                class="text-[11px] uppercase tracking-wide text-neutral-400"
              >
                {entry_kind(entry)}
              </p>
              <p :if={entry_errors(@uploads, entry) != []} class="truncate text-[11px] text-red-600">
                {upload_error_label(List.first(entry_errors(@uploads, entry)))}
              </p>
            </div>
          </div>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            aria-label={gettext("Remove attachment")}
            class={[
              "absolute -right-1.5 -top-1.5 z-10 grid h-5 w-5 place-items-center rounded-full",
              "bg-neutral-900 text-white shadow-subtle",
              "opacity-0 transition-opacity duration-[var(--duration-micro)]",
              "group-hover/upload:opacity-100 focus-visible:opacity-100"
            ]}
          >
            <.icon name="x-mark" class="h-3 w-3" />
          </button>
        </div>
      </div>
      <p
        :for={err <- Enum.uniq(upload_errors(@uploads.attachments))}
        class="mt-1.5 text-xs text-red-600"
      >
        {upload_error_label(err)}
      </p>
    </div>
    """
  end

  defp entry_errors(uploads, entry), do: upload_errors(uploads.attachments, entry)

  defp upload_error_label(:too_large), do: gettext("Too large — files can be up to 10 MB")
  defp upload_error_label(:not_accepted), do: gettext("Unsupported file type")
  defp upload_error_label(:too_many_files), do: gettext("You can attach up to 8 files")
  defp upload_error_label(_error), do: gettext("Upload failed")

  defp entry_kind(entry) do
    case entry.client_name |> Path.extname() |> String.trim_leading(".") do
      "" -> gettext("File")
      ext -> String.upcase(ext)
    end
  end

  # Native-picker filters, from the same runtime-capability lists that gate
  # allow_upload — see AssistantChats.attachment_upload_extensions/0.
  @upload_accept_all Enum.join(AssistantChats.attachment_upload_extensions(), ",")
  @upload_accept_images Enum.join(AssistantChats.image_upload_extensions(), ",")

  attr(:id, :string, required: true)
  attr(:uploads, :any, required: true)
  attr(:placement, :string, default: "bottom")

  # The composer's + menu: Upload files / Upload images. Items are plain
  # buttons — the SkillComposer hook handles their click by swapping the
  # (single) live_file_input's accept from data-upload-accept and calling
  # input.click() synchronously, inside the click's own user activation, so
  # the native picker opens with the right filter. No label-forwarding
  # involved: labels lose their default action edge-cases (menu hidden
  # mid-dispatch, duplicate control ids) that can eat the picker.
  defp attach_menu(assigns) do
    assigns =
      assigns
      |> assign(:accept_all, @upload_accept_all)
      |> assign(:accept_images, @upload_accept_images)

    ~H"""
    <div class="flex items-center">
      <.dropdown id={@id} align="left" placement={@placement}>
        <:trigger>
          <button
            type="button"
            title={gettext("Attach files or images — or drop them anywhere on this box")}
            aria-label={gettext("Attach files or images")}
            class="grid h-8 w-8 shrink-0 cursor-pointer place-items-center rounded-full text-neutral-500 transition-colors duration-100 hover:bg-neutral-100 hover:text-neutral-800"
          >
            <.icon name="plus" class="h-4 w-4" />
          </button>
        </:trigger>
        <button
          type="button"
          data-upload-accept={@accept_all}
          phx-click={JS.hide(to: "##{@id}-menu")}
          class="flex w-full cursor-pointer items-center gap-2 px-3 py-1.5 text-left text-[13px] text-neutral-700 hover:bg-neutral-50"
        >
          <.icon name="document-text" class="h-4 w-4 text-neutral-400" />
          {gettext("Upload files")}
        </button>
        <button
          type="button"
          data-upload-accept={@accept_images}
          phx-click={JS.hide(to: "##{@id}-menu")}
          class="flex w-full cursor-pointer items-center gap-2 px-3 py-1.5 text-left text-[13px] text-neutral-700 hover:bg-neutral-50"
        >
          <.icon name="image" class="h-4 w-4 text-neutral-400" />
          {gettext("Upload images")}
        </button>
      </.dropdown>
      <.live_file_input upload={@uploads.attachments} class="hidden" />
    </div>
    """
  end
end
