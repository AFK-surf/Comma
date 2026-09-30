defmodule SalixIM.Provider.Internal do
  @moduledoc false

  import SalixIM.Provider.Util
  require Logger

  alias SalixIM.{
    ConversationAttachments,
    ConversationInput,
    ConversationParticipantActivity,
    ConversationParticipantProjection,
    Conversations,
    GroupDirectory,
    ProviderRecipientIdentity
  }

  alias SalixIM.Ports.{AgentDelivery, TaskCreate, TaskSchedule}
  alias SalixIM.Provider.Feishu.MeetingActivationAuthorization
  alias SalixIM.Triage.DelegationAuthorization
  alias SalixStore.{Ids, RuntimeIds}

  @delivery_filter_limit SalixIM.ConversationLimits.delivery_filter_limit()
  @inline_task_ref_limit SalixIM.ConversationLimits.inline_task_ref_limit()
  @task_list_default_limit 200
  @task_list_max_limit 1_000
  @task_list_cursor_max_length 1_024
  @conversation_update_string_fields ~w(kind status activity_status title owner_user_id)
  @conversation_update_map_fields ~w(metadata latest_artifact artifact_manifest source_refs)
  @send_message_params ~w(conversation_id content request_id delivery_filter mentions reply_to_message_id)
  @router_task_apis ~w(internal.task.create internal.task.update internal.task.list)
  @router_label_apis ~w(internal.label.list internal.label.assign internal.label.propose)
  @label_propose_params ~w(op payload summary)
  @add_agent_participant_api "internal.add_agent_participant"
  @egress_archive_broker_key :egress_archive_reservation_broker
  @egress_archive_reservation_key :egress_archive_reservation
  defp label_proposal_next_action(%{"status" => "pending"}),
    do:
      "The change is pending until the user confirms it in Comma, in this chat or in Settings › Labels. Existing matching labels can already be assigned. Do not re-propose while it is pending."

  defp label_proposal_next_action(%{"application_status" => status})
       when status in ["pending", "conflict"],
       do:
         "The label change was approved, but the Task labels were not confirmed applied. Report application_error; do not claim the Task was labeled or overwrite later user choices."

  defp label_proposal_next_action(%{"status" => "approved"}),
    do:
      "The change was approved and applied under the workspace's label permission. Report the result; do not ask again."

  defp label_proposal_next_action(_proposal),
    do: "The proposal was rejected. Do not apply or re-propose it without new user direction."

  # ---- internal dispatch (willow callInternalProviderAPI) ----

  def call(%{agent: %{"role" => "worker"}} = scope, "internal.triage.read_memory", params)
      when is_map(params),
      do: SalixIM.Triage.Investigation.read_memory(scope, params)

  def call(%{agent: %{"role" => "worker"}} = scope, "internal.triage.read_context", params)
      when is_map(params) and map_size(params) == 0,
      do: SalixIM.Triage.Investigation.read_context(scope)

  def call(%{agent: %{"role" => "worker"}} = scope, "internal.triage.read_source", params)
      when is_map(params) and map_size(params) == 0,
      do: SalixIM.Triage.Investigation.read_source(scope)

  def call(%{agent: %{"role" => "worker"}} = scope, "internal.triage.complete", params)
      when is_map(params),
      do: SalixIM.Triage.Investigation.complete(scope, params)

  def call(%{agent: %{"role" => "router"}} = scope, "internal.task.create", params)
      when is_map(params) do
    with {:ok, command} <- task_create_command(scope, params) do
      case TaskCreate.create_task_conversation(
             scope.group_id,
             scope.agent_id,
             command.target_agent_id,
             command.attrs
           ) do
        {:ok, result} ->
          task_create_response(result, command)

        {:error, {:conflict, _} = reason} ->
          task_create_conflict(scope, command, reason)

        {:error, reason} ->
          {:error, control_error(reason)}
      end
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}} = scope, "internal.task.update", params)
      when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id command schedule),
             "im_api.internal.task.update"
           ),
         conversation_id when conversation_id != "" <- str(params["conversation_id"]),
         {:ok, schedule} <- task_schedule_update(params),
         :ok <- authorize_task_update(scope),
         {:ok, conversation} <-
           TaskSchedule.update_task_schedule(scope.group_id, conversation_id, schedule) do
      schedule = conversation["schedule"] || %{}

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "conversation_kind" => "agent_task",
         "schedule" => schedule,
         "scheduled" => str(schedule["schedule_id"]) != "",
         "updated" => true
       }}
    else
      "" -> {:error, "conversation_id is required"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}} = scope, "internal.task.list", params)
      when is_map(params) do
    with {:ok, opts} <- task_list_options(params),
         {:ok, page} <- Conversations.list_group_conversations(scope.group_id, opts) do
      tasks = Enum.map(page["data"], &task_list_entry/1)

      {:ok,
       %{
         "tasks" => tasks,
         "count" => length(tasks),
         "has_more" => page["has_more"],
         "next_action" => task_list_next_action(page["has_more"])
       }
       |> maybe_put("next_cursor", page["next_cursor"])}
    else
      {:error, :not_found} -> {:error, "group not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}}, api, _params) when api in @router_task_apis,
    do: {:error, "params must be a JSON object"}

  def call(_scope, api, _params) when api in @router_task_apis,
    do: {:error, "operation is not authorized for this agent role"}

  # ---- task labels (router only; catalog writes are human-confirmed proposals) ----

  def call(%{agent: %{"role" => "router"}} = scope, "internal.label.list", params)
      when is_map(params) do
    with :ok <- validate_param_keys(params, [], "im_api.internal.label.list"),
         {:ok, catalog} <- SalixIM.TaskLabels.list(scope.group_id) do
      {:ok,
       %{
         "labels" => catalog["labels"],
         "approval_policy" => catalog["approval_policy"],
         "pending_proposals" => Enum.filter(catalog["proposals"], &(&1["status"] == "pending")),
         "colors" => catalog["colors"]
       }}
    else
      {:error, :not_found} -> {:error, "group not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}} = scope, "internal.label.assign", params)
      when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id label_ids),
             "im_api.internal.label.assign"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, conversation} <-
           SalixIM.TaskLabels.assign(scope.group_id, conversation_id, params["label_ids"]) do
      {:ok,
       Map.take(conversation, ~w(conversation_id labels label_revision))
       |> Map.put("applied", true)}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}} = scope, "internal.label.propose", params)
      when is_map(params) do
    tool_context = SalixIM.Provider.current_tool_context()

    with :ok <-
           validate_param_keys(params, @label_propose_params, "im_api.internal.label.propose"),
         {:ok, _op} <- required_string(params, "op"),
         {:ok, proposal} <-
           SalixIM.TaskLabels.propose(scope.group_id, params, %{
             "agent_id" => scope.agent_id,
             "session_id" => context_value(tool_context, "session_id"),
             "tool_call_id" => Map.get(scope, :tool_call_id),
             "source_conversation_id" =>
               proposal_source_conversation_id(scope.group_id, tool_context)
           }) do
      {:ok,
       Map.merge(proposal, %{
         "proposed" => true,
         "next_action" => label_proposal_next_action(proposal)
       })}
    else
      {:error, :not_found} -> {:error, "group or conversation not found"}
      # A duplicate name is a conflict the agent should read as plain text.
      {:error, {:conflict, message}} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}}, api, _params) when api in @router_label_apis,
    do: {:error, "params must be a JSON object"}

  def call(_scope, api, _params) when api in @router_label_apis,
    do: {:error, "operation is not authorized for this agent role"}

  def call(%{agent: %{"role" => "router"}} = scope, @add_agent_participant_api, params)
      when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id agent_id role_label notification_filter),
             "im_api.internal.add_agent_participant"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, agent_id} <- required_string(params, "agent_id"),
         {:ok, agent_id} <- task_create_group_agent(scope, agent_id),
         {:ok, attrs} <- add_agent_participant_attrs(params, agent_id),
         {:ok, participant} <-
           ConversationInput.ensure_group_conversation_agent_participant(
             scope.group_id,
             conversation_id,
             attrs
           ) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participant_id" => participant["participant_id"],
         "agent_id" => agent_id,
         "role_label" => participant["role_label"],
         "notification_filter" => participant["notification_filter"],
         "state" => participant["state"]
       }}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}}, @add_agent_participant_api, _params),
    do: {:error, "params must be a JSON object"}

  def call(_scope, @add_agent_participant_api, _params),
    do: {:error, "operation is not authorized for this agent role"}

  def call(scope, "internal.search_conversations", params) do
    query = str(params["query"])
    limit = int_or(params["limit"], 0)
    opts = if limit > 0, do: [limit: limit], else: []

    case Conversations.search_group_conversations(scope.group_id, query, opts) do
      {:ok, results} -> {:ok, %{"results" => results}}
      {:error, :not_found} -> {:error, "group not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(scope, "internal.read_conversation", params) do
    conversation_id = str(params["conversation_id"])
    message_id = str(params["message_id"])
    limit = int_or(params["limit"], 0)
    after_seq = int_or(params["after_seq"], -1)
    tail = int_or(params["tail"], 0)

    opts =
      []
      |> then(&if(limit > 0, do: Keyword.put(&1, :limit, limit), else: &1))
      |> then(&if(after_seq >= 0, do: Keyword.put(&1, :after_seq, after_seq), else: &1))
      |> then(&if(tail > 0, do: Keyword.put(&1, :tail, tail), else: &1))

    with {:ok, conversation} <- get_conversation(scope.group_id, conversation_id),
         {:ok, participants} <-
           list_conversation_participants(scope.group_id, conversation_id, []),
         {:ok, messages} <-
           read_conversation_messages(scope.group_id, conversation_id, message_id, opts),
         {:ok, messages} <- ConversationAttachments.materialize_messages(scope.agent_id, messages),
         {:ok, task_lifecycle} <- public_task_lifecycle(conversation) do
      current = current_agent_participant(participants, scope.agent_id)

      state = build_read_state(conversation["kind"], current, participants, messages)

      result =
        %{
          "conversation_id" => conversation_id,
          "state" => state,
          "participants" => public_participants(participants),
          "messages" => Enum.map(messages, &public_message/1)
        }
        |> put_present("task_lifecycle", task_lifecycle)
        |> put_present("current_participant_id", current && current["participant_id"])

      {:ok, result}
    end
  end

  def call(scope, "internal.list_conversation_participants", params) do
    conversation_id = str(params["conversation_id"])
    limit = int_or(params["limit"], 0)
    opts = if limit > 0, do: [limit: limit], else: []

    with {:ok, participants} <-
           list_conversation_participants(scope.group_id, conversation_id, opts) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => public_participants(participants)
       }}
    end
  end

  def call(scope, "internal.get_conversation_participant_status", params) do
    conversation_id = str(params["conversation_id"])
    participant_id = str(params["participant_id"])

    with {:ok, participant} <-
           get_conversation_participant(scope.group_id, conversation_id, participant_id),
         {:ok, status} <- participant_status(scope.group_id, conversation_id, participant),
         {:ok, status} <- maybe_put_device_id(status, participant, scope) do
      {:ok, status}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, participant_status_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}} = scope, "internal.update_conversation", params)
      when is_map(params) do
    mutable_fields =
      @conversation_update_string_fields ++ @conversation_update_map_fields ++ ["labels"]

    with :ok <-
           validate_param_keys(
             params,
             ["conversation_id" | mutable_fields],
             "im_api.internal.update_conversation"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, conversation} <- get_conversation(scope.group_id, conversation_id),
         :ok <- authorize_conversation_update(scope, conversation_id),
         {:ok, update} <-
           params
           |> Map.drop(["conversation_id"])
           |> validate_conversation_update(),
         {:ok, activation_provenance} <-
           MeetingActivationAuthorization.provenance_for_tool_context(
             scope.group_id,
             SalixIM.Provider.current_tool_context()
           ),
         {:ok, destination_provenance} <-
           MeetingActivationAuthorization.provenance_for_conversation(conversation),
         {:ok, effective_provenance} <-
           MeetingActivationAuthorization.merge_provenance([
             activation_provenance,
             destination_provenance
           ]),
         :ok <- validate_activation_conversation_update(effective_provenance, update),
         {:ok, updated} <-
           SalixIM.ConversationServer.update_group_conversation(
             scope.group_id,
             conversation_id,
             Map.put(update, :router_agent_id, scope.agent_id)
           ) do
      {:ok,
       updated
       |> Map.take(
         ~w(conversation_id kind status activity_status title owner_user_id labels metadata latest_artifact artifact_manifest source_refs updated_at)
       )
       |> Map.put("updated", true)}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  def call(%{agent: %{"role" => "router"}}, "internal.update_conversation", _params),
    do: {:error, "params must be a JSON object"}

  def call(_scope, "internal.update_conversation", _params),
    do: {:error, "operation is not authorized for this agent role"}

  def call(scope, "internal.send_message", params) when is_map(params) do
    SalixIM.SendTiming.run("im_send_total", fn -> send_message(scope, params) end)
  end

  def call(_scope, "internal.send_message", _params),
    do: {:error, "params must be a JSON object"}

  def call(_scope, _api, _params), do: {:error, "unsupported internal provider api"}

  defp authorize_conversation_update(scope, conversation_id) do
    with {:ok, participants} <-
           ConversationParticipantProjection.list_bounded(scope.group_id, conversation_id) do
      case current_agent_participant(participants, scope.agent_id) do
        %{"state" => "active"} ->
          :ok

        %{} ->
          {:error, "current Agent participant is not active"}

        nil ->
          {:error, "current Agent is not a Conversation participant"}
      end
    end
  end

  defp task_create_command(scope, params) do
    tool_context = SalixIM.Provider.current_tool_context()
    content = to_string_safe(params["content"])
    title = to_string_safe(params["title"])
    schedule = params["schedule"]

    with :ok <-
           if(Map.has_key?(params, "workflow"),
             do: {:error, "Task graph creation is retired; supply agent_id and content"},
             else: :ok
           ),
         :ok <- validate_task_create_params(content, schedule),
         {:ok, target_agent_id} <- required_string(params, "agent_id"),
         {:ok, labels} <-
           SalixIM.TaskLabels.validate_initial_labels(scope.group_id, params["label_ids"] || []),
         {:ok, triage} <- DelegationAuthorization.prepare(scope, tool_context, params),
         {:ok, provenance_refs} <- task_create_provenance(scope, tool_context, schedule),
         {:ok, trusted_origin} <- task_create_trusted_origin(scope, tool_context),
         {:ok, target_agent_id, public_target} <-
           task_create_target(scope, target_agent_id),
         {:ok, execution_refs} <-
           SalixIM.TaskExecution.prepare(scope, tool_context, params, target_agent_id) do
      session_id = context_value(tool_context, "session_id")

      source_refs =
        %{}
        |> put_present("origin_agent_id", scope.agent_id)
        |> put_present(
          "parent_conversation_id",
          trusted_origin && trusted_origin["conversation_id"]
        )
        |> put_present("parent_message_id", trusted_origin && trusted_origin["message_id"])
        |> put_present("origin_session_id", session_id)
        |> Map.merge(provenance_refs)
        |> Map.merge(SalixIM.TaskReplySource.source_refs(scope, tool_context))
        |> Map.merge(task_ifc_refs(tool_context))
        |> Map.merge(execution_refs)
        |> Map.merge(SalixIM.TaskContinuation.source_refs(scope, tool_context, params))

      attrs =
        %{
          "content" => content,
          "title" => title,
          "schedule" => schedule,
          "client_request_id" =>
            task_create_request_id(
              scope,
              tool_context,
              trusted_origin,
              target_agent_id,
              content,
              title,
              schedule
            ),
          "origin_session_id" => session_id,
          "source_refs" => source_refs,
          "conversation_metadata" => task_origin_metadata(scope, tool_context),
          "labels" => labels
        }
        |> put_present(
          "owner_user_id",
          get_in(execution_refs, ["task_execution", "requester_id"])
        )

      attrs =
        if triage do
          attrs
          |> Map.delete("origin_session_id")
          |> Map.put("client_request_id", triage.request_id)
          # Product-owned investigations already carry stable, read-only sources.
          # Do not mix the current delivery origin into their idempotent command.
          |> Map.put("source_refs", Map.merge(triage.source_refs, task_ifc_refs(tool_context)))
        else
          attrs
        end

      {:ok,
       %{
         attrs: attrs,
         public_target: public_target,
         target_agent_id: target_agent_id,
         title: title,
         triage: triage
       }}
    end
  end

  defp task_create_conflict(scope, %{triage: %{request_id: request_id}}, _reason) do
    existing =
      case SalixIM.ConversationServer.lookup_task_create_request(scope.group_id, request_id) do
        {:ok, result} -> result
        {:error, _reason} -> %{"disposition" => "unavailable"}
      end

    {:error,
     Jason.encode!(%{
       "error" => "triage_delegation_conflict",
       "message" =>
         "This handoff already reserved a different immutable Task command. Do not create a replacement; inspect or continue the existing Task when available.",
       "existing_task" => existing
     })}
  end

  defp task_create_conflict(_scope, _command, reason), do: {:error, control_error(reason)}

  defp validate_task_create_params(content, schedule) do
    cond do
      content == "" ->
        {:error, "content is required"}

      not is_nil(schedule) and not is_map(schedule) ->
        {:error, "schedule must be an object"}

      is_map(schedule) and str(schedule["cron"]) != "" and
          str(schedule["timezone"]) == "" ->
        {:error,
         "schedule.timezone is required with schedule.cron; ask the user if it is unclear"}

      true ->
        :ok
    end
  end

  defp task_create_provenance(scope, tool_context, schedule) do
    case MeetingActivationAuthorization.provenance_for_tool_context(
           scope.group_id,
           tool_context
         ) do
      {:ok, refs} when is_map(refs) and is_map(schedule) and map_size(refs) > 0 ->
        {:error,
         "im_api.internal.task.create schedule provenance rejected: :meeting_activation_schedule_not_authorized"}

      {:ok, refs} when is_map(refs) ->
        {:ok, refs}

      {:error, reason} ->
        {:error, "im_api.internal.task.create source provenance rejected: #{inspect(reason)}"}

      other ->
        {:error, "im_api.internal.task.create source provenance invalid: #{inspect(other)}"}
    end
  end

  # A Task's audience is decided when it is created and stored with it, as
  # server-owned `source_refs` keys the model can neither read nor set
  # (docs/verification.md):
  #
  #   * `ifc_provenance` — the join of the sources the Router declared, so a
  #     Worker's report inherits what the Task was made from;
  #   * `ifc_members` — the people it is shared with, which starts as the
  #     person who asked for it.
  #
  # Absent when the Group has the check off, in which case the Task simply
  # carries no audience and nothing about it changes.
  defp task_ifc_refs(tool_context) do
    case context_value(tool_context, "ifc_evidence") do
      %{} = evidence ->
        members =
          if evidence["requester"] == "system",
            do: [],
            else: list_of_strings(List.wrap(evidence["requester"]))

        %{}
        |> put_present("ifc_provenance", list_of_strings(evidence["sources_label"]))
        |> put_present("ifc_members", members)

      _absent ->
        %{}
    end
  end

  defp list_of_strings(values) when is_list(values) do
    case Enum.filter(values, &(is_binary(&1) and &1 != "")) do
      [] -> nil
      strings -> strings
    end
  end

  defp list_of_strings(_values), do: nil

  defp task_create_trusted_origin(scope, tool_context) do
    case context_value(tool_context, "trusted_origin") do
      nil ->
        {:ok, nil}

      origin when is_map(origin) ->
        origin = stringify_value(origin)

        if origin["provider"] == "internal" and
             origin["conversation_kind"] in ["user_chat", "agent_task"] do
          validate_task_create_origin(scope, tool_context, origin)
        else
          {:ok, nil}
        end

      _invalid ->
        {:error, "im_api.internal.task.create trusted origin rejected: expected an object"}
    end
  end

  # Where the Task was asked for. Provider inbound (Slack, Telegram, …) carries
  # its provider on the trusted origin; a Comma client request arrives as an
  # `internal` origin whose parent user Message carries the client metadata
  # the product stamped on it. Both are display facts, never authorization.
  defp task_origin_metadata(scope, tool_context) do
    origin =
      case context_value(tool_context, "trusted_origin") do
        origin when is_map(origin) -> stringify_value(origin)
        _other -> %{}
      end

    provider = str(origin["provider"])

    base =
      cond do
        provider == "" -> %{}
        provider == "internal" -> internal_origin_metadata(scope, origin)
        true -> %{"provider" => provider}
      end

    if map_size(base) == 0, do: %{}, else: %{"origin" => base}
  end

  defp internal_origin_metadata(scope, origin) do
    with conversation_id when is_binary(conversation_id) <- origin["conversation_id"],
         message_id when is_binary(message_id) <- origin["message_id"],
         {:ok, message} <-
           SalixIM.Conversations.get_group_conversation_message(
             scope.group_id,
             conversation_id,
             message_id
           ) do
      metadata = stringify_value(message["metadata"] || %{})

      %{"provider" => "comma"}
      |> put_present("client_kind", str(metadata["client_kind"]))
      |> put_present("client_platform", str(metadata["client_platform"]))
    else
      _other -> %{"provider" => "comma"}
    end
  end

  defp validate_task_create_origin(scope, tool_context, origin) do
    conversation_id = origin["conversation_id"]
    message_id = origin["message_id"]
    participant_id = origin["participant_id"]
    source_message_id = context_value(tool_context, "source_message_id")

    valid? =
      origin["agent_group_id"] == scope.group_id and
        Ids.valid_conversation_id?(conversation_id) and Ids.valid_message_id?(message_id) and
        Ids.valid_participant_id?(participant_id) and
        group_conversation_source_identity(source_message_id, conversation_id) ==
          {message_id, participant_id}

    if valid?,
      do: {:ok, origin},
      else: {:error, "im_api.internal.task.create trusted internal Conversation origin rejected"}
  end

  defp task_create_target(scope, target_agent_id) do
    case task_create_group_agent(scope, target_agent_id) do
      {:ok, target_agent_id} ->
        {:ok, target_agent_id, %{"agent_id" => target_agent_id}}

      {:error, reason} ->
        {:error, "Task requires a valid group-local agent_id: #{inspect(reason)}"}
    end
  end

  defp task_create_group_agent(scope, agent_id) do
    case GroupDirectory.get_agent(agent_id) do
      {:ok, %{"group_id" => group_id, "agent_id" => ^agent_id} = agent}
      when group_id == scope.group_id ->
        if agent["status"] in ["cancelled", "failed"],
          do: {:error, :not_found},
          else: {:ok, agent_id}

      {:ok, _other_group} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp task_create_request_id(
         scope,
         _tool_context,
         %{"conversation_id" => conversation_id, "message_id" => message_id},
         target_agent_id,
         content,
         title,
         schedule
       ) do
    command_digest =
      {target_agent_id, content, title, schedule}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Enum.join(
      ["comma-user-chat-task", scope.agent_id, conversation_id, message_id, command_digest],
      ":"
    )
  end

  defp task_create_request_id(
         scope,
         tool_context,
         nil,
         _target_agent_id,
         _content,
         _title,
         _schedule
       ) do
    case Map.get(scope, :tool_call_id) do
      id when is_binary(id) and id != "" ->
        Enum.join([scope.agent_id, context_value(tool_context, "session_id"), id], ":")

      _missing ->
        nil
    end
  end

  defp task_create_response(result, command) when is_map(result) do
    conversation_id = str(result["conversation_id"])

    if Ids.valid_conversation_id?(conversation_id) do
      response =
        %{
          "created" => true,
          "conversation_id" => conversation_id,
          "conversation_ref" => %{
            "type" => "conversation_ref",
            "conversation_id" => conversation_id,
            "kind" => "agent_task",
            "presentation" => "inline"
          },
          "conversation_kind" => "agent_task",
          "inserted" => result["inserted"] != false,
          "response_delivery" => "ordinary_conversation_message",
          "response_conversation_id" => conversation_id,
          "next_action" => task_create_next_action()
        }
        |> Map.merge(command.public_target)
        |> put_task_create_delivery(result)
        |> put_present("status", get_in(result, ["conversation", "status"]))
        |> put_present("title", command.title)

      response =
        if is_map(result["schedule"]),
          do: Map.put(response, "schedule", result["schedule"]),
          else: response

      {:ok, response}
    else
      {:error, "Task projection returned an invalid conversation_id"}
    end
  end

  defp task_create_response(_result, _command),
    do: {:error, "Task projection returned an invalid result"}

  defp put_task_create_delivery(response, result) do
    response
    |> Map.put("sent", true)
    |> Map.put("delivery_status", result["delivery_status"] || "queued")
    |> put_present("message_id", result["message_id"])
  end

  defp task_create_next_action() do
    "Continue any independent work now. Work that needs the participant response resumes when a later ordinary message arrives in this Task. Use raw IDs only in structured tool parameters and content blocks, never in visible text."
  end

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key) || Map.get(context, String.to_atom(key))

  defp stringify_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(value), do: value

  defp task_schedule_update(params) do
    command? = Map.has_key?(params, "command")
    schedule? = Map.has_key?(params, "schedule")
    command = params["command"]
    schedule = params["schedule"]

    cond do
      not command? and not schedule? ->
        {:error, "provide command and/or schedule"}

      command? and (not is_binary(command) or String.trim(command) == "") ->
        {:error, "command must be complete command text"}

      schedule? and not (is_map(schedule) or is_nil(schedule)) ->
        {:error, "schedule must be an object or null"}

      schedule? and is_nil(schedule) and command? ->
        {:error, "command cannot be changed while removing schedule"}

      true ->
        schedule =
          cond do
            is_map(schedule) -> schedule
            schedule? -> nil
            true -> %{}
          end

        schedule =
          if is_map(schedule) and command?,
            do: Map.put(schedule, "command", command),
            else: schedule

        validate_task_schedule_update(schedule)
    end
  end

  defp validate_task_schedule_update(nil), do: {:ok, nil}

  defp validate_task_schedule_update(schedule) do
    cron? = str(schedule["cron"]) != ""
    interval? = is_integer(schedule["interval_minutes"]) and schedule["interval_minutes"] > 0

    cond do
      cron? and str(schedule["timezone"]) == "" ->
        {:error,
         "schedule.timezone is required with schedule.cron; ask the user if it is unclear"}

      cron? and interval? ->
        {:error, "provide exactly one of schedule.interval_minutes or schedule.cron"}

      true ->
        {:ok, schedule}
    end
  end

  defp authorize_task_update(scope) do
    case MeetingActivationAuthorization.provenance_for_tool_context(
           scope.group_id,
           SalixIM.Provider.current_tool_context()
         ) do
      {:ok, refs} when map_size(refs) == 0 -> :ok
      {:ok, _refs} -> {:error, :meeting_activation_task_update_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  defp validate_param_keys(params, allowed, operation) do
    allowed_text =
      case allowed do
        [first, second] -> "#{first} and #{second}"
        _ -> Enum.join(allowed, ", ")
      end

    if Enum.all?(Map.keys(params), &(&1 in allowed)),
      do: :ok,
      else: {:error, "#{operation} accepts only #{allowed_text}"}
  end

  defp required_string(params, key) do
    case params[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, "#{key} is required"}, else: {:ok, value}

      _invalid ->
        {:error, "#{key} is required"}
    end
  end

  defp add_agent_participant_attrs(params, agent_id) do
    role_label = params["role_label"]

    notification_filter =
      case params["notification_filter"] do
        nil -> %{"messages" => "all", "statuses" => "none"}
        filter -> filter
      end

    cond do
      not is_nil(role_label) and not is_binary(role_label) ->
        {:error, "role_label must be a string"}

      not is_map(notification_filter) ->
        {:error, "notification_filter must be an object"}

      notification_filter["statuses"] != "none" ->
        {:error, "notification_filter.statuses must be none for Agent participants"}

      true ->
        {:ok,
         %{"agent_id" => agent_id}
         |> maybe_put("role_label", role_label && String.trim(role_label))
         |> Map.put("notification_filter", notification_filter)}
    end
  end

  defp task_list_options(params) do
    with :ok <- validate_param_keys(params, ~w(cursor limit), "im_api.internal.task.list"),
         {:ok, limit} <- task_list_limit(params),
         {:ok, cursor} <- task_list_cursor(params) do
      {:ok, [limit: limit] |> maybe_put_keyword(:cursor, cursor)}
    end
  end

  defp task_list_limit(params) do
    case Map.fetch(params, "limit") do
      :error -> {:ok, @task_list_default_limit}
      {:ok, limit} when is_integer(limit) and limit in 1..@task_list_max_limit -> {:ok, limit}
      {:ok, _invalid} -> {:error, "limit must be an integer between 1 and 1000"}
    end
  end

  defp task_list_cursor(params) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, nil}

      {:ok, cursor} when is_binary(cursor) and cursor != "" ->
        if String.length(cursor) <= @task_list_cursor_max_length,
          do: {:ok, cursor},
          else: {:error, "cursor must be a non-empty string of at most 1024 characters"}

      {:ok, _invalid} ->
        {:error, "cursor must be a non-empty string of at most 1024 characters"}
    end
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp task_list_entry(conversation) do
    task_id = conversation["conversation_id"]
    kind = conversation["kind"]

    conversation
    |> Map.take(~w(title status activity_status created_at updated_at))
    |> Map.put("task_id", task_id)
    |> Map.put("kind", kind)
    |> Map.put("task_ref", task_ref(task_id, kind))
  end

  defp task_ref(task_id, "agent_task") do
    %{
      "type" => "conversation_ref",
      "conversation_id" => task_id,
      "kind" => "agent_task",
      "presentation" => "inline"
    }
  end

  defp task_ref(task_id, kind) do
    %{
      "type" => "conversation_ref",
      "conversation_id" => task_id,
      "kind" => kind
    }
  end

  defp task_list_next_action(has_more) do
    base =
      "Each tasks[].task_ref is the authoritative locator for that internal IM resource. Only agent_task refs include presentation=inline for rich Task mentions. Choose the candidates relevant to the current decision and follow the current send-message content contract when mentioning them. If the listed facts do not establish whether a resource is the same work, read that conversation before deciding; do not decide from its title alone. Continue the exact existing Task with im_api.internal.send_message and omitted mentions; The responsible Worker and Router subscribe to ordinary Task Messages. An ordinary Message does not reopen an ended Task. Do not create a replacement Task."

    if has_more do
      base <>
        " More results remain; when more candidates are needed, call im_api.internal.task.list again with params.cursor=next_cursor and the same limit. Do not claim the list is exhaustive until has_more is false."
    else
      base
    end
  end

  defp get_conversation(group_id, conversation_id) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :not_found} -> {:error, "conversation not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp list_conversation_messages(group_id, conversation_id, opts) do
    case Conversations.list_group_conversation_messages(group_id, conversation_id, opts) do
      {:ok, messages} -> {:ok, messages}
      {:error, :not_found} -> {:error, "conversation not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp read_conversation_messages(group_id, conversation_id, "", opts),
    do: list_conversation_messages(group_id, conversation_id, opts)

  defp read_conversation_messages(group_id, conversation_id, message_id, _opts) do
    case Conversations.get_group_conversation_message(group_id, conversation_id, message_id) do
      {:ok, message} -> {:ok, [message]}
      {:error, :not_found} -> {:error, "message not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp list_conversation_participants(group_id, conversation_id, opts) do
    case Conversations.list_group_conversation_participants(group_id, conversation_id, opts) do
      {:ok, %{"participants" => participants}} -> {:ok, participants}
      {:error, :not_found} -> {:error, "conversation not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp get_conversation_participant(group_id, conversation_id, participant_id) do
    with {:ok, _conversation} <- get_conversation(group_id, conversation_id) do
      case Conversations.get_group_conversation_participant(
             group_id,
             conversation_id,
             participant_id
           ) do
        {:ok, participant} -> {:ok, participant}
        {:error, :not_found} -> {:error, "participant not found"}
        {:error, {:bad_request, "invalid participant_id"}} -> {:error, "participant not found"}
        {:error, reason} -> {:error, control_error(reason)}
      end
    end
  end

  defp public_participants(participants) do
    participants
    |> Enum.map(&public_participant/1)
    |> Enum.reject(&(str(&1["participant_id"]) == ""))
  end

  defp public_task_lifecycle(%{"kind" => "agent_task"} = conversation) do
    {:ok,
     %{
       "kind" => "agent_task",
       "mode" => "plain",
       "status" => str(conversation["status"])
     }}
  end

  defp public_task_lifecycle(_conversation), do: {:ok, nil}

  defp public_message(message) when is_map(message) do
    # Message metadata and immutable attachment refs are private delivery state.
    message
    |> Map.drop([
      "metadata",
      "owner_inline_task_refs_v1",
      ProviderRecipientIdentity.owner_field()
    ])
    |> Map.update("content", [], fn content ->
      Enum.map(content, &Map.delete(&1, "blob_ref"))
    end)
  end

  defp public_participant(participant) do
    participant_id = str(participant["participant_id"])

    %{
      "participant_id" => participant_id,
      "type" => participant_type(participant),
      "name" => participant_name(participant, participant_id)
    }
  end

  defp participant_type(participant) do
    case str(participant["actor_type"]) do
      "" -> "unknown"
      type -> type
    end
  end

  defp participant_name(participant, participant_id) do
    if str(participant["actor_type"]) == "provider" do
      "provider participant"
    else
      participant_name_value(participant, participant_id)
    end
  end

  defp participant_name_value(participant, participant_id) do
    [
      participant["name"],
      participant["display_name"],
      participant["agent_name"],
      participant["user_name"],
      participant_id
    ]
    |> Enum.map(&str/1)
    |> Enum.find(&(&1 != ""))
  end

  defp current_agent_participant(participants, agent_id) do
    candidates =
      Enum.filter(participants, fn participant ->
        participant_agent?(participant) and str(participant["agent_id"]) == agent_id
      end)

    session_id =
      SalixIM.Provider.current_tool_context()
      |> Map.get("session_id")
      |> str()

    cond do
      session_id != "" ->
        Enum.find(candidates, &(str(get_in(&1, ["payload", "session_id"])) == session_id))

      length(candidates) == 1 ->
        List.first(candidates)

      true ->
        nil
    end
  end

  defp participant_status(group_id, conversation_id, participant) do
    with {:ok, status} <-
           ConversationParticipantActivity.read(
             group_id,
             conversation_id,
             str(participant["participant_id"]),
             participant
           ) do
      {:ok, Map.delete(status, "presentation_activity")}
    end
  end

  defp maybe_put_device_id(status, participant, scope) do
    with {agent_id, session_id} <- ConversationParticipantActivity.session_ref(participant),
         {:ok, session} <- AgentDelivery.get_session(agent_id, session_id, projection: :status),
         true <- session["runtime_kind"] == "external",
         true <- session["tenant_id"] == scope.tenant_id and session["group_id"] == scope.group_id,
         provider <- session["provider"],
         true <- RuntimeIds.external_runtime_provider?(provider),
         device_id when is_binary(device_id) and device_id != "" <- session["device_id"],
         runtime_id when is_binary(runtime_id) and runtime_id != "" <- session["runtime_id"],
         expected_id = RuntimeIds.device_runtime_id(device_id, provider, runtime_id),
         true <- session["device_runtime_id"] == expected_id do
      {:ok, Map.put(status, "device_id", device_id)}
    else
      relation when relation in [nil, false, {:error, :not_found}] ->
        {:ok, status}

      _relation_error ->
        Logger.warning("participant device relation lookup failed")
        {:ok, status}
    end
  end

  defp participant_status_error(:participant_status_unavailable),
    do: "participant status is unavailable"

  defp participant_status_error(:agent_id_missing), do: "participant agent id is missing"
  defp participant_status_error(:session_id_missing), do: "participant session id is missing"
  defp participant_status_error(:session_not_found), do: "participant session was not found"
  defp participant_status_error(:runtime_unavailable), do: "session activity is unavailable"

  # willow buildIMReadState: peer/own counts, peer_reply_state, and the
  # recommendation fields (omitted when empty, like Go's omitempty).
  defp build_read_state(conversation_kind, current, participants, messages) do
    current_id = (current && str(current["participant_id"])) || ""
    observer = current_id == ""

    active_peers =
      Enum.count(participants, fn p ->
        str(p["participant_id"]) != current_id and p["state"] == "active"
      end)

    own = Enum.count(messages, &(str(&1["participant_id"]) == current_id))
    peer = length(messages) - own
    only_current = own > 0 and peer == 0

    peer_reply_state =
      cond do
        peer > 0 -> "has_peer_messages"
        active_peers > 0 -> "waiting_for_peer"
        true -> "no_peer_activity"
      end

    state = %{
      "peer_reply_state" => peer_reply_state,
      "own_message_count" => own,
      "peer_message_count" => peer,
      "active_peer_count" => active_peers,
      "only_current_participant_messages" => only_current
    }

    cond do
      task_report_for_delegator?(conversation_kind, current) and
          peer_reply_state == "has_peer_messages" ->
        Map.put(
          state,
          "recommended_next_action",
          "A worker task report is available in this task conversation. Treat it as the delegated task result."
        )

      peer_reply_state == "has_peer_messages" and observer ->
        Map.put(
          state,
          "recommended_next_action",
          "Peer messages are available. Plain assistant text stays in the runtime transcript and is not visible in this conversation. If progress, a result, or an answer should be visible, use call(tool=\"im_api.internal.send_message\", params={\"connect_id\":\"internal\",\"conversation_id\":\"...\",\"content\":[{\"type\":\"text\",\"text\":\"...\"}]}) with this conversation_id. A request to reply, report, or answer is not complete until that call succeeds; otherwise stay silent."
        )

      peer_reply_state == "has_peer_messages" ->
        Map.put(
          state,
          "recommended_next_action",
          "Peer messages are available. Plain assistant text stays in the runtime transcript and is not visible in this conversation. If progress, a result, or an answer should be visible, reply with call(tool=\"im_api.internal.send_message\", params={\"connect_id\":\"internal\",\"conversation_id\":\"...\",\"content\":[{\"type\":\"text\",\"text\":\"...\"}]}) using this conversation_id. A request to reply, report, or answer is not complete until that call succeeds; otherwise stay silent."
        )

      peer_reply_state == "waiting_for_peer" and only_current ->
        Map.put(
          state,
          "recommended_next_action",
          "No peer reply is available yet. Continue any independent work now. Work that needs the peer response resumes when a later ordinary message arrives in this conversation."
        )

      true ->
        state
    end
  end

  defp validate_conversation_update(%{} = update) do
    cond do
      invalid_conversation_update_string_field(update) ->
        {:error,
         "#{invalid_conversation_update_string_field(update)} must be a string when present"}

      invalid_conversation_update_map_field(update) ->
        {:error,
         "#{invalid_conversation_update_map_field(update)} must be a JSON object when present"}

      Map.has_key?(update, "labels") and not valid_conversation_update_labels?(update["labels"]) ->
        {:error, "labels must be an array of strings when present"}

      true ->
        trimmed = normalize_conversation_update(update)

        if map_size(trimmed) == 0 do
          {:error, "conversation update requires at least one mutable field"}
        else
          {:ok, trimmed}
        end
    end
  end

  defp validate_activation_conversation_update(
         provenance,
         %{"source_refs" => _source_refs}
       )
       when is_map(provenance) and map_size(provenance) > 0 do
    {:error, "activation-bound internal operations cannot mutate source_refs"}
  end

  defp validate_activation_conversation_update(_provenance, _conversation_update),
    do: :ok

  defp normalize_conversation_update(update) do
    string_fields =
      Enum.reduce(@conversation_update_string_fields, %{}, fn field, acc ->
        case update[field] do
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> acc
              trimmed -> Map.put(acc, field, trimmed)
            end

          _ ->
            acc
        end
      end)

    map_fields =
      Enum.reduce(@conversation_update_map_fields, string_fields, fn field, acc ->
        case update[field] do
          value when is_map(value) -> Map.put(acc, field, value)
          _ -> acc
        end
      end)

    case update["labels"] do
      labels when is_list(labels) ->
        labels =
          labels
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(map_fields, "labels", labels)

      _ ->
        map_fields
    end
  end

  defp invalid_conversation_update_string_field(update) do
    Enum.find(@conversation_update_string_fields, fn field ->
      Map.has_key?(update, field) and not (is_binary(update[field]) or is_nil(update[field]))
    end)
  end

  defp invalid_conversation_update_map_field(update) do
    Enum.find(@conversation_update_map_fields, fn field ->
      Map.has_key?(update, field) and not (is_map(update[field]) or is_nil(update[field]))
    end)
  end

  defp valid_conversation_update_labels?(labels) when is_list(labels),
    do: Enum.all?(labels, &is_binary/1)

  defp valid_conversation_update_labels?(_labels), do: false

  defp validate_inline_task_refs(content) do
    inline_refs =
      content
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and &1["presentation"] == "inline"))

    cond do
      length(inline_refs) > @inline_task_ref_limit ->
        {:error, "content exceeds the #{@inline_task_ref_limit} inline Task reference limit"}

      true ->
        inline_refs
        |> Enum.map(&canonical_inline_task_ref/1)
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, ref}, {:ok, refs} -> {:cont, {:ok, [ref | refs]}}
          {:error, reason}, _acc -> {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, refs} -> {:ok, Enum.reverse(refs)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp canonical_inline_task_ref(%{
         "type" => "conversation_ref",
         "conversation_id" => conversation_id,
         "kind" => "agent_task",
         "presentation" => "inline"
       }) do
    if Ids.valid_conversation_id?(conversation_id) do
      {:ok,
       %{
         "type" => "conversation_ref",
         "conversation_id" => conversation_id,
         "kind" => "agent_task",
         "presentation" => "inline"
       }}
    else
      {:error, "inline Task conversation_ref.conversation_id must be canonical"}
    end
  end

  defp canonical_inline_task_ref(%{"type" => "conversation_ref"}),
    do: {:error, "inline Task conversation_ref.kind must be agent_task"}

  defp canonical_inline_task_ref(_block),
    do: {:error, "inline Task presentation requires type conversation_ref"}

  defp send_message(scope, params) do
    with :ok <-
           validate_param_keys(
             params,
             @send_message_params,
             "im_api.internal.send_message"
           ),
         {:ok, activation_provenance} <-
           SalixIM.SendTiming.measure("im_send_authorize", fn ->
             MeetingActivationAuthorization.provenance_for_tool_context(
               scope.group_id,
               SalixIM.Provider.current_tool_context()
             )
           end),
         {:ok, delivery_filter} <- validate_delivery_filter(params["delivery_filter"]),
         {:ok, mentions} <- validate_mentions(params["mentions"]) do
      case str(params["conversation_id"]) do
        "" ->
          {:error, "conversation_id is required"}

        conversation_id ->
          case SalixIM.SendTiming.measure("im_send_conversation", fn ->
                 Conversations.get_group_conversation(scope.group_id, conversation_id)
               end) do
            {:ok, conversation} ->
              with {:ok, destination_provenance} <-
                     MeetingActivationAuthorization.provenance_for_conversation(conversation),
                   {:ok, effective_provenance} <-
                     MeetingActivationAuthorization.merge_provenance([
                       activation_provenance,
                       destination_provenance
                     ]),
                   {:ok, _inline_task_refs} <- validate_inline_task_refs(params["content"]) do
                internal_send(
                  scope,
                  conversation,
                  str(params["request_id"]),
                  params["content"],
                  effective_provenance,
                  delivery_filter,
                  mentions,
                  message_reply_target(params, conversation_id)
                )
              end

            {:error, :not_found} ->
              {:error, "conversation not found"}

            {:error, reason} ->
              {:error, control_error(reason)}
          end
      end
    end
  end

  # willow callInternalSendMessage → internalNativeSendMessageResult /
  # internalRoutedSendMessageToolResult (see @moduledoc for the
  # PersistedOutput / metadata divergence).
  defp internal_send(
         scope,
         conversation,
         request_id,
         content,
         activation_provenance,
         delivery_filter,
         mentions,
         {reply_field, reply_to_message_id}
       ) do
    conversation_id = conversation["conversation_id"]
    client_request_id = internal_send_client_request_id(scope, conversation_id, request_id)

    with {:ok, content} <-
           SalixIM.SendTiming.measure("im_send_attachments", fn ->
             ConversationAttachments.bind_sender_files(scope.agent_id, content)
           end) do
      attrs =
        %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => scope.agent_id,
          "content" => content
        }
        |> put_present("client_request_id", client_request_id)
        |> put_present(reply_field, reply_to_message_id)
        |> then(fn attrs ->
          SalixIM.SendTiming.measure("im_send_participant", fn ->
            put_current_conversation_participant(attrs, conversation_id, scope)
          end)
        end)
        |> put_activation_provenance_metadata(activation_provenance)
        |> put_delivery_filter(delivery_filter)
        |> put_mentions(mentions)
        |> put_egress_archive_broker()

      SalixIM.ConversationServer.append_group_conversation_agent_message(
        scope.group_id,
        conversation_id,
        scope.agent_id,
        attrs
      )
    end
    |> case do
      {:ok, %{"message_id" => message_id} = append_result} ->
        base =
          %{
            "sent" => true,
            "conversation_id" => conversation_id,
            "message_id" => message_id,
            "inserted" => append_result["inserted"] == true,
            "delivery_status" => append_result["delivery_status"] || "recorded"
          }
          |> put_egress_archive_reservation(append_result)

        cond do
          str(conversation["kind"]) in ["", "user_chat"] ->
            {:ok, base}

          true ->
            {:ok,
             SalixIM.SendTiming.measure("im_send_result", fn ->
               best_effort_routed_send_result(scope, conversation_id, message_id, base)
               |> put_terminal_task_notice(scope, conversation)
             end)}
        end

      {:error, reason} ->
        {:error, control_error(reason)}
    end
  end

  # Use the conversation already read for this send. This is advice, not a
  # lifecycle transition, and must not affect human ingress or Worker replies.
  defp put_terminal_task_notice(
         result,
         %{agent: %{"role" => "router"}},
         %{"kind" => "agent_task", "status" => status}
       )
       when status in ~w(canceled cancelled completed failed terminal) do
    Map.put(result, "task_status_notice", %{
      "status" => status,
      "message" =>
        "This task is cancelled or ended (status=#{status}). Sending this message does not reopen it. " <>
          "If you intend to continue execution, explicitly reopen the task. " <>
          "Use im_api.internal.update_conversation with status=active. " <>
          "If this message only adds information, ignore this notice."
    })
  end

  defp put_terminal_task_notice(result, _scope, _conversation), do: result

  defp put_activation_provenance_metadata(
         attrs,
         %{"meeting_activation_refs" => refs}
       )
       when is_list(refs) and refs != [],
       do: put_message_metadata(attrs, "meeting_activation_refs", refs)

  defp put_activation_provenance_metadata(attrs, _provenance), do: attrs

  defp put_delivery_filter(attrs, nil), do: attrs
  defp put_delivery_filter(attrs, filter), do: Map.put(attrs, "delivery_filter", filter)
  defp put_mentions(attrs, nil), do: attrs
  defp put_mentions(attrs, mentions), do: Map.put(attrs, "mentions", mentions)

  defp put_egress_archive_broker(attrs) do
    case SalixIM.Provider.current_tool_context()[@egress_archive_broker_key] do
      {pid, token} = broker when is_pid(pid) and is_reference(token) ->
        Map.put(attrs, @egress_archive_broker_key, broker)

      _missing ->
        attrs
    end
  end

  defp message_reply_target(params, conversation_id) do
    case Map.fetch(params, "reply_to_message_id") do
      {:ok, target} ->
        {"reply_to_message_id", target}

      :error ->
        context = SalixIM.Provider.current_tool_context()

        source =
          context_value(context, "source_message_id") ||
            List.last(tool_context_source_message_ids(context))

        target =
          case SalixIM.ConversationSourceIdentity.message_id(source, conversation_id) do
            {:ok, message_id} -> message_id
            {:error, :invalid_source_identity} -> nil
          end

        {:default_reply_to_message_id, target}
    end
  end

  defp put_egress_archive_reservation(result, append_result) do
    case append_result[@egress_archive_reservation_key] do
      nil -> result
      reservation -> Map.put(result, @egress_archive_reservation_key, reservation)
    end
  end

  defp validate_delivery_filter(nil), do: {:ok, nil}

  defp validate_delivery_filter(%{"participant_ids" => participant_ids})
       when is_list(participant_ids) and length(participant_ids) <= @delivery_filter_limit do
    if Enum.all?(participant_ids, &is_binary/1),
      do: {:ok, %{"participant_ids" => participant_ids}},
      else: {:error, "delivery_filter.participant_ids must be an array of participant IDs"}
  end

  defp validate_delivery_filter(_other),
    do: {:error, "delivery_filter.participant_ids must be an array of participant IDs"}

  defp validate_mentions(nil), do: {:ok, nil}

  defp validate_mentions(%{"participant_ids" => participant_ids})
       when is_list(participant_ids) and length(participant_ids) <= @delivery_filter_limit do
    if Enum.all?(participant_ids, &is_binary/1),
      do: {:ok, %{"participant_ids" => participant_ids}},
      else: {:error, "mentions.participant_ids must be an array of participant IDs"}
  end

  defp validate_mentions(_other),
    do: {:error, "mentions.participant_ids must be an array of participant IDs"}

  defp put_current_conversation_participant(attrs, conversation_id, scope) do
    participant_ids =
      SalixIM.Provider.current_tool_context()
      |> tool_context_source_message_ids()
      |> Enum.flat_map(fn source_message_id ->
        case group_conversation_source_identity(source_message_id, conversation_id) do
          {_message_id, participant_id} -> [participant_id]
          nil -> []
        end
      end)
      |> Enum.uniq()

    participant_id =
      case participant_ids do
        [participant_id] -> participant_id
        [] -> current_tool_session_participant_id(scope, conversation_id)
        _ -> nil
      end

    if is_binary(participant_id),
      do: Map.put(attrs, "participant_id", participant_id),
      else: attrs
  end

  defp current_tool_session_participant_id(scope, conversation_id) do
    case list_conversation_participants(scope.group_id, conversation_id, []) do
      {:ok, participants} ->
        case current_agent_participant(participants, scope.agent_id) do
          %{"participant_id" => participant_id} -> participant_id
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  # The Group conversation whose message woke this turn: the chat then offers
  # the confirmation in place. A turn without a decodable source (a schedule,
  # an external wake) files the proposal for Settings › Labels alone.
  defp proposal_source_conversation_id(group_id, tool_context) do
    tool_context
    |> tool_context_source_message_ids()
    |> Enum.find_value(fn source_message_id ->
      with {:ok, conversation_id} <-
             SalixIM.ConversationSourceIdentity.conversation_id(source_message_id),
           {:ok, _conversation} <-
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id) do
        conversation_id
      else
        _ -> nil
      end
    end)
  end

  defp tool_context_source_message_ids(tool_context) do
    source_message_ids =
      case Map.get(tool_context, "source_message_ids") do
        message_ids when is_list(message_ids) -> message_ids
        _missing -> []
      end

    (source_message_ids ++ [Map.get(tool_context, "source_message_id")])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp group_conversation_source_identity(source_message_id, conversation_id) do
    case SalixIM.ConversationSourceIdentity.decode(source_message_id, conversation_id) do
      {:ok, %{message_id: message_id, participant_id: participant_id}} ->
        {message_id, participant_id}

      {:error, :invalid_source_identity} ->
        nil
    end
  end

  defp put_message_metadata(attrs, key, value) do
    metadata = Map.get(attrs, "metadata", %{})
    Map.put(attrs, "metadata", Map.put(metadata, key, value))
  end

  defp internal_send_client_request_id(scope, conversation_id, idempotency_key) do
    cond do
      presence(idempotency_key) != nil ->
        namespaced_message_id(scope, conversation_id, "request", idempotency_key)

      presence(scope[:tool_call_id]) != nil ->
        namespaced_message_id(scope, conversation_id, "tool", scope[:tool_call_id])

      true ->
        nil
    end
  end

  defp namespaced_message_id(scope, conversation_id, source, value) do
    material =
      [
        "internal.send_message",
        source,
        scope.group_id,
        conversation_id,
        scope.agent_id,
        value
      ]
      |> Enum.map(&str/1)
      |> Enum.join("\0")

    "internal-send-" <> short_hash(material)
  end

  defp short_hash(material) do
    :crypto.hash(:sha256, material)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end

  # willow internalRoutedSendMessageToolResult; recipients derive from the
  # non-sender participants (Salix has no IM delivery rows — @moduledoc).
  defp routed_send_result(agent_id, participants, base, target_ids) do
    Map.merge(base, %{
      "recipients" => routed_recipients(agent_id, participants, target_ids),
      "peer_has_replied" => false,
      "peer_reply_state" => "pending",
      "recommended_next_action" =>
        "The message was routed asynchronously to the listed recipients. Later ordinary messages in this conversation will wake this session if they require follow-up."
    })
  end

  defp best_effort_routed_send_result(scope, conversation_id, message_id, base) do
    with {:ok, participants} <-
           list_conversation_participants(scope.group_id, conversation_id, []),
         {:ok, target_ids} <-
           routed_target_ids(scope.group_id, conversation_id, message_id) do
      routed_send_result(scope.agent_id, participants, base, target_ids)
    else
      {:error, _reason} -> routed_send_result(scope.agent_id, [], base, [])
    end
  end

  defp routed_recipients(agent_id, participants, target_ids) do
    participants
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> maybe_filter_recipient_ids(target_ids)
    |> Enum.reject(fn p ->
      participant_agent?(p) and str(p["agent_id"]) == agent_id
    end)
    |> Enum.map(fn p ->
      %{"participant_id" => p["participant_id"]}
      |> put_present("agent_id", p["agent_id"])
      |> put_present("agent_name", p["agent_name"])
      |> put_present("role_label", p["role_label"])
    end)
  end

  defp maybe_filter_recipient_ids(participants, nil), do: participants

  defp maybe_filter_recipient_ids(participants, target_ids) do
    target_ids = MapSet.new(target_ids)
    Enum.filter(participants, &MapSet.member?(target_ids, &1["participant_id"]))
  end

  defp routed_target_ids(group_id, conversation_id, message_id) do
    with {:ok, message} <-
           Conversations.get_group_conversation_message(group_id, conversation_id, message_id) do
      case get_in(message, ["delivery_filter", "participant_ids"]) do
        nil -> {:ok, nil}
        participant_ids when is_list(participant_ids) -> {:ok, participant_ids}
        _ -> {:error, "persisted delivery filter is invalid"}
      end
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp participant_agent?(participant), do: participant["actor_type"] == "agent"

  defp task_report_for_delegator?(conversation_kind, current),
    do:
      str(conversation_kind) == "agent_task" and is_map(current) and
        str(current["role_label"]) == "delegator"
end
