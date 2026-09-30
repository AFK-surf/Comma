defmodule SalixAgent.InputTime do
  @moduledoc false

  # Admission supplies the envelope, never JSON parsed from message content.
  # Provider/Conversation owners normalize their source timestamp to milliseconds.
  def capture(payload) when is_map(payload) do
    timezone = timezone(value(payload, :source_timezone))

    %{
      "source_sent_at" => iso(value(payload, :source_sent_at_ms)),
      "received_at" => iso(value(payload, :delivered_at_ms)),
      "timezone" => timezone,
      "timezone_source" =>
        if(timezone,
          do: "source_configuration",
          else: "unknown"
        ),
      "anchor_kind" =>
        if(value(payload, :kind) == "schedule", do: "scheduled_for", else: "message")
    }
  end

  defp iso(ms) when is_integer(ms) and ms > 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, time} -> DateTime.to_iso8601(time)
      _ -> nil
    end
  end

  defp iso(_), do: nil

  defp timezone(zone) when is_binary(zone) and byte_size(zone) <= 64 do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _} -> zone
      _ -> nil
    end
  end

  defp timezone(_), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
