defmodule SalixIM.LarkTaskCard do
  @moduledoc """
  The Task card of a Lark chat: one provider Participant of a Task
  Conversation.

  `SalixIM.TaskCardProjection` owns what the card shows. This module owns the
  Lark address, the card layout and the write evidence.

  The card is one interactive message that answers the source message. The
  first delivery posts it. Later deliveries update the same message with
  `PATCH /im/v1/messages/:message_id`. Lark sends the bot no event for its
  own message, so the write evidence is the API response only:

    * A post carries a `uuid` made from the card identity and the message it
      replaces. Lark sends at most one message per `uuid` in one hour. After
      a post with an unknown outcome, the runtime sends the same request with
      the same `uuid` again and takes the message address it returns.
    * When that cannot prove the address inside the hour, the card is
      quarantined. It never posts a second card for the same address.
    * An update is idempotent and is sent again unchanged. A card that was
      recalled, deleted or is too old to edit is replaced by one new post.
  """

  alias SalixIM.{
    ConversationServer,
    Conversations,
    MessageRenderer,
    ProviderConversationInput,
    TaskCardProjection
  }

  alias SalixIM.MessageRenderer.Surface
  alias SalixIM.Provider.Lark
  alias SalixIM.Provider.Lark.MessageRenderer, as: LarkMessageRenderer
  alias SalixStore.Crypto

  import SalixIM.Provider.Util, only: [str: 1]

  @kind "lark_task_card"
  @projection_version TaskCardProjection.projection_version()
  @lifecycles TaskCardProjection.lifecycles()
  @chat_types ~w(group p2p)
  # Inside the hour Lark keeps a `uuid`, with margin for clock skew between
  # this node and Lark.
  @replay_window_ms 50 * 60_000
  # The card was recalled (230011), is older than the 14-day edit window
  # (230031), or was deleted (230110).
  @card_gone_codes ~w(230011 230031 230110)
  @rate_limit_codes ~w(230020 99991400)
  @rate_limit_delay_ms 1_000

  def kind, do: @kind

  def post(
        %{agent: %{"role" => "router"}, group_id: group_id, agent_id: agent_id},
        connect,
        %{"conversation_id" => conversation_id, "chat_id" => chat_id, "message_id" => message_id} =
          params
      ) do
    chat_type = str(params["chat_type"] || "group")

    with :ok <- validate_card_target(str(chat_id), str(message_id), chat_type),
         :ok <- validate_card_connect(connect),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(group_id, conversation_id),
         :ok <- validate_card_conversation(conversation, group_id, agent_id),
         :ok <- validate_card_address(connect, str(chat_id), str(message_id)),
         {:ok, attrs} <-
           participant_attrs(connect, conversation, str(chat_id), str(message_id), chat_type),
         {:ok, participant} <-
           ConversationServer.ensure_group_conversation_provider_participant(
             group_id,
             conversation_id,
             attrs
           ),
         :ok <- validate_card_participant(participant),
         {:ok, queued} <-
           ConversationServer.send_provider_participant_message(
             group_id,
             conversation_id,
             participant["participant_id"],
             %{
               "idempotency_key" => "lark-task-card:" <> attrs["payload"]["task_id"],
               "content" => attrs["payload"]["task_id"]
             }
           ) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "task_id" => attrs["payload"]["task_id"],
         "delivery_status" => queued["delivery_status"]
       }}
    end
  end

  def post(%{agent: %{"role" => "router"}}, _connect, _params),
    do: {:error, "conversation_id, chat_id and message_id are required"}

  def post(_scope, _connect, _params),
    do: {:error, "only the Router that created this Task can publish its Task card"}

  def delivery?(rec), do: get_in(rec, ["participant_payload", "projection"]) == @kind

  @doc """
  Performs one claimed Task-card delivery. A result with
  `participant_receipt` updates the Participant payload.
  """
  def deliver(connect, rec) do
    case project(rec) do
      {:ok, :noop, _desired, nil} ->
        {:ok, :task_card_projection_current}

      {:ok, :post, desired, card} ->
        post_card(connect, rec, desired, card)

      {:ok, :update, desired, card} ->
        update_card(connect, rec, desired, card)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Every ambiguous Task-card write is settled by replaying the same delivery.
  The post replay reuses its `uuid`; an update is idempotent.
  """
  def verify(rec) do
    if delivery?(rec),
      do: {:missing, :replay_lark_task_card_write},
      else: {:unknown, :stale_provider_delivery_unverified}
  end

  def project(
        %{
          "participant_payload" =>
            %{
              "projection" => @kind,
              "projection_version" => @projection_version,
              "task_id" => "comma_" <> _,
              "chat_id" => chat_id,
              "reply_message_id" => reply_message_id,
              "card_message_id" => card_message_id,
              "lifecycle" => lifecycle,
              "title" => title,
              "output" => output
            } = payload
        } = rec
      )
      when chat_id != "" and reply_message_id != "" and is_binary(card_message_id) and
             lifecycle in @lifecycles and is_binary(title) and is_binary(output) do
    if str(payload["blocked_reason"]) == "" do
      with {:ok, refreshed} <- TaskCardProjection.refresh(payload, rec) do
        desired = TaskCardProjection.advance(refreshed, rec)

        action =
          cond do
            card_message_id == "" -> :post
            render_required?(payload, desired) -> :update
            true -> :noop
          end

        if action == :noop,
          do: {:ok, :noop, desired, nil},
          else: with({:ok, card} <- render(desired), do: {:ok, action, desired, card})
      end
    else
      {:ok, :noop, payload, nil}
    end
  end

  def project(_rec), do: {:error, :invalid_lark_task_card_projection}

  defp post_card(connect, rec, desired, card) do
    replay? = is_integer(rec["provider_outcome_ambiguous_at"])

    # Replacement posts have the same deduplication limit as first posts.
    # The old card address does not prove whether the replacement landed.
    if replay? and
         SystemsClock.system_time(:millisecond) - rec["provider_outcome_ambiguous_at"] >
           @replay_window_ms do
      quarantine(desired, :task_card_post_outcome_unknown)
    else
      case Lark.reply_card(
             connect,
             desired["reply_message_id"],
             card,
             post_uuid(desired),
             desired["chat_type"] != "p2p"
           ) do
        {:ok, response} ->
          with {:ok, receipt} <- written(desired, response) do
            if replay?, do: refresh_replayed_card(connect, receipt, card), else: {:ok, receipt}
          end

        {:error, reason} ->
          cond do
            ambiguous?(reason) -> {:error, {:ambiguous, reason}}
            rate_limited?(reason) -> {:error, {:retry_after, @rate_limit_delay_ms, reason}}
            # An earlier attempt may have posted. Without its address, a
            # different outcome now cannot prove that no card exists.
            replay? -> quarantine(desired, :task_card_post_outcome_unknown)
            true -> {:error, reason}
          end
      end
    end
  end

  # A deduplicated replay can return the card that an earlier attempt posted
  # with older content. Write the current content to that exact address.
  defp refresh_replayed_card(connect, receipt, card) do
    payload = get_in(receipt, ["participant_receipt", "payload"])

    case Lark.update_card(connect, payload["card_message_id"], card) do
      {:ok, _response} ->
        {:ok, receipt}

      {:error, _reason} ->
        {:ok, put_in(receipt, ["participant_receipt", "payload", "render_repair_required"], true)}
    end
  end

  defp update_card(connect, rec, desired, card) do
    card_message_id = desired["card_message_id"]

    case Lark.update_card(connect, card_message_id, card) do
      {:ok, _response} ->
        {:ok, receipt(desired, card_message_id)}

      {:error, reason} ->
        cond do
          card_gone?(reason) ->
            replacement =
              desired
              |> Map.put("card_message_id", "")
              |> Map.put("replaced_card_message_id", card_message_id)

            post_card(connect, rec, replacement, card)

          ambiguous?(reason) ->
            {:error, {:ambiguous, reason}}

          rate_limited?(reason) ->
            {:error, {:retry_after, @rate_limit_delay_ms, reason}}

          true ->
            {:error, reason}
        end
    end
  end

  defp written(desired, %{"message_id" => message_id} = response)
       when is_binary(message_id) and message_id != "" do
    if str(response["chat_id"]) in ["", desired["chat_id"]],
      do: {:ok, receipt(desired, message_id)},
      else: quarantine(desired, :task_card_write_address_conflict)
  end

  defp written(_desired, _response),
    do: {:error, {:ambiguous, :task_card_write_address_missing}}

  defp receipt(payload, card_message_id) do
    %{
      "participant_receipt" => %{
        "payload" =>
          payload
          |> Map.put("card_message_id", str(card_message_id))
          |> Map.delete("replaced_card_message_id")
      }
    }
  end

  defp quarantine(payload, reason) do
    {:ok,
     %{
       "participant_receipt" => %{
         "payload" => Map.put(payload, "blocked_reason", inspect(reason)),
         "notification_filter" => %{"messages" => "none", "statuses" => "none"},
         "telemetry_operation" => "lark_task_card"
       }
     }}
  end

  # One deterministic request identity per card address: the first post, or
  # the post that replaces one exact gone card. Lark limits `uuid` to 50
  # characters.
  defp post_uuid(payload) do
    digest =
      :crypto.hash(
        :sha256,
        Enum.join([@kind, payload["task_id"], str(payload["replaced_card_message_id"])], "\0")
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    "ctc_" <> digest
  end

  defp render_required?(payload, desired) do
    payload["render_repair_required"] != false or
      render(TaskCardProjection.normalize(payload)) !=
        render(TaskCardProjection.normalize(desired))
  end

  defp render(payload) do
    {status, status_label} = TaskCardProjection.status(payload["lifecycle"])

    MessageRenderer.render_surface(LarkMessageRenderer, %Surface{
      kind: :task_card,
      id: payload["task_id"],
      fallback: "Task #{payload["title"]}: #{String.downcase(status_label)}",
      title: payload["title"],
      subtitle: status_label,
      status: surface_status(status),
      details: TaskCardProjection.details(payload),
      output: TaskCardProjection.output(payload)
    })
  end

  defp surface_status("pending"), do: :pending
  defp surface_status("in_progress"), do: :in_progress
  defp surface_status("complete"), do: :complete
  defp surface_status("error"), do: :error

  defp participant_attrs(connect, conversation, chat_id, message_id, chat_type) do
    target = %{
      "provider" => "lark",
      "projection" => @kind,
      "connect_id" => str(connect["connect_id"]),
      "chat_id" => chat_id,
      "reply_message_id" => message_id
    }

    task_id =
      "comma_" <>
        Crypto.hex(
          conversation["conversation_id"] <> ProviderConversationInput.target_key(target)
        )

    with {:ok, projection} <- TaskCardProjection.initial_payload(conversation) do
      payload =
        Map.merge(projection, %{
          "task_id" => task_id,
          "chat_type" => chat_type,
          "card_message_id" => ""
        })

      {:ok,
       ProviderConversationInput.provider_participant(target, %{
         "role_label" => "task_card",
         "delivery_cursor_seq" => TaskCardProjection.tail_seq(conversation),
         "notification_filter" => %{"messages" => "all", "statuses" => "all"},
         "payload" => payload
       })}
    end
  end

  defp validate_card_target(chat_id, message_id, chat_type) do
    cond do
      chat_id == "" or message_id == "" ->
        {:error, "chat_id and message_id are required"}

      chat_type not in @chat_types ->
        {:error, "chat_type must be group or p2p"}

      true ->
        :ok
    end
  end

  defp validate_card_connect(connect) do
    if str(connect["connect_id"]) != "",
      do: :ok,
      else: {:error, "connect_id is required"}
  end

  # The IFC destination takes chat_id as a hint for the replied message. Bind
  # the card to the chat that really holds that message before any write.
  defp validate_card_address(connect, chat_id, message_id) do
    case Lark.message_chat_id(connect, message_id) do
      {:ok, ^chat_id} ->
        :ok

      {:ok, _other} ->
        {:error, "message_id does not belong to chat_id"}

      {:error, reason} ->
        {:error, "cannot read the Lark source message: #{reason_text(reason)}"}
    end
  end

  defp validate_card_conversation(conversation, group_id, agent_id) do
    cond do
      conversation["kind"] != "agent_task" or conversation["agent_group_id"] != group_id ->
        {:error, "conversation_id must identify a Task conversation in this group"}

      conversation["created_by_agent_id"] != agent_id ->
        {:error, "only the Router that created this Task can publish its Task card"}

      true ->
        :ok
    end
  end

  defp validate_card_participant(participant) do
    case str(get_in(participant, ["payload", "blocked_reason"])) do
      "" ->
        :ok

      reason ->
        {:error,
         "Task card publication is quarantined for this Task (" <>
           reason <> "); reposting cannot re-enable it"}
    end
  end

  defp ambiguous?(reason),
    do: reason |> reason_text() |> String.contains?("write outcome unknown")

  defp rate_limited?(reason) do
    text = reason_text(reason)

    String.contains?(text, "Lark HTTP 429") or
      Enum.any?(@rate_limit_codes, &String.contains?(text, "Lark API error #{&1} "))
  end

  defp card_gone?(reason) do
    text = reason_text(reason)
    Enum.any?(@card_gone_codes, &String.contains?(text, "Lark API error #{&1} "))
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
