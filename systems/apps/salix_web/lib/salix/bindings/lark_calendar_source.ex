defmodule Salix.Bindings.LarkCalendarSource do
  @moduledoc """
  Read-only Feishu/Lark calendar source adapter (Calendar v4).

  One module serves both platforms: the adapter key names the platform
  (`feishu_calendar` or `lark_calendar`) and the source locator names the
  connect, the identity and the calendar. The identity is the app (`account`
  `app`), which reads a team calendar it subscribed to, or a person who signed
  in with the app (an OAuth Binding alias), whose own calendars are read with
  their user access token (`SalixIM.Ports.LarkUserAccounts`,
  `SalixIM.Ports.FeishuUserAccounts`). A person's token is resolved for the
  Group's Router, as the Lark document reads resolve it.

  The event list is incremental: the first page starts a day back
  (`anchor_time`), later reads carry Lark's `sync_token`. A recurring event
  is stored as its master with the exceptions as overrides; an exception's id
  is `{uid}_{original_time}`, so its original start is the suffix. The
  event's meeting link is its `vchat.meeting_url`: a Feishu/Lark video
  meeting, or a third-party meeting (Zoom, Microsoft Teams) set on the event.
  A recognized link other than a Google Meet qualifies the item
  (`SalixCalendar.OccurrenceQualification`); a Google Meet there is left out,
  since the bot joins only a Meet that Google Calendar itself attached.

  Request shapes follow the platform's Calendar v4 API as the official
  larksuite/cli `calendar` shortcuts use it.
  """

  @behaviour SalixCalendar.SourceAdapter

  alias Salix.Control.Groups
  alias SalixIM.Ports.{FeishuUserAccounts, LarkUserAccounts}
  alias SalixIM.Provider.Feishu.API, as: FeishuAPI
  alias SalixIM.Provider.Lark.API, as: LarkAPI
  alias SalixIM.ProviderConnects
  alias SalixStore.{Crypto, JSON}

  @adapters %{"feishu_calendar" => "feishu", "lark_calendar" => "lark"}
  @app "app"
  @min_page_size 50
  @max_page_size 1_000
  @history_window_seconds 24 * 60 * 60
  @attendee_page_size 100
  @max_attendee_pages 10
  @upcoming_window_seconds 14 * 24 * 60 * 60
  @sync_token_expired 190_008
  @rrule_keys ~w(FREQ INTERVAL BYDAY WKST UNTIL)

  @doc "The adapter key of a platform's calendar source."
  def adapter_for("feishu"), do: "feishu_calendar"
  def adapter_for("lark"), do: "lark_calendar"

  @doc "Whether a source is a Feishu/Lark calendar."
  def adapter?(adapter), do: Map.has_key?(@adapters, adapter)

  @impl true
  def adapter_contract_id, do: "lark_calendar.events.v5"

  @impl true
  def capabilities do
    %{
      "object_types" => ["Event"],
      "sync_mode" => "collection_delta",
      "exact_read" => true,
      "max_page_size" => @max_page_size,
      "source_writes" => false,
      "recurrence_storage" => "master_with_overrides"
    }
  end

  @impl true
  def start_sync(source, query_contract, completed_cursor),
    do: read_page(source, query_contract, completed_cursor, nil)

  @impl true
  def continue_sync(source, query_contract, continuation) when is_binary(continuation) do
    with {:ok, %{"page_token" => page_token} = decoded} <- decode_continuation(continuation),
         do: read_page(source, query_contract, decoded["sync_token"], page_token)
  end

  @impl true
  def exact_refresh(source, item, occurrence) do
    source = JSON.stringify(source)

    requested_at = request_stamp(source)

    with {:ok, event} <- read_occurrence(source, item, occurrence),
         do:
           normalize(event,
             default_time_zone: default_time_zone(source),
             requested_at: requested_at
           )
  end

  @doc """
  The event an occurrence reads: its exception when it has one, else the
  master of its series.
  """
  def read_occurrence(source, item, occurrence) do
    source = JSON.stringify(source)
    item = JSON.stringify(item)
    occurrence = JSON.stringify(occurrence)
    key = get_in(occurrence, ["occurrence_ref", "recurrence_key", "value"])
    master_id = get_in(item, ["origin", "external_locator", "event_id"])
    instance_id = get_in(item, ["source_version", "recurrence_instances", key])
    event_id = if nonblank?(instance_id), do: instance_id, else: master_id

    with true <- nonblank?(event_id),
         {:ok, access} <- access(source),
         {:ok, data} <- get(access, events_path(access) <> "/" <> segment(event_id), %{}) do
      case data["event"] do
        %{} = event -> {:ok, event}
        _ -> {:error, :invalid_lark_calendar_response}
      end
    else
      false -> {:error, :calendar_event_source_mismatch}
      {:error, _} = error -> error
    end
  end

  @doc """
  The people of the exact meeting while it still has the expected title, link
  and times: `%{"user_id", "name", "organizer"}` with the platform's open_id.
  A group, room or outside email attendee is left out; Lark refuses the list
  when the identity may not see it.
  """
  def read_attendees(source, item, occurrence) do
    source = JSON.stringify(source)

    with {:ok, event} <- read_occurrence(source, item, occurrence),
         false <- cancelled?(event),
         :ok <- identity_current(event, item, occurrence, default_time_zone(source)),
         {:ok, access} <- access(source),
         {:ok, attendees} <- attendees(access, event["event_id"], nil, @max_attendee_pages, []) do
      {:ok,
       for %{"type" => "user", "user_id" => "ou_" <> _ = open_id} = attendee <- attendees,
           attendee["is_external"] != true,
           attendee["rsvp_status"] not in ["decline", "removed"] do
         %{
           "user_id" => open_id,
           "name" => present_or_nil(attendee["display_name"]),
           "organizer" => attendee["is_organizer"] == true
         }
       end}
    else
      true -> {:error, :calendar_event_cancelled}
      {:error, _} = error -> error
    end
  end

  @doc "One page of the next two weeks' meetings for the team's series selector."
  def upcoming_meetings(source, _page_token \\ nil) do
    now = SystemsClock.system_time(:second)

    with {:ok, access} <- access(JSON.stringify(source)),
         {:ok, data} <-
           get(access, events_path(access) <> "/instance_view", %{
             "start_time" => Integer.to_string(now),
             "end_time" => Integer.to_string(now + @upcoming_window_seconds),
             "user_id_type" => "open_id"
           }) do
      meetings =
        (data["items"] || [])
        |> Enum.filter(&(lark_meeting_url(&1) != nil and not cancelled?(&1)))
        |> Enum.map(fn event ->
          %{
            "event_id" => series_id(event),
            "title" => present_or_nil(event["summary"]) || "Calendar meeting",
            "recurring" => recurring?(event),
            "start" => start_iso8601(event)
          }
        end)
        |> Enum.uniq_by(& &1["event_id"])

      {:ok, %{"meetings" => meetings, "next_cursor" => nil}}
    end
  end

  @impl true
  def normalize(event, opts \\ [])

  def normalize(event, opts) when is_map(event) do
    event = JSON.stringify(event)
    default_time_zone = Keyword.get(opts, :default_time_zone, "UTC")

    requested_at =
      Keyword.get_lazy(opts, :requested_at, fn -> request_stamp(%{}) end)

    case parse_event_id(event["event_id"]) do
      {:ok, _uid, 0} ->
        if cancelled?(event),
          do: {:ok, tombstone(event)},
          else: normalize_master(event, default_time_zone, requested_at)

      {:ok, _uid, original_time} ->
        normalize_exception(event, original_time, default_time_zone)

      :error ->
        {:error, :invalid_lark_event}
    end
  end

  def normalize(_event, _opts), do: {:error, :invalid_lark_event}

  # ---------------------------------------------------------------------------
  # sync

  defp read_page(source, query_contract, sync_token, page_token) do
    source = JSON.stringify(source)
    query_contract = JSON.stringify(query_contract)

    page_size =
      (query_contract["page_size"] || get_in(source, ["sync_policy", "page_size"]) || 200)
      |> max(@min_page_size)

    with true <- page_size <= @max_page_size,
         true <- query_contract["object_type"] in [nil, "Event"],
         true <- query_contract["group_id"] == source["group_id"],
         {:ok, access} <- access(source) do
      started_at = SystemsClock.monotonic_time()
      result = list_page(access, source, page_size, sync_token, page_token)

      Salix.Telemetry.emit_operation(
        "salix_calendar",
        "source_sync",
        "system",
        telemetry_outcome(result),
        SystemsClock.monotonic_time() - started_at
      )

      result
    else
      false -> {:error, :lark_calendar_query_contract_mismatch}
      {:error, _} = error -> error
    end
  end

  # Lark refuses a sync_token beside anchor_time: the anchor bounds only the
  # first read, and a sync_token continues from where it ended.
  defp list_page(access, source, page_size, sync_token, page_token) do
    query =
      %{"page_size" => Integer.to_string(page_size), "user_id_type" => "open_id"}
      |> put_optional("page_token", present_or_nil(page_token))
      |> put_optional("sync_token", present_or_nil(sync_token))
      |> then(fn query ->
        if nonblank?(sync_token) or nonblank?(page_token),
          do: query,
          else:
            Map.put(
              query,
              "anchor_time",
              Integer.to_string(SystemsClock.system_time(:second) - @history_window_seconds)
            )
      end)

    requested_at = request_stamp(source)

    with {:ok, data} <- get(access, events_path(access), query),
         {:ok, events} <- event_items(data),
         {:ok, changes} <- normalize_all(events, source, requested_at),
         {:ok, page} <- page_tokens(data, sync_token) do
      {:ok, Map.put(page, "changes", changes)}
    end
  end

  defp page_tokens(data, previous_sync_token) do
    page_token = present_or_nil(data["page_token"])
    sync_token = present_or_nil(data["sync_token"])

    cond do
      data["has_more"] == true and is_binary(page_token) ->
        {:ok,
         %{
           "next_continuation" =>
             encode_continuation(%{
               "page_token" => page_token,
               "sync_token" => previous_sync_token
             }),
           "completed_cursor" => nil
         }}

      is_binary(sync_token) ->
        {:ok, %{"next_continuation" => nil, "completed_cursor" => sync_token}}

      true ->
        {:error, :lark_sync_token_missing}
    end
  end

  defp normalize_all(events, source, requested_at) do
    default_time_zone = default_time_zone(source)

    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, records} ->
      case normalize(event, default_time_zone: default_time_zone, requested_at: requested_at) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, {trim(event["event_id"]), reason}}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp event_items(data) do
    case data["items"] || [] do
      items when is_list(items) ->
        if Enum.all?(items, &is_map/1),
          do: {:ok, items},
          else: {:error, :invalid_lark_calendar_response}

      _ ->
        {:error, :invalid_lark_calendar_response}
    end
  end

  # ---------------------------------------------------------------------------
  # normalization

  defp tombstone(event) do
    %{
      "external_locator" => %{"event_id" => trim(event["event_id"])},
      "tombstone" => true,
      "source_version" => source_version(event)
    }
  end

  defp normalize_master(event, default_time_zone, requested_at) do
    event_id = trim(event["event_id"])

    with {:ok, timing} <- timing(event, default_time_zone) do
      {rules, state} =
        case recurrence(event["recurrence"], timing) do
          {:ok, rules} -> {rules, "complete"}
          {:error, :unsupported_lark_recurrence} -> {[], "unsupported_timing"}
        end

      meeting_url = lark_meeting_url(event)

      object =
        %{
          "@type" => "Event",
          "uid" => event_id,
          "title" => present_or_nil(event["summary"]) || "Calendar event",
          "description" => event["description"],
          "start" => timing.start,
          "duration" => timing.duration,
          "timeZone" => timing.time_zone,
          "showWithoutTime" => timing.all_day,
          "status" => "confirmed",
          "freeBusyStatus" => if(event["free_busy_status"] == "free", do: "free", else: "busy"),
          "recurrenceRules" => rules,
          "virtualLocations" => virtual_locations(meeting_url),
          "links" => event_links(event["app_link"]),
          "participants" => organizer(event)
        }
        |> compact()

      item_eligible? = state == "complete" and not timing.all_day

      item_reason =
        cond do
          state != "complete" -> "unsupported_timing"
          timing.all_day -> "all_day_event"
          true -> "eligible"
        end

      {:ok,
       %{
         "external_locator" => %{"event_id" => event_id},
         "copy_role" => "unknown",
         "object" => object,
         "scheduling_identity" => scheduling_identity(event),
         # Lark gives an event no update time, sequence or etag. Copies of
         # one meeting on several calendars are the same Lark event, ordered
         # by when their read was sent (`request_stamp/1`), not by when its
         # answer arrived.
         "scheduling_revision" => %{
           "timestamp" => requested_at,
           "shared_fact_hash" => shared_fact_hash(object)
         },
         "source_version" => source_version(event),
         "present_fields" => event |> Map.keys() |> Enum.sort(),
         "participant_set_state" => "not_requested",
         "attachment_set_state" => "not_requested",
         "normalization_state" => state,
         "source_fresh_at" => div(requested_at, 1_000_000),
         "meeting_qualification" => %{
           "item_eligible" => item_eligible?,
           "item_reason" => item_reason,
           "authorized" => item_eligible? and is_binary(meeting_url),
           "reason" => if(item_eligible?, do: conference_reason(meeting_url), else: item_reason)
         }
       }
       |> compact()}
    end
  end

  # An exception changes one occurrence of the series named by
  # `recurring_event_id`; its key is the original start in the master's zone.
  defp normalize_exception(event, original_time, default_time_zone) do
    master_id = trim(event["recurring_event_id"])
    time_zone = present_or_nil(get_in(event, ["start_time", "timezone"])) || default_time_zone

    with true <- master_id != "",
         {:ok, key} <- original_key(event, original_time, time_zone),
         {:ok, override} <- override_value(event, default_time_zone) do
      {:ok,
       %{
         "external_locator" => %{"event_id" => master_id},
         "object_patch" => %{"recurrenceOverrides" => %{key => override}},
         "source_version_patch" => %{"recurrence_instances" => %{key => trim(event["event_id"])}}
       }}
    else
      false -> {:error, :invalid_lark_exception}
      {:error, _} = error -> error
    end
  end

  defp original_key(event, original_time, time_zone) do
    if get_in(event, ["start_time", "date"]) |> nonblank?() and
         not nonblank?(get_in(event, ["start_time", "timestamp"])) do
      # An all-day series names its original day at midnight UTC.
      with {:ok, datetime} <- DateTime.from_unix(original_time),
           do: {:ok, (datetime |> DateTime.to_date() |> Date.to_iso8601()) <> "T00:00:00"}
    else
      with {:ok, datetime} <- DateTime.from_unix(original_time),
           {:ok, local} <- DateTime.shift_zone(datetime, time_zone) do
        {:ok, local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()}
      else
        _ -> {:error, :invalid_lark_event_time}
      end
    end
  end

  defp override_value(event, default_time_zone) do
    if cancelled?(event) do
      {:ok, %{"excluded" => true}}
    else
      with {:ok, timing} <- timing(event, default_time_zone) do
        start = if timing.all_day, do: timing.start <> "T00:00:00", else: timing.start

        {:ok,
         %{
           "start" => start,
           "duration" => timing.duration,
           "virtualLocations" => virtual_locations(lark_meeting_url(event))
         }
         |> put_optional("title", present_or_nil(event["summary"]))}
      end
    end
  end

  defp timing(event, default_time_zone) do
    with {:ok, start} <- temporal(event["start_time"], default_time_zone),
         {:ok, ending} <- temporal(event["end_time"], default_time_zone),
         true <- start.all_day == ending.all_day and ending.ms > start.ms,
         {:ok, duration} <- duration(start, ending) do
      {:ok,
       %{
         start: start.value,
         time_zone: start.time_zone,
         start_ms: start.ms,
         end_ms: ending.ms,
         all_day: start.all_day,
         duration: duration
       }}
    else
      false -> {:error, :invalid_lark_event_time}
      {:error, _} = error -> error
    end
  end

  defp temporal(%{"timestamp" => timestamp} = value, default_time_zone)
       when is_binary(timestamp) and timestamp != "" do
    time_zone = present_or_nil(value["timezone"]) || default_time_zone

    with {seconds, ""} <- Integer.parse(timestamp),
         {:ok, datetime} <- DateTime.from_unix(seconds),
         {:ok, local} <- DateTime.shift_zone(datetime, time_zone) do
      {:ok,
       %{
         value: local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601(),
         time_zone: time_zone,
         ms: seconds * 1_000,
         all_day: false
       }}
    else
      _ -> {:error, :invalid_lark_event_time}
    end
  end

  defp temporal(%{"date" => date} = value, default_time_zone)
       when is_binary(date) and date != "" do
    time_zone = present_or_nil(value["timezone"]) || default_time_zone

    with {:ok, day} <- Date.from_iso8601(date),
         {:ok, datetime} <- DateTime.new(day, ~T[00:00:00], time_zone) do
      {:ok,
       %{
         value: date,
         time_zone: time_zone,
         ms: DateTime.to_unix(datetime, :millisecond),
         all_day: true
       }}
    else
      _ -> {:error, :invalid_lark_event_time}
    end
  end

  defp temporal(_value, _default_time_zone), do: {:error, :invalid_lark_event_time}

  defp duration(%{all_day: true, value: start_value}, %{all_day: true, value: end_value}) do
    with {:ok, start_date} <- Date.from_iso8601(start_value),
         {:ok, end_date} <- Date.from_iso8601(end_value),
         days when days > 0 <- Date.diff(end_date, start_date) do
      {:ok, "P#{days}D"}
    else
      _ -> {:error, :invalid_lark_event_time}
    end
  end

  defp duration(%{all_day: false, ms: start_ms}, %{all_day: false, ms: end_ms}) do
    seconds = div(end_ms - start_ms, 1_000)
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    rest = rem(seconds, 60)

    {:ok,
     "PT" <>
       if(hours > 0, do: "#{hours}H", else: "") <>
       if(minutes > 0, do: "#{minutes}M", else: "") <>
       if(rest > 0, do: "#{rest}S", else: "")}
  end

  # Lark writes the RRULE body without its `RRULE:` prefix. The calendar
  # domain generates DAILY and WEEKLY series (`SalixCalendar.Recurrence`);
  # anything else is stored without rules and never qualifies.
  defp recurrence(value, _timing) when value in [nil, ""], do: {:ok, []}

  defp recurrence(value, timing) when is_binary(value) do
    parts =
      value
      |> String.replace_prefix("RRULE:", "")
      |> String.split(";", trim: true)
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, rule] -> {String.upcase(key), rule}
          [key] -> {String.upcase(key), ""}
        end
      end)

    with true <- Map.keys(parts) -- @rrule_keys == [],
         frequency when frequency in ["DAILY", "WEEKLY"] <- parts["FREQ"],
         {:ok, interval} <- positive_integer(parts["INTERVAL"] || "1"),
         {:ok, first_day} <- week_start(parts["WKST"], frequency),
         {:ok, by_day} <- by_day(parts["BYDAY"]),
         {:ok, until} <- until(parts["UNTIL"], timing) do
      {:ok,
       [
         %{
           "@type" => "RecurrenceRule",
           "frequency" => String.downcase(frequency),
           "interval" => interval
         }
         |> put_optional("byDay", if(by_day == [], do: nil, else: by_day))
         |> put_optional("firstDayOfWeek", first_day)
         |> put_optional("until", until)
       ]}
    else
      _ -> {:error, :unsupported_lark_recurrence}
    end
  end

  defp recurrence(_value, _timing), do: {:error, :unsupported_lark_recurrence}

  # UNTIL is the last start the series may have, inclusive: an RFC 5545 UTC
  # date-time, a floating date-time or a date. The calendar domain compares
  # it as a local date-time in the series' zone.
  defp until(nil, _timing), do: {:ok, nil}

  defp until(value, timing) do
    cond do
      Regex.match?(~r/^\d{8}T\d{6}Z$/, value) ->
        with {:ok, naive} <- basic_naive(value),
             {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC"),
             {:ok, local} <- DateTime.shift_zone(utc, timing.time_zone) do
          {:ok, local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()}
        else
          _ -> {:error, :unsupported_lark_recurrence}
        end

      Regex.match?(~r/^\d{8}T\d{6}$/, value) ->
        with {:ok, naive} <- basic_naive(value), do: {:ok, NaiveDateTime.to_iso8601(naive)}

      Regex.match?(~r/^\d{8}$/, value) ->
        with {:ok, naive} <- basic_naive(value <> "T235959"),
             do: {:ok, NaiveDateTime.to_iso8601(naive)}

      true ->
        {:error, :unsupported_lark_recurrence}
    end
  end

  defp basic_naive(
         <<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           _rest::binary>>
       ) do
    case NaiveDateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:#{mi}:#{s}") do
      {:ok, naive} -> {:ok, naive}
      _ -> {:error, :unsupported_lark_recurrence}
    end
  end

  defp week_start(nil, _frequency), do: {:ok, nil}

  defp week_start(day, "WEEKLY") when day in ~w(MO TU WE TH FR SA SU),
    do: {:ok, String.downcase(day)}

  defp week_start(_day, _frequency), do: {:error, :unsupported_lark_recurrence}

  defp by_day(nil), do: {:ok, []}

  defp by_day(value) do
    tokens = String.split(value, ",", trim: true)

    if tokens != [] and Enum.all?(tokens, &(&1 in ~w(MO TU WE TH FR SA SU))),
      do: {:ok, Enum.map(tokens, &%{"@type" => "NDay", "day" => String.downcase(&1)})},
      else: {:error, :unsupported_lark_recurrence}
  end

  defp positive_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :unsupported_lark_recurrence}
    end
  end

  defp identity_current(event, item, occurrence, default_time_zone) do
    expected_start = occurrence["start_ms"]
    expected_end = occurrence["end_ms"]
    exception? = match?({:ok, _uid, time} when time > 0, parse_event_id(event["event_id"]))

    cond do
      exception? ->
        case timing(event, default_time_zone) do
          {:ok, %{start_ms: ^expected_start, end_ms: ^expected_end}} -> :ok
          _ -> {:error, :calendar_event_changed}
        end

      get_in(item, ["object", "recurrenceRules"]) in [nil, []] ->
        case timing(event, default_time_zone) do
          {:ok, %{start_ms: ^expected_start, end_ms: ^expected_end}} -> :ok
          _ -> {:error, :calendar_event_changed}
        end

      # An occurrence of a series has the times of its own day; the master
      # still names the same meeting.
      true ->
        if lark_meeting_url(event) ==
             get_in(item, ["object", "virtualLocations", "conference", "uri"]),
           do: :ok,
           else: {:error, :calendar_event_changed}
    end
  end

  defp attendees(_access, _event_id, _page_token, 0, _acc),
    do: {:error, :meeting_attendees_unavailable}

  defp attendees(access, event_id, page_token, pages_left, acc) do
    query =
      %{"user_id_type" => "open_id", "page_size" => Integer.to_string(@attendee_page_size)}
      |> put_optional("page_token", page_token)

    with {:ok, data} <-
           get(access, events_path(access) <> "/" <> segment(event_id) <> "/attendees", query) do
      items = acc ++ Enum.filter(List.wrap(data["items"]), &is_map/1)

      case {data["has_more"], present_or_nil(data["page_token"])} do
        {true, token} when is_binary(token) ->
          attendees(access, event_id, token, pages_left - 1, items)

        _ ->
          {:ok, items}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # access

  @doc false
  def access(source) do
    group_id = trim(source["group_id"])
    locator = source["source_locator"] || %{}
    connect_id = trim(locator["connect_id"])
    account = trim(locator["account"])
    calendar_id = trim(locator["external_calendar_id"])

    with {:ok, provider} <- Map.fetch(@adapters, source["adapter"]),
         true <- group_id != "" and connect_id != "" and account != "" and calendar_id != "",
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, provider),
         {:ok, client} <- identity(provider, connect, account) do
      {:ok, %{provider: provider, client: client, calendar_id: calendar_id, account: account}}
    else
      :error -> {:error, :invalid_lark_calendar_source}
      false -> {:error, :invalid_lark_calendar_source}
      {:error, :not_found} -> {:error, :lark_calendar_connect_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "The connect acting as the app, or as the person `account` names."
  def identity(_provider, connect, @app), do: {:ok, connect}

  def identity(provider, connect, alias_name) do
    with {:ok, group} <- Groups.get(connect["group_id"]),
         agent_id when is_binary(agent_id) and agent_id != "" <- group["router_agent_id"],
         {:ok, token} <- user_token(provider, agent_id, alias_name) do
      {:ok, api(provider).as_user(connect, token)}
    else
      {:error, _} -> {:error, :lark_calendar_account_unavailable}
      _ -> {:error, :lark_calendar_account_unavailable}
    end
  end

  defp user_token("lark", agent_id, alias_name),
    do: LarkUserAccounts.access_token(agent_id, alias_name)

  defp user_token("feishu", agent_id, alias_name),
    do: FeishuUserAccounts.access_token(agent_id, alias_name)

  @doc false
  def api("lark"), do: LarkAPI
  def api("feishu"), do: FeishuAPI

  defp get(access, path, query) do
    case api(access.provider).get(access.client, path, query) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _other} ->
        {:error, :invalid_lark_calendar_response}

      {:error, reason} when is_binary(reason) ->
        if String.contains?(reason, Integer.to_string(@sync_token_expired)),
          do: {:error, :cursor_expired},
          else: {:error, {:lark_calendar, reason}}

      {:error, reason} ->
        {:error, {:lark_calendar, reason}}
    end
  end

  defp events_path(access),
    do: "/calendar/v4/calendars/" <> segment(access.calendar_id) <> "/events"

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # ---------------------------------------------------------------------------
  # helpers

  @doc false
  def parse_event_id(event_id) when is_binary(event_id) do
    case Regex.run(~r/^(.+)_(\d+)$/, String.trim(event_id)) do
      [_whole, uid, original] -> {:ok, uid, String.to_integer(original)}
      nil -> :error
    end
  end

  def parse_event_id(_event_id), do: :error

  defp recurring?(event),
    do: nonblank?(event["recurrence"]) or nonblank?(event["recurring_event_id"])

  defp series_id(event) do
    case present_or_nil(event["recurring_event_id"]) do
      nil ->
        case parse_event_id(event["event_id"]) do
          {:ok, uid, _time} -> uid <> "_0"
          :error -> trim(event["event_id"])
        end

      master ->
        master
    end
  end

  defp start_iso8601(event) do
    with timestamp when is_binary(timestamp) <- get_in(event, ["start_time", "timestamp"]),
         {seconds, ""} <- Integer.parse(timestamp),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      DateTime.to_iso8601(datetime)
    else
      _ -> get_in(event, ["start_time", "date"])
    end
  end

  defp lark_meeting_url(event) do
    case SalixCalendar.OccurrenceQualification.canonical_meeting_url(
           get_in(event, ["vchat", "meeting_url"])
         ) do
      {:google_meet, _url} -> nil
      {_provider, url} -> url
      nil -> nil
    end
  end

  defp conference_reason(meeting_url) do
    case SalixCalendar.OccurrenceQualification.canonical_meeting_url(meeting_url) do
      {:lark, _url} -> "lark_meeting"
      {:zoom, _url} -> "zoom_meeting"
      {:teams, _url} -> "teams_meeting"
      _ -> "no_supported_conference"
    end
  end

  defp virtual_locations(nil), do: nil

  defp virtual_locations(uri),
    do: %{"conference" => %{"@type" => "VirtualLocation", "uri" => uri}}

  @app_link_hosts ~w(applink.feishu.cn applink.larksuite.com applink.larkoffice.com)

  defp event_links(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri when is_binary(host) ->
        if String.downcase(host) in @app_link_hosts,
          do: %{
            "event" => %{"@type" => "Link", "href" => URI.to_string(uri), "rel" => "alternate"}
          }

      _ ->
        nil
    end
  end

  defp event_links(_url), do: nil

  defp organizer(event) do
    case get_in(event, ["event_organizer", "user_id"]) do
      "ou_" <> _ = open_id ->
        %{
          "organizer" =>
            %{"@type" => "Participant", "roles" => %{"owner" => true}, "lark_open_id" => open_id}
            |> put_optional(
              "name",
              present_or_nil(get_in(event, ["event_organizer", "display_name"]))
            )
        }

      _ ->
        nil
    end
  end

  # The same meeting has the same uid in every calendar it is on, so copies
  # on several members' calendars link to one meeting. The organizer's
  # open_id is the authority, as an organizer's email is on Google.
  defp scheduling_identity(event) do
    with {:ok, uid, 0} <- parse_event_id(event["event_id"]),
         "ou_" <> _ = organizer <- get_in(event, ["event_organizer", "user_id"]) do
      %{
        "identity_version" => "lark_event_uid.v1",
        "namespace" => "lark_event_uid",
        "series_uid" => uid,
        "scheduling_authority_key" => organizer
      }
    else
      _ -> nil
    end
  end

  defp source_version(event),
    do: compact(%{"event_id" => trim(event["event_id"]), "create_time" => event["create_time"]})

  defp shared_fact_hash(object) do
    object
    |> Map.take(
      ~w(@type uid title description start duration timeZone showWithoutTime status recurrenceRules recurrenceOverrides virtualLocations)
    )
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  # The microsecond a read was sent, times 1000, plus a fixed number of the
  # source: reads of two calendars sent in the same microsecond still order,
  # so one meeting's copies never tie and stop its calendar's scan.
  @doc false
  def request_stamp(source) do
    SystemsClock.system_time(:microsecond) * 1_000 +
      :erlang.phash2(source["source_id"] || "", 1_000)
  end

  defp cancelled?(event), do: String.downcase(trim(event["status"])) == "cancelled"

  defp telemetry_outcome({:ok, _}), do: "ok"
  defp telemetry_outcome({:error, :cursor_expired}), do: "conflict"
  defp telemetry_outcome(_result), do: "error"

  defp encode_continuation(value),
    do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode_continuation(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{} = continuation} <- Jason.decode(decoded),
         true <- nonblank?(continuation["page_token"]) do
      {:ok, continuation}
    else
      _ -> {:error, :invalid_lark_calendar_continuation}
    end
  end

  defp default_time_zone(source),
    do: get_in(source, ["sync_policy", "default_time_zone"]) |> present_or_nil() || "UTC"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp present_or_nil(value), do: if(nonblank?(value), do: trim(value), else: nil)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp trim(value), do: String.trim(to_string(value || ""))
  defp compact(map), do: Map.reject(map, fn {_key, value} -> value in [nil, "", %{}, []] end)
end
