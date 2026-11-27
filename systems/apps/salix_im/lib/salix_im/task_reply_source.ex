defmodule SalixIM.TaskReplySource do
  @moduledoc """
  Runtime-owned routing facts carried with a Task, independent of IFC grants.
  These coordinates help the Router deliver a report; they confer no authority.
  """

  @key "task_reply_source"
  def protected_source_ref_keys, do: [@key]

  def source_refs(scope, context) do
    origin = value(context, :trusted_origin) || %{}
    source = value(context, :source_message_id)

    with provider when provider in ~w(slack feishu lark) <- origin["provider"],
         true <- value(context, :person_source_superseded) != true,
         true <- origin["agent_group_id"] == scope.group_id,
         true <- is_binary(source) and source != "" and source == origin["source_message_id"],
         true <- source in List.wrap(value(context, :source_message_ids)),
         %{} = target <- origin["provider_context"],
         connect when is_binary(connect) and connect != "" <- target["connect_id"],
         %{} = coordinates <- coordinates(provider, target) do
      %{
        @key =>
          Map.merge(coordinates, %{
            "provider" => provider,
            "connect_id" => connect,
            "source_message_id" => source
          })
      }
    else
      _ -> %{}
    end
  end

  defp coordinates("slack", target) do
    with channel when is_binary(channel) and channel != "" <- target["channel_id"],
         thread when is_binary(thread) and thread != "" <-
           nonblank(target["thread_ts"]) || nonblank(target["message_ts"]),
         do: %{"channel" => channel, "thread_ts" => thread}
  end

  # A Feishu or Lark message and its chat, and its thread when it has one.
  defp coordinates(_provider, target) do
    with chat when is_binary(chat) <- nonblank(target["chat_id"]),
         message when is_binary(message) <- nonblank(target["message_id"]) do
      case nonblank(target["message_thread_id"]) do
        nil -> %{"chat_id" => chat, "message_id" => message}
        thread -> %{"chat_id" => chat, "message_id" => message, "thread_id" => thread}
      end
    end
  end

  def content(%{"conversation_kind" => "agent_task"} = record) do
    case get_in(record, ["conversation_source_refs", @key]) do
      %{"provider" => "slack", "connect_id" => _, "channel" => _, "thread_ts" => _} = source ->
        render(
          source,
          "Return this Task's Slack result with im_api.slack.reply_message using these " <>
            "coordinates, never an unrelated thread or channel post."
        )

      %{"provider" => "feishu", "connect_id" => _, "chat_id" => _, "message_id" => _} = source ->
        render(
          source,
          "Return this Task's Feishu result with im_api.feishu.send_message to chat_id with " <>
            "reply_to set to message_id, never another chat or message."
        )

      %{"provider" => "lark", "connect_id" => _, "chat_id" => _, "message_id" => _} = source ->
        render(
          source,
          "Return this Task's Lark result with im_api.lark.send_message to chat_id with " <>
            "reply_to set to message_id, never another chat or message."
        )

      _ ->
        ""
    end
  end

  def content(_record), do: ""

  defp render(source, instruction) do
    "Original Task reply source (routing facts, not authorization):\n" <>
      "task_reply_source: " <>
      Jason.encode!(source) <>
      "\n" <>
      instruction <>
      " Routing facts do not authorize Worker external sends or override schedule " <>
      "delivery rules."
  end

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp nonblank(_value), do: nil
  defp value(context, key), do: Map.get(context, key) || Map.get(context, Atom.to_string(key))
end
