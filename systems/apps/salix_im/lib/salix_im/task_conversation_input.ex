defmodule SalixIM.TaskConversationInput do
  @moduledoc """
  Product input adapter for canonical Task conversations.

  It resolves group, agent, provenance, participant, and initial-message facts
  before sending the bounded Task materialization command through
  `ConversationServer`.
  """

  require Logger

  alias SalixIM.{
    ConversationInput,
    ConversationServer,
    Conversations,
    GroupDirectory,
    ProviderConversationInput
  }

  alias SalixStore.Ids

  def create_with_id(
        group_id,
        conversation_id,
        delegator_agent_id,
        worker_agent_id,
        attrs,
        opts \\ []
      )
      when is_map(attrs) do
    attrs = stringify(attrs)
    schedule = attrs["schedule"]
    content = trim(attrs["content"])

    with true <- content != "",
         :ok <- validate_schedule(schedule, content),
         initial when is_map(initial) <- attrs["initial_message_attrs"],
         {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, delegator} <- task_agent(delegator_agent_id, group_id),
         {:ok, worker} <- worker_agent(worker_agent_id, group_id),
         source_refs <- stringify(attrs["source_refs"] || %{}),
         {:ok, investigation} <-
           SalixIM.Triage.Investigation.creation(
             group_id,
             delegator_agent_id,
             worker_agent_id,
             attrs
           ),
         :ok <- validate_parent_refs(group_id, source_refs),
         {:ok, owner_user_id} <- owner_user_id(group_id, attrs, source_refs),
         now <- System.system_time(:millisecond),
         conversation <-
           task_conversation(
             group_id,
             conversation_id,
             attrs["title"],
             worker,
             schedule,
             now,
             %{
               "created_by_agent_id" => delegator_agent_id,
               "owner_user_id" => owner_user_id,
               "source_refs" => source_refs,
               "metadata" => stringify(attrs["conversation_metadata"] || %{}),
               "labels" => attrs["labels"],
               "latest_artifact" => attrs["latest_artifact"],
               "artifact_manifest" => attrs["artifact_manifest"]
             }
           ),
         {:ok, delegator_participant} <-
           task_agent_participant(
             group,
             conversation,
             delegator,
             "delegator",
             now,
             origin_session_id: attrs["origin_session_id"],
             notification_filter:
               cond do
                 investigation != nil -> %{"messages" => "none", "statuses" => "none"}
                 true -> %{"messages" => "all", "statuses" => "none"}
               end
           ),
         {:ok, worker_participant} <-
           task_agent_participant(group, conversation, worker, "worker", now, []),
         participants <-
           SalixIM.Triage.Investigation.result_participants(investigation, now) ++
             owner_participants(owner_user_id, now) ++
             personal_status_participants(group_id, now) ++
             [delegator_participant, worker_participant],
         {:ok, appended} <-
           ConversationServer.create_task(
             group_id,
             conversation_id,
             %{
               "conversation" => Map.put(conversation, "participants", participants),
               "worker_agent_id" => worker_agent_id,
               "delegator_agent_id" => delegator_agent_id,
               "initial_message" => initial,
               "initial_delivery" => Keyword.get(opts, :initial_delivery, :command)
             }
           ) do
      {:ok,
       appended
       |> Map.merge(%{
         "conversation_id" => conversation["conversation_id"],
         "conversation_kind" => "agent_task",
         "worker_agent_id" => worker_agent_id,
         "schedule" => schedule
       })}
    else
      false -> {:error, {:bad_request, "task command and canonical identity are required"}}
      nil -> {:error, {:bad_request, "task conversation initial message is missing"}}
      {:error, _reason} = error -> error
    end
  end

  def ensure_with_id(
        group_id,
        conversation_id,
        worker_agent_id,
        %{"title" => title, "command" => command, "created_at" => created_at} = materialization
      )
      when map_size(materialization) == 3 and is_binary(title) and is_binary(command) and
             is_integer(created_at) do
    with true <- Ids.valid_conversation_id?(conversation_id) and trim(title) != "",
         {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, worker} <- worker_agent(worker_agent_id, group_id),
         conversation <-
           task_conversation(
             group_id,
             conversation_id,
             title,
             worker,
             %{"schedule_id" => nil, "command" => command},
             created_at,
             %{"task_materialization" => materialization}
           ),
         {:ok, worker_participant} <-
           task_agent_participant(
             group,
             conversation,
             worker,
             "worker",
             created_at,
             notification_filter: %{"messages" => "all", "statuses" => "none"}
           ),
         {:ok, result} <-
           ConversationServer.create_task(
             group_id,
             conversation_id,
             %{
               "conversation" =>
                 conversation
                 |> Map.put("participants", [worker_participant])
                 |> Map.delete("task_materialization"),
               "worker_agent_id" => worker_agent_id,
               "materialization" => materialization
             }
           ) do
      {:ok, result}
    else
      false -> task_conflict()
      {:error, _reason} = error -> error
    end
  end

  def ensure_with_id(_group_id, _conversation_id, _worker_agent_id, _materialization),
    do: {:error, {:bad_request, "invalid task materialization"}}

  defp task_conversation(group_id, conversation_id, title, worker, schedule, created_at, extras) do
    worker_name =
      case trim(worker["name"]) do
        "" -> trim(worker["agent_id"])
        name -> name
      end

    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "title" => if(trim(title) == "", do: "Task for " <> worker_name, else: trim(title)),
      "status" => "active",
      "activity_status" => "idle",
      "schedule" => schedule,
      "created_at" => created_at,
      "updated_at" => created_at
    }
    |> Map.merge(extras)
    |> Map.reject(fn {_key, value} -> value in [nil, "", %{}] end)
  end

  defp task_agent(agent_id, group_id) do
    with {:ok, %{"group_id" => ^group_id} = agent} <- GroupDirectory.get_agent(agent_id) do
      {:ok, agent}
    else
      {:ok, _agent} -> {:error, {:bad_request, "task agent is outside the group"}}
      {:error, _reason} = error -> error
    end
  end

  defp worker_agent(agent_id, group_id) do
    with {:ok, agent} <- task_agent(agent_id, group_id),
         true <- agent["role"] != "router" do
      {:ok, agent}
    else
      false -> {:error, {:bad_request, "router cannot be a Task command target"}}
      {:error, _reason} = error -> error
    end
  end

  defp task_agent_participant(group, conversation, agent, role_label, now, opts) do
    notification_filter =
      Keyword.get(opts, :notification_filter, %{
        "messages" => "all",
        "statuses" => "none"
      })

    participant = %{
      "actor_type" => "agent",
      "agent_id" => agent["agent_id"],
      "agent_name" => agent["name"],
      "role_label" => role_label,
      "state" => "active",
      "notification_filter" => notification_filter,
      "created_at" => now,
      "updated_at" => now
    }

    ConversationInput.prepare_agent_for_create(
      group["group_id"],
      conversation,
      participant,
      opts
    )
  end

  defp owner_participants(value, now) when is_binary(value) and value != "" do
    [
      %{
        "actor_type" => "user",
        "user_id" => value,
        "role_label" => "requester",
        "state" => "active",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"},
        "created_at" => now,
        "updated_at" => now
      }
    ]
  end

  defp owner_participants(_value, _now), do: []

  # The product adapter names the owner's bound personal chat, if any. Cards
  # are an accessory to the Task: a lookup failure never blocks its creation.
  defp personal_status_participants(group_id, now) do
    with module when is_atom(module) and not is_nil(module) <-
           Application.get_env(:salix_im, :task_status_personal_adapter),
         targets when is_list(targets) <- module.task_status_targets(group_id) do
      for target <- targets, is_map(target) do
        target
        |> ProviderConversationInput.provider_participant(%{
          "role_label" => "task_status_personal",
          "notification_filter" => %{
            "messages" => "none",
            # Intermediate states retire the previous attention card before re-entry.
            "statuses" => "all"
          }
        })
        |> Map.merge(%{"created_at" => now, "updated_at" => now})
      end
    else
      _ -> []
    end
  rescue
    error ->
      Logger.warning("Task status card destination unavailable",
        group_id: group_id,
        reason: Exception.message(error)
      )

      []
  end

  defp owner_user_id(group_id, attrs, source_refs) do
    case trim(attrs["owner_user_id"]) do
      "" ->
        case trim(source_refs["parent_conversation_id"]) do
          "" ->
            {:ok, nil}

          parent_id ->
            case Conversations.get_group_conversation(group_id, parent_id) do
              {:ok, parent} -> {:ok, blank_to_nil(parent["owner_user_id"])}
              {:error, _reason} = error -> error
            end
        end

      owner_user_id ->
        {:ok, owner_user_id}
    end
  end

  defp validate_parent_refs(group_id, source_refs) do
    parent_id = trim(source_refs["parent_conversation_id"])
    message_id = trim(source_refs["parent_message_id"])

    cond do
      parent_id == "" and message_id == "" ->
        :ok

      not Ids.valid_conversation_id?(parent_id) ->
        {:error, {:bad_request, "parent_conversation_id must be canonical"}}

      message_id != "" and not Ids.valid_message_id?(message_id) ->
        {:error, {:bad_request, "parent_message_id must be canonical"}}

      true ->
        with {:ok, _parent} <- Conversations.get_group_conversation(group_id, parent_id),
             :ok <- validate_parent_message(group_id, parent_id, message_id) do
          :ok
        end
    end
  end

  defp validate_parent_message(_group_id, _parent_id, ""), do: :ok

  defp validate_parent_message(group_id, parent_id, message_id) do
    case Conversations.get_group_conversation_message(group_id, parent_id, message_id) do
      {:ok, _message} ->
        :ok

      {:error, :not_found} ->
        {:error, {:bad_request, "parent_message_id does not belong to parent_conversation_id"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_schedule(
         %{"schedule_id" => schedule_id, "command" => command} = schedule,
         content
       )
       when map_size(schedule) == 2 and command == content do
    if is_nil(schedule_id) or Ids.valid_schedule_id?(schedule_id),
      do: :ok,
      else: {:error, {:bad_request, "invalid task schedule mapping"}}
  end

  defp validate_schedule(_schedule, _content),
    do: {:error, {:bad_request, "task schedule must match the complete command"}}

  defp task_conflict,
    do: {:error, {:conflict, "conversation_id is already assigned to another task"}}

  defp blank_to_nil(value), do: if(trim(value) == "", do: nil, else: trim(value))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
