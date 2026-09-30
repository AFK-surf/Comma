defmodule SalixCalendar.Recurrence do
  @moduledoc "Bounded expansion for the initial JSCalendar recurrence subset."

  @default_limit 200
  @max_limit 1_000
  @default_day_budget 3_660
  @weekday %{"mo" => 1, "tu" => 2, "we" => 3, "th" => 4, "fr" => 5, "sa" => 6, "su" => 7}

  def expand(item, range_start_ms, range_end_ms, opts \\ [])

  def expand(item, range_start_ms, range_end_ms, opts)
      when is_map(item) and is_integer(range_start_ms) and is_integer(range_end_ms) do
    limit = Keyword.get(opts, :limit, @default_limit)
    day_budget = Keyword.get(opts, :day_budget, @default_day_budget)

    with true <- range_start_ms < range_end_ms,
         true <- is_integer(limit) and limit > 0 and limit <= @max_limit,
         true <- is_integer(day_budget) and day_budget > 0,
         {:ok, anchor} <- anchor(item["object"] || %{}, opts),
         {:ok, rules} <- rules(item["object"] || %{}),
         :ok <- validate_anchor_rules(anchor, rules),
         {:ok, generated} <-
           expand_rules(item, anchor, rules, range_start_ms, range_end_ms, limit, day_budget),
         {:ok, moved_overrides} <-
           expand_moved_overrides(
             item,
             anchor,
             rules,
             range_start_ms,
             range_end_ms,
             day_budget
           ),
         {:ok, views} <- merge_views(generated, moved_overrides, limit) do
      {:ok, views}
    else
      false -> {:error, :invalid_expansion_bounds}
      {:error, _} = error -> error
    end
  end

  def expand(_item, _range_start_ms, _range_end_ms, _opts),
    do: {:error, :invalid_expansion_bounds}

  @doc "Resolve one stable OccurrenceRef without materializing a series."
  def resolve(item, occurrence_ref, opts \\ [])

  def resolve(item, occurrence_ref, opts) when is_map(item) and is_map(occurrence_ref) do
    object = item["object"] || %{}
    recurrence_key = occurrence_ref["recurrence_key"] || %{}

    with true <- occurrence_ref["calendar_id"] == item["calendar_id"],
         true <- occurrence_ref["scheduling_link_id"] == item["scheduling_link_id"],
         {:ok, anchor} <- anchor(object, opts),
         {:ok, rules} <- rules(object),
         :ok <- validate_anchor_rules(anchor, rules),
         {:ok, view} <- resolve_key(item, anchor, rules, recurrence_key),
         true <- is_map(view) do
      {:ok, view}
    else
      false -> {:error, :occurrence_not_found}
      {:error, _} = error -> error
    end
  end

  def resolve(_item, _occurrence_ref, _opts), do: {:error, :invalid_occurrence_ref}

  def valid_key?(%{"kind" => "single"} = key), do: map_size(key) == 1

  def valid_key?(
        %{
          "kind" => "recurring",
          "value" => value,
          "value_kind" => kind,
          "time_zone" => zone
        } = key
      ),
      do:
        map_size(key) == 4 and is_binary(value) and
          kind in ~w(date local_date_time utc_date_time) and
          is_binary(zone) and zone != "" and
          match?({:ok, _}, NaiveDateTime.from_iso8601(value))

  def valid_key?(_key), do: false

  defp resolve_key(item, anchor, [%{"frequency" => "once"}], %{"kind" => "single"} = key) do
    if map_size(key) == 1 do
      original_naive = NaiveDateTime.new!(anchor.date, anchor.time)

      occurrence_naive(
        item,
        anchor,
        original_naive,
        nil,
        -9_000_000_000_000_000,
        9_000_000_000_000_000
      )
    else
      {:error, :invalid_occurrence_ref}
    end
  end

  defp resolve_key(
         item,
         anchor,
         [rule],
         %{
           "kind" => "recurring",
           "value" => value,
           "value_kind" => value_kind,
           "time_zone" => time_zone
         } = key
       )
       when is_binary(value) do
    with :ok <- require_recurrence_key(key, value_kind, time_zone, anchor),
         {:ok, original_naive} <- NaiveDateTime.from_iso8601(value),
         :ok <- require_explicit_or_generated_occurrence(item, original_naive, anchor, rule),
         {:ok, original_ms} <- zoned_ms(original_naive, anchor.time_zone) do
      occurrence_naive(
        item,
        anchor,
        original_naive,
        original_ms,
        -9_000_000_000_000_000,
        9_000_000_000_000_000
      )
    else
      {:error, _} = error -> error
    end
  end

  defp resolve_key(_item, _anchor, _rules, _key), do: {:error, :invalid_occurrence_ref}

  defp require_recurrence_key(key, value_kind, time_zone, anchor) do
    if map_size(key) == 4 and value_kind == anchor.value_kind and time_zone == anchor.time_zone,
      do: :ok,
      else: {:error, :invalid_occurrence_ref}
  end

  defp require_explicit_or_generated_occurrence(item, original_naive, anchor, rule) do
    recurrence_key = NaiveDateTime.to_iso8601(original_naive)
    overrides = get_in(item, ["object", "recurrenceOverrides"]) || %{}

    cond do
      not is_map(overrides) ->
        {:error, :invalid_override}

      Map.has_key?(overrides, recurrence_key) ->
        if is_map(overrides[recurrence_key]), do: :ok, else: {:error, :invalid_override}

      occurrence_member?(original_naive, anchor, rule) ->
        :ok

      true ->
        {:error, :occurrence_not_found}
    end
  end

  defp anchor(object, opts) do
    value = object["start"] || object["due"]
    time_zone = object["timeZone"] || Keyword.get(opts, :floating_time_zone)

    cond do
      not is_binary(value) ->
        {:error, :undated_item}

      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) ->
        with {:ok, date} <- Date.from_iso8601(value) do
          {:ok,
           %{date: date, time: ~T[00:00:00], time_zone: time_zone || "UTC", value_kind: "date"}}
        end

      String.ends_with?(value, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, value) ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
          zone = time_zone || "UTC"

          with {:ok, shifted} <- DateTime.shift_zone(datetime, zone) do
            {:ok,
             %{
               date: DateTime.to_date(shifted),
               time: DateTime.to_time(shifted),
               time_zone: zone,
               value_kind: "utc_date_time"
             }}
          end
        end

      true ->
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             zone when is_binary(zone) <- time_zone do
          {:ok,
           %{
             date: NaiveDateTime.to_date(naive),
             time: NaiveDateTime.to_time(naive),
             time_zone: zone,
             value_kind: "local_date_time"
           }}
        else
          nil -> {:error, :floating_time_zone_required}
          {:error, _} -> {:error, :invalid_start}
        end
    end
  end

  defp rules(object) do
    case {object["recurrenceRules"] || [], object["excludedRecurrenceRules"] || []} do
      {[], []} -> {:ok, [%{"frequency" => "once", "interval" => 1}]}
      {[rule], []} when is_map(rule) -> validate_rule(rule)
      _ -> {:error, :unsupported_recurrence}
    end
  end

  defp validate_rule(rule) do
    frequency = rule["frequency"]
    interval = rule["interval"] || 1
    by_day = rule["byDay"]
    by_hour = rule["byHour"]
    by_minute = rule["byMinute"]

    allowed_keys =
      case frequency do
        "weekly" -> ~w(@type frequency interval byDay byHour byMinute firstDayOfWeek)
        "daily" -> ~w(@type frequency interval byDay byHour byMinute)
        _ -> ~w(@type frequency interval)
      end

    valid_by_day? =
      is_nil(by_day) or
        (frequency in ~w(daily weekly) and is_list(by_day) and by_day != [] and
           Enum.all?(by_day, fn
             %{"day" => day} = nday ->
               Map.keys(nday) -- ~w(@type day) == [] and nday["@type"] in [nil, "NDay"] and
                 Map.has_key?(@weekday, day)

             _ ->
               false
           end))

    valid_clock? =
      valid_single_integer?(by_hour, 0..23) and valid_single_integer?(by_minute, 0..59)

    valid_first_day? =
      is_nil(rule["firstDayOfWeek"]) or
        (frequency == "weekly" and Map.has_key?(@weekday, rule["firstDayOfWeek"]))

    if Map.keys(rule) -- allowed_keys == [] and rule["@type"] in [nil, "RecurrenceRule"] and
         frequency in ~w(minutely daily weekly) and is_integer(interval) and interval > 0 and
         valid_by_day? and valid_clock? and valid_first_day? do
      {:ok, [Map.put(rule, "interval", interval)]}
    else
      {:error, :unsupported_recurrence}
    end
  end

  defp valid_single_integer?(nil, _range), do: true

  defp valid_single_integer?([value], range) when is_integer(value), do: value in range
  defp valid_single_integer?(_value, _range), do: false

  defp validate_anchor_rules(_anchor, [%{"frequency" => "once"}]), do: :ok

  defp validate_anchor_rules(
         %{value_kind: "utc_date_time", time_zone: zone},
         [%{"frequency" => "minutely"}]
       )
       when zone in ["UTC", "Etc/UTC"],
       do: :ok

  defp validate_anchor_rules(_anchor, [%{"frequency" => "minutely"}]),
    do: {:error, :unsupported_recurrence}

  defp validate_anchor_rules(anchor, [%{"frequency" => frequency} = rule])
       when frequency in ~w(daily weekly) do
    hour_matches? = is_nil(rule["byHour"]) or rule["byHour"] == [anchor.time.hour]
    minute_matches? = is_nil(rule["byMinute"]) or rule["byMinute"] == [anchor.time.minute]

    if hour_matches? and minute_matches?, do: :ok, else: {:error, :unsupported_recurrence}
  end

  defp validate_anchor_rules(_anchor, _rules), do: {:error, :unsupported_recurrence}

  defp expand_rules(item, anchor, [%{"frequency" => "once"}], from, to, _limit, _budget) do
    occurrence(item, anchor, anchor.date, from, to)
    |> case do
      {:ok, nil} -> {:ok, []}
      {:ok, view} -> {:ok, [view]}
      error -> error
    end
  end

  defp expand_rules(
         item,
         anchor,
         [%{"frequency" => "minutely", "interval" => interval}],
         from,
         to,
         limit,
         day_budget
       ) do
    with {:ok, anchor_ms} <-
           zoned_ms(NaiveDateTime.new!(anchor.date, anchor.time), anchor.time_zone),
         {:ok, duration} <- duration_ms(get_in(item, ["object", "duration"])),
         true <- div(max(to - from, 0), 86_400_000) <= day_budget do
      step_ms = interval * 60_000
      first_index = max(div(max(from - duration - anchor_ms, 0), step_ms), 0)

      expand_minutely(item, anchor, anchor_ms, step_ms, first_index, from, to, limit, [])
    else
      false -> {:error, :recurrence_budget_exceeded}
      {:error, _} = error -> error
    end
  end

  defp expand_rules(item, anchor, [rule], from, to, limit, day_budget) do
    with {:ok, duration} <- duration_ms(get_in(item, ["object", "duration"])),
         {:ok, from_date} <- local_date(from - duration, anchor.time_zone),
         {:ok, to_date} <- local_date(to - 1, anchor.time_zone) do
      first =
        case Date.compare(anchor.date, from_date) do
          :lt -> from_date
          _ -> anchor.date
        end

      days = Date.diff(to_date, first) + 1

      cond do
        days <= 0 ->
          {:ok, []}

        days > day_budget ->
          {:error, :recurrence_budget_exceeded}

        true ->
          first
          |> Date.range(to_date)
          |> Enum.reduce_while({:ok, []}, fn date, {:ok, views} ->
            cond do
              member?(date, anchor.date, rule) ->
                case occurrence(item, anchor, date, from, to) do
                  {:ok, nil} ->
                    {:cont, {:ok, views}}

                  {:ok, view} ->
                    if length(views) < limit,
                      do: {:cont, {:ok, [view | views]}},
                      else: {:halt, {:error, :occurrence_limit_exceeded}}

                  {:error, _} = error ->
                    {:halt, error}
                end

              true ->
                {:cont, {:ok, views}}
            end
          end)
          |> case do
            {:ok, views} -> {:ok, Enum.reverse(views)}
            error -> error
          end
      end
    end
  end

  defp member?(date, anchor, %{"frequency" => "daily", "interval" => interval} = rule),
    do:
      Date.compare(date, anchor) != :lt and
        (date == anchor or
           (rem(Date.diff(date, anchor), interval) == 0 and
              matches_by_day?(date, rule["byDay"])))

  defp member?(date, anchor, %{"frequency" => "weekly", "interval" => interval} = rule) do
    first_day = @weekday[rule["firstDayOfWeek"] || "mo"]

    week =
      div(
        Date.diff(beginning_of_week(date, first_day), beginning_of_week(anchor, first_day)),
        7
      )

    days = rule["byDay"] || [%{"day" => day_name(anchor)}]

    Date.compare(date, anchor) != :lt and
      (date == anchor or
         (week >= 0 and rem(week, interval) == 0 and matches_by_day?(date, days)))
  end

  defp beginning_of_week(date, first_day) do
    offset = rem(Date.day_of_week(date) - first_day + 7, 7)
    Date.add(date, -offset)
  end

  defp matches_by_day?(_date, nil), do: true

  defp matches_by_day?(date, days) when is_list(days),
    do: Enum.any?(days, &(@weekday[&1["day"]] == Date.day_of_week(date)))

  defp occurrence_member?(naive, anchor, %{"frequency" => "once"}),
    do: naive == NaiveDateTime.new!(anchor.date, anchor.time)

  defp occurrence_member?(naive, anchor, %{"frequency" => frequency} = rule)
       when frequency in ~w(daily weekly),
       do:
         NaiveDateTime.to_time(naive) == anchor.time and
           member?(NaiveDateTime.to_date(naive), anchor.date, rule)

  defp occurrence_member?(naive, anchor, %{"frequency" => "minutely", "interval" => interval}) do
    with {:ok, anchor_ms} <-
           zoned_ms(NaiveDateTime.new!(anchor.date, anchor.time), anchor.time_zone),
         {:ok, occurrence_ms} <- zoned_ms(naive, anchor.time_zone) do
      difference = occurrence_ms - anchor_ms
      difference >= 0 and rem(difference, interval * 60_000) == 0
    else
      _ -> false
    end
  end

  defp occurrence_member?(_naive, _anchor, _rule), do: false

  defp expand_minutely(item, anchor, anchor_ms, step_ms, index, from, to, limit, views) do
    original_ms = anchor_ms + index * step_ms

    cond do
      original_ms >= to ->
        {:ok, Enum.reverse(views)}

      true ->
        with {:ok, datetime} <- DateTime.from_unix(original_ms, :millisecond),
             {:ok, local} <- DateTime.shift_zone(datetime, anchor.time_zone),
             {:ok, view} <-
               occurrence_naive(
                 item,
                 anchor,
                 DateTime.to_naive(local),
                 original_ms,
                 from,
                 to
               ) do
          cond do
            is_nil(view) ->
              expand_minutely(
                item,
                anchor,
                anchor_ms,
                step_ms,
                index + 1,
                from,
                to,
                limit,
                views
              )

            length(views) < limit ->
              expand_minutely(
                item,
                anchor,
                anchor_ms,
                step_ms,
                index + 1,
                from,
                to,
                limit,
                [view | views]
              )

            true ->
              {:error, :occurrence_limit_exceeded}
          end
        end
    end
  end

  defp expand_moved_overrides(_item, _anchor, [%{"frequency" => "once"}], _from, _to, _budget),
    do: {:ok, []}

  defp expand_moved_overrides(item, anchor, [_rule], from, to, budget) do
    overrides = get_in(item, ["object", "recurrenceOverrides"]) || %{}

    if is_map(overrides) and map_size(overrides) <= budget do
      overrides
      |> Enum.reduce_while({:ok, []}, fn {original, override}, {:ok, views} ->
        with true <- is_binary(original) and is_map(override),
             {:ok, original_naive} <- NaiveDateTime.from_iso8601(original),
             {:ok, view} <- occurrence_naive(item, anchor, original_naive, nil, from, to) do
          {:cont, {:ok, if(view, do: [view | views], else: views)}}
        else
          false -> {:halt, {:error, :invalid_override}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, views} -> {:ok, Enum.reverse(views)}
        error -> error
      end
    else
      {:error, :recurrence_budget_exceeded}
    end
  end

  defp merge_views(generated, overrides, limit) do
    views =
      (generated ++ overrides)
      |> Map.new(fn view -> {get_in(view, ["occurrence_ref", "recurrence_key"]), view} end)
      |> Map.values()
      |> Enum.sort_by(
        &{&1["start_ms"], get_in(&1, ["occurrence_ref", "recurrence_key", "value"])}
      )

    if length(views) <= limit,
      do: {:ok, views},
      else: {:error, :occurrence_limit_exceeded}
  end

  defp occurrence(item, anchor, date, from, to),
    do: occurrence_naive(item, anchor, NaiveDateTime.new!(date, anchor.time), nil, from, to)

  defp occurrence_naive(item, anchor, original_naive, original_ms, from, to) do
    recurrence_key = NaiveDateTime.to_iso8601(original_naive)
    overrides = get_in(item, ["object", "recurrenceOverrides"]) || %{}
    override = overrides[recurrence_key] || %{}

    if override["excluded"] == true do
      {:ok, nil}
    else
      with {:ok, start_naive} <- override_start(override["start"], original_naive),
           {:ok, start_ms} <-
             effective_start_ms(override["start"], start_naive, original_ms, anchor.time_zone),
           duration <- override["duration"] || get_in(item, ["object", "duration"]),
           {:ok, end_ms} <- effective_end_ms(start_naive, start_ms, duration, anchor) do
        if start_ms < to and end_ms > from do
          recurrence_key_value =
            if get_in(item, ["object", "recurrenceRules"]) in [nil, []] do
              %{"kind" => "single"}
            else
              %{
                "kind" => "recurring",
                "value_kind" => anchor.value_kind,
                "value" => recurrence_key,
                "time_zone" => anchor.time_zone
              }
            end

          {:ok,
           %{
             "occurrence_ref" => %{
               "calendar_id" => item["calendar_id"],
               "scheduling_link_id" => item["scheduling_link_id"],
               "recurrence_key" => recurrence_key_value
             },
             "object_type" => get_in(item, ["object", "@type"]),
             "effective" => %{
               "start" => NaiveDateTime.to_iso8601(start_naive),
               "timeZone" => anchor.time_zone,
               "duration" => override["duration"] || get_in(item, ["object", "duration"]),
               "virtualLocations" =>
                 effective_field(
                   override,
                   "virtualLocations",
                   get_in(item, ["object", "virtualLocations"])
                 )
             },
             "start_ms" => start_ms,
             "end_ms" => end_ms,
             "calendar_revision" => item["revision"]
           }}
        else
          {:ok, nil}
        end
      end
    end
  end

  defp override_start(nil, original), do: {:ok, original}

  defp override_start(value, _original) when is_binary(value),
    do: NaiveDateTime.from_iso8601(value)

  defp override_start(_value, _original), do: {:error, :invalid_override}

  defp effective_field(override, field, fallback) do
    if Map.has_key?(override, field), do: override[field], else: fallback
  end

  defp effective_start_ms(nil, _start_naive, original_ms, _zone) when is_integer(original_ms),
    do: {:ok, original_ms}

  defp effective_start_ms(_override, start_naive, _original_ms, zone),
    do: zoned_ms(start_naive, zone)

  defp local_date(ms, zone) do
    with {:ok, datetime} <- DateTime.from_unix(ms, :millisecond),
         {:ok, shifted} <- DateTime.shift_zone(datetime, zone) do
      {:ok, DateTime.to_date(shifted)}
    end
  end

  @doc "Resolves a local wall time with the recurrence domain's DST disambiguation policy."
  def resolve_local_time(%NaiveDateTime{} = naive, zone) when is_binary(zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, datetime} -> local_time_result(datetime)
      {:ambiguous, earlier, _later} -> local_time_result(earlier)
      {:gap, before_gap, _after_gap} -> gap_local_time_result(naive, before_gap)
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_local_time(_naive, _zone), do: {:error, :invalid_local_time}

  defp zoned_ms(naive, zone) do
    with {:ok, %{unix_ms: unix_ms}} <- resolve_local_time(naive, zone), do: {:ok, unix_ms}
  end

  defp local_time_result(datetime) do
    {:ok,
     %{
       unix_ms: DateTime.to_unix(datetime, :millisecond),
       iso8601: DateTime.to_iso8601(datetime)
     }}
  end

  defp gap_local_time_result(naive, before_gap) do
    with {:ok, unix_ms} <- gap_ms(naive, before_gap) do
      offset_seconds = before_gap.utc_offset + before_gap.std_offset

      {:ok,
       %{
         unix_ms: unix_ms,
         iso8601: NaiveDateTime.to_iso8601(naive) <> iso8601_offset(offset_seconds)
       }}
    end
  end

  defp iso8601_offset(0), do: "Z"

  defp iso8601_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    seconds = abs(seconds)
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    seconds = rem(seconds, 60)
    base = sign <> pad2(hours) <> ":" <> pad2(minutes)
    if seconds == 0, do: base, else: base <> ":" <> pad2(seconds)
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp gap_ms(naive, before_gap) do
    with {:ok, utc_wall_time} <- DateTime.from_naive(naive, "Etc/UTC") do
      offset_seconds = before_gap.utc_offset + before_gap.std_offset

      {:ok, DateTime.to_unix(utc_wall_time, :millisecond) - offset_seconds * 1_000}
    end
  end

  defp effective_end_ms(
         start_naive,
         _start_ms,
         duration,
         %{value_kind: "date", time_zone: zone}
       ) do
    with {:ok, days} <- date_duration_days(duration),
         end_date <- start_naive |> NaiveDateTime.to_date() |> Date.add(days),
         end_naive <- NaiveDateTime.new!(end_date, NaiveDateTime.to_time(start_naive)),
         {:ok, end_ms} <- zoned_ms(end_naive, zone) do
      {:ok, end_ms}
    end
  end

  defp effective_end_ms(_start_naive, start_ms, duration, _anchor) do
    with {:ok, duration_ms} <- duration_ms(duration) do
      {:ok, start_ms + duration_ms}
    end
  end

  defp date_duration_days(value) when is_binary(value) do
    case Regex.run(~r/^P([1-9]\d*)D$/, value, capture: :all_but_first) do
      [days] -> {:ok, String.to_integer(days)}
      _ -> {:error, :invalid_all_day_duration}
    end
  end

  defp date_duration_days(_value), do: {:error, :invalid_all_day_duration}

  defp duration_ms(nil), do: {:ok, 1}

  defp duration_ms(value) when is_binary(value) do
    pattern =
      ~r/^P(?:(?<days>\d+)D)?(?:T(?:(?<hours>\d+)H)?(?:(?<minutes>\d+)M)?(?:(?<seconds>\d+)S)?)?$/

    case Regex.named_captures(pattern, value) do
      %{} = captures ->
        [days, hours, minutes, seconds] =
          ~w(days hours minutes seconds)
          |> Enum.map(&integer_or_zero(captures[&1]))

        milliseconds = (((days * 24 + hours) * 60 + minutes) * 60 + seconds) * 1_000

        if milliseconds > 0, do: {:ok, milliseconds}, else: {:error, :invalid_duration}

      nil ->
        {:error, :invalid_duration}
    end
  end

  defp duration_ms(_value), do: {:error, :invalid_duration}

  defp integer_or_zero(""), do: 0
  defp integer_or_zero(nil), do: 0
  defp integer_or_zero(value), do: String.to_integer(value)

  defp day_name(date) do
    @weekday |> Enum.find(fn {_name, number} -> number == Date.day_of_week(date) end) |> elem(0)
  end
end
