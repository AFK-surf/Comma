defmodule SalixIM.SlackTaskCard do
  @moduledoc """
  Slack native Task-surface projection over a provider Participant.

  Tasks render as `task_card`.

  Conversation lifecycle remains authoritative; this module materializes its
  externally deliverable projection and classifies Slack write evidence. The
  ordered delivery, receipt-first settlement, quarantine, and crash recovery
  protocol is modeled in `tla/salix/SlackTaskCard.tla`.
  """

  alias SalixIM.{
    AgentModelLabel,
    ConversationMessage,
    ConversationServer,
    Conversations,
    MessageRenderer,
    ProviderConversationInput
  }

  alias SalixIM.MessageRenderer.Surface
  alias SalixIM.Provider.Slack.MessageRenderer, as: SlackMessageRenderer

  alias SalixStore.Crypto

  import SalixIM.Provider.Util, only: [int_or: 2, str: 1]

  @kind "slack_task_card"
  @metadata_event_type "comma_task_card_projection"
  @projection_version 2
  @render_version 7
  @lifecycles ~w(active ready_for_review completed failed cancelled escalated)
  @terminal ~w(completed failed cancelled)
  @content_limit 2_500
  @timeline_entry_limit 1_200
  @timeline_details_limit 2
  @timeline_window_limit 3
  @initial_timeline_scan_limit 200
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

  def output_message?(%{"actor_type" => "agent"} = message) do
    str(message["role_label"]) != "delegator" and
      timeline_message?(message)
  end

  def output_message?(_message), do: false

  def timeline_message?(%{"actor_type" => actor_type} = message)
      when actor_type in ["agent", "user", "provider_user"] do
    String.trim(ConversationMessage.text_content(message["content"])) != "" and
      get_in(message, ["metadata", "message_type"]) != "task_command" and
      nonempty_audience?(message["delivery_filter"]) and
      nonempty_audience?(message["mentions"])
  end

  def timeline_message?(_message), do: false

  def participant?(%{
        "actor_type" => "provider",
        "provider" => "slack",
        "role_label" => "task_card"
      }),
      do: true

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

  @spec merge_participant_receipt(map(), map()) :: map()
  def merge_participant_receipt(
        %{"payload" => %{"projection" => @kind, "blocked_reason" => reason}} = participant,
        _receipt
      )
      when is_binary(reason) and reason != "",
      do: participant

  def merge_participant_receipt(participant, receipt), do: Map.merge(participant, receipt)

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

    tail_seq =
      max(int_or(conversation["message_tail_seq"] || conversation["message_count"], 0), 0)

    with {:ok, output} <- initial_output(conversation),
         {:ok, recent_messages} <- initial_recent_messages(conversation) do
      payload =
        %{
          "task_id" => task_id,
          "message_ts" => "",
          "title" => title(conversation["title"]),
          "lifecycle" => lifecycle(conversation["status"], "active"),
          "projection_version" => @projection_version,
          "recent_messages" => recent_messages,
          "recent_messages_through_seq" => tail_seq,
          "render_repair_required" => true,
          "output" => output
        }
        |> put_model_label(AgentModelLabel.resolve(conversation["task_worker_agent_id"]))
        |> Map.put("surface_kind", "task_card")

      {:ok,
       ProviderConversationInput.provider_participant(target, %{
         "role_label" => "task_card",
         "delivery_cursor_seq" => tail_seq,
         "notification_filter" => %{"messages" => "all", "statuses" => "all"},
         "payload" => payload
       })}
    end
  end

  defp initial_output(%{"task_public_output_message_id" => message_id} = conversation)
       when is_binary(message_id) do
    case Conversations.get_group_conversation_message(
           conversation["agent_group_id"],
           conversation["conversation_id"],
           message_id
         ) do
      {:ok, message} ->
        {:ok,
         message["content"]
         |> ConversationMessage.text_content()
         |> String.trim()
         |> bounded_content()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initial_output(_conversation), do: {:ok, ""}

  defp initial_recent_messages(
         %{
           "agent_group_id" => group_id,
           "conversation_id" => conversation_id
         } = conversation
       ) do
    tail_seq = conversation["message_tail_seq"] || conversation["message_count"]
    recent_messages_through(group_id, conversation_id, max(int_or(tail_seq, 0), 0))
  end

  defp recent_messages_through(_group_id, _conversation_id, 0), do: {:ok, []}

  defp recent_messages_through(group_id, conversation_id, boundary_seq)
       when is_integer(boundary_seq) and boundary_seq > 0 do
    case Conversations.list_group_conversation_messages(group_id, conversation_id,
           after_seq: max(boundary_seq - @initial_timeline_scan_limit, 0),
           limit: @initial_timeline_scan_limit
         ) do
      {:ok, messages} ->
        {:ok,
         messages
         |> Enum.filter(&(int_or(&1["seq"], 0) <= boundary_seq))
         |> Enum.filter(&timeline_message?/1)
         |> Enum.take(-@timeline_window_limit)
         |> Enum.map(&recent_message/1)}

      {:error, _reason} = error ->
        error
    end
  end

  defp refresh_projection_payload(payload, _rec, 1), do: {:ok, payload}

  defp refresh_projection_payload(
         payload,
         %{
           "agent_group_id" => group_id,
           "conversation_id" => conversation_id
         } = rec,
         @projection_version
       ) do
    boundary_seq = int_or(rec["message_seq"] || rec["conversation_message_tail_seq"], -1)

    with true <- boundary_seq >= 0,
         {:ok, recent_messages} <-
           recent_messages_through(group_id, conversation_id, boundary_seq) do
      {:ok,
       payload
       |> Map.delete("details")
       |> Map.put("render_repair_required", false)
       |> Map.put("recent_messages", recent_messages)
       |> Map.put("recent_messages_through_seq", boundary_seq)}
    else
      false -> {:error, :invalid_slack_task_card_projection_boundary}
      {:error, _reason} = error -> error
    end
  end

  defp refresh_projection_payload(_payload, _rec, @projection_version),
    do: {:error, :invalid_slack_task_card_projection_boundary}

  defp advance(payload, rec, 1) do
    next_lifecycle = lifecycle(rec["conversation_status"], payload["lifecycle"])
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
          bounded_content(output)

        true ->
          payload["output"]
      end

    payload
    |> Map.put("title", title(rec["conversation_title"]))
    |> Map.put("lifecycle", next_lifecycle)
    |> Map.put("output", next_output)
  end

  defp advance(payload, rec, @projection_version) do
    payload = normalize_recent_messages(payload)
    next_lifecycle = lifecycle(rec["conversation_status"], payload["lifecycle"])
    message_text = rec["message_content"] |> ConversationMessage.text_content() |> String.trim()
    metadata = rec["message_metadata"] || %{}
    recent_messages = append_recent_message(payload["recent_messages"], rec, message_text)

    next_output =
      cond do
        metadata["task_command"] == true ->
          ""

        payload["lifecycle"] in @terminal and next_lifecycle == payload["lifecycle"] ->
          payload["output"]

        rec["source_actor_type"] == "agent" and str(rec["source_role_label"]) != "delegator" and
            message_text != "" ->
          bounded_content(message_text)

        true ->
          payload["output"]
      end

    payload
    |> Map.put("title", title(rec["conversation_title"]))
    |> Map.put("lifecycle", next_lifecycle)
    |> Map.put("recent_messages", recent_messages)
    |> Map.put(
      "recent_messages_through_seq",
      max(
        int_or(payload["recent_messages_through_seq"], 0),
        max(int_or(rec["message_seq"] || rec["conversation_message_tail_seq"], 0), 0)
      )
    )
    |> Map.put("output", next_output)
    |> Map.put("surface_kind", "task_card")
  end

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
    {status, status_label} = status_details(payload["lifecycle"])

    surface =
      %Surface{
        kind: :task_card,
        id: payload["task_id"],
        render_id: render_block_id(payload, @projection_version),
        fallback: "Task #{payload["title"]}: #{String.downcase(status_label)}",
        title: payload["title"],
        status: surface_status(status),
        details: card_details(payload),
        output: timeline_output(payload)
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
    do: normalize_recent_messages(payload)

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

  defp normalize_recent_messages(payload) do
    recent_messages =
      payload["recent_messages"]
      |> List.wrap()
      |> Enum.map(&normalize_recent_message/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["seq"])
      |> Enum.sort_by(& &1["seq"])
      |> Enum.take(-@timeline_window_limit)

    payload
    |> Map.delete("details")
    |> Map.put("recent_messages", recent_messages)
    |> Map.put(
      "recent_messages_through_seq",
      max(int_or(payload["recent_messages_through_seq"], 0), 0)
    )
  end

  defp receipt_projection(payload, @projection_version, %{"render_version" => @render_version}),
    do: Map.put(payload, "render_repair_required", false)

  defp receipt_projection(payload, @projection_version, _event),
    do: Map.put(payload, "render_repair_required", true)

  defp receipt_projection(payload, 1, _event), do: payload

  defp append_recent_message(recent_messages, rec, text) do
    message = if delivery_timeline_message?(rec, text), do: recent_message(rec, text)

    case message do
      nil ->
        recent_messages

      message ->
        recent_messages
        |> Enum.reject(&(&1["seq"] == message["seq"]))
        |> Kernel.++([message])
        |> Enum.sort_by(& &1["seq"])
        |> Enum.take(-@timeline_window_limit)
    end
  end

  defp recent_message(message) do
    %{
      "seq" => message["seq"],
      "role" => timeline_role(message["actor_type"], message["role_label"]),
      "text" => timeline_text(message["content"])
    }
  end

  defp recent_message(%{"message_seq" => seq} = rec, text)
       when is_integer(seq) and seq > 0 and text != "" do
    %{
      "seq" => seq,
      "role" => timeline_role(rec["source_actor_type"], rec["source_role_label"]),
      "text" => timeline_text(text)
    }
  end

  defp recent_message(_rec, _text), do: nil

  defp normalize_recent_message(%{"seq" => seq, "role" => role, "text" => text})
       when is_integer(seq) and seq > 0 and role in ["Router", "Worker", "User"] and
              is_binary(text) do
    case timeline_text(text) do
      "" -> nil
      text -> %{"seq" => seq, "role" => role, "text" => text}
    end
  end

  defp normalize_recent_message(_message), do: nil

  defp card_details(payload) do
    [model_line(payload), timeline_details(payload)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> bounded_content()
  end

  defp model_line(payload) do
    case str(payload["model_label"]) do
      "" -> ""
      label -> "Model: " <> label
    end
  end

  defp put_model_label(payload, ""), do: payload
  defp put_model_label(payload, label), do: Map.put(payload, "model_label", label)

  defp timeline_details(%{"recent_messages" => [_ | _] = messages}) do
    messages
    |> Enum.drop(-1)
    |> Enum.take(-@timeline_details_limit)
    |> Enum.map_join("\n\n", &"#{&1["role"]}: #{timeline_detail_text(&1["text"])}")
    |> bounded_content()
  end

  defp timeline_details(_payload), do: ""

  defp timeline_output(%{"recent_messages" => [_ | _] = messages}) do
    messages
    |> List.last()
    |> Map.fetch!("text")
    |> timeline_text()
  end

  defp timeline_output(_payload), do: ""

  defp timeline_role("agent", "delegator"), do: "Router"
  defp timeline_role("agent", _role), do: "Worker"
  defp timeline_role(actor_type, _role) when actor_type in ["user", "provider_user"], do: "User"
  defp timeline_role(_actor_type, _role), do: "User"

  defp timeline_text(content) do
    content
    |> ConversationMessage.text_content()
    |> String.trim()
  end

  defp timeline_detail_text(content),
    do: content |> timeline_text() |> String.slice(0, @timeline_entry_limit)

  defp status_details("active"), do: {"in_progress", "Work in progress"}
  defp status_details("ready_for_review"), do: {"complete", "Ready for review"}
  defp status_details("completed"), do: {"complete", "Completed"}
  defp status_details("failed"), do: {"error", "Failed"}
  defp status_details("cancelled"), do: {"error", "Cancelled"}
  defp status_details("escalated"), do: {"error", "Needs attention"}

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

  defp title(value),
    do: value |> str() |> String.slice(0, 200) |> then(&if(&1 == "", do: "Task", else: &1))

  defp bounded_content(value),
    do: value |> str() |> String.trim() |> String.slice(0, @content_limit)

  defp lifecycle(value, fallback),
    do: if(str(value) in @lifecycles, do: str(value), else: fallback)

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

  defp delivery_timeline_message?(rec, text) do
    rec["source_actor_type"] in ["agent", "user", "provider_user"] and text != "" and
      get_in(rec, ["message_metadata", "message_type"]) != "task_command"
  end

  defp valid_message_ts?(value), do: is_binary(value) and Regex.match?(@timestamp, value)

  defp nonempty_audience?(nil), do: true
  defp nonempty_audience?(%{"participant_ids" => [_ | _]}), do: true
  defp nonempty_audience?(_audience), do: false
end
