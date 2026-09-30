defmodule SalixIM.DesktopMeeting do
  @moduledoc "Pure, versioned transitions for a desktop meeting's canonical Task metadata."
  @capture ~w(awaiting_recording recording paused)

  def plan(conversation, owner_id, command) do
    meeting = get_in(conversation, ["metadata", "desktop_meeting"])
    version = command["version"]

    cond do
      not is_map(meeting) or meeting["owner_user_id"] != owner_id ->
        {:error, :not_found}

      not is_integer(version) or version < 1 ->
        {:error, {:bad_request, "A positive meeting version is required"}}

      is_map(meeting["pending_finalize"]) ->
        if meeting["pending_finalize"] == command do
          transition(Map.delete(meeting, "pending_finalize"), command)
        else
          {:error, {:conflict, "Audio delivery is pending. Retry the saved recording first."}}
        end

      version <= meeting["version"] ->
        {:ok, :unchanged}

      conversation["status"] == "archived" ->
        {:error, {:conflict, "Meeting Task is archived"}}

      meeting["phase"] not in @capture ->
        {:error, {:conflict, "Recording is already finalized"}}

      command["action"] == "dismiss" and meeting["phase"] != "awaiting_recording" ->
        {:error, {:conflict, "A recorded meeting cannot be dismissed"}}

      true ->
        transition(meeting, command)
    end
  end

  def commit(conversation, meeting, now) do
    updated =
      conversation
      |> put_in(["metadata", "desktop_meeting"], meeting)
      |> Map.put("updated_at", now)

    case meeting["phase"] do
      "dismissed" ->
        updated
        |> Map.put("status", "archived")
        |> Map.put("archived_from_status", "cancelled")
        |> Map.put("archived_at", now)

      "discarded" ->
        Map.put(updated, "status", "cancelled")

      "saved" ->
        Map.put(updated, "status", "completed")

      _ ->
        updated
    end
  end

  defp transition(meeting, %{"action" => action, "version" => version} = command) do
    next = Map.put(meeting, "version", version)

    case action do
      "recording" ->
        {:ok, Map.put(next, "phase", "recording")}

      "paused" ->
        {:ok, Map.put(next, "phase", "paused")}

      "dismiss" ->
        {:ok, Map.put(next, "phase", "dismissed")}

      "discard" ->
        {:ok, Map.put(next, "phase", "discarded")}

      "finalize" ->
        {:ok,
         next
         |> Map.put("phase", if(command["smart_summary"], do: "processing", else: "saved"))
         |> Map.put("recording", command["recording"])}

      _ ->
        {:error, {:bad_request, "Invalid meeting transition"}}
    end
  end
end
