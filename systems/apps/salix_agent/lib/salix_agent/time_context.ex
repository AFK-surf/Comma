defmodule SalixAgent.TimeContext do
  @moduledoc false

  @refresh_seconds 300

  # Reads only the already loaded, bounded live context/input batch. No history
  # lookup, per-source RPC, timer, or idle wake is needed for a clock refresh.
  def prepare(session, known, now \\ DateTime.utc_now()) do
    sampled_at = DateTime.to_unix(now)
    messages = value(session, :input_messages) || value(session, :messages) || []
    users = Enum.filter(messages, &(value(&1, :role) == "user"))
    latest = List.last(users)
    cursor = if latest, do: value(latest, :source_message_id) || value(latest, :id)
    input_id = if latest, do: value(latest, :id)
    input_time = if latest, do: value(latest, :input_time) || %{}, else: %{}
    timezone = input_time["timezone"]
    session_id = value(session, :session_id)
    previous = known["time_context"] || %{}
    previous_sample = previous["sampled_at"]

    refresh? =
      not is_integer(previous_sample) or previous["source_cursor"] != cursor or
        previous["session_id"] != session_id or previous["timezone"] != timezone or
        sampled_at - previous_sample >= @refresh_seconds or sampled_at < previous_sample or
        local_date(sampled_at, timezone) != local_date(previous_sample, timezone)

    if refresh? do
      state = %{
        "sampled_at" => sampled_at,
        "source_cursor" => cursor,
        "session_id" => session_id,
        "last_input_id" => input_id,
        "timezone" => timezone
      }

      last_ack = value(session, :last_ack_message_id) || 0

      anchors =
        users
        |> Enum.filter(fn message ->
          id = value(message, :id)

          is_nil(value(message, :input_time)) and
            (is_nil(id) or
               (is_integer(id) and id > last_ack and id > (previous["last_input_id"] || 0)) or
               (is_binary(id) and id != previous["last_input_id"]))
        end)
        |> Enum.map(&anchor/1)

      content = """
      Current time context. This reading supersedes current_date and clock readings in older prompt snapshots; it does not change when earlier messages were sent.
      sampled_at: #{DateTime.to_iso8601(now)}
      clock_timezone: UTC (server clock, not the user's timezone)
      latest_message_timezone: #{timezone || "unknown"}; use each message's explicit timezone or a timezone stated in that request. Never infer user timezone from language or server location.
      Interpret relative dates such as yesterday against that message's source_sent_at, or its received_at when the source time is unknown. A scheduled_for anchor refers to the scheduled occurrence. Do not move the anchor to when a queued request finishes. New messages carry their own Message time context; keep multiple messages' anchors separate. If an unknown timezone or timestamp could change the answer or an external action, clarify it.
      Legacy message anchors (JSON): #{Jason.encode!(anchors)}. These are arrival/record timestamps, not proof of source send time.
      """

      payload = %{
        "runtime_message_id" => "time-context:" <> Ecto.UUID.generate(),
        "runtime_message_type" => "time_context",
        "content_kind" => "model_context",
        "summary" => "current time context",
        "content" => String.trim(content),
        "created_at" => sampled_at,
        "source_refs" => %{"providers" => ["time_context"]}
      }

      {[payload], state}
    else
      {[], previous}
    end
  end

  defp anchor(message) do
    %{
      "source_message_id" => value(message, :source_message_id),
      "message_id" => value(message, :id),
      "source_sent_at" => nil,
      "received_at" => iso(value(message, :delivered_at_ms), :millisecond),
      "message_recorded_at" => legacy_record_time(value(message, :created_at))
    }
  end

  defp iso(value, unit) when is_integer(value) do
    case DateTime.from_unix(value, unit) do
      {:ok, time} -> DateTime.to_iso8601(time)
      _ -> nil
    end
  end

  defp iso(_, _), do: nil

  defp legacy_record_time(value) when is_integer(value) and value > 10_000_000_000,
    do: iso(value, :millisecond)

  defp legacy_record_time(value), do: iso(value, :second)

  defp local_date(timestamp, timezone) when is_integer(timestamp) do
    with {:ok, utc} <- DateTime.from_unix(timestamp),
         {:ok, local} <- DateTime.shift_zone(utc, timezone || "Etc/UTC") do
      DateTime.to_date(local)
    else
      _ -> nil
    end
  end

  defp local_date(_, _), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
