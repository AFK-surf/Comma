defmodule Comma.MeetingTasks do
  @moduledoc "Authorized desktop meeting commands over the canonical Task owner."
  alias Comma.Workspaces

  def enter(user, session, group_id, attrs) do
    with {:ok, workspace} <- scope(user, session, group_id),
         {:ok, entry} <- entry(attrs),
         {:ok, task} <- Comma.Salix.Client.impl().enter_meeting_task(workspace, user["id"], entry),
         do: {:ok, present(group_id, task)}
  end

  def update(user, session, group_id, occurrence_id, attrs) do
    with {:ok, workspace} <- scope(user, session, group_id),
         true <- valid_id?(occurrence_id),
         {:ok, command} <- command(attrs),
         {:ok, task} <-
           Comma.Salix.Client.impl().update_meeting_task(
             workspace,
             user["id"],
             occurrence_id,
             command
           ) do
      {:ok, present(group_id, task)}
    else
      false -> invalid()
      error -> error
    end
  end

  defp scope(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         do: Comma.Salix.Client.impl().resolve_workspace_scope(workspace)
  end

  defp entry(attrs) when is_map(attrs) do
    with true <-
           Enum.sort(Map.keys(attrs)) == Enum.sort(~w(occurrence_id name started_at archive_date)),
         true <- valid_id?(attrs["occurrence_id"]),
         true <- is_binary(attrs["name"]) and byte_size(attrs["name"]) in 1..1024,
         true <- is_integer(attrs["started_at"]) and attrs["started_at"] > 0,
         true <- is_binary(attrs["archive_date"]),
         {:ok, _date} <- Date.from_iso8601(attrs["archive_date"]) do
      {:ok, attrs}
    else
      _ -> invalid()
    end
  end

  defp entry(_), do: invalid()

  defp command(%{"action" => action, "version" => version} = attrs)
       when is_integer(version) and version > 0 and
              action in ~w(recording paused dismiss discard finalize) do
    allowed =
      if action == "finalize",
        do: ~w(action version recording file smart_summary),
        else: ~w(action version)

    with true <- Enum.sort(Map.keys(attrs)) == Enum.sort(allowed),
         :ok <- if(action == "finalize", do: recording(attrs), else: :ok) do
      {:ok, attrs}
    else
      _ -> invalid()
    end
  end

  defp command(_), do: invalid()

  defp recording(%{"smart_summary" => summary, "file" => file, "recording" => recording})
       when is_boolean(summary) and is_map(file) and is_map(recording) do
    with true <- valid_id?(recording["recording_id"]),
         duration when is_integer(duration) and duration >= 0 and duration <= 86_400_000 <-
           recording["durationMs"],
         %{"space" => space, "path" => path} <- recording["driveFile"],
         true <- is_binary(space) and byte_size(space) in 1..256,
         true <-
           is_binary(path) and byte_size(path) in 1..1024 and
             String.starts_with?(path, "recording/"),
         %{"localFileRef" => ref, "name" => name, "mediaType" => "audio/mp4", "size" => size} <-
           file,
         true <- is_binary(ref) and Regex.match?(~r/^lfi1_[A-Za-z0-9_-]{43}$/, ref),
         true <- is_binary(name) and byte_size(name) in 1..512,
         true <- is_integer(size) and size > 0 and size <= 512 * 1024 * 1024,
         true <- map_size(file) == 4,
         true <- byte_size(Jason.encode!(recording)) <= 4096 do
      :ok
    else
      _ -> invalid()
    end
  end

  defp recording(_), do: invalid()
  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]{16,64}$/, id)
  defp invalid, do: {:error, {:bad_request, "Invalid desktop meeting command"}}

  defp present(group_id, task),
    do: %{
      "group_id" => group_id,
      "task_id" => task["conversation_id"],
      "status" => task["status"],
      "meeting" =>
        Map.take(
          get_in(task, ["metadata", "desktop_meeting"]),
          ~w(occurrence_id name archive_date started_at phase version)
        )
    }
end
