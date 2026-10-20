defmodule Salix.Bindings.LarkMeetingCalendarNotifier do
  @moduledoc """
  The notice a Lark chat gets when a calendar meeting starts: the title, the
  time and the Google Meet link of the event.

  `Salix.Bindings.MeetingCalendarNotifier` calls it for a Lark connect in
  `notify` mode. The message goes out through
  `SalixIM.Ports.LarkDirectDelivery`, once per occurrence. It starts no Task
  and writes no Router Conversation.
  """

  alias SalixIM.Ports.LarkDirectDelivery
  alias SalixIM.ProviderConnects

  @spec notify(map(), map(), String.t()) :: {:ok, :queued} | {:error, term()}
  def notify(group, event, occurrence_id)
      when is_map(group) and is_map(event) and is_binary(occurrence_id) do
    group_id = trim(group["group_id"])
    connect_id = trim(group["connect_id"])
    target = %{"chat_id" => trim(group["chat_id"]), "chat_type" => "group"}

    with true <- group_id != "" and connect_id != "" and target["chat_id"] != "",
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, "lark"),
         {:ok, _status} <-
           LarkDirectDelivery.post_text(
             connect,
             target,
             notification_text(event),
             group["mentions"] || %{"mode" => "none", "users" => []},
             "calendar-notify:" <> occurrence_id
           ) do
      {:ok, :queued}
    else
      false -> {:error, :calendar_notification_invalid_target}
      {:error, _} = error -> error
      other -> {:error, {:calendar_notification_invalid_result, other}}
    end
  end

  defp notification_text(event) do
    [
      "📅 " <> default(trim(event["title"]), "Google Meet"),
      "Time: " <> event_time(event),
      "Google Meet: " <> trim(event["meet_url"])
    ]
    |> Enum.join("\n")
  end

  defp event_time(%{"start_time" => start_time} = event) when is_binary(start_time) do
    case {trim(start_time), trim(event["time_zone"])} do
      {"", _time_zone} -> "to be confirmed"
      {value, ""} -> value
      {value, time_zone} -> value <> " (" <> time_zone <> ")"
    end
  end

  defp event_time(%{"start_ms" => start_ms}) when is_integer(start_ms) do
    start_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp event_time(_event), do: "to be confirmed"
  defp default("", fallback), do: fallback
  defp default(value, _fallback), do: value
  defp trim(value), do: value |> to_string() |> String.trim()
end
