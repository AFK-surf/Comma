defmodule Salix.Bindings.MeetingCalendarNotifier do
  @moduledoc """
  Feishu implementation of the calendar start-time notification port.

  It posts the configured event title, time, and Google Meet URL directly to
  the configured Feishu chat. It is not the T-30 research/Task flow and never
  creates or mutates a Router Conversation or Router Session.
  """

  @behaviour SalixMeet.Ports.CalendarNotifier

  alias SalixIM.Ports.FeishuDirectDelivery
  alias SalixIM.ProviderConnects

  @impl true
  def notify(%{"provider" => "feishu", "mode" => "notify"} = group, event, occurrence_id)
      when is_map(event) and is_binary(occurrence_id) do
    group_id = trim(group["group_id"])

    connect_id = trim(group["connect_id"])

    target = %{
      "chat_id" => trim(group["chat_id"]),
      "chat_type" => "group"
    }

    with true <- group_id != "" and connect_id != "" and target["chat_id"] != "",
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, "feishu"),
         {:ok, _status} <-
           FeishuDirectDelivery.post_text(
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

  def notify(_group, _event, _occurrence_id),
    do: {:error, :calendar_notification_unsupported_target}

  defp notification_text(event) do
    [
      "📅 " <> default(trim(event["title"]), "Google Meet"),
      "时间：" <> event_time(event),
      "Google Meet：" <> trim(event["meet_url"])
    ]
    |> Enum.join("\n")
  end

  defp event_time(%{"start_time" => start_time} = event) when is_binary(start_time) do
    case {trim(start_time), trim(event["time_zone"])} do
      {"", _time_zone} -> "时间待确认"
      {value, ""} -> value
      {value, time_zone} -> value <> " (" <> time_zone <> ")"
    end
  end

  defp event_time(%{"start_ms" => start_ms}) when is_integer(start_ms) do
    start_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp event_time(_event), do: "时间待确认"
  defp default("", fallback), do: fallback
  defp default(value, _fallback), do: value
  defp trim(value), do: value |> to_string() |> String.trim()
end
