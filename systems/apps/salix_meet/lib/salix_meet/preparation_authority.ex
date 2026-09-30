defmodule SalixMeet.PreparationAuthority do
  @moduledoc "Organization authority for one live meeting research assignment."

  # FORMAL-SPEC: VerifiedKernel.IFC.System.Gates.commandScope.
  # Current assignment and revocation checks discharge this host obligation.
  # Runtime tests cover cleanup after revocation; Lean does not prove this adapter.

  alias SalixIM.{Conversations, GroupDirectory}
  alias SalixMeet.{CalendarEnrollmentCache, MeetingPlan, PreparationTask}
  alias SalixStore.Ids

  # Only the meeting domain's canonical Task create writes this grant. Generic
  # Conversation create/update cannot introduce or change it.
  def protected_source_ref_keys, do: ["meeting_preparation"]

  @meeting_tools ~w(
    meeting.preparation.open_trigger meeting.preparation.record_decision
    meeting.preparation.publish_report meeting.preparation.personal_context
    meeting.preparation.read_shared_source meeting.preparation.read_recipient
    meeting.preparation.publish_personal_report meeting.preparation.read_status
  )
  @research_tools ~w(help tool_call.get_status tool_call.get_result end_turn)

  # Source refs are lookup hints. The plan's first-write binding and the
  # Conversation owner's actual message/assignment are the authority.
  def seal_conversation(record) do
    hints = record["conversation_source_refs"] || %{}

    scope = %{
      "role" => "worker",
      "meeting_plan_id" => hints["meeting_plan_id"],
      "dispatch_revision" => hints["dispatch_revision"],
      "conversation_id" => record["conversation_id"],
      "message_id" => record["message_id"],
      "agent_id" => record["participant_agent_id"],
      "session_id" => get_in(record, ["participant_payload", "session_id"]),
      "participant_id" => record["participant_id"]
    }

    with "agent" <- record["source_actor_type"],
         {:ok, scope} <- seal_scope(record["agent_group_id"], scope) do
      {:ok, principal} = SalixIFC.Codec.encode_principal({:agent, scope["agent_id"]})
      {:ok, scope, principal}
    else
      _ -> :none
    end
  end

  defp seal_scope(group_id, scope) do
    case validate(group_id, scope) do
      {:ok, _} ->
        {:ok, scope}

      _ ->
        with :ok <- validate_cleanup(group_id, scope) do
          {:ok, Map.put(scope, "cleanup_only", true)}
        end
    end
  end

  def seal_schedule(id, payload, scheduled_for) do
    hints = payload["meeting_preparation"] || %{}

    with {:ok, agent} <- GroupDirectory.get_agent(payload["agent_id"]),
         {:ok, session_id} <- SalixStore.RuntimeIds.persisted_router_session_id(agent),
         scope <- %{
           "role" => "router",
           "meeting_plan_id" => hints["meeting_plan_id"],
           "dispatch_revision" => hints["dispatch_revision"],
           "schedule_id" => id,
           "scheduled_for" => scheduled_for,
           "agent_id" => payload["agent_id"],
           "session_id" => session_id
         },
         {:ok, plan} <- validate(hints["group_id"], scope),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:agent, scope["agent_id"]}) do
      origin = %{
        "provider" => "schedule",
        "schedule_id" => id,
        "meeting_preparation" => scope,
        "ifc" => %{
          "integrity" => "command",
          "principal" => principal,
          "label" => ["conversation|" <> plan["conversation_id"]]
        }
      }

      # Generic schedule edits cannot replace the organization command.
      {:ok, MeetingPlan.research_command(plan), origin}
    else
      _ -> :none
    end
  end

  def authorize_call(call, ctx) do
    # Settling a turn has no external effect and remains possible after expiry.
    scopes =
      [
        get_in(ctx, [:trusted_origin, "meeting_preparation"])
        | List.wrap(ctx[:organization_scopes])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Every consumed organization command constrains this activation, even when
    # later data supplies its singular origin or the model cites another request.
    results = Enum.map(scopes, &authorize_scope(call, ctx, &1))

    cond do
      {:error, :meeting_preparation_scope_denied} in results ->
        {:error, :meeting_preparation_scope_denied}

      {:error, :meeting_preparation_operation_not_permitted} in results ->
        {:error, :meeting_preparation_operation_not_permitted}

      true ->
        Enum.find(results, :ok, &match?({:error, _}, &1))
    end
  end

  defp authorize_scope(call, ctx, scope) do
    case {call[:name] || call["name"], scope} do
      {"end_turn", _} ->
        :ok

      {_, nil} ->
        :ok

      {_, scope} when is_map(scope) ->
        with true <- scope["agent_id"] == ctx[:agent_id],
             true <- scope["session_id"] == ctx[:session_id],
             true <- consumed?(scope, ctx),
             :ok <- validate_call(ctx[:group_id], scope, call) do
          if allowed?(call, scope, ctx),
            do: :ok,
            else: {:error, :meeting_preparation_operation_not_permitted}
        else
          {:error, :meeting_preparation_incomplete} = error -> error
          _ -> {:error, :meeting_preparation_scope_denied}
        end

      _ ->
        {:error, :meeting_preparation_scope_denied}
    end
  end

  defp consumed?(%{"role" => "router"} = scope, ctx) do
    "schedule:#{scope["schedule_id"]}:#{scope["scheduled_for"]}" in List.wrap(
      ctx[:source_message_ids]
    )
  end

  defp consumed?(scope, ctx) do
    Enum.any?(List.wrap(ctx[:source_message_ids]), fn source_id ->
      case SalixIM.ConversationSourceIdentity.decode(source_id, scope["conversation_id"]) do
        {:ok, identity} ->
          identity.message_id == scope["message_id"] and
            identity.participant_id == scope["participant_id"]

        _ ->
          false
      end
    end)
  end

  defp validate(group_id, %{"role" => "router"} = scope) do
    with {:ok, plan, group} <- current_plan(group_id, scope),
         true <- group["router_agent_id"] == scope["agent_id"],
         {:ok, agent} <- GroupDirectory.get_agent(scope["agent_id"]),
         {:ok, session_id} <- SalixStore.RuntimeIds.persisted_router_session_id(agent),
         true <- session_id == scope["session_id"],
         true <- get_in(plan, ["preparation", "schedule_ids", "decision"]) == scope["schedule_id"],
         true <- get_in(plan, ["preparation", "decision_at"]) == scope["scheduled_for"] do
      {:ok, plan}
    else
      _ -> {:error, :meeting_preparation_scope_denied}
    end
  end

  defp validate(group_id, %{"role" => "worker"} = scope) do
    with true <- Ids.valid_conversation_id?(scope["conversation_id"]),
         {:ok, plan, _group} <- current_plan(group_id, scope),
         true <-
           get_in(plan, ["preparation", "research_task", "conversation_id"]) ==
             scope["conversation_id"],
         :ok <- PreparationTask.authorize(plan, scope["agent_id"], scope["session_id"]),
         {:ok, _conversation} <- validate_assignment(group_id, scope) do
      {:ok, plan}
    else
      _ -> {:error, :meeting_preparation_scope_denied}
    end
  end

  defp validate(_group_id, _scope), do: {:error, :meeting_preparation_scope_denied}

  defp validate_assignment(group_id, scope) do
    with :ok <-
           PreparationTask.authorize_task(
             group_id,
             scope["conversation_id"],
             scope["agent_id"],
             scope["session_id"]
           ),
         {:ok, conversation} <-
           Conversations.get_group_conversation(group_id, scope["conversation_id"]),
         true <-
           Map.take(
             get_in(conversation, ["source_refs", "meeting_preparation"]) || %{},
             ~w(meeting_plan_id dispatch_revision)
           ) ==
             Map.take(scope, ~w(meeting_plan_id dispatch_revision)),
         true <-
           get_in(conversation, ["source_refs", "meeting_plan_id"]) == scope["meeting_plan_id"],
         true <-
           get_in(conversation, ["source_refs", "dispatch_revision"]) ==
             scope["dispatch_revision"],
         true <- conversation["task_worker_agent_id"] == scope["agent_id"],
         {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             group_id,
             scope["conversation_id"],
             scope["participant_id"]
           ),
         true <- participant["agent_id"] == scope["agent_id"] and participant["state"] == "active",
         true <- get_in(participant, ["payload", "session_id"]) == scope["session_id"],
         {:ok, message} <-
           Conversations.get_group_conversation_message(
             group_id,
             scope["conversation_id"],
             scope["message_id"]
           ),
         "agent" <- message["actor_type"],
         true <- message["agent_id"] == conversation["created_by_agent_id"],
         true <- get_in(message, ["metadata", "task_command"]) == true do
      {:ok, conversation}
    else
      _ -> {:error, :meeting_preparation_scope_denied}
    end
  end

  # A revoked meeting grant cannot read or publish. The already assigned Task
  # can still record its own failure and settle, under current owner fencing.
  defp validate_call(group_id, scope, call) do
    name = call[:name] || call["name"]
    cleanup = scope["role"] == "worker" and name == "im_api.internal.send_message"

    cond do
      cleanup ->
        validate_cleanup(group_id, scope)

      scope["cleanup_only"] == true ->
        {:error, :meeting_preparation_scope_denied}

      true ->
        case validate(group_id, scope) do
          {:ok, _plan} ->
            :ok

          error ->
            error
        end
    end
  end

  defp validate_cleanup(group_id, scope) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, _} <- validate_assignment(group_id, scope) do
      :ok
    else
      _ -> {:error, :meeting_preparation_scope_denied}
    end
  end

  defp current_plan(group_id, scope) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, plan} <- MeetingPlan.get(group_id, scope["meeting_plan_id"]),
         true <- plan["status"] == "planned",
         true <- get_in(plan, ["preparation", "dispatch_revision"]) == scope["dispatch_revision"],
         deadline when is_integer(deadline) <-
           get_in(plan, ["preparation", "publish_deadline_at"]),
         true <- System.system_time(:millisecond) < deadline,
         :ok <- enrolled(plan) do
      {:ok, plan, group}
    else
      _ -> {:error, :meeting_preparation_scope_denied}
    end
  end

  defp enrolled(plan) do
    with "slack" <- get_in(plan, ["publication_target", "provider"]),
         {:ok, entry} <- SalixMeet.CalendarConfiguration.enrollment(plan),
         {:ok, %{group: group}} <- CalendarEnrollmentCache.load(entry),
         true <- group["group_id"] == plan["group_id"] do
      :ok
    else
      _ -> {:error, :meeting_preparation_not_enrolled}
    end
  end

  defp allowed?(call, %{"role" => "router"} = scope, _ctx) do
    name = call[:name] || call["name"]
    args = call[:args] || call["args"] || %{}

    name in ~w(help agent.list tool_call.get_status tool_call.get_result) or
      (name == "meeting.preparation.start_research" and
         args["meeting_plan_id"] == scope["meeting_plan_id"] and
         args["dispatch_revision"] == scope["dispatch_revision"])
  end

  defp allowed?(call, scope, _ctx) do
    name = call[:name] || call["name"]
    args = call[:args] || call["args"] || %{}

    cond do
      name in @meeting_tools ->
        args["meeting_plan_id"] == scope["meeting_plan_id"] and
          args["dispatch_revision"] == scope["dispatch_revision"]

      name in @research_tools ->
        true

      name in ~w(im_api.internal.send_message im_api.internal.list_conversation_participants) ->
        args["conversation_id"] == scope["conversation_id"]

      true ->
        false
    end
  end
end
