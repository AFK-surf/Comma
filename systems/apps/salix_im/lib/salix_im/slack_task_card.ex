defmodule SalixIM.SlackTaskCard do
  @moduledoc """
  Slack native Task-surface projection over a provider Participant.

  Tasks render as `task_card`.

  Conversation lifecycle remains authoritative. `SalixIM.TaskCardProjection`
  owns the provider-neutral projection; this module owns the Slack address,
  layout and write evidence: ordered delivery, receipt-first settlement through
  signed message metadata, quarantine, and crash recovery.
  """

  alias SalixIM.{
    ConversationMessage,
    ConversationServer,
    Conversations,
    MessageRenderer,
    ProviderConversationInput,
    TaskCardProjection
  }

  alias SalixIM.MessageRenderer.Surface
  alias SalixIM.Provider.Slack.MessageRenderer, as: SlackMessageRenderer

  alias SalixStore.Crypto

  import SalixIM.Provider.Util, only: [str: 1]

  @kind "slack_task_card"
  @metadata_event_type "comma_task_card_projection"
  @projection_version TaskCardProjection.projection_version()
  @render_version 7
  @lifecycles TaskCardProjection.lifecycles()
  @terminal ~w(completed failed cancelled)
  @timestamp ~r/\A\d{1,20}\.\d{1,12}\z/

  def metadata_event_type, do: @metadata_event_type

  def metadata(rec, desired) do
    {:ok, version} = projection_version(desired)

    %{
      "event_type" => @metadata_event_type,
      "event_payload" => %{
        "group_id" => rec["agent_group_id"],
        "conversation_id" => rec["conversation_id"],
        "participant_id" => rec["participant_id"],
        "delivery_id" => rec["delivery_id"],
        "operation_ref" => rec["operation_ref"],
        "connect_id" => get_in(rec, ["participant_payload", "connect_id"]),
        "block_id" => block_id!(desired),
        "render_version" => render_version(version)
      }
    }
  end

  def event(%{"event" => event, "event_id" => event_id}) when is_map(event) do
    kind = event["type"]

    metadata =
      if kind == "message_metadata_deleted",
        do: event["previous_metadata"],
        else: event["metadata"]

    route = if is_map(metadata), do: metadata["event_payload"], else: nil

    if kind in ~w(message_metadata_posted message_metadata_updated message_metadata_deleted) and
         is_map(metadata) and metadata["event_type"] == @metadata_event_type and is_map(route) do
      {:ok,
       route
       |> Map.take(
         ~w(group_id conversation_id participant_id delivery_id operation_ref connect_id block_id render_version)
       )
       |> Map.merge(%{
         "kind" => kind,
         "event_id" => str(event_id),
         "channel_id" => str(event["channel_id"]),
         "message_ts" => str(event["message_ts"])
       })}
    else
      :ignore
    end
  end

  def event(_envelope), do: :ignore

  def post(
        %{agent: %{"role" => "router"}, group_id: group_id, agent_id: agent_id},
        connect,
        %{"conversation_id" => conversation_id, "channel" => channel, "thread_ts" => thread_ts}
      ) do
    with :ok <- validate_card_target(channel, thread_ts),
         :ok <- validate_card_connect(connect),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(group_id, conversation_id),
         :ok <- validate_card_conversation(conversation, group_id, agent_id),
         {:ok, attrs} <- participant_attrs(connect, conversation, channel, thread_ts),
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
               "idempotency_key" => "slack-task-card:" <> attrs["payload"]["task_id"],
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

  def post(_scope, _connect, _params), do: {:error, "invalid Slack Task card request"}

  defp validate_card_target(channel, thread_ts) do
    if channel != "" and is_binary(thread_ts) and Regex.match?(@timestamp, thread_ts),
      do: :ok,
      else:
        {:error,
         "channel and thread_ts are required, and thread_ts must be a Slack message timestamp"}
  end

  defp validate_card_connect(connect) do
    if str(connect["connect_id"]) != "",
      do: :ok,
      else: {:error, "connect_id is required"}
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

  def delivery?(rec), do: get_in(rec, ["participant_payload", "projection"]) == @kind

  defdelegate output_message?(message), to: TaskCardProjection
  defdelegate timeline_message?(message), to: TaskCardProjection

  def participant?(%{"provider" => "slack"} = participant),
    do: TaskCardProjection.participant?(participant)

  def participant?(_participant), do: false

  def project(
        %{
          "participant_payload" =>
            %{
              "projection" => @kind,
              "task_id" => "comma_" <> _,
              "channel_id" => channel,
              "thread_ts" => thread,
              "lifecycle" => lifecycle,
              "title" => title,
              "output" => output
            } = payload
        } = rec
      )
      when channel != "" and thread != "" and lifecycle in @lifecycles and is_binary(title) and
             is_binary(output) do
    with {:ok, version} <- projection_version(payload) do
      if str(payload["blocked_reason"]) == "" do
        with {:ok, projection_payload} <- refresh_projection_payload(payload, rec, version) do
          desired = advance(projection_payload, rec, version)

          action =
            cond do
              desired["message_ts"] == "" ->
                :post

              get_in(rec, ["message_metadata", "slack_task_card_repair"]) ==
                desired["message_ts"] or render_required?(payload, desired, version) ->
                :update

              true ->
                :noop
            end

          {:ok, action, desired, if(action == :noop, do: nil, else: render(desired, version))}
        end
      else
        {:ok, :noop, payload, nil}
      end
    end
  end

  def project(_rec), do: {:error, :invalid_slack_task_card_projection}

  def written(desired, expected_ts, channel, %{"channel" => channel, "ts" => message_ts})
      when is_binary(message_ts) do
    if valid_message_ts?(message_ts) and (is_nil(expected_ts) or expected_ts == message_ts),
      do: {:ok, receipt(desired, message_ts)},
      else: {:error, {:ambiguous, :task_card_write_address_mismatch}}
  end

  def written(_desired, _expected_ts, _channel, _response),
    do: {:error, {:ambiguous, :task_card_write_address_mismatch}}

  def accept_event(payload, rec, event) do
    if event["operation_ref"] != rec["operation_ref"] do
      :ignore
    else
      case projection_version(payload) do
        {:ok, version} ->
          case refresh_projection_payload(payload, rec, version) do
            {:ok, projection_payload} ->
              desired = advance(projection_payload, rec, version)
              ts = event["message_ts"]

              cond do
                event["block_id"] != block_id(desired, version) ->
                  quarantine(payload, :task_card_identity_conflict)

                not valid_message_ts?(ts) ->
                  quarantine(payload, :task_card_write_address_missing)

                not address_authorized?(payload, event) ->
                  quarantine(payload, :task_card_write_address_conflict)

                true ->
                  {:ok, receipt(receipt_projection(desired, version, event), ts)}
              end

            {:error, reason} ->
              {:error, {:task_card_projection_refresh_failed, reason}}
          end

        {:error, _reason} ->
          quarantine(payload, :invalid_task_card_projection_version)
      end
    end
  end

  def current_deletion?(payload, event) do
    with {:ok, version} <- projection_version(payload) do
      event["kind"] == "message_metadata_deleted" and
        event["block_id"] == block_id(payload, version) and valid_message_ts?(event["message_ts"]) and
        event["message_ts"] == payload["message_ts"]
    else
      {:error, _reason} -> false
    end
  end

  defp address_authorized?(payload, event) do
    payload["message_ts"] in ["", event["message_ts"]] or
      event["kind"] == "message_metadata_posted"
  end

  defp receipt(payload, message_ts) do
    %{"participant_receipt" => %{"payload" => Map.put(payload, "message_ts", str(message_ts))}}
  end

  defp quarantine(payload, reason) do
    {:ok,
     %{
       "participant_receipt" => %{
         "payload" => Map.put(payload, "blocked_reason", inspect(reason)),
         "notification_filter" => %{"messages" => "none", "statuses" => "none"},
         "telemetry_operation" => "slack_task_card"
       }
     }}
  end

  defp participant_attrs(connect, conversation, channel, thread_ts) do
    target = %{
      "provider" => "slack",
      "projection" => @kind,
      "connect_id" => str(connect["connect_id"]),
      "channel_id" => channel,
      "thread_ts" => thread_ts
    }

    task_id =
      "comma_" <>
        Crypto.hex(
          conversation["conversation_id"] <> ProviderConversationInput.target_key(target)
        )

    with {:ok, projection} <- TaskCardProjection.initial_payload(conversation) do
      payload = Map.merge(projection, %{"task_id" => task_id, "message_ts" => ""})

      {:ok,
       ProviderConversationInput.provider_participant(target, %{
         "role_label" => "task_card",
         "delivery_cursor_seq" => TaskCardProjection.tail_seq(conversation),
         "notification_filter" => %{"messages" => "all", "statuses" => "all"},
         "payload" => payload
       })}
    end
  end

  defp refresh_projection_payload(payload, _rec, 1), do: {:ok, payload}

  defp refresh_projection_payload(payload, rec, @projection_version),
    do: TaskCardProjection.refresh(payload, rec)

  defp advance(payload, rec, 1) do
    next_lifecycle =
      TaskCardProjection.lifecycle(rec["conversation_status"], payload["lifecycle"])

    output = rec["message_content"] |> ConversationMessage.text_content() |> String.trim()
    metadata = rec["message_metadata"] || %{}

    next_output =
      cond do
        metadata["task_command"] == true ->
          ""

        payload["lifecycle"] in @terminal and next_lifecycle == payload["lifecycle"] ->
          payload["output"]

        rec["source_actor_type"] == "agent" and str(rec["source_role_label"]) != "delegator" and
            output != "" ->
          TaskCardProjection.bounded_content(output)

        true ->
          payload["output"]
      end

    payload
    |> Map.put("title", TaskCardProjection.title(rec["conversation_title"]))
    |> Map.put("lifecycle", next_lifecycle)
    |> Map.put("output", next_output)
  end

  defp advance(payload, rec, @projection_version), do: TaskCardProjection.advance(payload, rec)

  defp surface_status("pending"), do: :pending
  defp surface_status("in_progress"), do: :in_progress
  defp surface_status("complete"), do: :complete
  defp surface_status("error"), do: :error

  defp render(payload, 1) do
    {status, details} = legacy_status_details(payload["lifecycle"], payload["output"])

    card = %{
      "type" => "task_card",
      "task_id" => payload["task_id"],
      "block_id" => render_block_id(payload, 1),
      "title" => payload["title"],
      "status" => status,
      "details" => rich_text(details)
    }

    %{
      "text" => "Task #{payload["title"]}: #{String.downcase(details)}",
      "blocks" => [
        if(payload["output"] == "",
          do: card,
          else: Map.put(card, "output", rich_text(payload["output"]))
        )
      ]
    }
  end

  defp render(payload, @projection_version) do
    {status, status_label} = TaskCardProjection.status(payload["lifecycle"])

    surface =
      %Surface{
        kind: :task_card,
        id: payload["task_id"],
        render_id: render_block_id(payload, @projection_version),
        fallback: "Task #{payload["title"]}: #{String.downcase(status_label)}",
        title: payload["title"],
        status: surface_status(status),
        details: TaskCardProjection.details(payload),
        output: TaskCardProjection.output(payload)
      }

    {:ok, rendered} = MessageRenderer.render_surface(SlackMessageRenderer, surface)
    %{"text" => rendered.text, "blocks" => rendered.blocks}
  end

  defp render_required?(payload, desired, version) do
    render_proof_missing?(payload, version) or
      render(normalized_render_payload(payload, version), version) !=
        render(normalized_render_payload(desired, version), version)
  end

  defp render_proof_missing?(payload, @projection_version),
    do: payload["render_repair_required"] != false

  defp render_proof_missing?(_payload, 1), do: false

  defp normalized_render_payload(payload, 1), do: payload

  defp normalized_render_payload(payload, @projection_version),
    do: TaskCardProjection.normalize(payload)

  # Version 2 deliberately retains the deployed version-1 identity. An old
  # ordinal preserves unknown payload fields but can still render and sign this
  # identity during a rolling deploy or rollback; operation_ref keeps receipts
  # scoped to the exact delivery.
  defp block_id(payload, version) when version in [1, @projection_version] do
    identity = Map.take(payload, ~w(task_id title lifecycle output))
    "comma_task_card_" <> Crypto.hex(:erlang.term_to_binary(identity, [:deterministic]))
  end

  # The metadata route keeps the deployed receipt identity above so old owners
  # can still admit exact operation-scoped evidence. Slack Block Kit requires a
  # fresh block_id for an updated block, so the visible v2 card also identifies
  # its render generation and canonical visible message window. The scan
  # boundary is deliberately excluded: an internal/control message can advance
  # that boundary without changing anything Slack renders.
  defp render_block_id(payload, 1), do: block_id(payload, 1)

  defp render_block_id(payload, @projection_version) do
    identity = %{
      "projection_block_id" => block_id(payload, @projection_version),
      "surface_kind" => payload["surface_kind"] || "task_card",
      "recent_messages" => payload["recent_messages"],
      "model_label" => str(payload["model_label"]),
      "render_version" => @render_version
    }

    "comma_task_card_render_" <>
      Crypto.hex(:erlang.term_to_binary(identity, [:deterministic]))
  end

  defp block_id!(payload) do
    {:ok, version} = projection_version(payload)
    block_id(payload, version)
  end

  defp receipt_projection(payload, @projection_version, %{"render_version" => @render_version}),
    do: Map.put(payload, "render_repair_required", false)

  defp receipt_projection(payload, @projection_version, _event),
    do: Map.put(payload, "render_repair_required", true)

  defp receipt_projection(payload, 1, _event), do: payload

  defp legacy_status_details("active", _output), do: {"in_progress", "Work in progress"}
  defp legacy_status_details("ready_for_review", _output), do: {"complete", "Ready for review"}
  defp legacy_status_details("completed", _output), do: {"complete", "Completed"}
  defp legacy_status_details("failed", _output), do: {"error", "Failed"}
  defp legacy_status_details("cancelled", _output), do: {"error", "Cancelled"}
  defp legacy_status_details("escalated", _output), do: {"error", "Needs attention"}

  defp rich_text(value),
    do: %{
      "type" => "rich_text",
      "elements" => [
        %{
          "type" => "rich_text_section",
          "elements" => [%{"type" => "text", "text" => value}]
        }
      ]
    }

  defp projection_version(%{"projection_version" => @projection_version}),
    do: {:ok, @projection_version}

  defp projection_version(payload) when is_map(payload) do
    if Map.has_key?(payload, "projection_version") or Map.has_key?(payload, "recent_messages"),
      do: {:error, :invalid_slack_task_card_projection_version},
      else: {:ok, 1}
  end

  defp projection_version(_payload), do: {:error, :invalid_slack_task_card_projection_version}

  defp render_version(1), do: 1
  defp render_version(@projection_version), do: @render_version

  defp valid_message_ts?(value), do: is_binary(value) and Regex.match?(@timestamp, value)
end
