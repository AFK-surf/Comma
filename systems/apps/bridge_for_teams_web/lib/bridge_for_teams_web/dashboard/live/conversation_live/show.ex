defmodule BridgeForTeamsWeb.Dashboard.ConversationLive.Show do
  @moduledoc """
  Project task detail with a steering composer.

  BFT tasks and messages live as conversations in Salix under the project group.
  This page validates the org/project route locally, reads the conversation through
  `BridgeForTeams.Conversations`, and appends user messages through the same
  context so Salix can deliver them to conversation participants.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Agents, Conversations, Memberships, Orgs, Projects}
  alias BridgeForTeamsWeb.Dashboard.{RelativeTime, SchedulePresentation}

  @message_limit 100
  @subscription_retry_ms 1_000

  @impl true
  def mount(
        %{"org" => slug, "id" => project_id, "conversation_id" => conversation_id},
        _session,
        socket
      ) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id,
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         {:ok, _project_role} <- Memberships.project_role(project.id, user.id),
         subscription_ref <- subscribe_before_snapshot(project, socket, conversation_id),
         {:ok, %{conversation: conversation, messages: messages}} <-
           Conversations.get_project_conversation_with_messages(project, conversation_id,
             tail: @message_limit
           ) do
      participants = load_conversation_participants(project, conversation_id)
      conversation = Map.put(conversation, "participants", participants)
      {conversation, task_schedule_error} = hydrate_task_schedule(project, conversation)
      participants = conversation_participants(conversation, project)
      provider_user_display_names = provider_user_display_names(conversation["participants"])

      {:ok,
       socket
       |> assign(:orgs, orgs)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:content_chrome, :workbench)
       |> assign(:can_view_operations, org_role in ["owner", "admin"])
       |> assign(:can_view_audit, org_role in ["owner", "admin"])
       |> assign(:project, project)
       |> assign(:conversation, conversation)
       |> assign(:task_schedule_error, task_schedule_error)
       |> assign(:participants, participants)
       |> assign(:provider_user_display_names, provider_user_display_names)
       |> assign(:messages, messages)
       |> assign(:conversation_owner_ref, subscription_ref)
       |> assign(:message_form, message_form(%{}))
       |> assign(:schedule_form, schedule_form(conversation))
       |> assign(:task_schedule_modal_open, false)
       |> assign(:active_nav, :projects)
       |> assign(:page_title, conversation_title(conversation))
       |> assign(:breadcrumbs, breadcrumbs(org, project, conversation))}
    else
      _ ->
        {:ok,
         socket
         |> assign(:orgs, orgs)
         |> put_flash(:error, gettext("Task not found."))
         |> push_navigate(to: ~p"/orgs/#{slug}/projects/#{project_id}/tasks")}
    end
  end

  defp load_conversation_participants(project, conversation_id) do
    case Conversations.list_project_conversation_participants(project, conversation_id) do
      {:ok, participants} -> participants
      {:error, _reason} -> []
    end
  end

  @impl true
  def handle_info(
        {:conversation_message_created, _group_id, _conversation_id, _message_id, _seq},
        socket
      ) do
    {:noreply, refresh_messages(socket)}
  end

  def handle_info(
        {:conversation_status_changed, group_id, conversation_id, _status},
        socket
      ) do
    if group_id == socket.assigns.project.salix_group_id and
         conversation_id == socket.assigns.conversation["conversation_id"] do
      {:noreply, refresh_messages(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _owner, _reason},
        %{assigns: %{conversation_owner_ref: ref}} = socket
      )
      when is_reference(ref) do
    schedule_subscription_retry()
    {:noreply, assign(socket, :conversation_owner_ref, nil)}
  end

  def handle_info(:subscribe_conversation, %{assigns: %{conversation_owner_ref: nil}} = socket) do
    ref =
      subscribe_conversation(
        socket.assigns.project,
        socket.assigns.conversation["conversation_id"]
      )

    socket = assign(socket, :conversation_owner_ref, ref)
    {:noreply, if(ref, do: refresh_messages(socket), else: socket)}
  end

  def handle_info(:subscribe_conversation, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send_message", %{"message" => %{"text" => text}}, socket) do
    conversation_id = socket.assigns.conversation["conversation_id"]

    case Conversations.send_project_conversation_message(
           socket.assigns.project,
           conversation_id,
           text,
           audit_opts(socket)
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_messages()
         |> assign(:message_form, message_form(%{}))
         |> put_flash(:info, message_sent_flash(result))}

      {:error, {:validation, :message_required}} ->
        {:noreply, assign(socket, :message_form, message_form(%{"text" => text}))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not send the message."))}
    end
  end

  def handle_event("accept_task_review", _params, socket) do
    conversation = socket.assigns.conversation

    with review_version when is_integer(review_version) and review_version > 0 <-
           conversation["updated_at"],
         {:ok, accepted} <-
           Conversations.accept_project_task_review(
             socket.assigns.project,
             conversation["conversation_id"],
             review_version
           ) do
      {:noreply,
       socket
       |> assign_task_schedule(accepted)
       |> put_flash(:info, gettext("Task marked complete."))}
    else
      _ ->
        {:noreply,
         socket
         |> refresh_messages()
         |> put_flash(:error, gettext("The task changed. Review it again before completing it."))}
    end
  end

  def handle_event("open_task_schedule_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:schedule_form, schedule_form(socket.assigns.conversation))
     |> assign(:task_schedule_modal_open, true)}
  end

  def handle_event("close_task_schedule_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:schedule_form, schedule_form(socket.assigns.conversation))
     |> assign(:task_schedule_modal_open, false)}
  end

  def handle_event("save_task_schedule", %{"schedule" => params}, socket) do
    with {:ok, recurrence} <- SchedulePresentation.to_recurrence(params),
         command when is_binary(command) and command != "" <- String.trim(params["command"] || ""),
         {:ok, conversation} <-
           Conversations.put_project_task_schedule(
             socket.assigns.project,
             socket.assigns.conversation["conversation_id"],
             Map.put(recurrence, "command", command),
             audit_opts(socket)
           ) do
      {:noreply,
       socket
       |> assign_task_schedule(conversation)
       |> assign(:task_schedule_modal_open, false)
       |> put_flash(:info, gettext("Task schedule saved."))}
    else
      {:error, :invalid_schedule} ->
        {:noreply,
         socket
         |> assign(:schedule_form, schedule_form_from_params(params))
         |> put_flash(:error, gettext("Enter a valid schedule."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the task schedule."))}
    end
  end

  def handle_event("validate_task_schedule", %{"schedule" => params}, socket) do
    {:noreply, assign(socket, :schedule_form, schedule_form_from_params(params))}
  end

  def handle_event("delete_task_schedule", _params, socket) do
    project = socket.assigns.project
    conversation_id = socket.assigns.conversation["conversation_id"]

    case Conversations.delete_project_task_schedule(
           project,
           conversation_id,
           audit_opts(socket)
         ) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign_task_schedule(conversation)
         |> assign(:task_schedule_modal_open, false)
         |> put_flash(:info, gettext("Task schedule updated."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the task schedule."))}
    end
  end

  defp message_form(params), do: to_form(params, as: :message)

  defp subscribe_before_snapshot(project, socket, conversation_id) do
    if connected?(socket),
      do: subscribe_conversation(project, conversation_id),
      else: nil
  end

  defp subscribe_conversation(project, conversation_id) do
    case Conversations.subscribe_project_conversation(project, conversation_id, self()) do
      {:ok, %{"owner_pid" => owner, "tail_seq" => tail_seq}}
      when is_pid(owner) and is_integer(tail_seq) ->
        Process.monitor(owner)

      _error ->
        schedule_subscription_retry()
        nil
    end
  end

  # At most one retry RPC per connected task view per interval; no child scan.
  defp schedule_subscription_retry,
    do: Process.send_after(self(), :subscribe_conversation, @subscription_retry_ms)

  defp refresh_messages(socket) do
    case Conversations.get_project_conversation_with_messages(
           socket.assigns.project,
           socket.assigns.conversation["conversation_id"],
           tail: @message_limit
         ) do
      {:ok, %{conversation: conversation, messages: messages}} ->
        conversation =
          conversation
          |> Map.put("participants", socket.assigns.conversation["participants"] || [])

        socket
        |> assign(:messages, messages)
        |> assign_task_schedule(conversation)

      {:error, _reason} ->
        socket
    end
  end

  defp assign_task_schedule(socket, conversation) do
    {conversation, task_schedule_error} =
      hydrate_task_schedule(socket.assigns.project, conversation)

    socket
    |> assign(:conversation, conversation)
    |> assign(:task_schedule_error, task_schedule_error)
    |> assign(:schedule_form, schedule_form(conversation))
  end

  defp hydrate_task_schedule(
         project,
         %{
           "conversation_id" => conversation_id,
           "schedule" => %{"schedule_id" => schedule_id} = schedule
         } =
           conversation
       )
       when is_binary(schedule_id) and schedule_id != "" do
    case Conversations.get_project_task_schedule(project, conversation_id, schedule_id) do
      {:ok, definition} ->
        recurrence = Map.take(definition, ~w(interval_minutes cron timezone))
        {Map.put(conversation, "schedule", Map.merge(schedule, recurrence)), nil}

      {:error, reason} ->
        {conversation, reason}
    end
  end

  defp hydrate_task_schedule(_project, conversation), do: {conversation, nil}

  defp schedule_form(conversation) do
    schedule = conversation["schedule"] || %{}

    schedule
    |> SchedulePresentation.form_values()
    |> Map.put("command", schedule["command"] || "")
    |> schedule_form_from_params()
  end

  defp schedule_form_from_params(params) do
    params =
      SchedulePresentation.form_values(%{})
      |> Map.merge(Map.take(params, ~w(mode interval_value interval_unit cron timezone command)))

    to_form(params, as: :schedule)
  end

  defp breadcrumbs(org, project, conversation) do
    [
      {gettext("Agent Swarms"), ~p"/orgs/#{org.slug}/projects"},
      {project.name, ~p"/orgs/#{org.slug}/projects/#{project.id}"},
      {gettext("Tasks"), ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks"},
      {conversation_title(conversation), nil}
    ]
  end

  defp message_sent_flash(_result), do: gettext("Guidance added.")

  defp conversation_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp conversation_title(_conversation), do: gettext("Untitled task")

  defp conversation_kind_label(%{"kind" => kind}) when is_binary(kind) and kind != "" do
    kind
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp conversation_kind_label(_conversation), do: gettext("Task")

  defp scheduled_task?(conversation) do
    case get_in(conversation, ["schedule", "schedule_id"]) do
      id when is_binary(id) -> String.trim(id) != ""
      _ -> false
    end
  end

  defp task_schedule_recurrence(conversation) do
    SchedulePresentation.recurrence(conversation["schedule"] || %{})
  end

  defp task_schedule_command(conversation) do
    get_in(conversation, ["schedule", "command"]) || ""
  end

  defp task_schedule_form_recurrence(form) do
    if task_schedule_form_has_recurrence?(form.params),
      do: SchedulePresentation.recurrence(form.params)
  end

  defp task_schedule_form_has_recurrence?(%{"mode" => "cron", "cron" => cron})
       when is_binary(cron),
       do: String.trim(cron) != ""

  defp task_schedule_form_has_recurrence?(%{"mode" => "interval", "interval_value" => value})
       when is_binary(value),
       do: String.trim(value) != ""

  defp task_schedule_form_has_recurrence?(_params), do: false

  defp task_schedule_error_message(:not_found), do: gettext("That schedule no longer exists.")

  defp task_schedule_error_message(_reason),
    do: gettext("Could not load schedules from Salix. Retry shortly.")

  defp task_conversation?(conversation), do: conversation["kind"] == "agent_task"

  defp task_reviewable?(conversation) do
    task_conversation?(conversation) and conversation["status"] == "ready_for_review" and
      is_integer(conversation["updated_at"]) and conversation["updated_at"] > 0 and
      not scheduled_task?(conversation)
  end

  defp conversation_status_label(%{"status" => "active"}), do: gettext("In progress")

  defp conversation_status_label(%{"status" => "ready_for_review"}),
    do: gettext("Ready for review")

  defp conversation_status_label(%{"status" => "completed"}), do: gettext("Completed")
  defp conversation_status_label(%{"status" => "failed"}), do: gettext("Failed")
  defp conversation_status_label(%{"status" => "cancelled"}), do: gettext("Cancelled")
  defp conversation_status_label(%{"status" => "escalated"}), do: gettext("Blocked")
  defp conversation_status_label(conversation), do: humanize_status(conversation["status"])

  defp humanize_status(status) when is_binary(status) do
    status |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize_status(_status), do: gettext("In progress")

  defp message_actor(message, provider_user_display_names)

  defp message_actor(%{"actor_type" => "agent"} = message, _provider_user_display_names),
    do: message["agent_name"] || message["role_label"] || gettext("Agent")

  defp message_actor(%{"actor_type" => "provider_user"} = message, provider_user_display_names) do
    provider = provider_user_label(message)
    display_name = provider_user_display_name(message, provider_user_display_names)

    case {provider, display_name, trim(message["user_id"])} do
      {"", name, _user_id} when name != "" -> name
      {provider, name, _user_id} when name != "" -> provider <> " · " <> name
      {"", "", ""} -> gettext("External user")
      {provider, "", ""} -> provider <> " " <> gettext("user")
      {"", "", user_id} -> user_id
      {provider, "", user_id} -> provider <> " " <> user_id
    end
  end

  defp message_actor(%{"actor_type" => "user"}, _provider_user_display_names), do: gettext("You")
  defp message_actor(_message, _provider_user_display_names), do: gettext("Message")

  defp message_from_user?(%{"actor_type" => actor_type})
       when actor_type in ["user", "provider_user"],
       do: true

  defp message_from_user?(_message), do: false

  defp provider_user_label(message) do
    source =
      message
      |> provider_user_source()
      |> String.replace_suffix("_user", "")
      |> String.replace("_", " ")
      |> String.trim()

    case source do
      "" -> ""
      value -> String.capitalize(value)
    end
  end

  defp provider_user_source(message) do
    case trim(message["provider"]) do
      "" -> trim(message["role_label"])
      provider -> provider
    end
  end

  defp provider_user_display_name(message, provider_user_display_names) do
    metadata = if is_map(message["metadata"]), do: message["metadata"], else: %{}
    profile = if is_map(metadata["user_profile"]), do: metadata["user_profile"], else: %{}
    user_id = trim(message["user_id"])

    display_name =
      [
        message["display_name"],
        message["user_display_name"],
        metadata["user_display_name"],
        profile["display_name_normalized"],
        profile["display_name"],
        message["real_name"],
        message["user_real_name"],
        metadata["user_real_name"],
        profile["real_name_normalized"],
        profile["real_name"],
        message["user_name"],
        metadata["user_name"],
        metadata["username"]
      ]
      |> Enum.map(&trim/1)
      |> Enum.reject(&(&1 == "" or &1 == user_id or slack_user_id?(&1)))
      |> Enum.find("", fn _value -> true end)

    case display_name do
      "" -> provider_user_display_name_from_participant(message, provider_user_display_names)
      name -> name
    end
  end

  defp provider_user_display_name_from_participant(message, provider_user_display_names)
       when is_map(provider_user_display_names) do
    user_id = trim(message["user_id"])
    provider = provider_user_provider(message)

    cond do
      user_id == "" ->
        ""

      provider != "" ->
        provider_user_display_names[{provider, user_id}] ||
          provider_user_display_names[{"", user_id}] ||
          ""

      true ->
        provider_user_display_names[{"", user_id}] || ""
    end
  end

  defp provider_user_display_name_from_participant(_message, _provider_user_display_names), do: ""

  defp provider_user_provider(message) do
    message
    |> provider_user_source()
    |> String.replace_suffix("_user", "")
    |> trim()
  end

  defp message_content_blocks(%{"content" => content}), do: content_blocks(content)
  defp message_content_blocks(_message), do: []

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp content_text(%{"text" => text}) when is_binary(text), do: text
  defp content_text(%{"type" => "image_url"}), do: gettext("[image]")
  defp content_text(content) when is_map(content), do: content |> Map.values() |> content_text()
  defp content_text(_content), do: ""

  defp content_blocks(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp content_blocks(content) when is_list(content), do: content
  defp content_blocks(content) when is_map(content), do: [content]
  defp content_blocks(_content), do: []

  attr(:message, :map, required: true)
  attr(:org, :map, required: true)
  attr(:project, :map, required: true)
  attr(:conversation, :map, required: true)

  @doc "Pure committed Message body shared with the Session review surface."
  def message_body(assigns) do
    ~H"""
    <.message_content_block
      :for={{block, index} <- Enum.with_index(message_content_blocks(@message))}
      block={block}
      download_url={attachment_download_url(@org, @project, @conversation, @message, block, index)}
    />
    """
  end

  attr(:block, :map, required: true)
  attr(:download_url, :string, default: nil)

  defp message_content_block(%{block: %{"type" => "text", "text" => text}} = assigns)
       when is_binary(text) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <.markdown text={@text} />
    """
  end

  defp message_content_block(%{block: %{"type" => "image"}} = assigns) do
    assigns = assign_attachment(assigns, gettext("Image"))

    ~H"""
    <.attachment_block label={@label} name={@name} path={@path} mime={@mime} download_url={@download_url} />
    """
  end

  defp message_content_block(%{block: %{"type" => "file"}} = assigns) do
    assigns = assign_attachment(assigns, gettext("File"))

    ~H"""
    <.attachment_block label={@label} name={@name} path={@path} mime={@mime} download_url={@download_url} />
    """
  end

  defp message_content_block(assigns) do
    assigns = assign(assigns, :text, content_text(assigns.block))

    ~H"""
    <.markdown :if={@text != ""} text={@text} />
    """
  end

  attr(:label, :string, required: true)
  attr(:name, :string, required: true)
  attr(:path, :string, default: "")
  attr(:mime, :string, default: "")
  attr(:download_url, :string, default: nil)

  defp attachment_block(assigns) do
    ~H"""
    <div class="flex items-start gap-3 rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm">
      <.icon name="folder" class="mt-0.5 h-4 w-4 flex-none text-neutral-500" />
      <div class="min-w-0 flex-1">
        <div class="font-medium text-neutral-800">{@name}</div>
        <div class="mt-1 flex flex-wrap gap-x-2 gap-y-1 text-xs text-neutral-500">
          <span>{@label}</span>
          <span :if={@mime != ""}>{@mime}</span>
        </div>
        <div :if={@path != ""} class="mt-1 break-all font-mono text-xs text-neutral-500">
          {@path}
        </div>
        <.link :if={@download_url} href={@download_url} class="mt-2 inline-block text-xs text-brand-600 underline">
          {gettext("Download (up to 10 MB)")}
        </.link>
      </div>
    </div>
    """
  end

  defp assign_attachment(assigns, label) do
    block = assigns.block
    path = attachment_path(block)
    name = attachment_name(block, path)

    assigns
    |> assign(:label, label)
    |> assign(:name, name)
    |> assign(:path, path)
    |> assign(:mime, attachment_mime(block))
  end

  defp attachment_download_url(org, project, conversation, message, block, index) do
    # The server rechecks the canonical sender/ref and current project access.
    # Never turn a workspace path or user-authored ref into a download link.
    if message["actor_type"] == "agent" and block["type"] in ["file", "image"] and
         is_map(block["blob_ref"]) do
      ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation["conversation_id"]}/messages/#{message["message_id"]}/attachments/#{index}"
    end
  end

  defp attachment_name(block, path) do
    [
      block["title"],
      block["file_name"],
      block["name"],
      if(path == "", do: nil, else: Path.basename(path))
    ]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.map(&String.trim/1)
    |> Enum.find(gettext("Attachment"), &(&1 != ""))
  end

  defp attachment_path(%{"path" => path}) when is_binary(path), do: String.trim(path)

  defp attachment_path(%{"file_ref" => %{"environment_id" => "vfs", "path" => path}})
       when is_binary(path),
       do: String.trim(path)

  defp attachment_path(_block), do: ""

  defp attachment_mime(block) do
    [block["mime_type"], block["mime"]]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp conversation_participants(%{"participants" => participants}, project)
       when is_list(participants) do
    agents_by_salix_id =
      project.id
      |> Agents.list_agents()
      |> Map.new(fn agent -> {agent.salix_agent_id, agent} end)

    Enum.map(participants, &participant_row(&1, agents_by_salix_id))
  end

  defp conversation_participants(_conversation, _project), do: []

  defp provider_user_display_names(participants) when is_list(participants) do
    participants
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn participant, acc ->
      payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}
      provider = trim(participant["provider"])
      user_id = first_nonblank([participant["user_id"], payload["created_from_user_id"]])
      display_name = participant_display_name_for_provider_user(participant)

      if user_id != "" and display_name != "" do
        acc
        |> Map.put({provider, user_id}, display_name)
        |> Map.put_new({"", user_id}, display_name)
      else
        acc
      end
    end)
  end

  defp provider_user_display_names(_participants), do: %{}

  defp participant_display_name_for_provider_user(%{"provider" => "slack"} = participant),
    do: slack_participant_display_name(participant)

  defp participant_display_name_for_provider_user(participant) do
    [
      participant["display_name"],
      participant["user_display_name"],
      participant["real_name"],
      participant["user_real_name"],
      participant["user_name"]
    ]
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == "" or slack_user_id?(&1)))
    |> Enum.find("", fn _value -> true end)
  end

  defp participant_row(participant, agents_by_salix_id) do
    salix_agent_id = trim(participant["agent_id"])
    agent = if salix_agent_id == "", do: nil, else: agents_by_salix_id[salix_agent_id]
    payload = participant["payload"] || %{}

    %{
      participant_id: trim(participant["participant_id"]),
      actor_type: trim(participant["actor_type"]),
      role_label: trim(participant["role_label"]),
      label: participant_label(participant, agent),
      slack_thread_url: slack_thread_url(payload),
      agent: agent
    }
  end

  defp slack_thread_url(payload) do
    trim(payload["thread_url"])
  end

  defp participant_label(_participant, %{salix: %{"name" => name}})
       when is_binary(name) and name != "",
       do: name

  defp participant_label(%{"agent_name" => name}, _agent) when is_binary(name) and name != "",
    do: name

  defp participant_label(%{"provider" => "slack"} = participant, _agent) do
    case slack_participant_display_name(participant) do
      "" -> provider_participant_label(participant)
      name -> name
    end
  end

  defp participant_label(%{"provider" => provider, "role_label" => role}, _agent)
       when is_binary(provider) and provider != "" do
    provider_participant_label(%{"provider" => provider, "role_label" => role})
  end

  defp participant_label(%{"role_label" => role}, _agent) when is_binary(role) and role != "",
    do: role

  defp participant_label(%{"participant_id" => id}, _agent) when is_binary(id) and id != "",
    do: id

  defp participant_label(_participant, _agent), do: gettext("Participant")

  defp provider_participant_label(participant) do
    [participant["provider"], participant["role_label"]]
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp slack_participant_display_name(participant) do
    payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}
    user_id = first_nonblank([participant["user_id"], payload["created_from_user_id"]])

    [
      participant["display_name"],
      participant["user_display_name"],
      payload["created_from_user_display_name"],
      participant["real_name"],
      participant["user_real_name"],
      payload["created_from_user_real_name"],
      participant["user_name"],
      payload["created_from_user_name"]
    ]
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == "" or &1 == user_id or slack_user_id?(&1)))
    |> Enum.find("", fn _value -> true end)
  end

  defp participant_agent_url(%{agent: %{id: agent_id}}, org, project) do
    ~p"/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent_id}"
  end

  defp participant_agent_url(_participant, _org, _project), do: nil

  defp participant_session_url(
         %{actor_type: "agent"} = participant,
         org,
         project,
         conversation
       ) do
    ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation["conversation_id"]}/session?#{%{participant: participant.participant_id}}"
  end

  defp participant_session_url(_participant, _org, _project, _conversation), do: nil

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp first_nonblank(values) do
    values
    |> List.wrap()
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp slack_user_id?(value), do: Regex.match?(~r/^[UW][A-Z0-9]{7,}$/, trim(value))

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
      trim(user.email) != "" -> trim(user.email)
      trim(user.name) != "" -> trim(user.name)
      true -> user.id
    end
  end

  defp format_message_time(value), do: RelativeTime.label(value, absolute_after_days: 7) || "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-5 lg:flex lg:h-full lg:min-h-0 lg:flex-col lg:space-y-0">
      <header class="flex items-start justify-between gap-4 lg:shrink-0">
        <div class="min-w-0">
          <h1 class="truncate text-lg font-semibold tracking-tight text-neutral-950">
            {conversation_title(@conversation)}
          </h1>
          <div class="mt-1 flex flex-wrap items-center gap-2 text-xs text-neutral-500">
            <.status_pill
              status={@conversation["status"] || "active"}
              label={conversation_status_label(@conversation)}
            />
            <span aria-hidden="true">·</span>
            <span>{conversation_kind_label(@conversation)}</span>
            <span
              :if={scheduled_task?(@conversation)}
              class="rounded-full bg-brand-50 px-2 py-0.5 font-medium text-brand-700"
            >
              {gettext("Scheduled")}
            </span>
          </div>
        </div>

        <.dropdown
          :if={@can_view_operations || @can_view_audit}
          id="task-detail-operations"
          align="right"
        >
          <:trigger>
            <button
              type="button"
              class="grid h-8 w-8 place-items-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
              aria-label={gettext("Task operations")}
              title={gettext("Task operations")}
            >
              <.icon name="ellipsis" class="h-4 w-4" />
            </button>
          </:trigger>
          <.dropdown_item
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "conversation", resource_id: @conversation["conversation_id"]}}"}
          >
            {gettext("View events")}
          </.dropdown_item>
          <.dropdown_item
            :if={@can_view_audit}
            href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "project_conversation", resource_id: @conversation["conversation_id"]}}"}
          >
            {gettext("View audit")}
          </.dropdown_item>
        </.dropdown>
      </header>

      <div class={[
        "grid grid-cols-1 gap-8 lg:mt-5 lg:min-h-0 lg:flex-1",
        "lg:grid-cols-[minmax(0,1fr)_18rem]"
      ]}>
        <section class="min-w-0 lg:flex lg:min-h-0 lg:flex-col" aria-label={gettext("Task conversation")}>
          <.empty_state
            :if={@messages == []}
            icon="chat-bubble"
            title={gettext("No messages yet")}
            description={gettext("Steer this task to get started.")}
            class="min-h-64 lg:min-h-0 lg:flex-1"
          />

          <div
            :if={@messages != []}
            id="task-messages"
            phx-hook="ScrollToBottom"
            data-scroll-key={@messages |> List.last() |> Map.get("message_id", "")}
            class="space-y-5 py-2 lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:overscroll-contain lg:pr-3"
          >
            <article
              :for={message <- @messages}
              id={"message-#{message["message_id"]}"}
              class={[
                "flex items-start gap-2.5",
                message_from_user?(message) && "justify-end"
              ]}
            >
              <div
                :if={!message_from_user?(message)}
                class="mt-5 grid h-7 w-7 shrink-0 place-items-center rounded-md bg-neutral-100 text-neutral-600"
              >
                <.icon name="sparkles" class="h-3.5 w-3.5" />
              </div>

              <div class={["min-w-0 max-w-2xl", message_from_user?(message) && "text-right"]}>
                <div class={[
                  "mb-1 flex items-center gap-2 text-xs",
                  message_from_user?(message) && "justify-end"
                ]}>
                  <span class="font-medium text-neutral-700">
                    {message_actor(message, @provider_user_display_names)}
                  </span>
                  <time class="text-neutral-400">{format_message_time(message["created_at"])}</time>
                </div>
                <div class={[
                  "space-y-2 rounded-lg px-3.5 py-3 text-left text-sm text-neutral-800",
                  message_from_user?(message) && "border border-brand-100 bg-brand-50",
                  !message_from_user?(message) && "border border-neutral-200 bg-white"
                ]}>
                  <.message_body message={message} org={@current_org} project={@project} conversation={@conversation} />
                </div>
              </div>

              <div
                :if={message_from_user?(message)}
                class="mt-5 grid h-7 w-7 shrink-0 place-items-center rounded-md bg-brand-50 text-brand-600"
              >
                <.icon name="user" class="h-3.5 w-3.5" />
              </div>
            </article>
          </div>

          <div class="sticky bottom-0 mt-6 border-t border-neutral-200 bg-neutral-50/95 pt-3 backdrop-blur-sm lg:static lg:mt-3 lg:shrink-0">
            <.form for={@message_form} phx-submit="send_message" id="message-form">
              <div class="rounded-lg border border-neutral-200 bg-white p-2 shadow-subtle focus-within:border-brand-400 focus-within:ring-2 focus-within:ring-brand-100">
                <textarea
                  id={@message_form[:text].id}
                  name={@message_form[:text].name}
                  rows="3"
                  placeholder={gettext("Steer this task...")}
                  required
                  class="block min-h-20 w-full resize-none border-0 bg-transparent px-2 py-1.5 text-sm text-neutral-800 outline-none placeholder:text-neutral-400 focus:ring-0"
                >{Phoenix.HTML.Form.normalize_value("textarea", @message_form[:text].value)}</textarea>
                <div class="mt-1 flex justify-end">
                  <.button type="submit" variant="primary" size="sm">
                    <.icon name="arrow-up" class="h-3.5 w-3.5" />
                    {gettext("Steer")}
                  </.button>
                </div>
              </div>
            </.form>
          </div>
        </section>

        <aside
          class="space-y-6 border-t border-neutral-200 pt-5 lg:min-h-0 lg:overflow-y-auto lg:overscroll-contain lg:border-l lg:border-t-0 lg:pl-6 lg:pr-3 lg:pt-0"
          aria-label={gettext("Task details")}
        >
          <div :if={task_reviewable?(@conversation)} class="flex justify-end">
            <.button
              type="button"
              variant="primary"
              size="sm"
              phx-click="accept_task_review"
              data-task-accept
            >
              <.icon name="check" class="h-3.5 w-3.5" />
              {gettext("Mark complete")}
            </.button>
          </div>


          <section :if={task_conversation?(@conversation)}>
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-xs font-semibold text-neutral-900">{gettext("Task schedule")}</h2>
              <.button
                :if={is_nil(@task_schedule_error)}
                type="button"
                variant="ghost"
                size="sm"
                phx-click="open_task_schedule_modal"
              >
                <.icon name={if scheduled_task?(@conversation), do: "pencil", else: "plus"} class="mr-1 h-3.5 w-3.5" />
                {if scheduled_task?(@conversation), do: gettext("Edit"), else: gettext("Add schedule")}
              </.button>
            </div>
            <p
              :if={@task_schedule_error && scheduled_task?(@conversation)}
              class="mt-3 text-xs text-red-700"
              role="alert"
            >
              {task_schedule_error_message(@task_schedule_error)}
            </p>
            <div
              :if={scheduled_task?(@conversation) && is_nil(@task_schedule_error)}
              class="mt-3 space-y-3 text-xs"
            >
              <p class="font-medium text-neutral-800">{task_schedule_recurrence(@conversation)}</p>
              <div :if={task_schedule_command(@conversation) != ""}>
                <p class="text-neutral-500">{gettext("Command")}</p>
                <p class="mt-1 whitespace-pre-wrap break-words leading-5 text-neutral-700">
                  {task_schedule_command(@conversation)}
                </p>
              </div>
            </div>
          </section>

          <section>
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-xs font-semibold text-neutral-900">{gettext("Participants")}</h2>
              <span class="text-xs text-neutral-400">{length(@participants)}</span>
            </div>
            <div :if={@participants == []} class="mt-3 text-xs text-neutral-500">
              {gettext("No participants recorded.")}
            </div>
            <div :if={@participants != []} class="mt-3 divide-y divide-neutral-100">
              <div
                :for={participant <- @participants}
                id={"participant-#{participant.participant_id}"}
                class="py-3 first:pt-0 last:pb-0"
              >
                <div class="flex items-start gap-2.5">
                  <div class="grid h-6 w-6 shrink-0 place-items-center rounded-md bg-neutral-100 text-neutral-500">
                    <.icon name={if participant.actor_type == "agent", do: "sparkles", else: "user"} class="h-3.5 w-3.5" />
                  </div>
                  <div class="min-w-0 flex-1">
                    <.link
                      :if={participant_agent_url(participant, @current_org, @project)}
                      navigate={participant_agent_url(participant, @current_org, @project)}
                      class="block truncate text-xs font-medium text-neutral-800 hover:text-brand-600 hover:underline"
                    >
                      {participant.label}
                    </.link>
                    <div
                      :if={!participant_agent_url(participant, @current_org, @project)}
                      class="truncate text-xs font-medium text-neutral-800"
                    >
                      {participant.label}
                    </div>
                    <div class="mt-0.5 flex flex-wrap items-center gap-x-1.5 text-[11px] text-neutral-500">
                      <span :if={participant.role_label != ""}>{participant.role_label}</span>
                    </div>
                    <div
                      :if={participant_session_url(participant, @current_org, @project, @conversation) || participant.slack_thread_url != ""}
                      class="mt-2 flex flex-wrap items-center gap-3 text-xs"
                    >
                      <.link
                        :if={participant_session_url(participant, @current_org, @project, @conversation)}
                        navigate={participant_session_url(participant, @current_org, @project, @conversation)}
                        class="text-brand-600 hover:underline"
                      >
                        {gettext("View timeline")}
                      </.link>
                      <.link
                        :if={participant.slack_thread_url != ""}
                        href={participant.slack_thread_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="text-brand-600 hover:underline"
                      >
                        {gettext("Open Slack thread")}
                      </.link>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>

        </aside>

        <.task_schedule_modal
          :if={@task_schedule_modal_open}
          conversation={@conversation}
          form={@schedule_form}
        />
      </div>
    </div>
    """
  end

  defp task_schedule_modal(assigns) do
    ~H"""
    <.modal id="task-schedule-modal" show on_cancel={JS.push("close_task_schedule_modal")}>
      <:title>{gettext("Task schedule")}</:title>
      <.form
        for={@form}
        id="task-schedule-form"
        phx-submit="save_task_schedule"
        phx-change="validate_task_schedule"
        class="space-y-4"
      >
        <div class="grid grid-cols-2 gap-2" role="radiogroup" aria-label={gettext("Schedule type")}>
          <label
            class={[
              "flex min-h-9 cursor-pointer items-center justify-center rounded-md border px-2 text-xs font-medium",
              @form[:mode].value == "cron" && "border-brand-600 bg-brand-50 text-brand-700",
              @form[:mode].value != "cron" && "border-neutral-200 text-neutral-600 hover:bg-neutral-50"
            ]}
          >
            <input
              type="radio"
              name={@form[:mode].name}
              value="cron"
              checked={@form[:mode].value == "cron"}
              class="sr-only"
            />
            {gettext("At a fixed time")}
          </label>
          <label
            class={[
              "flex min-h-9 cursor-pointer items-center justify-center rounded-md border px-2 text-xs font-medium",
              @form[:mode].value == "interval" && "border-brand-600 bg-brand-50 text-brand-700",
              @form[:mode].value != "interval" && "border-neutral-200 text-neutral-600 hover:bg-neutral-50"
            ]}
          >
            <input
              type="radio"
              name={@form[:mode].name}
              value="interval"
              checked={@form[:mode].value == "interval"}
              class="sr-only"
            />
            {gettext("Repeat after a duration")}
          </label>
        </div>

        <div :if={@form[:mode].value == "cron"} class="space-y-2">
          <label class="block text-xs text-neutral-500" for={@form[:cron].id}>
            {gettext("Cron expression")}
          </label>
          <input
            id={@form[:cron].id}
            name={@form[:cron].name}
            value={@form[:cron].value}
            type="text"
            placeholder="0 17 * * *"
            required
            class="block w-full rounded-md border-neutral-300 font-mono text-sm"
          />
          <label class="block text-xs text-neutral-500" for={@form[:timezone].id}>
            {gettext("Time zone")}
          </label>
          <input
            id={@form[:timezone].id}
            name={@form[:timezone].name}
            value={@form[:timezone].value}
            type="text"
            required
            class="block w-full rounded-md border-neutral-300 text-sm"
          />
        </div>

        <div :if={@form[:mode].value == "interval"} class="space-y-2">
          <label class="block text-xs text-neutral-500" for={@form[:interval_value].id}>
            {gettext("Repeat every")}
          </label>
          <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-2">
            <input
              id={@form[:interval_value].id}
              name={@form[:interval_value].name}
              value={@form[:interval_value].value}
              type="number"
              min="1"
              required
              class="block min-w-0 rounded-md border-neutral-300 text-sm"
            />
            <select
              id={@form[:interval_unit].id}
              name={@form[:interval_unit].name}
              class="rounded-md border-neutral-300 text-sm"
            >
              <option value="minutes" selected={@form[:interval_unit].value == "minutes"}>
                {gettext("Minutes")}
              </option>
              <option value="hours" selected={@form[:interval_unit].value == "hours"}>
                {gettext("Hours")}
              </option>
              <option value="days" selected={@form[:interval_unit].value == "days"}>
                {gettext("Days")}
              </option>
            </select>
          </div>
        </div>

        <p
          :if={task_schedule_form_recurrence(@form)}
          class="rounded-md bg-neutral-50 px-2 py-1.5 text-xs text-neutral-600"
        >
          {task_schedule_form_recurrence(@form)}
        </p>

        <div>
          <label class="block text-xs text-neutral-500" for={@form[:command].id}>
            {gettext("Command")}
          </label>
          <textarea
            id={@form[:command].id}
            name={@form[:command].name}
            required
            rows="4"
            class="mt-2 block w-full rounded-md border-neutral-300 text-sm"
          >{@form[:command].value}</textarea>
        </div>

        <div class="flex items-center justify-end gap-2 pt-1">
          <.button type="button" variant="ghost" phx-click="close_task_schedule_modal">
            {gettext("Cancel")}
          </.button>
          <.button type="submit" variant="primary">
            {if scheduled_task?(@conversation),
              do: gettext("Update schedule"),
              else: gettext("Add schedule")}
          </.button>
        </div>
      </.form>

      <div :if={scheduled_task?(@conversation)} class="mt-5 border-t border-neutral-200 pt-4">
        <.button type="button" variant="danger" size="sm" phx-click="delete_task_schedule">
          {gettext("Delete schedule")}
        </.button>
      </div>
    </.modal>
    """
  end
end
