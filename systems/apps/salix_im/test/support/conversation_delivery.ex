defmodule SalixIM.TestSupport.ConversationDelivery do
  @moduledoc false

  # Payload-oriented IM tests replace the runtime boundary. Runtime admission,
  # crash recovery and atomic progress use real Sessions in ConversationLogTest.
  def notify(module, agent_id, source) do
    :global.trans({{__MODULE__, source}, self()}, fn ->
      alias SalixIM.ConversationSource
      alias SalixStore.CasRecord
      key = "test/conversation-delivery/#{source.participant_id}"

      progress =
        case CasRecord.get(key) do
          {:ok, value} -> value
          _ -> nil
        end

      with {:ok, binding} <- ConversationSource.binding(agent_id, source),
           {:ok, binding, messages} <- ConversationSource.batch(binding, progress) do
        Enum.reduce_while(messages, :ok, fn message, _ ->
          with {:ok, entry} <- admit(module, agent_id, binding, message, 3),
               {:ok, _} <- CasRecord.update(key, fn _ -> entry.conversation_source end) do
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
        end)
      else
        error -> error
      end
    end)
  end

  defp admit(module, agent, binding, message, attempts) do
    with {:ok, entry} <- SalixIM.ConversationSource.entry(binding, message),
         {:ok, _} <- deliver(module, agent, entry) do
      {:ok, entry}
    else
      _error when attempts > 1 ->
        Process.sleep(100)
        admit(module, agent, binding, message, attempts - 1)

      error ->
        SalixIM.ConversationSource.reject(binding, message, error)
    end
  end

  defp deliver(_, _, %{conversation_scan_only: true}), do: {:ok, :ignored}

  defp deliver(module, agent, entry),
    do:
      module.deliver(agent, entry.payload,
        source_message_id: entry.source_message_id,
        no_wake: entry.payload[:no_wake] == true
      )
end
