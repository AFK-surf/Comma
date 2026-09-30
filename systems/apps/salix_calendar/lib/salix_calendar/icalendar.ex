defmodule SalixCalendar.ICalendar do
  @moduledoc """
  Bounded RFC 5545 projection of Comma-local Events for a private Feed.

  Every distinct `TZID` referenced by the projection emits exactly one matching
  `VTIMEZONE`, generated from the IANA tzdb (`tz`) rather than a hand-written
  fixed-offset table, and covering the Feed horizon including DST transitions. A
  zone the tzdb cannot resolve fails the whole render explicitly. Calendar text is
  escaped iCalendar content, never executed; provider ids, prompts, raw subject
  ids and secrets are never emitted.
  """

  @gregorian_epoch_seconds 62_167_219_200

  @spec render([map()], integer(), integer()) :: {:ok, String.t()} | {:error, term()}
  def render(items, horizon_from_ms, horizon_to_ms)
      when is_list(items) and is_integer(horizon_from_ms) and is_integer(horizon_to_ms) do
    zones = items |> Enum.map(&get_in(&1, ["object", "timeZone"])) |> Enum.uniq()

    with {:ok, vtimezones} <- vtimezones(zones, horizon_from_ms, horizon_to_ms) do
      lines =
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Comma//Agent Calendar//EN",
          "CALSCALE:GREGORIAN"
        ] ++
          vtimezones ++
          Enum.flat_map(items, &vevent/1) ++
          ["END:VCALENDAR"]

      {:ok, encode(lines)}
    end
  end

  defp vtimezones(zones, from_ms, to_ms) do
    Enum.reduce_while(zones, {:ok, []}, fn zone, {:ok, acc} ->
      case vtimezone(zone, from_ms, to_ms) do
        {:ok, block} -> {:cont, {:ok, acc ++ block}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp vtimezone(zone, from_ms, to_ms) when is_binary(zone) do
    case periods(zone) do
      {:ok, spans} ->
        overlapping = Enum.filter(spans, fn s -> s.to_ms > from_ms and s.from_ms < to_ms end)
        kept = if overlapping == [], do: Enum.take(spans, -1), else: overlapping

        {:ok,
         ["BEGIN:VTIMEZONE", "TZID:#{zone}"] ++
           Enum.flat_map(kept, &observance/1) ++ ["END:VTIMEZONE"]}

      :error ->
        {:error, :unsupported_timezone}
    end
  end

  defp vtimezone(_zone, _from, _to), do: {:error, :unsupported_timezone}

  # tz periods are chronological-reversed 4-tuples:
  # {from_gregorian_seconds, {std_utc_off, dst_off, abbr}, prev_offsets | nil, _}
  defp periods(zone) do
    case Tz.PeriodsProvider.periods(zone) do
      {:ok, periods} ->
        chron = Enum.reverse(periods)

        spans =
          chron
          |> Enum.with_index()
          |> Enum.map(fn {{from_gs, {utc_off, dst_off, abbr}, prev, _}, index} ->
            to_ms =
              case Enum.at(chron, index + 1) do
                {next_gs, _, _, _} -> gregorian_ms(next_gs)
                nil -> :infinity
              end

            %{
              from_ms: gregorian_ms(from_gs),
              to_ms: to_ms,
              to_offset: utc_off + dst_off,
              from_offset: prev_offset(prev, utc_off + dst_off),
              dst?: dst_off != 0,
              abbr: abbr
            }
          end)

        {:ok, spans}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp prev_offset({utc_off, dst_off, _abbr}, _fallback), do: utc_off + dst_off
  defp prev_offset(_prev, fallback), do: fallback

  defp observance(span) do
    kind = if span.dst?, do: "DAYLIGHT", else: "STANDARD"

    [
      "BEGIN:#{kind}",
      "DTSTART:#{local_stamp(span.from_ms, span.from_offset)}",
      "TZOFFSETFROM:#{offset(span.from_offset)}",
      "TZOFFSETTO:#{offset(span.to_offset)}",
      "TZNAME:#{span.abbr}",
      "END:#{kind}"
    ]
  end

  defp vevent(item) do
    object = item["object"]
    stamp = utc_stamp(item["updated_at"])

    [
      "BEGIN:VEVENT",
      "UID:#{escape(object["uid"])}",
      "DTSTAMP:#{stamp}",
      "DTSTART;TZID=#{object["timeZone"]}:#{wall_stamp(object["start"])}",
      "DURATION:#{object["duration"]}",
      "SUMMARY:#{escape(object["title"])}",
      "CLASS:PRIVATE",
      "STATUS:#{status(object["status"])}",
      "SEQUENCE:#{item["revision"] || 0}",
      "LAST-MODIFIED:#{stamp}",
      "END:VEVENT"
    ]
  end

  defp status("cancelled"), do: "CANCELLED"
  defp status("tentative"), do: "TENTATIVE"
  defp status(_), do: "CONFIRMED"

  # ---- value formatting ----

  defp gregorian_ms(:infinity), do: :infinity
  defp gregorian_ms(gregorian_seconds), do: (gregorian_seconds - @gregorian_epoch_seconds) * 1000

  # Local wall clock at an instant, in a given offset: shift the instant by the
  # offset and read the components as if UTC.
  defp local_stamp(ms, offset_seconds) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.add(offset_seconds, :second)
    |> compact_datetime()
  end

  # A JSCalendar local wall time "2026-09-15T19:00:00" -> "20260915T190000".
  defp wall_stamp(local_iso) do
    local_iso
    |> String.replace(["-", ":"], "")
    |> String.slice(0, 15)
  end

  defp utc_stamp(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> compact_datetime() |> Kernel.<>("Z")
  end

  defp compact_datetime(%DateTime{} = dt) do
    "#{pad(dt.year, 4)}#{pad(dt.month, 2)}#{pad(dt.day, 2)}T" <>
      "#{pad(dt.hour, 2)}#{pad(dt.minute, 2)}#{pad(dt.second, 2)}"
  end

  defp offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    abs = abs(seconds)
    h = div(abs, 3600)
    m = div(rem(abs, 3600), 60)
    s = rem(abs, 60)
    base = "#{sign}#{pad(h, 2)}#{pad(m, 2)}"
    if s == 0, do: base, else: base <> pad(s, 2)
  end

  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")

  # RFC 5545 §3.3.11 TEXT escaping.
  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\r\n", "\\n")
    |> String.replace("\n", "\\n")
  end

  defp escape(_value), do: ""

  # CRLF line endings + folding to <=75 octets without splitting a UTF-8 char.
  defp encode(lines) do
    lines
    |> Enum.map_join("\r\n", &fold/1)
    |> Kernel.<>("\r\n")
  end

  defp fold(line) do
    line
    |> String.codepoints()
    |> Enum.reduce({[], 0, false}, fn cp, {acc, len, folded} ->
      size = byte_size(cp)
      limit = if folded, do: 74, else: 75

      if len + size > limit do
        {[cp, " ", "\r\n" | acc], size + 1, true}
      else
        {[cp | acc], len + size, folded}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
