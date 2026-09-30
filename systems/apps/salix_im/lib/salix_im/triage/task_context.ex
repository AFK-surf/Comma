defmodule SalixIM.Triage.TaskContext do
  @moduledoc """
  Bounded context from the canonical Task created for an exact Triage delegation.

  The caller owns project/group read authority. The existing Task request binding
  supplies the locator; no Task is searched, reserved, created or repaired here.
  At most three recent messages and 2,048 bytes of text per message are retained.
  These are attributed Task messages, not proof of a completed Slack delivery.
  """

  alias SalixIM.{ConversationServer, Conversations}
  alias SalixIM.Provider.Util

  @message_limit 3
  @text_bytes 2_048

  def read(group_id, obligation_id, index)
      when is_binary(group_id) and is_binary(obligation_id) and index in 0..1 do
    request = "triage-delegation:#{obligation_id}:#{index}"

    case ConversationServer.lookup_task_create_request(group_id, request) do
      {:ok, %{"disposition" => "created", "conversation_id" => conversation_id}} ->
        read_task(group_id, conversation_id)

      {:ok, %{"disposition" => disposition}}
      when disposition in ["not_created", "reserved_task_unavailable"] ->
        %{availability: disposition}

      _unavailable ->
        %{availability: "unavailable"}
    end
  rescue
    _ -> %{availability: "unavailable"}
  catch
    :exit, _ -> %{availability: "unavailable"}
  end

  defp read_task(group_id, conversation_id) do
    case Conversations.get_group_conversation_with_messages(group_id, conversation_id,
           tail: @message_limit
         ) do
      {:ok, %{"conversation" => %{"kind" => "agent_task"} = task, "messages" => messages}} ->
        %{
          availability: "available",
          conversation_id: conversation_id,
          title: Util.truncate_utf8(task["title"] || "", 256),
          task_status: task["status"],
          recent_messages: Enum.map(messages, &message/1),
          history_window: "latest_three_messages"
        }

      _unavailable ->
        %{availability: "unavailable", conversation_id: conversation_id}
    end
  end

  defp message(message) do
    blocks = message["content"] |> List.wrap() |> Enum.take(9)

    text =
      blocks
      |> Enum.take(8)
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) ->
          [Util.truncate_utf8(text, @text_bytes)]

        _ ->
          []
      end)
      |> Enum.join("\n")

    %{
      message_id: message["message_id"],
      agent_id: message["agent_id"],
      actor_type: message["actor_type"],
      created_at: message["created_at"],
      text_excerpt: Util.truncate_utf8(text, @text_bytes),
      excerpt_only: true,
      has_other_content: length(blocks) > 8 or Enum.any?(blocks, &(&1["type"] != "text"))
    }
  end
end
