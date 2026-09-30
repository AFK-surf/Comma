defmodule SalixIM.ConversationIds do
  @moduledoc false

  @spec group_router(map()) :: {:ok, String.t()} | {:error, atom()}
  def group_router(%{"router_conversation_id" => conversation_id})
      when is_binary(conversation_id) do
    conversation_id = String.trim(conversation_id)

    cond do
      conversation_id == "" -> {:error, :router_conversation_id_required}
      SalixStore.Ids.valid_conversation_id?(conversation_id) -> {:ok, conversation_id}
      true -> {:error, :invalid_router_conversation_id}
    end
  end

  def group_router(_group), do: {:error, :router_conversation_id_required}
end
