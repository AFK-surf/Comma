defmodule SalixIM.TaskManualStatus do
  @moduledoc """
  A user ends an in-progress or in-review Task by hand.

  The transition is a Conversation-owned status write, checked in the owner's
  update transaction. `manual_status_change` records who ended the Task and
  from which status. While the Task keeps that status, its Router can change
  the status again only in a turn started by a human Message sent after the
  change. A Worker report, a runtime notice or a turn already running when the
  user ended the Task cannot reopen it.
  """

  @sources ~w(active ready_for_review escalated)
  @targets ~w(completed cancelled)
  @field "manual_status_change"

  def targets, do: @targets
  def field, do: @field
  def message_type, do: "task_manual_status"

  def transition(conversation, status, version, user_id, now)
      when status in @targets and is_integer(version) and is_binary(user_id) do
    cond do
      conversation["kind"] != "agent_task" ->
        conflict("Only Tasks have a status")

      conversation["status"] == "archived" ->
        conflict("Task is archived; restore it in Settings before making changes")

      conversation["updated_at"] != version ->
        conflict("Task changed; refresh and try again")

      scheduled?(conversation["schedule"]) ->
        conflict("Recurring Task runs cannot end the Task")

      # A review acceptance keeps the human acceptance contract, which also
      # covers Triage and legacy Workflow Tasks waiting for review.
      review_acceptance?(conversation, status) ->
        ended(conversation, status, user_id, now)

      not is_nil(conversation["workflow"]) ->
        conflict("Workflow Tasks must use their Gates and human review")

      is_map(get_in(conversation, ["source_refs", "triage_investigation"])) ->
        conflict("Triage Task status is product-owned")

      conversation["status"] not in @sources ->
        conflict("Only in-progress or in-review Tasks can be ended by hand")

      true ->
        ended(conversation, status, user_id, now)
    end
  end

  def transition(_conversation, _status, _version, _user_id, _now),
    do: {:error, {:bad_request, "status must be completed or cancelled"}}

  @doc "Whether this change accepts a Task's review, the old accept transition."
  def review_acceptance?(%{"status" => "ready_for_review"}, "completed"), do: true
  def review_acceptance?(_conversation, _status), do: false

  @doc "A later status change by anyone else ends the manual record."
  def clear_on_status_change(%{@field => _, "status" => current} = conversation, %{
        "status" => status
      })
      when status != current,
      do: Map.delete(conversation, @field)

  def clear_on_status_change(conversation, _updates), do: conversation

  defp ended(conversation, status, user_id, now) do
    conversation
    |> Map.put("status", status)
    |> Map.put(@field, %{
      "status" => status,
      "from_status" => conversation["status"],
      "user_id" => user_id,
      "at" => now
    })
    |> Map.put("updated_at", now)
  end

  # The provider supplies `human_turn_at`, the send time of the human Message
  # that started the Router's turn, from the server-sealed tool context. Only a
  # Message sent after the manual end counts: a turn already running when the
  # user ended the Task cannot undo that choice.
  def router_update(conversation, %{"status" => status}, router_id, human_turn_at)
      when is_binary(router_id) do
    current = conversation["status"]

    case conversation[@field] do
      %{"status" => ^current, "at" => ended_at} when current != status ->
        if is_integer(human_turn_at) and is_integer(ended_at) and human_turn_at > ended_at,
          do: :ok,
          else:
            {:error,
             {:forbidden,
              "A user ended this Task. Change its status only when a later user message asks to continue it"}}

      _ ->
        :ok
    end
  end

  def router_update(_conversation, _updates, _router_id, _human_turn?), do: :ok

  @doc "The runtime notice for the Router. Nil when the Task carries no manual change."
  def router_notice(%{@field => %{"status" => status, "from_status" => from}}) do
    case {from, status} do
      {"ready_for_review", "completed"} ->
        "A user accepted this Task from review and marked it Done. This is a normal " <>
          "acceptance: do not send a message about it and do not ask why. " <>
          "Change the status again only when a later user message asks to continue the Task."

      {_from, "completed"} ->
        "A user marked this Task Done by hand while it was #{label(from)}. " <>
          "Tell the requester briefly, in the Task's original source, that the Task is now Done " <>
          "and what that means. If the Task does not show why it ended, for example because " <>
          "work looks unfinished, ask the user briefly why. Do not ask when the reason is clear. " <>
          "Change the status again only when a later user message asks to continue the Task."

      {_from, "cancelled"} ->
        "A user cancelled this Task by hand while it was #{label(from)}. The Worker was told " <>
          "to stop. A step that is already running can still finish, and effects that already " <>
          "happened are not undone. Tell the requester briefly, in the Task's original source, " <>
          "that the Task is cancelled. If the Task does not show why it was cancelled, ask the " <>
          "user briefly why. Do not ask when the reason is clear. Change the status again only " <>
          "when a later user message asks to continue the Task."
    end
  end

  def router_notice(_conversation), do: nil

  def worker_notice,
    do:
      "A user cancelled this Task. Stop work now. Do not start new tool calls, do not publish " <>
        "a result Message and do not make more external changes. Effects that already " <>
        "happened stay as they are."

  defp label("active"), do: "in progress"
  defp label("ready_for_review"), do: "waiting for review"
  defp label("escalated"), do: "blocked"
  defp label(other), do: other

  defp scheduled?(%{"schedule_id" => id}) when is_binary(id), do: String.trim(id) != ""
  defp scheduled?(_), do: false

  defp conflict(message), do: {:error, {:conflict, message}}
end
