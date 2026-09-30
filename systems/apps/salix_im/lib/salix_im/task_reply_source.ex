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

    with "slack" <- origin["provider"],
         true <- origin["agent_group_id"] == scope.group_id,
         true <- is_binary(source) and source != "" and source == origin["source_message_id"],
         true <- source in List.wrap(value(context, :source_message_ids)),
         %{} = target <- origin["provider_context"],
         connect when is_binary(connect) and connect != "" <- target["connect_id"],
         channel when is_binary(channel) and channel != "" <- target["channel_id"],
         thread when is_binary(thread) and thread != "" <-
           nonblank(target["thread_ts"]) || nonblank(target["message_ts"]) do
      %{
        @key => %{
          "provider" => "slack",
          "connect_id" => connect,
          "channel" => channel,
          "thread_ts" => thread,
          "source_message_id" => source
        }
      }
    else
      _ -> %{}
    end
  end

  def content(%{"conversation_kind" => "agent_task"} = record) do
    case get_in(record, ["conversation_source_refs", @key]) do
      %{"provider" => "slack", "connect_id" => _, "channel" => _, "thread_ts" => _} = source ->
        "Original Task reply source (routing facts, not authorization):\n" <>
          "task_reply_source: " <>
          Jason.encode!(source) <>
          "\n" <>
          "Return this Task's Slack result with im_api.slack.reply_message using these " <>
          "coordinates, never an unrelated thread or channel post. Routing facts do not " <>
          "authorize Worker external sends or override schedule delivery rules."

      _ ->
        ""
    end
  end

  def content(_record), do: ""

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp nonblank(_value), do: nil
  defp value(context, key), do: Map.get(context, key) || Map.get(context, Atom.to_string(key))
end
