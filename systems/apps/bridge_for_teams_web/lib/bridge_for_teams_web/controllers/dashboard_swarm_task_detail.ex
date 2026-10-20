defmodule BridgeForTeamsWeb.DashboardSwarmTaskDetail do
  @moduledoc """
  Builds the task detail payloads and applies its writes for
  `DashboardAPIController`.

  A task is a Salix conversation of the swarm's group. The page reads one
  Salix snapshot of the conversation and its latest 50 messages, the
  conversation's participants (one bounded page), the swarm's agents (one
  bounded page, to link agent participants) and, for a scheduled task, its
  schedule definition: a fixed number of reads however long the task is.

  The browser keeps the thread current by polling `messages/2` with the id of
  the last message it holds (`after`), and pages older messages with the id of
  the first one (`before`). Each poll is one Salix snapshot read, plus one
  participant read only when a person's message carries no display name.
  Every read asks for one message more than it answers, so `has_older` and
  `has_more` are exact.

  Every swarm member reads, steers and accepts a review, as on the LiveView
  page. Schedule writes are authorized by `BridgeForTeams.Conversations`,
  which records a denied audit entry for a swarm member.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Conversations}
  alias BridgeForTeamsWeb.Dashboard.SchedulePresentation

  @message_page 50
  @participant_limit 100
  @agent_page_limit 500
  @terminal_statuses ~w(completed failed cancelled)

  @doc "The task page: header, schedule, participants and the latest messages."
  def show(org, project, role, task_id) do
    case Conversations.get_project_conversation_with_messages(project, task_id,
           tail: @message_page + 1,
           limit: @message_page + 1
         ) do
      {:ok, %{conversation: conversation, messages: messages}} ->
        {messages, has_older} = newest_page(messages)
        participants = participants(project, task_id)
        names = participant_names(participants)
        {schedule, conversation} = schedule(project, conversation)

        {:ok,
         %{
           "project" => public_project(project, role),
           "task" => header(conversation),
           "schedule" => schedule,
           "participants" => public_participants(participants, project, org),
           "messages" => public_messages(messages, names, org, project, task_id),
           "has_older" => has_older
         }}

      {:error, reason} ->
        read_error(reason)
    end
  end

  @doc """
  A page of messages. `after` answers the messages newer than that id (at
  most #{@message_page}; `has_more` says another page is waiting), `before`
  the ones older than that id (`has_more` says older ones remain). Both carry
  the current task header, so a poll also notices a status change.
  """
  def messages(org, project, task_id, params) do
    after_id = text(params["after"])
    before_id = text(params["before"])

    # One message more than a page says whether another page waits.
    opts =
      cond do
        after_id -> [after_id: after_id, limit: @message_page + 1]
        # `through_id` ends the page at that message; it is dropped.
        before_id -> [through_id: before_id, limit: @message_page + 2]
        true -> [tail: @message_page + 1, limit: @message_page + 1]
      end

    case Conversations.get_project_conversation_with_messages(project, task_id, opts) do
      {:ok, %{conversation: conversation, messages: messages}} ->
        {messages, has_more} =
          if after_id,
            do: {Enum.take(messages, @message_page), length(messages) > @message_page},
            else:
              messages
              |> Enum.reject(&(before_id && &1["message_id"] == before_id))
              |> newest_page()

        names = if needs_participant_names?(messages), do: names(project, task_id), else: %{}

        {:ok,
         %{
           "task" => header(conversation),
           "messages" => public_messages(messages, names, org, project, task_id),
           "has_more" => has_more
         }}

      {:error, :not_found} when is_binary(before_id) ->
        invalid_cursor()

      {:error, {:bad_request, _reason}} when is_binary(after_id) or is_binary(before_id) ->
        invalid_cursor()

      {:error, reason} ->
        read_error(reason)
    end
  end

  @doc "Append the user's guidance to the task; Salix delivers it to the participants."
  def send_message(_org, user, project, _role, task_id, params) do
    text = if is_binary(params["text"]), do: params["text"], else: ""

    case Conversations.send_project_conversation_message(
           project,
           task_id,
           text,
           audit_opts(user, params["request_id"])
         ) do
      {:ok, result} ->
        {:ok, %{"message_id" => result["message_id"]}}

      {:error, {:validation, :message_required}} ->
        message = gettext("Write a message first.")
        {:error, 422, "message_required", message, %{"fields" => %{"text" => [message]}}}

      {:error, :not_found} ->
        task_not_found()

      {:error, _reason} ->
        {:error, 503, "send_failed", gettext("Could not send the message."), %{}}
    end
  end

  @doc "Mark the task complete, only at the review version the user saw."
  def accept_review(_org, _user, project, _role, task_id, params) do
    with version when is_integer(version) and version > 0 <- params["review_version"],
         {:ok, accepted} <- Conversations.accept_project_task_review(project, task_id, version) do
      {:ok, %{"task" => header(accepted)}}
    else
      {:error, :not_found} ->
        task_not_found()

      # Salix refuses a review whose version or state changed as a conflict.
      {:error, {:conflict, _reason}} ->
        {:error, 409, "review_changed",
         gettext("The task changed. Review it again before completing it."), %{}}

      {:error, {:bad_request, _reason}} ->
        not_reviewable()

      {:error, _unavailable} ->
        {:error, 503, "runtime_unavailable",
         gettext("Could not complete the task. Salix is unavailable — retry shortly."), %{}}

      _no_version ->
        not_reviewable()
    end
  end

  defp not_reviewable,
    do: {:error, 422, "not_reviewable", gettext("This task cannot be completed here."), %{}}

  @doc "Add or change the task's schedule; answers the header and the schedule."
  def put_schedule(_org, user, project, _role, task_id, params) do
    params = schedule_params(params)

    with {:recurrence, {:ok, recurrence}} <-
           {:recurrence, SchedulePresentation.to_recurrence(params)},
         {:command, command} when command != "" <- {:command, params["command"]},
         {:ok, conversation} <-
           Conversations.put_project_task_schedule(
             project,
             task_id,
             Map.put(recurrence, "command", command),
             audit_opts(user)
           ) do
      {:ok, schedule_reply(project, conversation)}
    else
      {:recurrence, _invalid} ->
        {:error, 422, "invalid_schedule", gettext("Enter a valid schedule."), %{}}

      {:command, _blank} ->
        message = gettext("Enter the command this schedule runs.")
        {:error, 422, "command_required", message, %{"fields" => %{"command" => [message]}}}

      {:error, reason} ->
        schedule_write_error(reason, gettext("Could not save the task schedule."))
    end
  end

  @doc "Delete only the task's schedule; the task and its history stay."
  def delete_schedule(_org, user, project, _role, task_id) do
    case Conversations.delete_project_task_schedule(project, task_id, audit_opts(user)) do
      {:ok, conversation} ->
        {:ok, schedule_reply(project, conversation)}

      {:error, reason} ->
        schedule_write_error(reason, gettext("Could not update the task schedule."))
    end
  end

  @doc "How the schedule form's recurrence reads, for the preview under it."
  def preview_schedule(params) do
    params = schedule_params(params)

    {:ok,
     %{
       "recurrence" =>
         if(recurrence?(params), do: SchedulePresentation.recurrence(params), else: nil)
     }}
  end

  defp schedule_reply(project, conversation) do
    {schedule, conversation} = schedule(project, conversation)
    %{"task" => header(conversation), "schedule" => schedule}
  end

  defp schedule_write_error(:forbidden, _message),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage schedules."), %{}}

  defp schedule_write_error(:not_found, _message), do: task_not_found()

  # Salix validates the cron expression and the time zone.
  defp schedule_write_error(:invalid_schedule, _message),
    do: {:error, 422, "invalid_schedule", gettext("Enter a valid schedule."), %{}}

  # Another write changed or removed the schedule first.
  defp schedule_write_error(reason, _message)
       when reason in [:task_schedule_changed, :task_schedule_not_found],
       do:
         {:error, 409, "schedule_changed",
          gettext("The schedule changed. Reload the task and try again."), %{}}

  defp schedule_write_error(_reason, message), do: {:error, 503, "write_failed", message, %{}}

  defp schedule_params(params) do
    given =
      params
      |> Map.take(~w(mode interval_value interval_unit cron timezone command))
      |> Map.new(fn {key, value} -> {key, if(is_binary(value), do: value, else: "")} end)

    SchedulePresentation.form_values(%{})
    |> Map.merge(given)
    |> Map.put("command", String.trim(given["command"] || ""))
  end

  defp recurrence?(%{"mode" => "cron", "cron" => cron}), do: String.trim(cron) != ""

  defp recurrence?(%{"mode" => "interval", "interval_value" => value}),
    do: String.trim(value) != ""

  defp recurrence?(_params), do: false

  # The newest `@message_page` of messages read one over, and whether older
  # ones remain.
  defp newest_page(messages) do
    extra = length(messages) - @message_page
    {Enum.drop(messages, max(extra, 0)), extra > 0}
  end

  # ---- Header and schedule ----

  defp header(conversation) do
    status = text(conversation["status"]) || "active"
    scheduled = scheduled?(conversation)
    version = conversation["updated_at"]
    task? = conversation["kind"] == "agent_task"

    %{
      "id" => conversation["conversation_id"],
      "title" => text(conversation["title"]),
      "status" => status,
      "kind" => text(conversation["kind"]),
      "scheduled" => scheduled,
      "schedulable" => task?,
      # Accepting a review names the version the user saw; a newer one refuses.
      "review_version" =>
        if(
          task? and status == "ready_for_review" and not scheduled and is_integer(version) and
            version > 0,
          do: version
        ),
      "terminal" => status in @terminal_statuses,
      "updated_at" => iso_timestamp(version)
    }
  end

  defp scheduled?(conversation) do
    case get_in(conversation, ["schedule", "schedule_id"]) do
      id when is_binary(id) -> String.trim(id) != ""
      _ -> false
    end
  end

  # The recurrence lives in the schedule definition, read once per page.
  defp schedule(project, conversation) do
    schedule = conversation["schedule"] || %{}

    if scheduled?(conversation) do
      case Conversations.get_project_task_schedule(
             project,
             conversation["conversation_id"],
             schedule["schedule_id"]
           ) do
        {:ok, definition} ->
          schedule = Map.merge(schedule, Map.take(definition, ~w(interval_minutes cron timezone)))
          {public_schedule("ok", schedule), Map.put(conversation, "schedule", schedule)}

        {:error, :not_found} ->
          {public_schedule("missing", schedule), conversation}

        {:error, _reason} ->
          {public_schedule("unavailable", schedule), conversation}
      end
    else
      {public_schedule("none", %{}), conversation}
    end
  end

  defp public_schedule(status, schedule) do
    command = text(schedule["command"])

    %{
      "status" => status,
      "recurrence" => if(status == "ok", do: SchedulePresentation.recurrence(schedule)),
      "command" => command,
      "form" =>
        schedule
        |> SchedulePresentation.form_values()
        |> Map.put("command", command || "")
    }
  end

  # ---- Participants ----

  defp participants(project, task_id) do
    case Conversations.list_project_conversation_participants(project, task_id,
           limit: @participant_limit
         ) do
      {:ok, participants} -> Enum.filter(participants, &is_map/1)
      {:error, _reason} -> []
    end
  end

  defp names(project, task_id), do: project |> participants(task_id) |> participant_names()

  defp public_participants(participants, project, org) do
    agents = if participants == [], do: %{}, else: agents_by_salix_id(project)

    Enum.map(participants, fn participant ->
      agent = agents[trim(participant["agent_id"])]
      payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}

      %{
        "id" => trim(participant["participant_id"]),
        "label" => participant_label(participant, agent),
        "role_label" => text(participant["role_label"]),
        "agent_href" => agent && "/orgs/#{org.slug}/projects/#{project.id}/agents/#{agent.id}",
        "thread_url" => web_url(payload["thread_url"])
      }
    end)
  end

  # One bounded Salix page; without it, agent participants keep their names
  # and lose only their link.
  defp agents_by_salix_id(project) do
    case Agents.page_agents(project, limit: @agent_page_limit) do
      {:ok, %{items: agents}} -> Map.new(agents, &{&1.salix_agent_id, &1})
      {:error, _reason} -> %{}
    end
  end

  # A link to the provider thread opens only an http(s) address.
  defp web_url(value) do
    with url when is_binary(url) <- text(value),
         %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) <-
           URI.parse(url) do
      url
    else
      _ -> nil
    end
  end

  defp participant_label(_participant, %{salix: %{"name" => name}})
       when is_binary(name) and name != "",
       do: name

  defp participant_label(%{"agent_name" => name}, _agent) when is_binary(name) and name != "",
    do: name

  defp participant_label(%{"provider" => "slack"} = participant, _agent) do
    case slack_participant_name(participant) do
      "" -> provider_participant_label(participant)
      name -> name
    end
  end

  defp participant_label(%{"provider" => provider} = participant, _agent)
       when is_binary(provider) and provider != "",
       do: provider_participant_label(participant)

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

  defp slack_participant_name(participant) do
    payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}
    user_id = first_nonblank([participant["user_id"], payload["created_from_user_id"]])

    first_name(
      [
        participant["display_name"],
        participant["user_display_name"],
        payload["created_from_user_display_name"],
        participant["real_name"],
        participant["user_real_name"],
        payload["created_from_user_real_name"],
        participant["user_name"],
        payload["created_from_user_name"]
      ],
      user_id
    )
  end

  # Display names of the people in the task, by `{provider, user_id}` and by
  # `{"", user_id}`, for messages that carry only a user id.
  defp participant_names(participants) do
    Enum.reduce(participants, %{}, fn participant, acc ->
      payload = if is_map(participant["payload"]), do: participant["payload"], else: %{}
      user_id = first_nonblank([participant["user_id"], payload["created_from_user_id"]])

      name =
        if participant["provider"] == "slack",
          do: slack_participant_name(participant),
          else:
            first_name(
              [
                participant["display_name"],
                participant["user_display_name"],
                participant["real_name"],
                participant["user_real_name"],
                participant["user_name"]
              ],
              ""
            )

      if user_id != "" and name != "" do
        acc
        |> Map.put({trim(participant["provider"]), user_id}, name)
        |> Map.put_new({"", user_id}, name)
      else
        acc
      end
    end)
  end

  # ---- Messages ----

  defp needs_participant_names?(messages) do
    Enum.any?(messages, fn message ->
      message["actor_type"] == "provider_user" and message_person_name(message) == "" and
        trim(message["user_id"]) != ""
    end)
  end

  defp public_messages(messages, names, org, project, task_id) do
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn message ->
      %{
        "id" => message["message_id"],
        "seq" => if(is_integer(message["seq"]), do: message["seq"]),
        "author" => author(message, names),
        "from_person" => message["actor_type"] in ["user", "provider_user"],
        "created_at" => iso_timestamp(message["created_at"]),
        "blocks" => blocks(message, org, project, task_id)
      }
    end)
  end

  defp author(%{"actor_type" => "agent"} = message, _names),
    do: text(message["agent_name"]) || text(message["role_label"]) || gettext("Agent")

  defp author(%{"actor_type" => "provider_user"} = message, names) do
    provider = provider_label(message)
    user_id = trim(message["user_id"])

    name =
      case message_person_name(message) do
        "" -> participant_name(names, provider_key(message), user_id)
        name -> name
      end

    case {provider, name, user_id} do
      {"", name, _user_id} when name != "" -> name
      {provider, name, _user_id} when name != "" -> provider <> " · " <> name
      {"", "", ""} -> gettext("External user")
      {provider, "", ""} -> provider <> " " <> gettext("user")
      {"", "", user_id} -> user_id
      {provider, "", user_id} -> provider <> " " <> user_id
    end
  end

  # A canonical user message, as the LiveView page labelled it.
  defp author(%{"actor_type" => "user"}, _names), do: gettext("You")
  defp author(_message, _names), do: gettext("Message")

  defp participant_name(_names, _provider, ""), do: ""

  defp participant_name(names, provider, user_id),
    do: names[{provider, user_id}] || names[{"", user_id}] || ""

  defp message_person_name(message) do
    metadata = if is_map(message["metadata"]), do: message["metadata"], else: %{}
    profile = if is_map(metadata["user_profile"]), do: metadata["user_profile"], else: %{}

    first_name(
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
      ],
      trim(message["user_id"])
    )
  end

  # The dashboard's own messages need no provider prefix.
  defp provider_label(message) do
    case provider_key(message) do
      key when key in ["", "bft"] -> ""
      key -> key |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp provider_key(message) do
    source =
      case trim(message["provider"]) do
        "" -> trim(message["role_label"])
        provider -> provider
      end

    source |> String.replace_suffix("_user", "") |> String.trim()
  end

  defp blocks(message, org, project, task_id) do
    message["content"]
    |> content_blocks()
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, index} ->
      case block do
        %{"type" => type} when type in ["image", "file"] ->
          [attachment(block, message, org, project, task_id, index)]

        _text ->
          case block_text(block) do
            "" -> []
            text -> [%{"type" => "text", "html" => markdown_html(text)}]
          end
      end
    end)
  end

  defp content_blocks(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp content_blocks(content) when is_list(content), do: content
  defp content_blocks(content) when is_map(content), do: [content]
  defp content_blocks(_content), do: []

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp block_text(content), do: content_text(content)

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

  # Sanitized server-side, as the LiveView page rendered it: links open in a
  # new tab, and scripts or raw HTML never reach the browser.
  defp markdown_html(text) do
    MDEx.to_html!(text,
      extension: [autolink: true, strikethrough: true, table: true, tasklist: true],
      sanitize:
        Keyword.put(MDEx.Document.default_sanitize_options(), :set_tag_attribute_values, %{
          "a" => %{"target" => "_blank"}
        })
    )
  rescue
    _ -> text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp attachment(block, message, org, project, task_id, index) do
    path = attachment_path(block)

    %{
      "type" => "attachment",
      "kind" => block["type"],
      "name" =>
        text(
          first_nonblank([
            block["title"],
            block["file_name"],
            block["name"],
            if(path == "", do: nil, else: Path.basename(path))
          ])
        ) || gettext("Attachment"),
      "path" => text(path),
      "mime" => text(first_nonblank([block["mime_type"], block["mime"]])),
      # The download rechecks the canonical sender and the reader's access;
      # a workspace path or a user-authored ref never becomes a link.
      "href" =>
        if(message["actor_type"] == "agent" and is_map(block["blob_ref"]),
          do:
            "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{task_id}/messages/" <>
              "#{message["message_id"]}/attachments/#{index}"
        )
    }
  end

  defp attachment_path(%{"path" => path}) when is_binary(path), do: String.trim(path)

  defp attachment_path(%{"file_ref" => %{"environment_id" => "vfs", "path" => path}})
       when is_binary(path),
       do: String.trim(path)

  defp attachment_path(_block), do: ""

  # ---- Errors and helpers ----

  defp read_error(reason) when reason in [:not_found, :invalid_response], do: task_not_found()
  defp read_error({:bad_request, _reason}), do: task_not_found()

  defp read_error(_reason),
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Could not load this task. Salix is unavailable — retry shortly."), %{}}

  defp task_not_found, do: {:error, 404, "task_not_found", gettext("Task not found."), %{}}

  defp invalid_cursor,
    do: {:error, 422, "invalid_cursor", gettext("These messages are no longer available."), %{}}

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  # A browser retry of one send carries the same request id, so Salix keeps
  # one message.
  defp audit_opts(user, request_id \\ nil) do
    request_id =
      case Ecto.UUID.cast(request_id) do
        {:ok, uuid} -> uuid
        :error -> SystemsRuntime.Proc.uuid()
      end

    [actor_user_id: user.id, actor_label: actor_label(user), request_id: request_id]
  end

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  # Salix stores times as unix seconds or milliseconds.
  defp iso_timestamp(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp iso_timestamp(value) when is_binary(value), do: value
  defp iso_timestamp(_value), do: nil

  defp first_name(values, user_id) do
    values
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != "" and &1 != user_id and not slack_user_id?(&1)))
  end

  defp first_nonblank(values) do
    values
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp slack_user_id?(value), do: Regex.match?(~r/^[UW][A-Z0-9]{7,}$/, value)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
