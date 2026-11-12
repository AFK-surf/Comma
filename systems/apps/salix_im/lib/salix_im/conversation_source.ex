defmodule SalixIM.ConversationSource do
  @moduledoc "Ordered Conversation sources for Agent and provider Participants."

  alias SalixIM.{
    ConversationDelivery,
    ConversationMessage,
    Conversations,
    GroupDirectory
  }

  alias SalixStore.{CasRecord, Keys}

  @batch_size 32

  def notify(nil, source) do
    SystemsRuntime.TaskSupervisor.start_child(SalixIM.ConversationNotificationTasks, fn ->
      SalixIM.ConversationServer.wake_participant(
        source.group_id,
        source.conversation_id,
        source.participant_id
      )
    end)

    :ok
  catch
    :exit, _ -> :ok
  end

  def notify(agent_id, source) do
    ready = SalixStore.ReadScope.capture() || %{}

    case ready[{:conversation_input, agent_id}] do
      {:ok, reads} ->
        SalixStore.ReadScope.merge(reads)
        SalixStore.ReadScope.invalidate({:conversation_input, agent_id})

      _ ->
        :ok
    end

    scope = SalixStore.ReadScope.capture()

    SystemsRuntime.TaskSupervisor.start_child(SalixIM.ConversationNotificationTasks, fn ->
      SalixStore.ReadScope.run(scope || %{}, fn ->
        SalixIM.Ports.AgentDelivery.notify_conversation(agent_id, source)
      end)
    end)

    :ok
  catch
    :exit, _ -> :ok
  end

  def notify_targets(conversation, target_ids, participants) do
    sources(conversation, participants)
    |> Enum.filter(fn {_, source} -> source.participant_id in target_ids end)
    |> Enum.each(fn {agent_id, source} -> notify(agent_id, source) end)
  end

  def sources(conversation, participants) do
    Enum.flat_map(participants, fn
      %{"actor_type" => "agent", "agent_id" => agent} = participant ->
        if receives_messages?(participant),
          do: [{agent, agent_source(conversation, participant)}],
          else: []

      %{"actor_type" => "provider", "participant_id" => id} ->
        [
          {nil,
           %{
             group_id: conversation["agent_group_id"],
             conversation_id: conversation["conversation_id"],
             participant_id: id
           }}
        ]

      _ ->
        []
    end)
  end

  @doc """
  Whether an agent participant is delivered Messages at all. One that is not
  (`notification_filter.messages` `none`, such as the Worker of a Task run by
  another station's Session, `SalixIM.Ports.TaskStations`) has no source: it
  is never notified, woken or recovered. A Worker of such a Task made before
  (`payload.runs_on`) is not run by Salix either.
  """
  def receives_messages?(participant),
    do:
      get_in(participant, ["notification_filter", "messages"]) != "none" and
        not match?(%{"runs_on" => %{}}, participant["payload"])

  @doc "An agent participant's source."
  def agent_source(conversation, %{"participant_id" => id}) do
    %{
      group_id: conversation["agent_group_id"],
      conversation_id: conversation["conversation_id"],
      participant_id: id
    }
  end

  def prefetch(agent_id) do
    if SalixStore.Ids.valid_agent_id?(agent_id) do
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

      SalixStore.ReadScope.prefetch({:agent_config, agent_id}, fn ->
        case SalixStore.AgentPGStore.read_config(agent_id) do
          {:ok, %{record: record}} -> {:ok, record}
          error -> error
        end
      end)

      key = Keys.ctl_group(group_id)
      SalixStore.ReadScope.prefetch({:record, key}, fn -> CasRecord.get(key) end)
    end

    :ok
  end

  def binding(agent_id, source) do
    with {:ok, agent} <- source_agent(agent_id),
         true <- agent["group_id"] == source.group_id,
         {:ok, group} <- GroupDirectory.get_group(source.group_id),
         {:ok, conversation, participant, messages} <-
           SalixIM.ConversationServer.agent_source_snapshot(
             source.group_id,
             source.conversation_id,
             source.participant_id
           ),
         true <-
           participant["actor_type"] == "agent" and participant["agent_id"] == agent_id and
             participant["state"] != "inactive" and
             get_in(participant, ["notification_filter", "messages"]) != "none",
         session_id when is_binary(session_id) <-
           if(agent["role"] == "router",
             do: agent["router_session_id"],
             else: get_in(participant, ["payload", "session_id"])
           ),
         start when is_integer(start) and start >= 0 <- conversation["log_start_seq"] do
      {:ok,
       %{
         agent: agent,
         group: group,
         conversation: conversation,
         participant: participant,
         messages: if(is_list(messages), do: messages),
         start_seq: max(start, participant["source_start_seq"] || 0),
         session_id: session_id
       }}
    else
      nil -> {:error, :conversation_source_retired}
      false -> {:error, :conversation_source_retired}
      {:error, _} = error -> error
      _ -> {:error, :invalid_conversation_source_binding}
    end
  end

  defp source_agent(agent_id) do
    case GroupDirectory.get_agent(agent_id) do
      {:error, :not_found} -> {:error, :conversation_source_retired}
      result -> result
    end
  end

  def batch(binding, progress) do
    with {:ok, seq} <- frontier(binding, progress),
         true <- seq <= (binding.conversation["message_tail_seq"] || 0),
         true <- (binding.conversation["message_head_seq"] || 1) <= seq + 1,
         {:ok, messages} <- source_messages(binding, seq),
         true <-
           length(messages) ==
             min(@batch_size, (binding.conversation["message_tail_seq"] || 0) - seq),
         true <- Enum.map(messages, & &1["seq"]) == expected_sequences(seq, length(messages)) do
      {:ok, binding, messages}
    else
      false -> {:error, :conversation_source_gap}
      error -> error
    end
  end

  defp source_messages(%{messages: messages} = binding, seq) when is_list(messages) do
    tail = binding.conversation["message_tail_seq"] || 0

    if seq == tail or (messages != [] and hd(messages)["seq"] <= seq + 1) do
      {:ok, Enum.filter(messages, &(&1["seq"] > seq)) |> Enum.take(@batch_size)}
    else
      source_messages(%{binding | messages: nil}, seq)
    end
  end

  defp source_messages(binding, seq),
    do:
      Conversations.list_group_conversation_messages(
        binding.group["group_id"],
        binding.conversation["conversation_id"],
        after_seq: seq,
        limit: @batch_size
      )

  def frontier(binding, nil), do: {:ok, binding.start_seq}

  def frontier(binding, %{"conversation_id" => conversation_id, "seq" => seq})
      when is_integer(seq) and seq >= 0 do
    if conversation_id == binding.conversation["conversation_id"],
      do: {:ok, max(seq, binding.start_seq)},
      else: {:error, :conversation_source_retired}
  end

  def frontier(_, _), do: {:error, :invalid_conversation_source_progress}

  def entry(binding, message) do
    source = %{
      "conversation_id" => binding.conversation["conversation_id"],
      "participant_id" => binding.participant["participant_id"],
      "generation" => binding.session_id,
      "start_seq" => binding.start_seq,
      "seq" => message["seq"]
    }

    if target?(binding.participant, message) do
      record =
        binding.conversation
        |> ConversationMessage.delivery_record(
          message,
          binding.participant,
          SystemsClock.system_time(:millisecond)
        )
        |> Map.merge(
          SalixIM.AgentDeliveryPayload.participant_delivery_defaults(
            binding.group,
            binding.agent,
            binding.conversation
          )
        )
        |> Map.merge(%{
          "participant_agent_id" => binding.agent["agent_id"],
          "participant_payload" =>
            (binding.participant["payload"] || %{})
            |> Map.take(["session_model"])
            |> Map.put("session_id", binding.session_id)
        })

      with {:ok, _agent_id, payload, opts} <- materialize(binding, message, record) do
        payload =
          payload
          |> Map.put(:delivered_at_ms, SystemsClock.system_time(:millisecond))
          |> Map.put(:no_wake, opts[:no_wake] == true)

        {:ok,
         %{
           source_message_id: opts[:source_message_id],
           payload: payload,
           conversation_source: source
         }}
      else
        error ->
          error
      end
    else
      {:ok,
       %{
         source_message_id: nil,
         payload: %{session_id: binding.session_id},
         conversation_source: source,
         conversation_scan_only: true
       }}
    end
  end

  def target?(participant, message),
    do:
      message["delivery_log_skip"] != true and
        ConversationMessage.targets_participant?(participant, message)

  def reject(binding, message, reason) do
    with {:ok, _} <- settle_failed_command(binding, message),
         {:ok, scan} <- entry(binding, Map.put(message, "delivery_log_skip", true)) do
      rejection = %{
        "message_id" => message["message_id"],
        "seq" => message["seq"],
        "reason" => inspect(reason, limit: 20, printable_limit: 1024)
      }

      {:ok,
       %{
         scan
         | conversation_source: Map.put(scan.conversation_source, "last_rejection", rejection)
       }}
    end
  end

  # Retirement ends Session input, but an outstanding Triage command still
  # needs its Task outcome. The owner fences the captured tail and binding.
  def retire(binding) do
    if retirement_needs_tail?(binding) do
      with {:ok, messages} <-
             Conversations.list_group_conversation_messages(
               binding.group["group_id"],
               binding.conversation["conversation_id"],
               after_seq: max((binding.conversation["message_tail_seq"] || 0) - 1, 0),
               limit: 1
             ) do
        retire(binding, List.first(messages))
      end
    else
      :ok
    end
  end

  def retire(binding, captured_tail) do
    cond do
      not retirement_needs_tail?(binding) ->
        :ok

      is_map(captured_tail) ->
        with {:ok, _} <- settle_failed_command(binding, captured_tail), do: :ok

      true ->
        {:error, :conversation_source_gap}
    end
  end

  defp retirement_needs_tail?(binding) do
    SalixIM.Triage.Investigation.task?(binding.conversation) and
      binding.conversation["status"] == "active" and
      binding.conversation["task_worker_agent_id"] == binding.agent["agent_id"]
  end

  defp settle_failed_command(binding, message) do
    record =
      ConversationMessage.delivery_record(
        binding.conversation,
        message,
        binding.participant,
        SystemsClock.system_time(:millisecond)
      )
      |> Map.put("participant_agent_id", binding.agent["agent_id"])
      |> Map.put("participant_payload", %{"session_id" => binding.session_id})

    if SalixIM.Triage.Investigation.worker_assignment?(record) do
      SalixIM.ConversationServer.escalate_triage_command_delivery(
        binding.group["group_id"],
        binding.conversation["conversation_id"],
        record
      )
    else
      {:ok, nil}
    end
  end

  defp materialize(binding, %{"agent_redelivery" => replay}, record) when is_map(replay) do
    with {:ok, original} <-
           Conversations.get_group_conversation_message(
             binding.group["group_id"],
             binding.conversation["conversation_id"],
             replay["message_id"]
           ) do
      facts =
        ConversationMessage.delivery_record(
          binding.conversation,
          original,
          binding.participant,
          SystemsClock.system_time(:millisecond)
        )

      record =
        record
        |> Map.merge(facts)
        |> Map.put(
          "source_message_id_suffix",
          "redelivery:" <> SalixStore.Crypto.hex(replay["request_id"])
        )
        |> Map.put("participant_payload", %{"session_id" => binding.session_id})

      with {:ok, agent, payload, opts} <- materialize(binding, original, record) do
        source =
          if is_map(original["agent_input"]),
            do:
              opts[:source_message_id] <>
                ":redelivery:" <> SalixStore.Crypto.hex(replay["request_id"]),
            else: opts[:source_message_id]

        {:ok, agent, payload, Keyword.put(opts, :source_message_id, source)}
      end
    end
  end

  defp materialize(binding, %{"agent_input" => input, "source_message_id" => source}, _record)
       when is_map(input) and is_binary(source) do
    # Only owner-authored provider inputs and Task Loop wakes persist this field.
    # Preserve their accepted provenance, source identity and wake policy.
    fields =
      ~w(content trusted_attachment_refs name billing_context provider_reply_obligation trusted_origin source_sent_at_ms role pre_deliveries no_wake)a

    payload =
      Map.new(fields, fn key -> {key, Map.get(input, to_string(key), Map.get(input, key))} end)
      |> Map.reject(fn {_, value} -> is_nil(value) end)
      |> Map.put(:session_id, binding.session_id)

    {:ok, binding.agent["agent_id"], payload,
     [source_message_id: source, no_wake: payload[:no_wake] == true]}
  end

  defp materialize(_binding, _message, record), do: ConversationDelivery.materialize_agent(record)

  def recover(candidate) do
    with {:ok, conversation} <-
           SalixIM.ConversationServer.recover_log(
             candidate.group_id,
             candidate.conversation_id,
             {candidate.target_seq, candidate.status_version}
           ) do
      cond do
        conversation["deleted_at"] -> SalixStore.ConversationLogRecovery.complete(candidate)
        (conversation["message_tail_seq"] || 0) < candidate.target_seq -> {:ok, :pending}
        true -> recover_consumers(candidate, conversation)
      end
    else
      {:error, :not_found} -> SalixStore.ConversationLogRecovery.complete(candidate)
      error -> error
    end
  end

  defp recover_consumers(candidate, _conversation) do
    with {:ok, %{rows: rows}} <- SalixStore.ConversationLogRecovery.consumers(candidate),
         {:ok, observed, conversation, tail, consumers} <- decode_consumers(candidate, rows),
         :ok <- retire_consumers(observed, conversation, tail, consumers) do
      unfinished = Enum.filter(consumers, & &1.unfinished)

      for consumer <- unfinished do
        notify(consumer.agent_id, %{
          group_id: observed.group_id,
          conversation_id: observed.conversation_id,
          participant_id: consumer.participant_id
        })
      end

      # A Session can retire after this snapshot. It must return in the next
      # page for the original Triage retirement action before cleanup can pass.
      if unfinished == [],
        do: SalixStore.ConversationLogRecovery.complete(observed),
        else: {:ok, :pending}
    end
  end

  defp decode_consumers(_candidate, []), do: {:error, :not_found}

  defp decode_consumers(candidate, rows) do
    [metadata, kind, updated, tail, head, floor, status, membership, deleted | _] =
      hd(rows)

    conversation =
      SalixIM.ConversationPGStore.decode_projection(
        candidate.group_id,
        candidate.conversation_id,
        metadata,
        %{
          kind: kind,
          updated_at: updated,
          message_tail_seq: tail,
          message_head_seq: head,
          log_start_seq: floor,
          provider_status_version: status,
          membership_revision: membership,
          deleted_at: deleted
        }
      )

    observed =
      Map.merge(candidate, %{
        target_seq: tail,
        status_version: status,
        membership_revision: membership
      })

    consumers =
      Enum.flat_map(rows, fn row ->
        case Enum.drop(row, 20) do
          [nil | _] ->
            []

          [id, participant, agent, session, retired, unfinished] ->
            participant = :erlang.binary_to_term(participant, [:safe])

            [
              %{
                participant_id: id,
                participant: participant,
                agent: if(agent, do: SalixStore.Codec.decode_snapshot(agent)),
                agent_id: if(participant["actor_type"] == "agent", do: participant["agent_id"]),
                session_id: session,
                retired: retired == true,
                unfinished: unfinished == true
              }
            ]
        end
      end)

    tail_snapshot =
      ~w(payload seq message_id request_identity request_fingerprint revision tombstone archive_first_seq archive_last_seq object_key encoding)a
      |> Enum.zip(Enum.slice(hd(rows), 9, 11))
      |> Map.new()
      |> Map.merge(%{group_id: candidate.group_id, conversation_id: candidate.conversation_id})

    {:ok, observed, conversation, tail_snapshot, consumers}
  end

  defp retire_consumers(candidate, conversation, tail_snapshot, consumers) do
    case Enum.filter(consumers, & &1.retired) do
      [] ->
        :ok

      retired ->
        with {:ok, group} <- GroupDirectory.get_group(candidate.group_id) do
          bindings =
            Enum.map(retired, fn consumer ->
              %{
                agent: consumer.agent,
                group: group,
                conversation: conversation,
                participant: consumer.participant,
                session_id: consumer.session_id
              }
            end)

          with {:ok, tail} <- retirement_tail(bindings, tail_snapshot) do
            Enum.reduce_while(bindings, :ok, fn binding, :ok ->
              case retire(binding, tail) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            end)
          end
        end
    end
  end

  defp retirement_tail(bindings, snapshot) do
    if Enum.any?(bindings, &retirement_needs_tail?/1),
      do: SalixIM.ConversationPGStore.message_from_snapshot(snapshot),
      else: {:ok, nil}
  end

  defp expected_sequences(_, 0), do: []
  defp expected_sequences(seq, count), do: Enum.to_list((seq + 1)..(seq + count))
end
