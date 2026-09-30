defmodule SalixIM.ConversationSource do
  @moduledoc "Ordered Conversation sources for Agent and provider Participants."

  alias SalixIM.{ConversationDelivery, ConversationMessage, Conversations, GroupDirectory}
  alias SalixStore.{CasRecord, Keys}

  @batch_size 32

  def notify(nil, source) do
    Task.Supervisor.start_child(SalixIM.ConversationNotificationTasks, fn ->
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

    Task.Supervisor.start_child(SalixIM.ConversationNotificationTasks, fn ->
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
      %{"actor_type" => "agent", "agent_id" => agent, "participant_id" => id} ->
        [
          {agent,
           %{
             group_id: conversation["agent_group_id"],
             conversation_id: conversation["conversation_id"],
             participant_id: id
           }}
        ]

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

  def prefetch(agent_id) do
    if SalixStore.Ids.valid_agent_id?(agent_id) do
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

      for key <- [Keys.ctl_agent(agent_id), Keys.ctl_group(group_id)] do
        SalixStore.ReadScope.prefetch({:record, key}, fn -> CasRecord.get(key) end)
      end
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
         messages: messages,
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
          System.system_time(:millisecond)
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
          "participant_payload" => %{"session_id" => binding.session_id}
        })

      with {:ok, _agent_id, payload, opts} <- materialize(binding, message, record) do
        payload =
          payload
          |> Map.put(:delivered_at_ms, System.system_time(:millisecond))
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
    record =
      ConversationMessage.delivery_record(
        binding.conversation,
        message,
        binding.participant,
        System.system_time(:millisecond)
      )
      |> Map.put("participant_agent_id", binding.agent["agent_id"])
      |> Map.put("participant_payload", %{"session_id" => binding.session_id})

    settlement =
      if SalixIM.Triage.Investigation.worker_assignment?(record) do
        SalixIM.ConversationServer.escalate_triage_command_delivery(
          binding.group["group_id"],
          binding.conversation["conversation_id"],
          record
        )
      else
        {:ok, nil}
      end

    with {:ok, _} <- settlement,
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
          System.system_time(:millisecond)
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
    # Only the owner-only provider append can persist this field. Keep the
    # established provider provenance and wake policy without reinterpreting it.
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

  defp recover_consumers(candidate, conversation) do
    with {:ok, sources, observed_memberships} <-
           SalixIM.ConversationServer.delivery_sources(
             candidate.group_id,
             candidate.conversation_id
           ) do
      # The aggregate caps Participant slots at 200. Only indexed pending
      # Conversations enter this worker, never the idle Conversation catalog.
      results =
        Enum.map(sources, fn {agent, source} ->
          case recovered?(agent, source, conversation, candidate.target_seq) do
            true ->
              true

            _ ->
              notify(agent, source)
              false
          end
        end)

      SalixIM.ConversationServer.repair_display_projection(
        candidate.group_id,
        candidate.conversation_id
      )

      if Enum.all?(results),
        do:
          SalixIM.ConversationServer.complete_log_recovery(
            candidate.group_id,
            candidate.conversation_id,
            {candidate.target_seq, candidate.status_version},
            observed_memberships
          ),
        else: {:ok, :pending}
    end
  end

  defp recovered?(nil, source, conversation, target) do
    with {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             source.group_id,
             source.conversation_id,
             source.participant_id
           ) do
      (participant["delivery_log_cursor_seq"] || conversation["log_start_seq"] || 0) >= target
    end
  end

  defp recovered?(agent, source, _conversation, target) do
    with {:ok, binding} <- binding(agent, source),
         {:ok, progress} <-
           SalixIM.Ports.AgentDelivery.conversation_progress(
             agent,
             binding.session_id,
             source.participant_id
           ),
         {:ok, seq} <- frontier(binding, progress) do
      seq >= target
    else
      {:error, :conversation_source_retired} -> true
      error -> error
    end
  end

  defp expected_sequences(_, 0), do: []
  defp expected_sequences(seq, count), do: Enum.to_list((seq + 1)..(seq + count))
end
