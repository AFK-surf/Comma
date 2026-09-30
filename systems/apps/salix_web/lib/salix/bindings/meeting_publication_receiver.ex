defmodule Salix.Bindings.MeetingPublicationReceiver do
  @moduledoc """
  Shared-Schedules receiver for meeting notices. Slack's scheduled card includes
  the saved preparation body. Feishu retains the T-7 base card.

  Both use direct participant messages on the Router conversation and the
  existing idempotent outbox, never the research conversation. Each notice kind
  has one per-occurrence key. Receiver ACK means durably queued, not delivered.
  The delivery boundary rejects attempts admitted at or after meeting start;
  an in-flight provider request may finish later. Persisted T-1 reminders are
  terminally rejected without a message or attendee lookup.
  See docs/meetings-calendar.md for the boundary and assumptions.
  """

  alias SalixIM.{ConversationServer, ProviderConversationInput, RouterConversationInput}
  alias SalixMeet.MeetingPlan

  @doc false
  def receive(%{"kind" => "personal"} = payload, status, opts)
      when status in [:claimed, :exists] and is_list(opts),
      do: Salix.Bindings.MeetingPersonalPublication.receive(payload, opts)

  def receive(%{"kind" => "deadline_fence"} = payload, status, opts)
      when status in [:claimed, :exists] and is_list(opts) do
    case MeetingPlan.open_trigger(
           payload["group_id"],
           payload["meeting_plan_id"],
           "deadline_fence",
           payload["dispatch_revision"],
           Keyword.take(opts, [:now])
         ) do
      {:ok, _} -> {:ok, :fired}
      {:error, _} = error -> error
    end
  end

  def receive(payload, status, opts) when status in [:claimed, :exists] and is_list(opts) do
    payload = stringify(payload)
    group_id = trim(payload["group_id"])
    plan_id = trim(payload["meeting_plan_id"])

    kind = payload["kind"] || "card"
    plan_opts = [kind: kind] ++ Keyword.take(opts, [:now])

    if group_id == "" or plan_id == "" or kind != "card" do
      {:ok, :undeliverable, :invalid_meeting_publication_payload}
    else
      case MeetingPlan.card_action(group_id, plan_id, plan_opts) do
        {:settle, _reason} -> {:ok, :fired}
        {:ok, action} -> publish_card(group_id, plan_id, action, kind)
        {:error, _reason} = error -> error
      end
    end
  end

  def receive(_payload, {:error, reason}, _opts), do: {:error, reason}
  def receive(_payload, _status, _opts), do: {:error, :invalid_meeting_publication_invocation}

  defp publish_card(group_id, plan_id, action, kind) do
    with {:ok, :queued} <- queue_notice(group_id, plan_id, action),
         do: settle_sent(group_id, plan_id, kind)
  end

  @doc false
  def queue_notice(group_id, plan_id, action) do
    with {:ok, metadata} <- participant_metadata(action),
         {:ok, conversation} <- RouterConversationInput.ensure(group_id),
         conversation_id when conversation_id != "" <- trim(conversation["conversation_id"]),
         {:ok, participant_attrs} <-
           ProviderConversationInput.participant_attrs(%{"metadata" => metadata}),
         {:ok, participant} <-
           ConversationServer.ensure_group_conversation_provider_participant(
             group_id,
             conversation_id,
             participant_attrs
           ),
         {:ok, result} <-
           ConversationServer.send_provider_participant_message(
             group_id,
             conversation_id,
             participant["participant_id"],
             %{
               "idempotency_key" => action["idempotency_key"],
               "content" => [%{"type" => "text", "text" => action["text"]}],
               "metadata" => %{
                 "source" => "meeting_publication",
                 "meeting_plan_id" => plan_id,
                 "not_after_ms" => action["not_after_ms"]
               }
             }
           ) do
      case result["delivery_status"] do
        status when status in ["queued", "exists"] -> {:ok, :queued}
        other -> {:error, {:meeting_publication_invalid_status, other}}
      end
    else
      "" ->
        {:error, :router_conversation_missing}

      # Same key, different bytes: an older rendering of this occurrence's
      # card is already durably queued. That IS the card — content updates
      # are explicitly out of scope for this track.
      {:error, {:conflict, _details}} ->
        {:ok, :queued}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:meeting_publication_invalid_result, other}}
    end
  end

  # Queue durability first, checkpoint second: a failed checkpoint keeps the
  # schedule claim, the next sweep re-runs, and the outbox idempotency turns
  # the resend into `exists`.
  defp settle_sent(group_id, plan_id, kind) do
    case MeetingPlan.checkpoint_card_sent(group_id, plan_id, kind: kind) do
      :ok -> {:ok, :fired}
      {:error, _reason} = error -> error
    end
  end

  defp participant_metadata(%{"provider" => "slack", "params" => params}) do
    params = stringify(params)
    connect_id = trim(params["connect_id"])
    channel = trim(params["channel"])

    if connect_id == "" or channel == "" do
      {:error, :invalid_publication_target}
    else
      metadata =
        %{"provider" => "slack", "connect_id" => connect_id, "channel_id" => channel}
        |> put_present("thread_ts", trim(params["thread_ts"]))

      {:ok, metadata}
    end
  end

  defp participant_metadata(%{"provider" => "feishu", "params" => params}) do
    params = stringify(params)
    connect_id = trim(params["connect_id"])
    chat_id = trim(params["receive_id"])

    if connect_id == "" or chat_id == "" do
      {:error, :invalid_publication_target}
    else
      {:ok,
       %{
         "provider" => "feishu",
         "connect_id" => connect_id,
         "chat_id" => chat_id,
         "mentions" => %{"mode" => "none", "users" => []}
       }}
    end
  end

  defp participant_metadata(_action), do: {:error, :unsupported_publication_provider}

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
