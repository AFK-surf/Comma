defmodule SalixIM.RouterConversationInput do
  @moduledoc """
  Product orchestration for a group's fixed Router conversation.

  This Conversation supplies Comma and provider inputs to the same Router log.
  Provider effects use provider-owned delivery ports.

  Internal user mutations still enter through `ConversationServer`.
  """

  alias SalixIM.{
    ControlCommand,
    ConversationIds,
    ConversationInput,
    ConversationServer,
    Conversations,
    GroupDirectory
  }

  @spec ensure(String.t()) :: {:ok, map()} | {:error, term()}
  def ensure(group_id) do
    SalixStore.ReadScope.run(fn ->
      if agent_id = SalixIM.ConversationGroupActor.router_read_hint(group_id) do
        SalixStore.ReadScope.prefetch({:record, SalixStore.Keys.ctl_agent(agent_id)}, fn ->
          SalixStore.CasRecord.get(SalixStore.Keys.ctl_agent(agent_id))
        end)
      end

      with {:ok, spec} <- desired_spec(group_id),
           {:ok, conversation} <- ensure_conversation(group_id, spec),
           {:ok, user_spec} <- desired_participant(spec, "user", "current"),
           {:ok, router_spec} <- desired_participant(spec, "agent", spec["router_agent_id"]),
           {:ok, desired_router} <-
             ConversationInput.prepare_agent_for_create(group_id, conversation, router_spec) do
        desired =
          Enum.map([user_spec, desired_router], fn participant ->
            Map.drop(participant, ~w(created_at updated_at agent_name))
          end)

        participants =
          case ConversationServer.match_group_conversation_participants(
                 group_id,
                 spec["conversation_id"],
                 desired,
                 %{"actor_type" => "agent", "role_label" => ["agent", "router"]}
               ) do
            {:ok, [user, router]} -> {:ok, user, router}
            {:error, :participants_differ} -> reconcile(group_id, spec, user_spec)
            error -> error
          end

        with {:ok, user, router} <- participants do
          _ = ConversationServer.remember_router_read_hint(group_id, router["agent_id"])

          {:ok,
           conversation
           |> Map.put("router_agent_id", router["agent_id"])
           |> Map.put("user_participant_id", user["participant_id"])
           |> Map.put("router_participant_id", router["participant_id"])}
        end
      end
    end)
  end

  defp reconcile(group_id, spec, user_spec) do
    with {:ok, user} <-
           ConversationServer.ensure_group_conversation_user_participant(
             group_id,
             spec["conversation_id"],
             user_spec
           ),
         {:ok, router} <-
           ConversationInput.reconcile_group_conversation_router_participant(
             group_id,
             spec["conversation_id"]
           ) do
      {:ok, user, router}
    end
  end

  @spec append_user_message(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append_user_message(group_id, attrs) when is_map(attrs) do
    SalixStore.ReadScope.run(fn ->
      with {:ok, conversation} <- ensure(group_id) do
        attrs = stringify(attrs)
        command_text = command_text(attrs["content"])
        command? = ControlCommand.parse(command_text) != :none

        message =
          attrs
          |> stringify()
          |> Map.put("participant_id", conversation["user_participant_id"])
          |> Map.put("actor_type", "user")
          |> Map.put_new("user_id", "current")
          |> Map.put("delivery_filter", %{
            "participant_ids" =>
              if(command?, do: [], else: [conversation["router_participant_id"]])
          })
          |> Map.update("metadata", %{"source" => "group_router"}, fn metadata ->
            metadata |> stringify() |> Map.put("source", "group_router")
          end)

        with {:ok, result} <-
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation["conversation_id"],
                 message
               ) do
          if command? and result["inserted"] do
            metadata = %{
              "provider" => "internal",
              "connect_id" => "internal",
              "conversation_id" => conversation["conversation_id"],
              "source_message_id" => result["message_id"]
            }

            # The committed Message is the at-most-once receipt. Neither it nor
            # the command reply is agent input, including after delivery recovery.
            case ControlCommand.intercept(group_id, command_text, metadata) do
              {:error, _reason} ->
                ControlCommand.respond(
                  conversation["router_agent_id"],
                  metadata,
                  "Salix could not start this command. Please send it again shortly."
                )

              {:ok, :command} ->
                :ok
            end
          end

          {:ok, result}
        end
      end
    end)
  end

  # Provider adapters have already checked the sender and sealed its provenance.
  # The owner persists these facts with the Message, before any Session admission.
  def append_provider_input(group_id, source_message_id, payload, metadata \\ %{}) do
    with {:ok, conversation} <- ensure(group_id) do
      ConversationServer.append_provider_input(
        group_id,
        conversation["conversation_id"],
        conversation["router_participant_id"],
        source_message_id,
        payload,
        metadata
      )
    end
  end

  # Only sender-authored text blocks grant authority; attachment names and
  # other rich content are never interpreted as instructions.
  defp command_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp command_text(_), do: ""

  @spec desired_spec(String.t()) :: {:ok, map()} | {:error, term()}
  def desired_spec(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, router_agent} <- router_agent(group),
         {:ok, conversation_id} <- ConversationIds.group_router(group) do
      timestamp = group["created_at"] || System.system_time(:millisecond)

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "agent_group_id" => group_id,
         "router_agent_id" => router_agent["agent_id"],
         "kind" => "user_chat",
         "title" => "Bridge chat",
         "status" => "active",
         "activity_status" => "idle",
         "created_by_agent_id" => router_agent["agent_id"],
         "created_at" => timestamp,
         "updated_at" => timestamp,
         "participants" => [
           %{
             "actor_type" => "user",
             "user_id" => "current",
             "role_label" => "user",
             "state" => "active",
             "notification_filter" => %{"messages" => "all", "statuses" => "none"},
             "created_at" => timestamp,
             "updated_at" => timestamp
           },
           %{
             "actor_type" => "agent",
             "agent_id" => router_agent["agent_id"],
             "agent_name" => router_agent["name"],
             "role_label" => "agent",
             "state" => "active",
             "notification_filter" => %{"messages" => "all", "statuses" => "none"},
             "created_at" => timestamp,
             "updated_at" => timestamp
           }
         ]
       }}
    end
  end

  defp ensure_conversation(group_id, spec) do
    conversation_id = spec["conversation_id"]

    case ConversationServer.resident_group_conversation(group_id, conversation_id) do
      {:ok, conversation} ->
        {:ok, conversation}

      {:error, :not_found} ->
        case ConversationInput.create_group_conversation_with_id(
               group_id,
               conversation_id,
               Map.delete(spec, "router_agent_id")
             ) do
          {:error, :exists} -> Conversations.get_group_conversation(group_id, conversation_id)
          other -> other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp desired_participant(spec, actor_type, identity) do
    case Enum.find(spec["participants"], fn participant ->
           participant["actor_type"] == actor_type and
             (participant["agent_id"] == identity or participant["user_id"] == identity)
         end) do
      %{} = participant -> {:ok, participant}
      nil -> {:error, {:bad_request, "router participant specification is missing"}}
    end
  end

  defp router_agent(group) do
    case trim(group["router_agent_id"]) do
      "" -> {:error, :router_not_configured}
      agent_id -> GroupDirectory.get_agent(agent_id)
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
