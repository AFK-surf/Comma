defmodule SalixIM.DesktopMeetingInput do
  @moduledoc "Product-owned desktop meeting entry. One occurrence reserves one waiting Task."
  alias SalixIM.{ConversationServer, Conversations, TaskConversationInput}

  def ensure(group_id, router_id, worker_id, owner_id, entry) do
    request_id = request_id(owner_id, entry["occurrence_id"])

    attrs = %{
      "client_request_id" => request_id,
      "title" => entry["name"],
      "content" => "Meeting recording",
      "owner_user_id" => owner_id,
      "conversation_metadata" => %{
        "desktop_meeting" =>
          Map.merge(entry, %{
            "owner_user_id" => owner_id,
            "phase" => "awaiting_recording",
            "version" => 0
          })
      },
      "schedule" => %{"schedule_id" => nil, "command" => "Meeting recording"},
      "initial_message_attrs" => %{
        "actor_type" => "agent",
        "agent_id" => router_id,
        "content" => "Meeting detected. Waiting for recording.",
        "client_request_id" => request_id <> ":entry",
        "metadata" => %{"message_type" => "meeting_context"}
      }
    }

    with {:ok, id} <-
           ConversationServer.reserve_task_conversation_id(group_id, router_id, worker_id, attrs) do
      case Conversations.get_group_conversation(group_id, id) do
        # Dismissal proves materialization finished. An exact entry retry must not
        # attempt another write to an archived Task or restore it.
        {:ok, %{"status" => "archived"} = task} ->
          {:ok, task}

        _ ->
          with {:ok, _} <-
                 TaskConversationInput.create_with_id(group_id, id, router_id, worker_id, attrs,
                   initial_delivery: :context
                 ),
               do: Conversations.get_group_conversation(group_id, id)
      end
    end
  end

  def lookup(group_id, owner_id, occurrence_id) do
    with {:ok, %{"conversation_id" => id}} <-
           ConversationServer.lookup_task_create_request(
             group_id,
             request_id(owner_id, occurrence_id)
           ),
         do: Conversations.get_group_conversation(group_id, id)
  end

  defp request_id(owner_id, occurrence_id),
    do: "desktop-meeting:" <> owner_id <> ":" <> occurrence_id
end
