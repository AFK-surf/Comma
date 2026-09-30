defmodule BridgeForTeamsWeb.Dashboard.SchedulePresentation do
  @moduledoc false

  use Gettext, backend: BridgeForTeamsWeb.Gettext

  @minute_units %{"minutes" => 1, "hours" => 60, "days" => 1_440}
  @weekday_names %{
    "0" => "Sunday",
    "1" => "Monday",
    "2" => "Tuesday",
    "3" => "Wednesday",
    "4" => "Thursday",
    "5" => "Friday",
    "6" => "Saturday",
    "7" => "Sunday",
    "SUN" => "Sunday",
    "MON" => "Monday",
    "TUE" => "Tuesday",
    "WED" => "Wednesday",
    "THU" => "Thursday",
    "FRI" => "Friday",
    "SAT" => "Saturday"
  }

  @month_names %{
    "1" => 1,
    "2" => 2,
    "3" => 3,
    "4" => 4,
    "5" => 5,
    "6" => 6,
    "7" => 7,
    "8" => 8,
    "9" => 9,
    "10" => 10,
    "11" => 11,
    "12" => 12,
    "JAN" => 1,
    "FEB" => 2,
    "MAR" => 3,
    "APR" => 4,
    "MAY" => 5,
    "JUN" => 6,
    "JUL" => 7,
    "AUG" => 8,
    "SEP" => 9,
    "OCT" => 10,
    "NOV" => 11,
    "DEC" => 12
  }

  def form_values(schedule) when is_map(schedule) do
    base = %{
      "mode" => "cron",
      "interval_value" => "1",
      "interval_unit" => "days",
      "cron" => "",
      "timezone" => "UTC"
    }

    cond do
      nonblank?(schedule["cron"]) ->
        Map.merge(base, %{
          "mode" => "cron",
          "cron" => schedule["cron"],
          "timezone" => schedule["timezone"] || ""
        })

      is_integer(schedule["interval_minutes"]) and schedule["interval_minutes"] > 0 ->
        Map.merge(base, interval_form_values(schedule["interval_minutes"]))

      true ->
        base
    end
  end

  def form_values(_schedule), do: form_values(%{})

  def recurrence(%{"mode" => "interval"} = params), do: interval_recurrence(params)
  def recurrence(%{"mode" => "cron"} = params), do: cron_recurrence(params)

  def recurrence(%{"interval_minutes" => minutes}) when is_integer(minutes) and minutes > 0,
    do: interval_description(minutes)

  def recurrence(%{"cron" => cron} = schedule) when is_binary(cron) and cron != "",
    do: cron_description(cron, schedule["timezone"])

  def recurrence(_schedule), do: gettext("Schedule not configured")

  def to_recurrence(%{"mode" => "interval"} = params) do
    with {:ok, minutes} <- interval_minutes(params) do
      {:ok, %{"interval_minutes" => minutes}}
    end
  end

  def to_recurrence(%{"mode" => "cron"} = params) do
    cron = String.trim(params["cron"] || "")
    timezone = String.trim(params["timezone"] || "")

    if cron != "" and timezone != "",
      do: {:ok, %{"cron" => cron, "timezone" => timezone}},
      else: {:error, :invalid_schedule}
  end

  def to_recurrence(_params), do: {:error, :invalid_schedule}

  defp interval_form_values(minutes) do
    {value, unit} = interval_parts(minutes)

    %{
      "mode" => "interval",
      "interval_value" => to_string(value),
      "interval_unit" => unit
    }
  end

  defp interval_recurrence(params) do
    case interval_minutes(params) do
      {:ok, minutes} -> interval_description(minutes)
      {:error, _reason} -> gettext("Set a valid schedule")
    end
  end

  defp interval_minutes(params) do
    with {value, ""} when value > 0 <- Integer.parse(params["interval_value"] || ""),
         multiplier when is_integer(multiplier) <- @minute_units[params["interval_unit"]] do
      {:ok, value * multiplier}
    else
      _ -> {:error, :invalid_schedule}
    end
  end

  defp interval_description(minutes) do
    case interval_parts(minutes) do
      {1, "days"} ->
        gettext("Every day")

      {1, "minutes"} ->
        gettext("Every minute")

      {1, "hours"} ->
        gettext("Every hour")

      {count, "minutes"} ->
        ngettext("Every %{count} minute", "Every %{count} minutes", count, count: count)

      {count, "hours"} ->
        ngettext("Every %{count} hour", "Every %{count} hours", count, count: count)

      {count, "days"} ->
        ngettext("Every %{count} day", "Every %{count} days", count, count: count)
    end
  end

  defp interval_parts(minutes) when rem(minutes, 1_440) == 0, do: {div(minutes, 1_440), "days"}
  defp interval_parts(minutes) when rem(minutes, 60) == 0, do: {div(minutes, 60), "hours"}
  defp interval_parts(minutes), do: {minutes, "minutes"}

  defp cron_recurrence(params) do
    cron = String.trim(params["cron"] || "")

    if cron == "",
      do: gettext("Set a valid schedule"),
      else: cron_description(cron, params["timezone"])
  end

  defp cron_description(cron, timezone) do
    cron
    |> describe_cron()
    |> append_timezone(timezone)
  end

  defp describe_cron(cron) do
    # Salix accepts standard five-field Cron expressions, not aliases such as
    # `@daily`; never make an unsupported expression look valid in the preview.
    describe_cron_fields(cron)
  end

  defp describe_cron_fields(cron) do
    case String.split(String.upcase(String.trim(cron)), ~r/\s+/, trim: true) do
      ["*/" <> step, "*", "*", "*", "*"] ->
        case positive_integer(step) do
          {:ok, minutes} -> interval_description(minutes)
          :error -> gettext("Custom schedule")
        end

      [minute, hour, "*", "*", weekday] ->
        with {:ok, minute} <- minute_value(minute),
             {:ok, hour} <- hour_value(hour) do
          describe_clock_schedule(weekday, hour, minute)
        else
          _ -> gettext("Custom schedule")
        end

      [minute, hour, day, "*", "*"] ->
        with {:ok, minute} <- minute_value(minute),
             {:ok, hour} <- hour_value(hour),
             {:ok, day} <- day_value(day) do
          monthly_at(day, hour, minute)
        else
          _ -> gettext("Custom schedule")
        end

      [minute, hour, day, month, "*"] ->
        with {:ok, minute} <- minute_value(minute),
             {:ok, hour} <- hour_value(hour),
             {:ok, day} <- day_value(day),
             {:ok, month} <- month_value(month) do
          yearly_at(month, day, hour, minute)
        else
          _ -> gettext("Custom schedule")
        end

      _ ->
        gettext("Custom schedule")
    end
  end

  defp describe_clock_schedule("*", hour, minute), do: every_day_at(hour, minute)
  defp describe_clock_schedule("1-5", hour, minute), do: every_weekday_at("weekday", hour, minute)

  defp describe_clock_schedule("MON-FRI", hour, minute),
    do: every_weekday_at("weekday", hour, minute)

  defp describe_clock_schedule(weekday, hour, minute) do
    case @weekday_names[weekday] do
      nil -> gettext("Custom schedule")
      weekday -> every_weekday_at(weekday, hour, minute)
    end
  end

  defp every_day_at(hour, minute),
    do: gettext("Every day at %{time}", time: localized_time(hour, minute))

  defp every_weekday_at("weekday", hour, minute),
    do: gettext("Every weekday at %{time}", time: localized_time(hour, minute))

  defp every_weekday_at(weekday, hour, minute),
    do:
      gettext("Every %{weekday} at %{time}",
        weekday: weekday_label(weekday),
        time: localized_time(hour, minute)
      )

  defp monthly_at(day, hour, minute),
    do:
      gettext("Every month on day %{day} at %{time}",
        day: day,
        time: localized_time(hour, minute)
      )

  defp yearly_at(month, day, hour, minute),
    do:
      gettext("Every year on %{month}/%{day} at %{time}",
        month: month,
        day: day,
        time: localized_time(hour, minute)
      )

  defp append_timezone(description, timezone) do
    if nonblank?(timezone),
      do: gettext("%{schedule} (%{timezone})", schedule: description, timezone: timezone),
      else: description
  end

  defp localized_time(hour, minute) do
    if String.starts_with?(Gettext.get_locale(BridgeForTeamsWeb.Gettext), "zh") do
      {period, display_hour} = chinese_time_period(hour)

      if minute == 0 do
        gettext("%{period} %{hour} o'clock", period: period_label(period), hour: display_hour)
      else
        gettext("%{period} %{hour} o'clock %{minute} minutes",
          period: period_label(period),
          hour: display_hour,
          minute: minute
        )
      end
    else
      display_hour = rem(hour + 11, 12) + 1
      suffix = if hour < 12, do: "AM", else: "PM"

      time =
        if minute == 0,
          do: Integer.to_string(display_hour),
          else: "#{display_hour}:#{pad(minute)}"

      "#{time} #{suffix}"
    end
  end

  defp chinese_time_period(hour) when hour < 6, do: {"early morning", hour}
  defp chinese_time_period(hour) when hour < 12, do: {"morning", hour}
  defp chinese_time_period(12), do: {"noon", 12}
  defp chinese_time_period(hour) when hour < 19, do: {"afternoon", hour - 12}
  defp chinese_time_period(hour), do: {"evening", hour - 12}

  defp weekday_label("Sunday"), do: gettext("Sunday")
  defp weekday_label("Monday"), do: gettext("Monday")
  defp weekday_label("Tuesday"), do: gettext("Tuesday")
  defp weekday_label("Wednesday"), do: gettext("Wednesday")
  defp weekday_label("Thursday"), do: gettext("Thursday")
  defp weekday_label("Friday"), do: gettext("Friday")
  defp weekday_label("Saturday"), do: gettext("Saturday")

  defp period_label("early morning"), do: gettext("early morning")
  defp period_label("morning"), do: gettext("morning")
  defp period_label("noon"), do: gettext("noon")
  defp period_label("afternoon"), do: gettext("afternoon")
  defp period_label("evening"), do: gettext("evening")

  defp minute_value(value), do: bounded_integer(value, 0, 59)
  defp hour_value(value), do: bounded_integer(value, 0, 23)
  defp day_value(value), do: bounded_integer(value, 1, 31)

  defp month_value(value) do
    case @month_names[value] do
      value when is_integer(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp bounded_integer(value, minimum, maximum) do
    with {:ok, value} <- positive_or_zero_integer(value),
         true <- value >= minimum and value <= maximum do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp positive_integer(value) do
    case positive_or_zero_integer(value) do
      {:ok, value} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp positive_or_zero_integer(value) do
    case Integer.parse(value) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: Integer.to_string(value)

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_value), do: false
end
