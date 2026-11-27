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
    ModelMentionTask,
    RequestMention,
    ShareMention,
    ConversationInput,
    ConversationServer,
    Conversations,
    GroupDirectory,
    StationTaskQuestionSync
  }

  @spec ensure(String.t()) :: {:ok, map()} | {:error, term()}
  def ensure(group_id) do
    SalixStore.ReadScope.run(fn ->
      if agent_id = SalixIM.ConversationGroupActor.router_read_hint(group_id) do
        SalixStore.ReadScope.prefetch({:record, SalixStore.Keys.ctl_agent(agent_id)}, fn ->
          with {:ok, %{record: record}} <- SalixStore.AgentPGStore.read_config(agent_id),
               do: {:ok, record}
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

        station_sync =
          if command?,
            do: :passthrough,
            else: StationTaskQuestionSync.prepare_user_answer(group_id, conversation, attrs)

        case station_sync do
          {:stale_card, _ref, question_id, binding} ->
            locale =
              case attrs["client_metadata"] do
                %{"locale" => loc} when is_binary(loc) -> loc
                _ -> nil
              end

            case StationTaskQuestionSync.fold_stale_card(
                   group_id,
                   conversation["conversation_id"],
                   attrs["user_id"] || "current",
                   question_id,
                   binding,
                   locale: locale
                 ) do
              {:ok, %{"message_id" => _} = folded_result} ->
                {:ok, folded_result}

              _ ->
                {:error,
                 {:conflict, "This card has already been answered or replaced in still.fail."}}
            end

          _ ->
            {attrs, station_handled?, station_sync_info} =
              case station_sync do
                {:handled, sync_info, extra_meta} ->
                  {merge_metadata(attrs, extra_meta), true, sync_info}

                {:fallback_to_router, extra_meta} ->
                  {merge_metadata(attrs, extra_meta), false, nil}

                :passthrough ->
                  {attrs, false, nil}
              end

            # A message naming a model starts a Task with it instead of the Router's turn;
            # one naming a person (and no model) sends them a Task request.
            model_task =
              if command? or station_handled?,
                do: :none,
                else: ModelMentionTask.parse(said_text(attrs["content"]), attrs["content"])

            # One naming people for a shared task starts it with them (and sends no requests).
            share =
              if command? or station_handled? or model_task != :none,
                do: :none,
                else: ShareMention.parse(said_text(attrs["content"]), attrs["content"])

            request =
              if command? or station_handled? or model_task != :none or share != :none,
                do: :none,
                else: RequestMention.parse(said_text(attrs["content"]), attrs["content"])

            message =
              user_message(
                conversation,
                attrs,
                if(
                  command? or station_handled? or model_task != :none or share != :none or
                    request != :none,
                  do: [],
                  else: [conversation["router_participant_id"]]
                )
              )

            with {:ok, result} <-
                   ConversationServer.append_group_conversation_message(
                     group_id,
                     conversation["conversation_id"],
                     message
                   ) do
              observe_append(
                conversation,
                message["source_message_id"],
                message["metadata"],
                result
              )

              if station_handled? and result["inserted"] == true do
                StationTaskQuestionSync.after_commit(group_id, station_sync_info)
              end

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

              with {:ok, mention} <- model_task,
                   true <- result["inserted"] == true do
                ModelMentionTask.start(
                  group_id,
                  conversation,
                  result["message_id"],
                  attrs["user_id"],
                  mention
                )
              end

              with {:ok, mention} <- share,
                   true <- result["inserted"] == true do
                ShareMention.start(
                  group_id,
                  conversation,
                  result["message_id"],
                  requester(attrs),
                  mention
                )
              end

              with {:ok, mention} <- request,
                   true <- result["inserted"] == true do
                RequestMention.send_request(
                  group_id,
                  conversation,
                  result["message_id"],
                  requester(attrs),
                  mention
                )
              end

              {:ok, result}
            end
        end
      end
    end)
  end

  @doc """
  Appends a non-waking `question_answer` message in Home when a still.fail
  options card was answered or closed directly inside still.fail, folding the
  bound Comma Home card with the user's choice.
  """
  @spec append_resolved_question_answer(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def append_resolved_question_answer(
        group_id,
        user_id,
        question_message_id,
        display_text,
        answer_block,
        station_ref
      )
      when is_binary(group_id) and is_binary(question_message_id) and is_binary(display_text) and
             is_map(answer_block) and is_binary(station_ref) do
    SalixStore.ReadScope.run(fn ->
      with {:ok, conversation} <- ensure(group_id) do
        block = Map.put(answer_block, "question_message_id", question_message_id)

        # Store only the structured `question_answer` block so folding a card
        # answered inside still.fail never renders a standalone user bubble at
        # the bottom of Home. `display_text` still goes to the Router's
        # `no_wake` context note below.
        content = [block]

        attrs = %{
          "user_id" => user_id || "current",
          "content" => content,
          "reply_to_message_id" => question_message_id,
          "client_request_id" => "sf-card-sync:" <> question_message_id,
          "metadata" => %{
            "resolved_in_stillfail" => true,
            "stillfail_conversation_id" => station_ref
          }
        }

        message = user_message(conversation, attrs, [])

        with {:ok, result} <-
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation["conversation_id"],
                 message
               ) do
          if result["inserted"] == true do
            StationTaskQuestionSync.stage_router_context(
              group_id,
              "station-res:" <> question_message_id,
              %{
                "event" => "station_card_resolved",
                "ref" => station_ref,
                "msg_id" => question_message_id,
                "text" => String.slice(display_text, 0, 120)
              }
            )
          end

          {:ok, result}
        end
      end
    end)
  end

  defp merge_metadata(attrs, extra) when is_map(extra) and map_size(extra) > 0 do
    Map.update(attrs, "metadata", extra, fn existing ->
      if is_map(existing), do: Map.merge(existing, extra), else: extra
    end)
  end

  defp merge_metadata(attrs, _extra), do: attrs

  # Only a full session's author sends a Task request or starts a shared task:
  # Comma marks a restricted one's message, which then has no requester.
  defp requester(%{"metadata" => %{"restricted_session" => true}}), do: nil
  defp requester(attrs), do: attrs["user_id"]

  defp user_message(conversation, attrs, participant_ids) do
    attrs
    |> Map.delete("requester_email")
    |> Map.put("participant_id", conversation["user_participant_id"])
    |> Map.put("actor_type", "user")
    |> Map.put_new("user_id", "current")
    |> Map.put("delivery_filter", %{"participant_ids" => participant_ids})
    |> Map.update("metadata", %{"source" => "group_router"}, fn metadata ->
      Map.put(metadata, "source", "group_router")
    end)
  end

  # Provider adapters have already checked the sender and sealed its provenance.
  # The owner persists these facts with the Message, before any Session admission.
  def append_provider_input(group_id, source_message_id, payload, metadata \\ %{}) do
    with {:ok, conversation} <-
           SalixIM.QQTiming.measure("conversation_ensure", fn -> ensure(group_id) end) do
      result =
        SalixIM.QQTiming.measure("conversation_append", fn ->
          ConversationServer.append_provider_input(
            group_id,
            conversation["conversation_id"],
            conversation["router_participant_id"],
            source_message_id,
            payload,
            metadata
          )
        end)

      case result do
        {:ok, message} -> observe_append(conversation, source_message_id, metadata, message)
        _ -> :ok
      end

      result
    end
  end

  defp observe_append(conversation, source, metadata, message) do
    source_sent_at =
      case SalixIM.SlackMessageMirror.Row.slack_ts_micros((metadata || %{})["message_ts"]) do
        {:ok, micros} -> div(micros, 1_000)
        _ -> nil
      end

    fields =
      SalixAgent.DeliveryTelemetry.identity(
        conversation["router_agent_id"],
        conversation["router_session_id"],
        source
      )
      |> Map.merge(%{
        conversation_seq: message["seq"],
        source_created_at_ms: message["created_at"],
        source_sent_at_ms: source_sent_at,
        thread_key: SalixAgent.DeliveryTelemetry.source_key((metadata || %{})["thread_ts"])
      })

    SalixAgent.DeliveryTelemetry.emit(:conversation_committed, :ok, 0, fields)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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

  # What the person wrote: the app sends its words as one string.
  defp said_text(content) when is_binary(content), do: content
  defp said_text(content), do: command_text(content)

  @router_title "Comma"
  @legacy_router_titles ["bridge chat"]

  @doc false
  def legacy_router_title?(title) when is_binary(title),
    do: String.downcase(String.trim(title)) in @legacy_router_titles

  def legacy_router_title?(_), do: false

  @doc false
  def normalize_router_title(title) do
    if legacy_router_title?(title), do: @router_title, else: title
  end

  @spec desired_spec(String.t()) :: {:ok, map()} | {:error, term()}
  def desired_spec(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, router_agent} <- router_agent(group),
         {:ok, conversation_id} <- ConversationIds.group_router(group) do
      timestamp = group["created_at"] || SystemsClock.system_time(:millisecond)

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "agent_group_id" => group_id,
         "router_agent_id" => router_agent["agent_id"],
         "kind" => "user_chat",
         "title" => @router_title,
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
        reconcile_legacy_router_title(group_id, conversation, spec["title"])

      {:error, :not_found} ->
        case ConversationInput.create_group_conversation_with_id(
               group_id,
               conversation_id,
               Map.delete(spec, "router_agent_id")
             ) do
          {:error, :exists} ->
            with {:ok, conversation} <-
                   Conversations.get_group_conversation(group_id, conversation_id) do
              reconcile_legacy_router_title(group_id, conversation, spec["title"])
            end

          other ->
            other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_legacy_router_title(group_id, %{"title" => title} = conversation, desired_title) do
    if legacy_router_title?(title) do
      case ConversationServer.update_group_conversation(
             group_id,
             conversation["conversation_id"],
             %{"title" => desired_title, if_title: title}
           ) do
        {:ok, updated} ->
          {:ok, updated}

        {:error, {:conflict, _}} ->
          case ConversationServer.resident_group_conversation(
                 group_id,
                 conversation["conversation_id"]
               ) do
            {:ok, current} -> {:ok, current}
            _ -> {:ok, Map.put(conversation, "title", desired_title)}
          end

        _ ->
          {:ok, Map.put(conversation, "title", desired_title)}
      end
    else
      {:ok, conversation}
    end
  end

  defp reconcile_legacy_router_title(_group_id, conversation, _desired_title),
    do: {:ok, conversation}

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
