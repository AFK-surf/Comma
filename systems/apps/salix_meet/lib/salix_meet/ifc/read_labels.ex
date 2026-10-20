defmodule SalixMeet.IFC.ReadLabels do
  @moduledoc "Audience of a published compact meeting read, from authoritative meeting state."

  alias SalixIM.IFC.{Facts, Ingress, ReadLabels}
  alias SalixIM.ProviderConnects

  @private %{"label" => ["agent_private"]}

  # A successful group lookup grants the agent a read, not permission to share
  # it with every human in the group. Only published notes establish a provider
  # audience. Raw captions/artifact contents are not in this compact read and
  # must not inherit this label if a future API starts returning them.
  def for_meeting(state, meeting) do
    if Facts.mode(state["tenant_id"], state["group_id"]) == "off" do
      nil
    else
      published_label(state, meeting)
    end
  end

  # Summary preparation is a separate product grant to the original meeting
  # destination, not an inference from the unpublished compact-read label.
  def for_summary_materials(state) do
    cond do
      Facts.mode(state["tenant_id"], state["group_id"]) == "off" ->
        nil

      state["provider"] == "comma" ->
        comma_label(state)

      true ->
        provider_summary_label(state)
    end
  end

  # A Meeting from a Comma chat belongs to that chat: its destination is the
  # Conversation, whose members are the audience (`SalixIM.IFC.Ingress`).
  # `meeting.join` takes Comma requests only from `user_chat` Conversations.
  defp comma_label(state) do
    with id when is_binary(id) and id != "" <- get_in(state, ["comma_ref", "conversation_id"]),
         atom when is_binary(atom) <- Ingress.conversation_atom("user_chat", id) do
      %{"label" => [atom]}
    else
      _ -> @private
    end
  end

  defp provider_summary_label(state) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             state["group_id"],
             state["connect_id"],
             state["provider"]
           ),
         true <- connect["tenant_id"] == state["tenant_id"] do
      ReadLabels.for_scope(connect, scope_id(state, state["provider"])) || @private
    else
      _ -> @private
    end
  end

  defp published_label(state, meeting) do
    with "visible" <- meeting["notes_delivery_status"],
         provider when provider in ["slack", "feishu", "lark"] <- state["provider"],
         connect_id when is_binary(connect_id) and connect_id != "" <- state["connect_id"],
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(state["group_id"], connect_id, provider),
         true <- connect["tenant_id"] == state["tenant_id"],
         true <- connect["group_id"] == state["group_id"],
         true <- connect["connect_id"] == connect_id do
      ReadLabels.for_scope(connect, scope_id(state, provider)) || @private
    else
      _unknown -> @private
    end
  end

  defp scope_id(state, "slack"), do: get_in(state, ["slack_ref", "channel_id"])
  defp scope_id(state, "feishu"), do: get_in(state, ["feishu_ref", "chat_id"])
  defp scope_id(state, "lark"), do: get_in(state, ["lark_ref", "chat_id"])
end
