defmodule SalixCalendar.Item do
  @moduledoc "Validation for the source-neutral CalendarItem object subset."

  @types ~w(Event Task)
  @forbidden_task_fields ~w(command messages artifacts)
  @max_normalized_bytes 256_000

  def validate(record) when is_map(record) do
    with %{"@type" => type} = object when type in @types <- record["object"],
         :ok <- validate_object(type, object),
         true <- valid_source_generation?(record["source_generation"]) do
      normalized =
        record
        |> Map.take(
          ~w(copy_role object scheduling_identity scheduling_revision source_version source_generation present_fields participant_set_state attachment_set_state normalization_state source_fresh_at meeting_qualification)
        )
        |> Map.put("source_revision", record["source_revision"])
        |> Map.put_new("copy_role", "unknown")
        |> Map.put_new("normalization_state", "complete")

      case Jason.encode(normalized) do
        {:ok, encoded} when byte_size(encoded) <= @max_normalized_bytes -> {:ok, normalized}
        _ -> {:error, :invalid_calendar_item}
      end
    else
      _ -> {:error, :invalid_calendar_item}
    end
  end

  def validate(_record), do: {:error, :invalid_calendar_item}

  def valid_source_revision?(revision)
      when is_list(revision) and revision != [] and length(revision) <= 4,
      do:
        Enum.all?(revision, fn
          value when is_integer(value) -> value >= 0
          value when is_binary(value) -> value != "" and byte_size(value) <= 256
          _ -> false
        end)

  def valid_source_revision?(_revision), do: false

  defp validate_object("Event", object) do
    if is_binary(object["start"]) and is_binary(object["duration"]),
      do: :ok,
      else: {:error, :invalid_event_time}
  end

  defp validate_object("Task", object) do
    if Enum.any?(@forbidden_task_fields, &Map.has_key?(object, &1)) do
      {:error, :task_private_content_forbidden}
    else
      :ok
    end
  end

  defp valid_source_generation?(nil), do: true
  defp valid_source_generation?(generation), do: is_integer(generation) and generation >= 0
end
