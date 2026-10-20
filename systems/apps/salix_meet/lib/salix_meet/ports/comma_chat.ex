defmodule SalixMeet.Ports.CommaChat do
  @moduledoc false

  @callback post(
              group_id :: String.t(),
              conversation_id :: String.t(),
              agent_id :: String.t(),
              idempotency_key :: String.t(),
              text :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  def post(group_id, conversation_id, agent_id, idempotency_key, text),
    do: impl().post(group_id, conversation_id, agent_id, idempotency_key, text)

  defp impl, do: SystemsRuntime.get_env(:salix_meet, :comma_chat_mod, __MODULE__.Conversation)

  defmodule Conversation do
    @moduledoc false
    @behaviour SalixMeet.Ports.CommaChat

    @impl true
    def post(group_id, conversation_id, agent_id, idempotency_key, text) do
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        group_id,
        conversation_id,
        agent_id,
        %{"content" => text, "client_request_id" => idempotency_key}
      )
    end
  end
end
