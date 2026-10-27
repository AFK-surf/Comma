defmodule SalixCluster.TaskSchedules do
  @moduledoc """
  Task binding and receiver for the shared Schedule store.

  Recurrence and run state remain in `SalixCluster.Schedules`. A scheduled
  Task stores the returned Schedule id and its command together under the
  Task's `schedule` property. When a Schedule fires, this receiver forwards
  the Task identity to its conversation owner.

  The owner answers with the Task's standing for that window. `fired` appended
  the command. `paused` means the Task is not `active` but has not ended
  (`escalated`, `failed`, `ready_for_review`): the window is skipped, the
  anchor advances, and the next window asks again, so a Task that returns to
  `active` fires on its next occurrence. `settled` (the Schedule is bound to
  another Task), `inactive` (the Task ended or unbound the Schedule) and a
  missing Task end the definition: `receive/3` deletes it and logs
  `task_schedule_deleted` with the reason. A Task that ended while still bound
  to the Schedule is unbound through `update_task_schedule/3` in the same
  step, so its record never points at a deleted definition.

  A binding whose definition is gone (`Schedules.get/1` answers `:not_found`)
  is rebuilt by `update_task_schedule/3` with the recurrence: the Task keeps
  its `schedule_id` and the definition is created under it again.
  """

  require Logger

  alias SalixCluster.Schedules

  alias SalixIM.{
    ConversationServer,
    Conversations,
    TaskCalendarChanges,
    TaskConversationInput
  }

  alias SalixStore.Ids

  @binding_fields ~w(interval_minutes cron timezone)

  def create_task_conversation(group_id, delegator_agent_id, target_agent_id, attrs)
      when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, command} <- command(attrs["content"]),
         {:ok, conversation_id, attrs} <-
           ConversationServer.reserve_task_conversation(
             group_id,
             delegator_agent_id,
             target_agent_id,
             attrs
           ),
         {:ok, schedule} <-
           schedule_for_task_create(
             group_id,
             conversation_id,
             attrs["schedule"],
             command
           ) do
      initial_message = initial_task_message(conversation_id, delegator_agent_id, attrs, schedule)

      case TaskConversationInput.create_with_id(
             group_id,
             conversation_id,
             delegator_agent_id,
             target_agent_id,
             attrs
             |> Map.put("schedule", schedule)
             |> Map.put("initial_message_attrs", initial_message)
           ) do
        {:ok, result} ->
          finish_task_create(
            group_id,
            conversation_id,
            schedule,
            attrs["schedule"],
            result
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp finish_task_create(group_id, conversation_id, schedule, schedule_attrs, result) do
    case ensure_schedule_definition(
           group_id,
           conversation_id,
           schedule,
           schedule_attrs
         ) do
      :ok ->
        publish_calendar_change(group_id, conversation_id)
        {:ok, result}

      {:error, reason} = error ->
        if result["inserted"] == true do
          compensate_failed_task_create(group_id, conversation_id, reason)
        else
          error
        end
    end
  end

  defp compensate_failed_task_create(group_id, conversation_id, schedule_error) do
    case delete_conversation(group_id, conversation_id) do
      :ok ->
        {:error, schedule_error}

      {:error, compensation_error} ->
        {:error,
         {:task_schedule_create_recoverable,
          %{
            "conversation_id" => conversation_id,
            "schedule_error" => schedule_error,
            "compensation_error" => compensation_error
          }}}
    end
  end

  def update_task_schedule(group_id, conversation_id, nil) do
    with {:ok, conversation} <- task_conversation(group_id, conversation_id),
         {:ok, %{"schedule_id" => schedule_id} = current} <- active_schedule(conversation),
         next <- Map.put(current, "schedule_id", nil),
         {:ok, updated} <-
           ConversationServer.replace_task_schedule(
             group_id,
             conversation_id,
             current,
             next
           ) do
      _ = delete(group_id, conversation_id, schedule_id)
      publish_calendar_change(group_id, conversation_id)
      {:ok, updated}
    end
  end

  def update_task_schedule(group_id, conversation_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, conversation} <- task_conversation(group_id, conversation_id),
         {:ok, command} <- schedule_command(conversation["schedule"], attrs),
         {:ok, schedule_id} <-
           schedule_id_for_update(
             group_id,
             conversation_id,
             conversation["schedule"],
             attrs
           ),
         schedule <- %{"schedule_id" => schedule_id, "command" => command},
         {:ok, updated} <-
           ConversationServer.replace_task_schedule(
             group_id,
             conversation_id,
             conversation["schedule"],
             schedule
           ),
         :ok <-
           ensure_schedule_definition(
             group_id,
             conversation_id,
             schedule,
             attrs
           ) do
      publish_calendar_change(group_id, conversation_id)
      {:ok, updated}
    end
  end

  def update_conversation(group_id, conversation_id, %{"schedule" => schedule} = attrs)
      when map_size(attrs) == 1,
      do: update_task_schedule(group_id, conversation_id, schedule)

  def update_conversation(group_id, conversation_id, attrs) when is_map(attrs) do
    with {:ok, updated} <-
           ConversationServer.update_group_conversation(group_id, conversation_id, attrs) do
      if updated["kind"] == "agent_task", do: publish_calendar_change(group_id, conversation_id)
      {:ok, updated}
    end
  end

  def delete_conversation(group_id, conversation_id) do
    with {:ok, conversation} <- Conversations.get_group_conversation(group_id, conversation_id),
         {:ok, conversation} <- unlink_schedule_for_delete(group_id, conversation),
         :ok <- ConversationServer.delete_group_conversation(group_id, conversation_id) do
      if conversation["kind"] == "agent_task" do
        tombstone =
          conversation
          |> Map.put("status", "terminal")
          |> Map.put(
            "updated_at",
            max(
              SystemsClock.system_time(:millisecond),
              (conversation["updated_at"] || conversation["created_at"] || 0) + 1
            )
          )

        _ = TaskCalendarChanges.record(tombstone, nil)
      end

      :ok
    end
  end

  defp unlink_schedule_for_delete(
         group_id,
         %{"kind" => "agent_task", "schedule" => %{"schedule_id" => schedule_id} = current} =
           conversation
       )
       when is_binary(schedule_id) and schedule_id != "" do
    replacement = Map.put(current, "schedule_id", nil)

    with {:ok, _updated} <-
           ConversationServer.replace_task_schedule(
             group_id,
             conversation["conversation_id"],
             current,
             replacement
           ) do
      _ = delete(group_id, conversation["conversation_id"], schedule_id)
      {:ok, conversation}
    end
  end

  defp unlink_schedule_for_delete(_group_id, conversation), do: {:ok, conversation}

  def page(group_id, opts \\ []) do
    limit = opts[:limit] || 100

    with :ok <-
           TaskCalendarChanges.repair_current_states(
             group_id,
             limit,
             &calendar_projection/3
           ) do
      TaskCalendarChanges.page(group_id, opts)
    end
  end

  defp update_definition(schedule, changes) when map_size(changes) == 0, do: {:ok, schedule}
  defp update_definition(schedule, changes), do: Schedules.update(schedule["id"], changes)

  defp schedule_id_for_update(group_id, conversation_id, current, attrs) do
    case current do
      %{"schedule_id" => schedule_id}
      when is_binary(schedule_id) and schedule_id != "" ->
        changes = Map.take(attrs, @binding_fields)

        case owned_schedule(group_id, conversation_id, schedule_id) do
          {:ok, definition} ->
            with :ok <- Schedules.validate_definition_update(definition, changes) do
              {:ok, schedule_id}
            end

          {:error, :not_found} ->
            with :ok <-
                   attrs
                   |> schedule_params(group_id, conversation_id)
                   |> Schedules.validate_definition() do
              {:ok, schedule_id}
            end

          {:error, _reason} = error ->
            error
        end

      _ ->
        schedule_id = Ids.new_schedule_id()

        with :ok <-
               attrs
               |> schedule_params(group_id, conversation_id)
               |> Schedules.validate_definition() do
          {:ok, schedule_id}
        end
    end
  end

  defp ensure_schedule_definition(
         _group_id,
         _conversation_id,
         %{"schedule_id" => nil},
         _attrs
       ),
       do: :ok

  defp ensure_schedule_definition(
         group_id,
         conversation_id,
         %{"schedule_id" => schedule_id},
         attrs
       )
       when is_binary(schedule_id) and schedule_id != "" and is_map(attrs) do
    changes = Map.take(attrs, @binding_fields)

    case owned_schedule(group_id, conversation_id, schedule_id) do
      {:ok, definition} ->
        with {:ok, _updated} <- update_definition(definition, changes), do: :ok

      {:error, :not_found} ->
        params = schedule_params(attrs, group_id, conversation_id)

        case Schedules.create(schedule_id, params) do
          {:ok, _definition} ->
            :ok

          {:error, :already_exists} ->
            with {:ok, definition} <- owned_schedule(group_id, conversation_id, schedule_id),
                 true <- Map.take(definition, @binding_fields) == changes do
              :ok
            else
              false -> {:error, :task_schedule_changed}
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp schedule_params(attrs, group_id, conversation_id) do
    attrs
    |> Map.take(@binding_fields)
    |> Map.merge(%{
      "receiver" => "task",
      "payload" => %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id
      }
    })
  end

  defp normalize_delete(:ok), do: :ok
  defp normalize_delete({:error, :not_found}), do: :ok
  defp normalize_delete(other), do: other

  @doc false
  def delete(group_id, conversation_id, id) do
    case owned_schedule(group_id, conversation_id, id) do
      # Idempotent: an already-deleted (or never-owned) definition is :ok.
      {:ok, _schedule} -> normalize_delete(Schedules.delete_task_owned(id, group_id))
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  @doc "Return the bounded public Schedule projection used by the Calendar Task source."
  def calendar_projection(group_id, conversation_id, %{"schedule_id" => schedule_id})
      when is_binary(schedule_id) and schedule_id != "" do
    with {:ok, schedule} <- owned_schedule(group_id, conversation_id, schedule_id) do
      recurrence_anchor = Schedules.next_fire_ms(Map.put(schedule, "last_run", nil))

      {:ok,
       schedule
       |> Map.take(~w(id receiver interval_minutes cron timezone created_at last_run payload))
       |> Map.put("recurrence_anchor_at", recurrence_anchor)
       |> Map.put("next_fire_at", Schedules.next_fire_ms(schedule))}
    end
  end

  def calendar_projection(_group_id, _conversation_id, _schedule), do: {:ok, nil}

  @doc "Receive one claimed Task Schedule window by notifying its Task owner."
  def receive(payload, status, opts) when status in [:claimed, :exists] do
    group_id = payload["agent_group_id"] || payload[:agent_group_id]
    conversation_id = payload["conversation_id"] || payload[:conversation_id]
    schedule_id = Keyword.fetch!(opts, :schedule_id)
    scheduled_for_ms = Keyword.fetch!(opts, :scheduled_for)

    ConversationServer.notify_task_schedule(
      group_id,
      conversation_id,
      schedule_id,
      scheduled_for_ms,
      now: opts[:now] || SystemsClock.system_time(:millisecond)
    )
    |> case do
      {:ok, %{"task_schedule_status" => "fired"}} ->
        {:ok, :fired}

      {:ok, %{"task_schedule_status" => "paused"} = reply} ->
        Logger.info(
          "Task Schedule window skipped: Task is #{reply["task_status"]}, not active group=#{group_id} conversation=#{conversation_id} schedule=#{schedule_id}",
          event: "task_schedule_paused",
          component: "salix_cluster",
          group_id: group_id,
          conversation_id: conversation_id,
          schedule_id: schedule_id,
          task_status: reply["task_status"],
          scheduled_for: scheduled_for_ms
        )

        {:ok, :paused}

      {:ok, %{"task_schedule_status" => "settled"}} ->
        delete_ended(group_id, conversation_id, schedule_id, "settled")
        {:ok, :settled}

      {:ok, %{"task_schedule_status" => "inactive"}} ->
        unbind_ended(group_id, conversation_id, schedule_id)
        {:ok, :inactive}

      {:error, :not_found} ->
        delete_ended(group_id, conversation_id, schedule_id, "not_found")
        {:ok, :inactive}

      {:error, _reason} = error ->
        error

      other ->
        {:error, other}
    end
  end

  def receive(_payload, {:error, reason}, _opts), do: {:error, reason}

  # The Task ended (completed, cancelled, archived) or unbound this Schedule.
  # A Task still bound to it is unbound through the ordinary path, which
  # replaces the binding under the owner's compare-and-swap and then deletes
  # the definition, so the record never keeps a `schedule_id` without a
  # definition. A Task bound to another Schedule keeps that binding.
  defp unbind_ended(group_id, conversation_id, schedule_id) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, %{"schedule" => %{"schedule_id" => ^schedule_id}}} ->
        case update_task_schedule(group_id, conversation_id, nil) do
          {:ok, _updated} ->
            log_deleted(group_id, conversation_id, schedule_id, "inactive", :ok, true)

          {:error, _reason} = error ->
            # The binding moved under us: delete only the definition.
            result = delete(group_id, conversation_id, schedule_id)

            log_deleted(
              group_id,
              conversation_id,
              schedule_id,
              "inactive",
              {error, result},
              false
            )
        end

      _not_bound_here ->
        delete_ended(group_id, conversation_id, schedule_id, "inactive")
    end
  end

  # The Schedule is bound to another Task, or its Task is gone: the definition
  # has no Task to fire for.
  defp delete_ended(group_id, conversation_id, schedule_id, reason) do
    result = delete(group_id, conversation_id, schedule_id)
    log_deleted(group_id, conversation_id, schedule_id, reason, result, false)
  end

  # Log each deletion so a Schedule that stopped firing can be explained later.
  defp log_deleted(group_id, conversation_id, schedule_id, reason, result, unbound) do
    Logger.info(
      "Task Schedule deleted: #{reason} group=#{group_id} conversation=#{conversation_id} schedule=#{schedule_id} unbound=#{unbound} result=#{inspect(result)}",
      event: "task_schedule_deleted",
      component: "salix_cluster",
      group_id: group_id,
      conversation_id: conversation_id,
      schedule_id: schedule_id,
      reason: reason,
      unbound: unbound,
      delete_result: inspect(result)
    )

    result
  end

  defp schedule_for_task_create(group_id, conversation_id, raw_schedule, command) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, %{"kind" => "agent_task", "schedule" => schedule}} when is_map(schedule) ->
        {:ok, schedule}

      {:ok, _conversation} ->
        {:error, {:conflict, "conversation_id is already assigned to another task"}}

      {:error, :not_found} ->
        with {:ok, reference} <-
               prepare_optional_schedule(group_id, conversation_id, raw_schedule) do
          {:ok, task_schedule(reference, command)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_optional_schedule(_group_id, _conversation_id, nil), do: {:ok, nil}

  defp prepare_optional_schedule(group_id, conversation_id, attrs) when is_map(attrs) do
    schedule_id = Ids.new_schedule_id()

    with :ok <-
           attrs
           |> schedule_params(group_id, conversation_id)
           |> Schedules.validate_definition() do
      {:ok, %{"schedule_id" => schedule_id}}
    end
  end

  defp prepare_optional_schedule(_group_id, _conversation_id, _attrs),
    do: {:error, {:bad_request, "schedule must be a JSON object"}}

  defp task_schedule(nil, command), do: %{"schedule_id" => nil, "command" => command}

  defp task_schedule(%{"schedule_id" => schedule_id}, command),
    do: %{"schedule_id" => schedule_id, "command" => command}

  defp initial_task_message(conversation_id, delegator_agent_id, attrs, schedule) do
    %{
      "kind" => "message",
      "content" => initial_task_content(schedule["command"], schedule["schedule_id"]),
      "metadata" => initial_task_metadata(attrs, schedule["schedule_id"]),
      "client_request_id" => "delegate-task-" <> conversation_id,
      "created_at" => SystemsClock.system_time(:millisecond)
    }
    |> Map.merge(initial_author(delegator_agent_id, attrs))
  end

  # The person who asked writes the first Message when the words are theirs
  # (`"initial_author" => "owner"`, a model mention in Home); otherwise the
  # delegating Agent does.
  defp initial_author(_delegator_agent_id, %{"initial_author" => "owner", "owner_user_id" => user})
       when is_binary(user) and user != "",
       do: %{"actor_type" => "user", "user_id" => user}

  defp initial_author(delegator_agent_id, _attrs),
    do: %{"actor_type" => "agent", "agent_id" => delegator_agent_id}

  # Modeled in tla/salix/ScheduledTaskDryRunUpgrade.tla. This structured
  # envelope is deliberately self-contained in Message content.
  # An older participant-delivery owner forwards it verbatim and therefore still
  # observes the dry-run fence during a rolling deploy or rollback. Its only
  # natural-language value is the Router-authored production command; the other
  # values are stable schema keys, enums, and booleans.
  defp initial_task_content(command, schedule_id)
       when is_binary(schedule_id) and schedule_id != "" do
    [
      {"format", "scheduled_task_initial/v1"},
      {"mode", "read_only_validation"},
      {"production_command", command},
      {"execute_production_command", false},
      {"external_side_effects", false},
      {"forbidden_operations",
       [
         "issue_create_or_update",
         "repository_write",
         "team_message_send",
         "deployment",
         "permission_change",
         "destructive_operation"
       ]},
      {"allowed_operations", ["read_only_discovery", "read_only_validation"]},
      {"required_report", ["planned_checks", "completed_validation", "results", "blockers"]},
      {"claim_production_completed", false}
    ]
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp initial_task_content(command, _schedule_id), do: command

  defp initial_task_metadata(attrs, schedule_id) do
    metadata =
      attrs
      |> Map.get("metadata", %{})
      |> stringify()
      |> put_optional("source_session_id", attrs["origin_session_id"])
      |> put_optional("origin_session_id", attrs["origin_session_id"])
      |> Map.put("message_type", "task_command")

    if is_binary(schedule_id) and schedule_id != "",
      do: Map.put(metadata, "task_schedule", %{"dry_run" => true, "schedule_id" => schedule_id}),
      else: metadata
  end

  defp schedule_command(schedule, attrs) when is_map(schedule) do
    command(attrs["command"] || schedule["command"])
  end

  defp schedule_command(_schedule, %{"command" => command}), do: command(command)

  defp schedule_command(_schedule, _attrs),
    do: {:error, {:bad_request, "schedule.command is required when adding a Schedule"}}

  defp command(command) when is_binary(command) do
    case String.trim(command) do
      "" -> {:error, {:bad_request, "schedule.command must be complete command text"}}
      command -> {:ok, command}
    end
  end

  defp command(_command),
    do: {:error, {:bad_request, "schedule.command must be complete command text"}}

  defp task_conversation(group_id, conversation_id) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, %{"kind" => "agent_task"} = conversation} -> {:ok, conversation}
      {:ok, _conversation} -> {:error, {:bad_request, "schedule is only supported on agent_task"}}
      other -> other
    end
  end

  defp active_schedule(%{"schedule" => %{"schedule_id" => id} = schedule})
       when is_binary(id) and id != "",
       do: {:ok, schedule}

  defp active_schedule(_conversation), do: {:error, :task_schedule_not_found}

  defp publish_calendar_change(group_id, conversation_id) do
    with {:ok, conversation} <- task_conversation(group_id, conversation_id),
         {:ok, definition} <-
           calendar_projection(group_id, conversation_id, conversation["schedule"]),
         {:ok, _change} <- TaskCalendarChanges.record(conversation, definition) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Task Calendar projection deferred group=#{group_id} conversation=#{conversation_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp put_optional(map, _key, value) when value in [nil, ""], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp owned_schedule(group_id, conversation_id, id) do
    with {:ok, schedule} <- Schedules.get(id),
         %{
           "receiver" => "task",
           "payload" => %{
             "agent_group_id" => ^group_id,
             "conversation_id" => ^conversation_id
           }
         } <- schedule do
      {:ok, schedule}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :not_found}
    end
  end
end
