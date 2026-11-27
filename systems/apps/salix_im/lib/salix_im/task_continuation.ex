defmodule SalixIM.TaskContinuation do
  @moduledoc """
  Call-local authority for a Router that receives its assigned Worker's report,
  a Loop runtime notice, or the notice that a user ended the Task by hand.
  Canonical Task ownership and the consumed Message authorize Task coordination.
  A protected return target authorizes a text reply to the original Slack
  thread, or to the original Feishu or Lark message and chat.
  Worker Messages remain data. The IFC kernel still checks every source label.
  """

  alias SalixIM.{ConversationParticipantActivity, ConversationSourceIdentity, Conversations}
  alias SalixIM.{GroupDirectory, ProviderConnects}

  @key "ifc_return"
  def protected_source_ref_keys, do: [@key]

  @providers ~w(slack feishu lark)
  # Text replies to the protected original target, by provider.
  @reply_apis ~w(slack.post_message slack.reply_message feishu.send_message feishu.reply_text
                 feishu.send_text lark.send_message)

  # Persist only an admitted human source. Neither Task parameters nor a
  # worker report can choose the requester, return target, or installation.
  def source_refs(scope, ctx, params) do
    origin = value(ctx, :trusted_origin) || %{}
    evidence = value(ctx, :ifc_evidence) || %{}
    target = origin["provider_context"] || %{}
    source = value(ctx, :source_message_id)

    with "router" <- scope.agent["role"],
         nil <- params["schedule"],
         provider when provider in @providers <- origin["provider"],
         "provider_user" <- origin["source_actor_type"],
         nil <- origin["triage_delegation"],
         true <- origin["agent_group_id"] == scope.group_id,
         true <- is_binary(source) and source != "" and source == origin["source_message_id"],
         true <- source in List.wrap(value(ctx, :source_message_ids)),
         %{"integrity" => "command", "principal" => principal, "label" => label} <- origin["ifc"],
         true <- evidence["requester"] == principal,
         {:ok, {:provider_user, connect_id, user_id}} <-
           SalixIFC.Codec.decode_principal(principal),
         true <- connect_id == target["connect_id"] and user_id == subject(provider, target),
         false <- target["app_authored"] == true,
         {:ok, return_target} <- return_target(provider, connect_id, target),
         {:ok, installation} <- installation(scope.group_id, connect_id, provider) do
      %{
        @key => %{
          "requester" => principal,
          "source_scope" => label,
          "installation" => installation,
          "target" => return_target
        }
      }
    else
      _ -> %{}
    end
  end

  # The provider user ingress names as the principal
  # (`SalixIM.AgentDeliveryPayload` subject order).
  defp subject("slack", target), do: target["user_id"]

  defp subject(_provider, target),
    do:
      Enum.find([target["user_id"], target["sender_open_id"], target["sender_user_id"]], &text?/1)

  defp return_target("slack", connect_id, target) do
    with channel when is_binary(channel) and channel != "" <- target["channel_id"],
         thread when is_binary(thread) and thread != "" <-
           target["thread_ts"] || target["message_ts"] do
      {:ok, %{"connect_id" => connect_id, "channel" => channel, "thread_ts" => thread}}
    else
      _ -> :none
    end
  end

  # The original message and its chat. A thread id, when the message came in
  # one, must match too.
  defp return_target(_provider, connect_id, target) do
    with chat when is_binary(chat) and chat != "" <- target["chat_id"],
         message when is_binary(message) and message != "" <- target["message_id"] do
      thread = target["message_thread_id"]

      {:ok,
       %{"connect_id" => connect_id, "chat_id" => chat, "message_id" => message}
       |> then(&if(text?(thread), do: Map.put(&1, "thread_id", thread), else: &1))}
    else
      _ -> :none
    end
  end

  def ifc_request("im_api." <> api, args, ctx)
      when api in ["internal.send_message", "internal.update_conversation" | @reply_apis] do
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
         true <- continuation_report?(report, task, api) do
      authorize_effect(api, args, source, scope, task)
    else
      _ -> :none
    end
  end

  def ifc_request(_, _, _), do: :none

  # Obtain candidate coordinates from owner-held state, then reuse the exact
  # continuation admission. Reading a target is not itself authorization.
  def ifc_projection_targets(ctx) do
    origin = value(ctx, :trusted_origin) || %{}

    with {:ok, scope} <- GroupDirectory.scope_for_agent(value(ctx, :agent_id)),
         "router" <- scope.agent["role"],
         "agent_task" <- origin["conversation_kind"],
         {:ok, task} <-
           Conversations.get_group_conversation_record(scope.group_id, origin["conversation_id"]),
         %{} = target <- get_in(task, ["source_refs", @key, "target"]) do
      Enum.find_value(
        ["slack.reply_message", "feishu.reply_text", "lark.send_message"],
        :none,
        fn api ->
          args =
            if api == "lark.send_message",
              do: target |> Map.delete("message_id") |> Map.put("reply_to", target["message_id"]),
              else: target

          case ifc_request("im_api." <> api, Map.put(args, "text", "Reply"), ctx) do
            {:ok, _source, _principal, label} -> {:ok, [label]}
            _ -> nil
          end
        end
      )
    else
      _ -> :none
    end
  end

  defp continuation_report?(%{"actor_type" => "agent", "agent_id" => agent} = report, task, _api) do
    worker = task["task_worker_agent_id"]

    if is_binary(worker) and worker != "" and agent == worker do
      cond do
        get_in(report, ["metadata", "explicit_router_mention"]) == true ->
          true

        is_binary(report["participant_id"]) and report["participant_id"] != "" ->
          case Conversations.get_group_conversation_participant(
                 task["agent_group_id"],
                 task["conversation_id"],
                 report["participant_id"]
               ) do
            {:ok, participant} -> SalixIM.TaskSessionSlots.primary_worker?(participant)
            _ -> false
          end

        true ->
          true
      end
    else
      false
    end
  end

  # Only the Conversation owner writes system Messages. A user's manual end
  # authorizes the closing text to the original target, nothing more.
  defp continuation_report?(
         %{"actor_type" => "system", "metadata" => %{"message_type" => "task_manual_status"}},
         _task,
         api
       ),
       do: api in @reply_apis

  # The owner persists these notices for this Loop Task. They authorize the
  # Router's existing Task coordination, never arbitrary system-message work.
  defp continuation_report?(
         %{"actor_type" => "system", "metadata" => %{"message_type" => "task_loop"}},
         task,
         _api
       ),
       do: loop_task?(task)

  defp continuation_report?(_report, _task, _api), do: false

  # Terminal status must not strand the closing notice. Only text to the
  # protected original target remains eligible; authorize_effect still
  # checks exact coordinates, membership and installation, and IFC checks flow.
  # This is reply authority, not a new command or exactly-once delivery grant.
  defp continuation_status?(%{"status" => status}, api, _args)
       when status in ~w(completed failed cancelled escalated) and api in @reply_apis,
       do: true

  # A lost response may retry the same exact status, never reopen the Task.
  defp continuation_status?(%{"status" => status} = task, api, args)
       when status in ~w(completed failed escalated) do
    allowed = if loop_task?(task), do: ~w(completed failed escalated), else: ~w(completed failed)

    status in allowed and api == "internal.update_conversation" and
      args == %{
        "connect_id" => "internal",
        "conversation_id" => task["conversation_id"],
        "status" => status
      }
  end

  defp continuation_status?(task, _api, _args),
    do: task["status"] in ["active", "ready_for_review"]

  defp authorize_effect(api, args, source, scope, task) when api in @reply_apis do
    [provider | _] = String.split(api, ".", parts: 2)

    with %{
           "requester" => principal,
           "source_scope" => label,
           "target" => target,
           "installation" => expected
         } <- get_in(task, ["source_refs", @key]),
         true <- reply_to_target?(api, args, target),
         true <- principal in List.wrap(get_in(task, ["source_refs", "ifc_members"])),
         {:ok, ^expected} <- installation(scope.group_id, target["connect_id"], provider) do
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
          statuses =
            if loop_task?(task),
              do: ~w(completed escalated failed),
              else: ~w(ready_for_review completed failed)

          args in Enum.map(statuses, &Map.put(target, "status", &1))
      end

    if allowed do
      {:ok, principal} = SalixIFC.Codec.encode_principal({:agent, scope.agent_id})
      {:ok, source, principal}
    else
      :none
    end
  end

  # Text to the exact target, nothing else: no other chat, message, thread,
  # person, mention or file.
  defp reply_to_target?(api, args, target)
       when api in ["slack.post_message", "slack.reply_message"],
       do: Map.drop(args, ["text"]) == target

  # A reply to the original message. The source facts a reply may also pass
  # must be the original's; `reply_in_thread` stays in that chat.
  defp reply_to_target?("feishu.reply_text", args, target) do
    allowed = ~w(connect_id message_id text format reply_in_thread chat_id chat_type thread_id)

    keys_within?(args, allowed) and text?(args["text"]) and
      args["connect_id"] == target["connect_id"] and
      args["message_id"] == target["message_id"] and
      optional_equal?(args, "chat_id", target["chat_id"]) and
      optional_equal?(args, "thread_id", target["thread_id"]) and
      optional_boolean?(args, "reply_in_thread")
  end

  # A new message to the original chat.
  defp reply_to_target?("feishu.send_text", args, target) do
    keys_within?(args, ~w(connect_id receive_id receive_id_type text format)) and
      text?(args["text"]) and args["connect_id"] == target["connect_id"] and
      args["receive_id"] == target["chat_id"] and
      optional_equal?(args, "receive_id_type", "chat_id")
  end

  # A message to the original chat, as a reply to the original message or not.
  defp reply_to_target?(api, args, target)
       when api in ["feishu.send_message", "lark.send_message"] do
    keys_within?(args, ~w(connect_id chat_id reply_to reply_in_thread text format)) and
      text?(args["text"]) and args["connect_id"] == target["connect_id"] and
      args["chat_id"] == target["chat_id"] and
      optional_equal?(args, "reply_to", target["message_id"]) and
      optional_boolean?(args, "reply_in_thread")
  end

  defp keys_within?(args, allowed), do: Enum.all?(Map.keys(args), &(&1 in allowed))
  defp optional_equal?(args, key, expected), do: args[key] in [nil, "", expected]
  defp optional_boolean?(args, key), do: args[key] in [nil, true, false]

  # The connect's current installation. A Slack connect has a generation that
  # a reinstall replaces; a Feishu or Lark connect is its app, which an update
  # can replace. A changed installation refuses the stored target.
  defp installation(group, connect_id, "slack") do
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

  defp installation(group, connect_id, provider) when provider in ["feishu", "lark"] do
    with {:ok, connect} <-
           ProviderConnects.get_delegatable_connect_by_id(group, connect_id, provider),
         app when is_binary(app) and app != "" <- connect["app_id"] do
      {:ok,
       connect
       |> Map.take(["connect_generation"])
       |> Map.filter(fn {_key, value} -> text?(value) end)
       |> Map.put("app_id", app)}
    else
      _ -> :none
    end
  end

  defp installation(_group, _connect_id, _provider), do: :none

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  # A Task that requested a Loop (`SalixIM.TaskLoop`). A failed read is no
  # Loop Task: it grants only the plain Task's authority.
  defp loop_task?(task) do
    match?(
      {:ok, %{"trigger" => %{}}},
      SalixIM.TaskLoop.get(task["agent_group_id"], task["conversation_id"])
    )
  end

  defp ordinary?(nil), do: true
  defp ordinary?(%{"schedule_id" => nil}), do: true
  defp ordinary?(_), do: false
  defp value(ctx, key), do: Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key))
end
