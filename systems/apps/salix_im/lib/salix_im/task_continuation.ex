defmodule SalixIM.TaskContinuation do
  @moduledoc """
  Call-local authority for a Router that receives its assigned Worker's report.
  Canonical Task ownership and the consumed Message authorize Task coordination.
  A protected return target authorizes a text reply to the original Slack thread.
  Worker Messages remain data. The IFC kernel still checks every source label.
  """

  alias SalixIM.{ConversationParticipantActivity, ConversationSourceIdentity, Conversations}
  alias SalixIM.{GroupDirectory, ProviderConnects}

  @key "ifc_return"
  def protected_source_ref_keys, do: [@key]

  # Persist only an admitted human source. Neither Task parameters nor a
  # worker report can choose the requester, return target, or installation.
  def source_refs(scope, ctx, params) do
    origin = value(ctx, :trusted_origin) || %{}
    evidence = value(ctx, :ifc_evidence) || %{}
    target = origin["provider_context"] || %{}
    source = value(ctx, :source_message_id)

    with "router" <- scope.agent["role"],
         nil <- params["schedule"],
         "slack" <- origin["provider"],
         "provider_user" <- origin["source_actor_type"],
         nil <- origin["triage_delegation"],
         true <- origin["agent_group_id"] == scope.group_id,
         true <- is_binary(source) and source != "" and source == origin["source_message_id"],
         true <- source in List.wrap(value(ctx, :source_message_ids)),
         %{"integrity" => "command", "principal" => principal, "label" => label} <- origin["ifc"],
         true <- evidence["requester"] == principal,
         {:ok, {:provider_user, connect_id, user_id}} <-
           SalixIFC.Codec.decode_principal(principal),
         true <- connect_id == target["connect_id"] and user_id == target["user_id"],
         false <- target["app_authored"] == true,
         channel when is_binary(channel) and channel != "" <- target["channel_id"],
         thread when is_binary(thread) and thread != "" <-
           target["thread_ts"] || target["message_ts"],
         {:ok, installation} <- installation(scope.group_id, connect_id) do
      %{
        @key => %{
          "requester" => principal,
          "source_scope" => label,
          "installation" => installation,
          "target" => %{"connect_id" => connect_id, "channel" => channel, "thread_ts" => thread}
        }
      }
    else
      _ -> %{}
    end
  end

  def ifc_request("im_api." <> api, args, ctx)
      when api in [
             "internal.send_message",
             "internal.update_conversation",
             "slack.post_message",
             "slack.reply_message"
           ] do
    origin = value(ctx, :trusted_origin) || %{}
    source = value(ctx, :source_message_id)

    with {:ok, scope} <- GroupDirectory.scope_for_agent(value(ctx, :agent_id)),
         "router" <- scope.agent["role"],
         {:ok, group} <- GroupDirectory.get_group(scope.group_id),
         true <- group["router_agent_id"] == scope.agent_id,
         "internal" <- origin["provider"],
         "agent_task" <- origin["conversation_kind"],
         true <- origin["agent_group_id"] == scope.group_id,
         true <-
           source == origin["source_message_id"] and
             source in List.wrap(value(ctx, :source_message_ids)),
         {:ok, identity} <- ConversationSourceIdentity.decode(source, origin["conversation_id"]),
         true <-
           identity.message_id == origin["message_id"] and
             identity.participant_id == origin["participant_id"],
         {:ok, task} <-
           Conversations.get_group_conversation_record(scope.group_id, origin["conversation_id"]),
         "agent_task" <- task["kind"],
         true <- continuation_status?(task, api, args),
         nil <- task["workflow"],
         true <- ordinary?(task["schedule"]),
         true <- task["created_by_agent_id"] == scope.agent_id,
         {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             scope.group_id,
             origin["conversation_id"],
             origin["participant_id"]
           ),
         "active" <- participant["state"],
         {agent, session} <- ConversationParticipantActivity.session_ref(participant),
         true <-
           agent == scope.agent_id and is_binary(session) and session == value(ctx, :session_id),
         {:ok, report} <-
           Conversations.get_group_conversation_message(
             scope.group_id,
             origin["conversation_id"],
             origin["message_id"]
           ),
         "agent" <- report["actor_type"],
         worker when is_binary(worker) and worker != "" <- task["task_worker_agent_id"],
         true <- report["agent_id"] == worker do
      authorize_effect(api, args, source, scope, task)
    else
      _ -> :none
    end
  end

  def ifc_request(_, _, _), do: :none

  # Terminal status must not strand the closing notice. Only text to the
  # protected original Slack target remains eligible; authorize_effect still
  # checks exact coordinates, membership and installation, and IFC checks flow.
  # This is reply authority, not a new command or exactly-once delivery grant.
  defp continuation_status?(%{"status" => status}, api, _args)
       when status in ~w(completed failed cancelled escalated) and
              api in ["slack.post_message", "slack.reply_message"],
       do: true

  # A lost completion response may be retried without reopening other writes.
  defp continuation_status?(%{"status" => "completed"} = task, api, args) do
    api == "internal.update_conversation" and
      args == %{
        "connect_id" => "internal",
        "conversation_id" => task["conversation_id"],
        "status" => "completed"
      }
  end

  defp continuation_status?(task, _api, _args),
    do: task["status"] in ["active", "ready_for_review"]

  defp authorize_effect(api, args, source, scope, task)
       when api in ["slack.post_message", "slack.reply_message"] do
    with %{
           "requester" => principal,
           "source_scope" => label,
           "target" => target,
           "installation" => expected
         } <- get_in(task, ["source_refs", @key]),
         true <- Map.drop(args, ["text"]) == target,
         true <- principal in List.wrap(get_in(task, ["source_refs", "ifc_members"])),
         {:ok, ^expected} <- installation(scope.group_id, target["connect_id"]) do
      {:ok, source, principal, label}
    else
      _ -> :none
    end
  end

  defp authorize_effect(api, args, source, scope, task) do
    target = %{"connect_id" => "internal", "conversation_id" => task["conversation_id"]}

    allowed =
      case api do
        "internal.send_message" ->
          Map.take(args, Map.keys(target)) == target

        "internal.update_conversation" ->
          args in Enum.map(~w(ready_for_review completed), &Map.put(target, "status", &1))
      end

    if allowed do
      {:ok, principal} = SalixIFC.Codec.encode_principal({:agent, scope.agent_id})
      {:ok, source, principal}
    else
      :none
    end
  end

  defp installation(group, connect_id) do
    with {:ok, connect} <-
           ProviderConnects.get_delegatable_connect_by_id(group, connect_id, "slack"),
         generation when is_binary(generation) and generation != "" <-
           connect["connect_generation"],
         workspace when is_binary(workspace) and workspace != "" <- connect["workspace_id"] do
      {:ok, %{"connect_generation" => generation, "workspace_id" => workspace}}
    else
      _ -> :none
    end
  end

  defp ordinary?(nil), do: true
  defp ordinary?(%{"schedule_id" => nil}), do: true
  defp ordinary?(_), do: false
  defp value(ctx, key), do: Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key))
end
