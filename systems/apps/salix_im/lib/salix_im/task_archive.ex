defmodule SalixIM.TaskArchive do
  @moduledoc """
  Pure Conversation-owned archive transitions, modeled in tla/salix/TaskArchive.tla.
  The saved status is a restore value, never a second running lifecycle.
  """
  @restorable ~w(ready_for_review completed failed cancelled escalated)
  @fields ~w(archived_from_status archived_at)

  def availability(conversation) do
    reason =
      cond do
        conversation["kind"] != "agent_task" ->
          "not_task"

        conversation["status"] == "archived" ->
          "already_archived"

        conversation["status"] not in @restorable ->
          "not_finished"

        is_binary(get_in(conversation, ["schedule", "schedule_id"])) and
            get_in(conversation, ["schedule", "schedule_id"]) != "" ->
          "schedule_bound"

        true ->
          nil
      end

    %{"allowed" => is_nil(reason), "reason" => reason}
  end

  # Existing list locator, frozen at archive time while canonical updated_at keeps advancing.
  def list_timestamp(%{"status" => "archived", "archived_at" => timestamp})
      when is_integer(timestamp), do: timestamp

  def list_timestamp(conversation),
    do: conversation["updated_at"] || conversation["created_at"] || 0

  def project(conversation) do
    if conversation["kind"] == "agent_task",
      do: Map.put(conversation, "archive_availability", availability(conversation)),
      else: conversation
  end

  def transition(conversation, action, version, now) do
    cond do
      conversation["kind"] != "agent_task" ->
        conflict("Only Tasks can be archived")

      action == :archive and conversation["status"] == "archived" ->
        conversation

      action == :unarchive and conversation["status"] != "archived" ->
        conversation

      conversation["updated_at"] != version ->
        conflict("Task changed; refresh and try again")

      action == :archive ->
        archive(conversation, now)

      conversation["archived_from_status"] not in @restorable ->
        conflict("Archived Task has no valid previous status; contact support")

      true ->
        conversation
        |> Map.put("status", conversation["archived_from_status"])
        |> Map.drop(@fields)
        |> Map.put("updated_at", now)
    end
  end

  defp archive(conversation, now) do
    case availability(conversation) do
      %{"allowed" => true} ->
        conversation
        |> Map.put("archived_from_status", conversation["status"])
        |> Map.put("archived_at", now)
        |> Map.put("status", "archived")
        |> Map.put("updated_at", now)

      %{"reason" => reason} ->
        conflict("Task cannot be archived: #{reason}")
    end
  end

  def writable(%{"kind" => "agent_task", "status" => "archived"}),
    do: conflict("Task is archived; restore it in Settings before making changes")

  def writable(_), do: :ok

  def ordinary_update(conversation, attrs) do
    with :ok <- writable(conversation) do
      if attrs["status"] == "archived" or Enum.any?(@fields, &Map.has_key?(attrs, &1)),
        do: conflict("Use the Task archive operation"),
        else: :ok
    end
  end

  # Already admitted retries and agent results retain their existing delivery contract.
  def admit_message(conversation, message, :uncommitted) do
    if message["actor_type"] in ["user", "provider_user"], do: writable(conversation), else: :ok
  end

  def admit_message(_, _, _), do: :ok

  defp conflict(message), do: {:error, {:conflict, message}}
end
