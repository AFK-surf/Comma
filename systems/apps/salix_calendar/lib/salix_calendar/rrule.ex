defmodule SalixCalendar.RRule do
  @moduledoc """
  Reads one iCalendar RRULE (RFC 5545) into the JSCalendar rule that
  `SalixCalendar.Recurrence` generates, for a series whose first start is
  `start_ms` in `time_zone`. The calendar sources share it, so they accept the
  same rules:

    * DAILY, and WEEKLY with weekdays (`BYDAY=MO,TH`) and a week start;
    * MONTHLY on the start's day of month, or on one ordinal weekday
      (`BYDAY=2TH`, `BYDAY=-1FR`);
    * YEARLY on the start's month and day;

  each with INTERVAL and either UNTIL or COUNT. UNTIL becomes the last local
  start the rule may generate; a date-only UNTIL includes that whole day.
  COUNT becomes the `until` of its last instance. Any other rule is
  `{:error, :unsupported_recurrence}`.
  """

  alias SalixCalendar.Recurrence

  @weekdays ~w(MO TU WE TH FR SA SU)
  @keys %{
    "DAILY" => ~w(FREQ INTERVAL BYDAY WKST UNTIL COUNT),
    "WEEKLY" => ~w(FREQ INTERVAL BYDAY WKST UNTIL COUNT),
    "MONTHLY" => ~w(FREQ INTERVAL BYDAY BYMONTHDAY WKST UNTIL COUNT),
    "YEARLY" => ~w(FREQ INTERVAL WKST UNTIL COUNT)
  }

  @spec parse(String.t(), integer(), String.t()) ::
          {:ok, map()} | {:error, :unsupported_recurrence}
  def parse(value, start_ms, time_zone)
      when is_binary(value) and is_integer(start_ms) and is_binary(time_zone) do
    parts = parts(value)
    frequency = parts["FREQ"]

    with keys when is_list(keys) <- @keys[frequency],
         [] <- Map.keys(parts) -- keys,
         false <- Map.has_key?(parts, "UNTIL") and Map.has_key?(parts, "COUNT"),
         {:ok, start} <- local_start(start_ms, time_zone),
         {:ok, interval} <- positive_integer(parts["INTERVAL"] || "1"),
         {:ok, first_day} <- week_start(parts["WKST"], frequency),
         {:ok, by_day} <- by_day(parts["BYDAY"], frequency),
         :ok <- month_day(parts["BYMONTHDAY"], by_day, start),
         {:ok, until} <- until(parts["UNTIL"], time_zone) do
      %{
        "@type" => "RecurrenceRule",
        "frequency" => String.downcase(frequency),
        "interval" => interval
      }
      |> put_optional("byDay", by_day)
      |> put_optional("firstDayOfWeek", first_day)
      |> put_optional("until", until)
      |> count(parts["COUNT"], start)
    else
      _ -> {:error, :unsupported_recurrence}
    end
  end

  def parse(_value, _start_ms, _time_zone), do: {:error, :unsupported_recurrence}

  defp parts(value) do
    value
    |> String.replace_prefix("RRULE:", "")
    |> String.split(";", trim: true)
    |> Map.new(fn part ->
      case String.split(part, "=", parts: 2) do
        [key, rule] -> {String.upcase(key), rule}
        [key] -> {String.upcase(key), ""}
      end
    end)
  end

  defp local_start(start_ms, time_zone) do
    with {:ok, datetime} <- DateTime.from_unix(start_ms, :millisecond),
         {:ok, local} <- DateTime.shift_zone(datetime, time_zone) do
      {:ok, local |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)}
    end
  end

  # The week start changes only a weekly rule with an interval; elsewhere it
  # has no effect and is dropped.
  defp week_start(nil, _frequency), do: {:ok, nil}
  defp week_start(day, "WEEKLY") when day in @weekdays, do: {:ok, String.downcase(day)}
  defp week_start(day, _frequency) when day in @weekdays, do: {:ok, nil}
  defp week_start(_day, _frequency), do: :error

  defp by_day(nil, _frequency), do: {:ok, nil}

  defp by_day(value, frequency) when frequency in ~w(DAILY WEEKLY) do
    tokens = String.split(value, ",", trim: true)

    if tokens != [] and Enum.all?(tokens, &(&1 in @weekdays)),
      do: {:ok, Enum.map(tokens, &%{"@type" => "NDay", "day" => String.downcase(&1)})},
      else: :error
  end

  defp by_day(value, "MONTHLY") do
    case Regex.run(~r/^([+-]?[1-5])(MO|TU|WE|TH|FR|SA|SU)$/, value, capture: :all_but_first) do
      [nth, day] ->
        {:ok,
         [
           %{
             "@type" => "NDay",
             "day" => String.downcase(day),
             "nthOfPeriod" => String.to_integer(String.trim_leading(nth, "+"))
           }
         ]}

      nil ->
        :error
    end
  end

  # A monthly rule repeats on the start's day of month by default, so only
  # that day may be named, and not together with a weekday.
  defp month_day(nil, _by_day, _start), do: :ok

  defp month_day(value, nil, start),
    do: if(value == Integer.to_string(start.day), do: :ok, else: :error)

  defp month_day(_value, _by_day, _start), do: :error

  defp until(nil, _time_zone), do: {:ok, nil}

  defp until(value, time_zone) do
    cond do
      Regex.match?(~r/^\d{8}T\d{6}Z$/, value) ->
        with {:ok, naive} <- basic_naive(value),
             {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC"),
             {:ok, local} <- DateTime.shift_zone(utc, time_zone) do
          {:ok, local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()}
        else
          _ -> :error
        end

      Regex.match?(~r/^\d{8}T\d{6}$/, value) ->
        with {:ok, naive} <- basic_naive(value), do: {:ok, NaiveDateTime.to_iso8601(naive)}

      Regex.match?(~r/^\d{8}$/, value) ->
        with {:ok, naive} <- basic_naive(value <> "T235959"),
             do: {:ok, NaiveDateTime.to_iso8601(naive)}

      true ->
        :error
    end
  end

  defp basic_naive(
         <<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           _rest::binary>>
       ) do
    case NaiveDateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:#{mi}:#{s}") do
      {:ok, naive} -> {:ok, naive}
      _ -> :error
    end
  end

  defp count(rule, nil, _start), do: {:ok, rule}

  defp count(rule, value, start) do
    with {:ok, count} <- positive_integer(value),
         {:ok, until} <- Recurrence.count_until(start, rule, count) do
      {:ok, Map.put(rule, "until", until)}
    else
      _ -> {:error, :unsupported_recurrence}
    end
  end

  defp positive_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
