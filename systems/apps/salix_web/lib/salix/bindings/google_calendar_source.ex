defmodule Salix.Bindings.GoogleCalendarSource do
  @moduledoc "Read-only Google Calendar source adapter over Composio."

  @behaviour SalixCalendar.SourceAdapter

  alias Salix.Bindings.GoogleCalendarError
  alias Salix.Control.ComposioSettings
  alias SalixCalendar.Recurrence
  alias SalixStore.{Composio, Crypto, JSON}

  @max_page_size 200
  # `events/<master>/instances?originalStart=` pages the whole series first and
  # filters second, so a long series answers the leading pages with `items: []`
  # plus a `nextPageToken`; the instance we asked for sits on a later page.
  # Ask for Google's largest page and follow the token a bounded number of
  # times before giving up.
  @instances_page_size 250
  @instances_max_pages 20
  # A timeMin/timeMax window is applied before paging, so the instance we ask
  # for lands on the first page however long the series is. The window keys on
  # the instance's actual start, so a lookup that comes back empty falls back
  # to the unwindowed listing (moved or cancelled instances).
  @instances_window_seconds 24 * 60 * 60
  @watch_ttl_seconds 7 * 24 * 60 * 60
  @google_calendar_api "https://www.googleapis.com/calendar/v3"

  @impl true
  def adapter_contract_id, do: "google_calendar.events.v3"

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
  def start_sync(source, query_contract, completed_cursor) do
    read_page(source, query_contract, completed_cursor, nil, nil)
  end

  @impl true
  def continue_sync(source, query_contract, continuation) when is_binary(continuation) do
    with {:ok, %{"page_token" => page_token, "sync_token" => sync_token} = decoded} <-
           decode_continuation(continuation) do
      read_page(
        source,
        query_contract,
        sync_token,
        page_token,
        present_or_nil(decoded["proxy_session_id"])
      )
    end
  end

  @impl true
  def exact_refresh(source, item, occurrence) do
    source = JSON.stringify(source)

    with {:ok, event} <- read_occurrence(source, item, occurrence),
         {:ok, normalized} <-
           normalize(event,
             default_time_zone: default_time_zone(source),
             access_profile: source["access_profile"]
           ) do
      {:ok, normalized}
    end
  end

  @doc "Read the exact provider instance using the enrolled source's pinned account."
  def read_occurrence(source, item, occurrence) do
    with {:ok, _access, event} <- source_occurrence(source, item, occurrence), do: {:ok, event}
  end

  @doc "One read-only page of upcoming meetings for the team's calendar selector."
  def upcoming_meetings(source, page_token \\ nil) do
    now = DateTime.utc_now()

    parameters =
      [
        proxy_query("singleEvents", true),
        proxy_query("showDeleted", false),
        proxy_query("maxResults", 50),
        proxy_query("orderBy", "startTime"),
        proxy_query("timeMin", DateTime.to_iso8601(now)),
        proxy_query("timeMax", now |> DateTime.add(14, :day) |> DateTime.to_iso8601())
      ]
      |> append_proxy_query("pageToken", page_token)

    with {:ok, access} <- source_access(source),
         {:ok, data, session_id} <- execute_list(access, parameters, nil, false) do
      cleanup_proxy_session(access, session_id)

      meetings =
        (data["items"] || [])
        |> Enum.filter(
          &(SalixCalendar.OccurrenceQualification.google_meet_url?(meet_url(&1)) and
              &1["status"] != "cancelled")
        )
        |> Enum.map(fn event ->
          %{
            "event_id" => event["recurringEventId"] || event["id"],
            "title" => event["summary"] || "Calendar meeting",
            "recurring" => is_binary(event["recurringEventId"]),
            "start" => get_in(event, ["start", "dateTime"])
          }
        end)
        |> Enum.uniq_by(& &1["event_id"])

      {:ok, %{"meetings" => meetings, "next_cursor" => data["nextPageToken"]}}
    end
  end

  defp source_occurrence(source, item, occurrence) do
    source = JSON.stringify(source)
    item = JSON.stringify(item)
    occurrence = JSON.stringify(occurrence)
    key = get_in(occurrence, ["occurrence_ref", "recurrence_key", "value"])
    master_id = get_in(item, ["origin", "external_locator", "event_id"])

    instance_id =
      get_in(item, ["source_version", "recurrence_instances", key]) |> present_or_nil()

    with true <- nonblank?(master_id),
         {:ok, access} <- source_access(source),
         {:ok, event} <-
           exact_event(access, master_id, instance_id, occurrence, default_time_zone(source)) do
      {:ok, access, event}
    else
      false -> {:error, :calendar_event_source_mismatch}
      {:error, _} = error -> error
    end
  end

  @doc "Return current attendees only while the exact meeting still has the expected title, link and times."
  def read_attendees(source, item, occurrence) do
    expected_start = occurrence["start_ms"]
    expected_end = occurrence["end_ms"]

    with {:ok, event} <- read_occurrence(source, item, occurrence),
         false <- cancelled?(event),
         :ok <- preparation_identity_current(event, item, occurrence),
         {:ok, %{start_ms: ^expected_start, end_ms: ^expected_end}} <-
           timing(event, default_time_zone(source)) do
      if event["attendeesOmitted"] == true,
        do: {:error, :meeting_attendees_unavailable},
        else: {:ok, event["attendees"] || []}
    else
      true -> {:error, :calendar_event_cancelled}
      {:error, _} = error -> error
      _ -> {:error, :calendar_event_changed}
    end
  end

  @doc """
  Update only Comma's preparation block on the organizer's exact occurrence.
  Google owns the ETag precondition: a concurrent edit returns a conflict and
  must be re-read before a new attempt. A lost response is never blindly retried.
  """
  def write_preparation(source, item, occurrence, report) do
    source = JSON.stringify(source)

    with {:ok, access, event} <- source_occurrence(source, item, occurrence),
         :ok <- preparation_write_eligible(event, item, occurrence, default_time_zone(source)),
         {:ok, description} <- SalixMeet.CalendarPreparation.merge(event["description"], report) do
      if description == (event["description"] || "") do
        {:ok, %{"status" => "unchanged"}}
      else
        with {:ok, session_id} <- ensure_proxy_session(access, nil) do
          request = %{
            "toolkit_slug" => "googlecalendar",
            "endpoint" =>
              "https://www.googleapis.com/calendar/v3/calendars/" <>
                encode_path_segment(access.calendar_id) <>
                "/events/" <>
                encode_path_segment(event["id"]),
            "method" => "PATCH",
            "parameters" => [
              %{"name" => "If-Match", "value" => event["etag"], "type" => "header"},
              proxy_query("sendUpdates", "none")
            ],
            "body" => %{"description" => description}
          }

          result = preparation_write_result(proxy_execute(access, session_id, request))
          cleanup_proxy_session(access, session_id)
          result
        end
      end
    end
  end

  defp preparation_write_eligible(event, item, occurrence, zone) do
    expected_start = occurrence["start_ms"]
    expected_end = occurrence["end_ms"]

    expected_description =
      SalixMeet.CalendarPreparation.human_description(get_in(item, ["object", "description"]))

    live_description = SalixMeet.CalendarPreparation.human_description(event["description"])

    cond do
      cancelled?(event) ->
        {:error, :calendar_event_cancelled}

      get_in(event, ["organizer", "self"]) != true ->
        {:error, :calendar_organizer_access_required}

      preparation_identity_current(event, item, occurrence) != :ok or
          live_description != expected_description ->
        {:error, :calendar_event_changed}

      not nonblank?(event["etag"]) ->
        {:error, :calendar_event_version_unavailable}

      true ->
        case timing(event, zone) do
          {:ok, %{start_ms: start_ms, end_ms: end_ms}}
          when start_ms == expected_start and end_ms == expected_end ->
            :ok

          _ ->
            {:error, :calendar_event_changed}
        end
    end
  end

  defp preparation_identity_current(event, item, occurrence) do
    expected_url = get_in(occurrence, ["effective", "virtualLocations", "conference", "uri"])
    expected_title = get_in(item, ["object", "title"])

    if (event["summary"] || "Calendar event") == expected_title and
         meet_url(event) == expected_url,
       do: :ok,
       else: {:error, :calendar_event_changed}
  end

  defp preparation_write_result({:ok, %{"status" => 200}}),
    do: {:ok, %{"status" => "written"}}

  defp preparation_write_result({:ok, %{"status" => 412}}),
    do: {:error, :calendar_event_changed}

  defp preparation_write_result({:ok, %{"status" => status}}) when status in [401, 403],
    do: {:error, :calendar_write_permission_required}

  defp preparation_write_result({:ok, %{"status" => 404}}),
    do: {:error, :calendar_event_not_found}

  defp preparation_write_result(_result),
    do: {:error, :calendar_preparation_write_unknown}

  def start_watch(source, callback_url, channel_id, channel_token) do
    source = JSON.stringify(source)

    with true <- valid_watch_input?(callback_url, channel_id, channel_token),
         {:ok, access} <- source_access(source),
         {:ok, response} <-
           execute_map(access, "GOOGLECALENDAR_EVENTS_WATCH", %{
             "calendarId" => access.calendar_id,
             "id" => channel_id,
             "type" => "web_hook",
             "address" => callback_url,
             "token" => channel_token,
             "params" => %{"ttl" => Integer.to_string(@watch_ttl_seconds)}
           }),
         {:ok, watch} <- watch_response(response, channel_id) do
      {:ok, watch}
    else
      false -> {:error, :invalid_google_calendar_watch}
      {:error, _} = error -> error
    end
  end

  def stop_watch(
        source,
        %{"channel_id" => channel_id, "resource_id" => resource_id}
      )
      when is_binary(channel_id) and channel_id != "" and is_binary(resource_id) and
             resource_id != "" do
    source = JSON.stringify(source)

    with {:ok, access} <- source_access(source),
         {:ok, session_id} <- ensure_proxy_session(access, nil) do
      request = %{
        "toolkit_slug" => "googlecalendar",
        "endpoint" => @google_calendar_api <> "/channels/stop",
        "method" => "POST",
        "body" => %{"id" => channel_id, "resourceId" => resource_id}
      }

      result =
        case proxy_execute(access, session_id, request) do
          {:ok, %{"status" => status}} when status in 200..299 -> :ok
          {:ok, %{"status" => 404}} -> :ok
          {:ok, %{"status" => status}} when is_integer(status) -> provider_http_error(status, nil)
          {:error, :not_found} -> :ok
          {:error, _} = error -> error
          _ -> {:error, :invalid_google_calendar_response}
        end

      cleanup_proxy_session(access, session_id)
      result
    end
  end

  def stop_watch(_source, _watch), do: {:error, :invalid_google_calendar_watch}

  @impl true
  def normalize(event, opts \\ [])

  def normalize(event, opts) when is_map(event) do
    event = JSON.stringify(event)
    event_id = trim(event["id"])
    recurring_event_id = trim(event["recurringEventId"])
    default_time_zone = Keyword.get(opts, :default_time_zone, "UTC")
    access_profile = Keyword.get(opts, :access_profile, "events_read")

    cond do
      event_id == "" ->
        {:error, :invalid_google_event}

      recurring_event_id != "" ->
        normalize_override(event, recurring_event_id, event_id, default_time_zone)

      cancelled?(event) ->
        {:ok,
         %{
           "external_locator" => %{"event_id" => event_id},
           "tombstone" => true,
           "source_version" => source_version(event),
           "source_revision" => source_revision(event)
         }}

      true ->
        normalize_master(event, event_id, default_time_zone, access_profile)
    end
  end

  def normalize(_event, _opts), do: {:error, :invalid_google_event}

  defp read_page(source, query_contract, sync_token, page_token, proxy_session_id) do
    source = JSON.stringify(source)
    query_contract = JSON.stringify(query_contract)
    page_size = query_contract["page_size"] || 100

    with true <- page_size in 1..@max_page_size,
         true <- query_contract["object_type"] in [nil, "Event"],
         true <- query_contract["group_id"] == source["group_id"],
         {:ok, access} <- source_access(source),
         parameters <- list_parameters(page_size, sync_token, page_token) do
      read_proxy_page(source, access, parameters, sync_token, proxy_session_id)
    else
      false -> {:error, :google_calendar_query_contract_mismatch}
      {:error, _} = error -> error
    end
  end

  defp read_proxy_page(source, access, parameters, sync_token, proxy_session_id) do
    started_at = System.monotonic_time()

    result =
      with {:ok, data, active_session_id} <-
             execute_list(access, parameters, proxy_session_id, true) do
        page_result =
          with {:ok, events} <- event_items(data),
               {:ok, changes} <- normalize_all(events, source),
               {:ok, page} <- page_tokens(data, sync_token, active_session_id) do
            {:ok, Map.put(page, "changes", changes)}
          end

        finalize_proxy_page(access, active_session_id, page_result)
      end

    Salix.Telemetry.emit_operation(
      "salix_calendar",
      "source_sync",
      "system",
      telemetry_outcome(result),
      System.monotonic_time() - started_at
    )

    result
  end

  defp source_access(source) do
    group_id = trim(source["group_id"])
    tenant_id = trim(SalixStore.Ids.tenant_id_from_group!(group_id))
    account_id = trim(get_in(source, ["source_locator", "connection_id"]))
    calendar_id = trim(get_in(source, ["source_locator", "external_calendar_id"]))

    with true <- group_id != "" and account_id != "" and calendar_id != "",
         {:ok, settings} <- ComposioSettings.get(tenant_id),
         :ok <- authorize_account(settings, account_id, group_id) do
      {:ok,
       %{
         settings: settings,
         group_id: group_id,
         account_id: account_id,
         calendar_id: calendar_id
       }}
    else
      false -> {:error, :invalid_google_calendar_source}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_google_calendar_source}
  end

  defp valid_watch_input?(callback_url, channel_id, channel_token) do
    match?(
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host),
      URI.parse(callback_url)
    ) and
      byte_size(channel_id) in 1..64 and byte_size(channel_token) in 1..256
  end

  defp watch_response(
         %{"id" => channel_id} = data,
         channel_id
       ) do
    with resource_id when is_binary(resource_id) and resource_id != "" <- data["resourceId"],
         {expiration, ""} <- Integer.parse(to_string(data["expiration"])),
         true <- expiration > 0 do
      {:ok,
       %{
         "channel_id" => channel_id,
         "resource_id" => resource_id,
         "expiration" => expiration
       }}
    else
      _ -> {:error, :invalid_google_calendar_watch_response}
    end
  end

  defp watch_response(_response, _channel_id),
    do: {:error, :invalid_google_calendar_watch_response}

  defp authorize_account(settings, account_id, group_id) do
    case Composio.get_connected_account(settings, account_id, error_mode: :structured)
         |> normalize_composio_error() do
      {:ok, account} ->
        toolkit = get_in(account, ["toolkit", "slug"]) || account["toolkit"]

        if trim(account["id"]) == account_id and trim(account["user_id"]) == group_id and
             account["status"] == Composio.active_status() and
             String.downcase(trim(toolkit)) == "googlecalendar",
           do: :ok,
           else: {:error, :calendar_connected_account_not_found}

      {:error, :not_found} ->
        {:error, :calendar_connected_account_not_found}

      {:error, _} = error ->
        error
    end
  end

  defp list_parameters(page_size, sync_token, page_token) do
    [
      proxy_query("singleEvents", false),
      proxy_query("showDeleted", true),
      proxy_query("maxResults", page_size)
    ]
    |> append_proxy_query("pageToken", page_token)
    |> append_proxy_query("syncToken", sync_token)
  end

  defp execute_list(access, parameters, session_id, retry_session?) do
    with {:ok, active_session_id} <- ensure_proxy_session(access, session_id) do
      request = %{
        "toolkit_slug" => "googlecalendar",
        "endpoint" =>
          @google_calendar_api <>
            "/calendars/" <>
            URI.encode(access.calendar_id, &URI.char_unreserved?/1) <> "/events",
        "method" => "GET",
        "parameters" => parameters
      }

      case proxy_execute(access, active_session_id, request) do
        {:ok, %{"status" => 200, "data" => data}} when is_map(data) ->
          {:ok, data, active_session_id}

        {:ok, %{"status" => status} = response} when is_integer(status) ->
          cleanup_proxy_session(access, active_session_id)
          provider_http_error(status, response["data"])

        {:error, :not_found} when retry_session? ->
          cleanup_proxy_session(access, active_session_id)
          execute_list(access, parameters, nil, false)

        {:error, _} = error ->
          cleanup_proxy_session(access, active_session_id)
          error

        _other ->
          cleanup_proxy_session(access, active_session_id)
          {:error, :invalid_google_calendar_response}
      end
    end
  end

  defp ensure_proxy_session(_access, session_id) when is_binary(session_id) and session_id != "",
    do: {:ok, session_id}

  defp ensure_proxy_session(access, _session_id) do
    access.settings
    |> Composio.create_proxy_session(
      access.group_id,
      access.account_id,
      "googlecalendar",
      error_mode: :structured
    )
    |> normalize_composio_error()
  end

  defp finalize_proxy_page(
         _access,
         _session_id,
         {:ok, %{"next_continuation" => continuation}} = result
       )
       when is_binary(continuation),
       do: result

  defp finalize_proxy_page(access, session_id, result) do
    cleanup_proxy_session(access, session_id)
    result
  end

  defp cleanup_proxy_session(access, session_id) do
    _ = Composio.delete_proxy_session(access.settings, session_id)
    :ok
  end

  defp provider_http_error(410, _data), do: {:error, :cursor_expired}

  defp provider_http_error(status, data) when status in [403, 429] do
    case GoogleCalendarError.from_http_response(status, JSON.stringify(data)) do
      {:google_calendar_rate_limited, ^status, _reasons} = reason -> {:error, reason}
      _reason -> {:error, {:google_calendar_http, status}}
    end
  end

  defp provider_http_error(status, _data), do: {:error, {:google_calendar_http, status}}

  defp proxy_query(name, value),
    do: %{"name" => name, "type" => "query", "value" => to_string(value)}

  defp append_proxy_query(parameters, _name, value) when value in [nil, ""], do: parameters
  defp append_proxy_query(parameters, name, value), do: parameters ++ [proxy_query(name, value)]

  defp telemetry_outcome({:ok, _}), do: "ok"
  defp telemetry_outcome({:error, :cursor_expired}), do: "conflict"

  defp telemetry_outcome({:error, {:google_calendar_http, status}})
       when status in [401, 403, 404, 429] or status >= 500,
       do: "unavailable"

  defp telemetry_outcome({:error, {:google_calendar_rate_limited, status, _reasons}})
       when status in [403, 429],
       do: "unavailable"

  defp telemetry_outcome({:error, :timeout}), do: "timeout"
  defp telemetry_outcome(_result), do: "error"

  defp get_event(access, event_id) do
    endpoint =
      @google_calendar_api <>
        "/calendars/" <>
        encode_path_segment(access.calendar_id) <> "/events/" <> encode_path_segment(event_id)

    case execute_exact_proxy(access, endpoint, []) do
      {:ok, %{"id" => ^event_id} = event} -> {:ok, event}
      {:ok, _data} -> {:error, :invalid_google_calendar_response}
      {:error, _} = error -> error
    end
  end

  defp execute_data(access, tool, args) do
    case Composio.execute_tool(access.settings, tool, access.group_id, args,
           connected_account_id: access.account_id,
           error_mode: :structured
         )
         |> normalize_composio_error() do
      {:ok, %{"successful" => true, "data" => data}} -> {:ok, data}
      {:ok, %{"successful" => false} = envelope} -> provider_error(envelope)
      {:error, _} = error -> error
      other -> {:error, {:invalid_google_calendar_response, other}}
    end
  end

  defp exact_event(
         access,
         master_event_id,
         instance_event_id,
         %{"occurrence_ref" => %{"recurrence_key" => %{"kind" => "recurring"} = key}},
         default_time_zone
       )
       when is_binary(instance_event_id) and instance_event_id != "" do
    with {:ok, event} <- get_event(access, instance_event_id),
         {:ok, verified} <-
           exact_instance([event], master_event_id, key["value"], default_time_zone) do
      {:ok, verified}
    end
  end

  defp exact_event(
         access,
         master_event_id,
         nil,
         %{"occurrence_ref" => %{"recurrence_key" => %{"kind" => "recurring"} = key}},
         default_time_zone
       ) do
    with {:ok, original_start} <- recurrence_original_start(key),
         {:ok, data} <- execute_instances(access, master_event_id, original_start),
         {:ok, events} <- event_items(data),
         {:ok, event} <-
           exact_instance(events, master_event_id, key["value"], default_time_zone) do
      {:ok, event}
    end
  end

  defp exact_event(
         access,
         master_event_id,
         nil,
         _occurrence,
         _default_time_zone
       ),
       do: get_event(access, master_event_id)

  defp exact_event(
         _access,
         _master_event_id,
         _instance_event_id,
         _occurrence,
         _default_time_zone
       ),
       do: {:error, :calendar_event_source_mismatch}

  defp execute_instances(access, master_event_id, original_start) do
    endpoint =
      @google_calendar_api <>
        "/calendars/" <>
        encode_path_segment(access.calendar_id) <>
        "/events/" <> encode_path_segment(master_event_id) <> "/instances"

    parameters = [
      proxy_query("originalStart", original_start),
      proxy_query("showDeleted", true),
      proxy_query("maxResults", @instances_page_size)
    ]

    # Only a windowed lookup that succeeded and found nothing falls back to
    # the unwindowed listing. A transport or provider error (429, 5xx,
    # timeout) or an exhausted page budget is returned as is: repeating the
    # listing without the window would double the failed requests and let the
    # worst case grow to two page budgets.
    case instances_window(original_start) do
      {:ok, window} ->
        case instances_page(access, endpoint, parameters ++ window, nil, @instances_max_pages) do
          {:ok, %{"items" => [_ | _]}} = hit ->
            hit

          {:ok, _empty} ->
            instances_page(access, endpoint, parameters, nil, @instances_max_pages)

          {:error, _} = error ->
            error
        end

      :error ->
        instances_page(access, endpoint, parameters, nil, @instances_max_pages)
    end
  end

  defp instances_window(original_start) do
    case DateTime.from_iso8601(original_start) do
      {:ok, at, _offset} ->
        {:ok,
         [
           proxy_query(
             "timeMin",
             at |> DateTime.add(-@instances_window_seconds, :second) |> DateTime.to_iso8601()
           ),
           proxy_query(
             "timeMax",
             at |> DateTime.add(@instances_window_seconds, :second) |> DateTime.to_iso8601()
           )
         ]}

      _ ->
        :error
    end
  end

  # An empty page that still carries a `nextPageToken` is not an answer: the
  # filter has simply not reached the instance yet. Only a page with items or
  # the end of the listing settles the lookup. Exhausting the page budget is
  # reported as its own error so the caller does not mistake it for a
  # definite "instance gone" (which cancels the meeting plan).
  defp instances_page(access, endpoint, parameters, page_token, pages_left) do
    case execute_exact_proxy(
           access,
           endpoint,
           append_proxy_query(parameters, "pageToken", page_token)
         ) do
      {:ok, %{"items" => [_ | _]} = data} ->
        {:ok, data}

      {:ok, data} when is_map(data) ->
        case present_or_nil(data["nextPageToken"]) do
          nil ->
            {:ok, data}

          token when pages_left > 1 ->
            instances_page(access, endpoint, parameters, token, pages_left - 1)

          _token ->
            {:error, :calendar_instances_page_budget_exhausted}
        end

      {:error, _} = error ->
        error
    end
  end

  defp execute_exact_proxy(access, endpoint, parameters),
    do: execute_exact_proxy(access, endpoint, parameters, true)

  defp execute_exact_proxy(access, endpoint, parameters, retry_session?) do
    with {:ok, session_id} <- ensure_proxy_session(access, nil) do
      request =
        %{
          "toolkit_slug" => "googlecalendar",
          "endpoint" => endpoint,
          "method" => "GET"
        }
        |> put_proxy_parameters(parameters)

      result =
        case proxy_execute(access, session_id, request) do
          {:ok, %{"status" => 200, "data" => data}} when is_map(data) ->
            {:ok, data}

          {:ok, %{"status" => 404}} ->
            {:error, :calendar_event_not_found}

          {:ok, %{"status" => status} = response} when is_integer(status) ->
            provider_http_error(status, response["data"])

          {:error, :not_found} when retry_session? ->
            :retry_proxy_session

          {:error, :not_found} ->
            {:error, :composio_proxy_session_unavailable}

          {:error, _} = error ->
            error

          _ ->
            {:error, :invalid_google_calendar_response}
        end

      cleanup_proxy_session(access, session_id)

      case result do
        :retry_proxy_session -> execute_exact_proxy(access, endpoint, parameters, false)
        other -> other
      end
    else
      {:error, :not_found} -> {:error, :composio_proxy_session_unavailable}
      {:error, _} = error -> error
    end
  end

  defp put_proxy_parameters(request, []), do: request
  defp put_proxy_parameters(request, parameters), do: Map.put(request, "parameters", parameters)

  defp encode_path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp execute_map(access, tool, args) do
    case execute_data(access, tool, args) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _data} -> {:error, :invalid_google_calendar_response}
      {:error, _} = error -> error
    end
  end

  defp recurrence_original_start(%{
         "value" => value,
         "time_zone" => time_zone
       })
       when is_binary(value) and is_binary(time_zone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, %{iso8601: iso8601}} <- Recurrence.resolve_local_time(naive, time_zone) do
      {:ok, iso8601}
    else
      _ -> {:error, :calendar_event_source_mismatch}
    end
  end

  defp recurrence_original_start(_key), do: {:error, :calendar_event_source_mismatch}

  defp exact_instance(events, master_event_id, recurrence_key, default_time_zone) do
    matches =
      Enum.filter(events, fn event ->
        trim(event["recurringEventId"]) == master_event_id and
          match_original_start?(event, recurrence_key, default_time_zone)
      end)

    case matches do
      [event] -> {:ok, event}
      [] -> {:error, :calendar_event_not_found}
      _ -> {:error, :ambiguous_calendar_event_instance}
    end
  end

  defp match_original_start?(event, recurrence_key, default_time_zone) do
    case original_start(event, default_time_zone) do
      {:ok, %{key: ^recurrence_key}} -> true
      _ -> false
    end
  end

  defp provider_error(envelope) do
    case GoogleCalendarError.from_composio_envelope(envelope) do
      {:google_calendar_http, 410} -> {:error, :cursor_expired}
      {:google_calendar_http, 404} -> {:error, :calendar_event_not_found}
      reason -> {:error, reason}
    end
  end

  defp proxy_execute(access, session_id, request) do
    access.settings
    |> Composio.proxy_execute(session_id, request, error_mode: :structured)
    |> normalize_composio_error()
  end

  defp normalize_composio_error({:error, {:http, status}}) when is_integer(status),
    do: {:error, {:google_calendar_http, status}}

  defp normalize_composio_error(result), do: result

  defp page_tokens(data, previous_sync_token, proxy_session_id) do
    page_token = present_or_nil(data["nextPageToken"]) || ""
    next_sync_token = present_or_nil(data["nextSyncToken"]) || ""

    cond do
      page_token != "" ->
        {:ok,
         %{
           "next_continuation" =>
             encode_continuation(%{
               "page_token" => page_token,
               "sync_token" => previous_sync_token,
               "proxy_session_id" => proxy_session_id
             }),
           "completed_cursor" => nil
         }}

      next_sync_token != "" ->
        {:ok, %{"next_continuation" => nil, "completed_cursor" => next_sync_token}}

      true ->
        {:error, :google_sync_token_missing}
    end
  end

  defp normalize_all(events, source) do
    default_time_zone = default_time_zone(source)
    access_profile = source["access_profile"]

    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, records} ->
      case normalize(event,
             default_time_zone: default_time_zone,
             access_profile: access_profile
           ) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, {trim(event["id"]), reason}}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp normalize_master(event, event_id, default_time_zone, access_profile) do
    with {:ok, timing} <- timing(event, default_time_zone) do
      {rules, exclusions, state} =
        case recurrence(event["recurrence"], timing.time_zone) do
          {:ok, rules, exclusions} -> {rules, exclusions, "complete"}
          {:error, :unsupported_google_recurrence} -> {[], %{}, "unsupported_timing"}
        end

      normalized_master_record(
        event,
        event_id,
        timing,
        rules,
        exclusions,
        state,
        access_profile
      )
    end
  end

  defp normalized_master_record(
         event,
         event_id,
         timing,
         recurrence_rules,
         exclusions,
         normalization_state,
         access_profile
       ) do
    meet_url = meet_url(event)

    object =
      %{
        "@type" => "Event",
        "uid" => trim(event["iCalUID"] || event_id),
        "title" => event["summary"] || "Calendar event",
        "description" => event["description"],
        "start" => timing.start,
        "duration" => timing.duration,
        "timeZone" => timing.time_zone,
        "showWithoutTime" => timing.all_day,
        "status" => if(cancelled?(event), do: "cancelled", else: "confirmed"),
        "freeBusyStatus" => if(event["transparency"] == "transparent", do: "free", else: "busy"),
        "recurrenceRules" => recurrence_rules,
        "recurrenceOverrides" => exclusions,
        "virtualLocations" => virtual_locations(meet_url),
        "links" => event_links(event["htmlLink"])
      }
      |> compact()

    object = apply_access_profile(object, access_profile)

    restricted? = access_profile in ["free_busy", "redacted"]
    supported? = normalization_state == "complete" and not restricted?
    item_eligible? = supported? and not timing.all_day
    item_reason = item_qualification_reason(restricted?, normalization_state, timing.all_day)

    {:ok,
     %{
       "external_locator" => %{"event_id" => event_id},
       "copy_role" => if(restricted?, do: "unknown", else: copy_role(event)),
       "object" => object,
       "scheduling_identity" => if(restricted?, do: nil, else: scheduling_identity(event)),
       "scheduling_revision" => scheduling_revision(event, object),
       "source_version" => source_version(event),
       "source_revision" => source_revision(event),
       "present_fields" =>
         if(restricted?, do: restricted_present_fields(event), else: present_fields(event)),
       "participant_set_state" =>
         if(restricted?,
           do: "redacted",
           else: if(event["attendeesOmitted"] == true, do: "truncated", else: "complete")
         ),
       "attachment_set_state" => if(restricted?, do: "redacted", else: "not_requested"),
       "normalization_state" => normalization_state,
       "source_fresh_at" => System.system_time(:millisecond),
       "meeting_qualification" => %{
         "item_eligible" => item_eligible?,
         "item_reason" => item_reason,
         "authorized" => item_eligible? and google_meet_url?(meet_url),
         "reason" =>
           if(item_eligible?, do: conference_qualification_reason(meet_url), else: item_reason)
       }
     }
     |> compact()}
  end

  defp apply_access_profile(object, access_profile)
       when access_profile in ["free_busy", "redacted"] do
    Map.take(
      object,
      ~w(@type start duration timeZone showWithoutTime status freeBusyStatus recurrenceRules recurrenceOverrides)
    )
  end

  defp apply_access_profile(object, _access_profile), do: object

  defp restricted_present_fields(event) do
    allowed = MapSet.new(~w(end start status transparency))

    event
    |> Map.keys()
    |> Enum.filter(&MapSet.member?(allowed, &1))
    |> Enum.sort()
  end

  defp item_qualification_reason(true, _normalization_state, _all_day),
    do: "access_profile_restricted"

  defp item_qualification_reason(false, normalization_state, _all_day)
       when normalization_state != "complete",
       do: "unsupported_timing"

  defp item_qualification_reason(false, _normalization_state, true), do: "all_day_event"
  defp item_qualification_reason(false, _normalization_state, false), do: "eligible"

  defp conference_qualification_reason(meet_url) do
    if google_meet_url?(meet_url), do: "google_meet", else: "no_supported_conference"
  end

  defp normalize_override(event, master_id, instance_id, default_time_zone) do
    with {:ok, original} <- original_start(event, default_time_zone),
         {:ok, override} <- override_value(event, original, default_time_zone) do
      {:ok,
       %{
         "external_locator" => %{"event_id" => master_id},
         "object_patch" => %{"recurrenceOverrides" => %{original.key => override}},
         "source_version_patch" => %{
           "recurrence_instances" => %{original.key => instance_id}
         },
         "source_revision_patch" => %{original.key => source_revision(event)}
       }}
    end
  end

  defp timing(event, default_time_zone) do
    start_value = event["start"]
    end_value = event["end"]

    with {:ok, start} <- temporal(start_value, default_time_zone),
         {:ok, ending} <- temporal(end_value, default_time_zone),
         true <- start.all_day == ending.all_day,
         true <- ending.ms > start.ms,
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
      false -> {:error, :invalid_google_event_time}
      {:error, _} = error -> error
    end
  end

  defp temporal(%{"date" => value}, default_time_zone) when is_binary(value) do
    time_zone = present_or_nil(default_time_zone) || "UTC"

    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, datetime} <- DateTime.new(date, ~T[00:00:00], time_zone) do
      {:ok,
       %{
         value: value,
         time_zone: time_zone,
         ms: DateTime.to_unix(datetime, :millisecond),
         all_day: true
       }}
    end
  end

  defp temporal(%{"dateTime" => value} = temporal, default_time_zone)
       when is_binary(value),
       do: datetime_temporal(value, temporal["timeZone"] || default_time_zone)

  defp temporal(_value, _default_time_zone), do: {:error, :invalid_google_event_time}

  defp datetime_temporal(value, time_zone) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, local} <- shift_if_present(datetime, time_zone) do
      canonical =
        if(nonblank?(time_zone),
          do: DateTime.to_naive(local) |> NaiveDateTime.to_iso8601(),
          else: value
        )

      {:ok,
       %{
         value: canonical,
         time_zone: present_or_nil(time_zone),
         ms: DateTime.to_unix(datetime, :millisecond),
         all_day: false
       }}
    else
      _ -> {:error, :invalid_google_event_time}
    end
  end

  defp duration(%{all_day: true, value: start_value}, %{all_day: true, value: end_value}) do
    with {:ok, start_date} <- Date.from_iso8601(start_value),
         {:ok, end_date} <- Date.from_iso8601(end_value),
         days when days > 0 <- Date.diff(end_date, start_date) do
      {:ok, "P#{days}D"}
    else
      _ -> {:error, :invalid_google_event_time}
    end
  end

  defp duration(%{all_day: false, ms: start_ms}, %{all_day: false, ms: end_ms}) do
    seconds = div(end_ms - start_ms, 1_000)
    if seconds > 0, do: {:ok, iso_duration(seconds)}, else: {:error, :invalid_google_event_time}
  end

  defp iso_duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    seconds = rem(seconds, 60)

    "PT" <>
      if(hours > 0, do: "#{hours}H", else: "") <>
      if(minutes > 0, do: "#{minutes}M", else: "") <>
      if(seconds > 0, do: "#{seconds}S", else: "")
  end

  defp recurrence(nil, _time_zone), do: {:ok, [], %{}}
  defp recurrence([], _time_zone), do: {:ok, [], %{}}

  defp recurrence(lines, time_zone) when is_list(lines) do
    rrules = Enum.filter(lines, &String.starts_with?(&1, "RRULE:"))
    rdates = Enum.filter(lines, &String.starts_with?(&1, "RDATE"))
    exdates = Enum.filter(lines, &String.starts_with?(&1, "EXDATE"))

    with [rrule] <- rrules,
         [] <- rdates,
         {:ok, rule} <- parse_rrule(rrule),
         {:ok, exclusions} <- parse_exdates(exdates, time_zone) do
      {:ok, [rule], exclusions}
    else
      _ -> {:error, :unsupported_google_recurrence}
    end
  end

  defp recurrence(_value, _time_zone), do: {:error, :unsupported_google_recurrence}

  defp parse_rrule("RRULE:" <> body) do
    parts =
      body
      |> String.split(";", trim: true)
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    allowed = ~w(FREQ INTERVAL BYDAY WKST)

    with true <- Map.keys(parts) -- allowed == [],
         frequency when frequency in ["DAILY", "WEEKLY"] <- parts["FREQ"],
         {:ok, interval} <- positive_integer(parts["INTERVAL"] || "1"),
         {:ok, first_day_of_week} <- parse_week_start(parts["WKST"], frequency),
         {:ok, by_day} <- parse_by_day(parts["BYDAY"]) do
      rule =
        %{
          "@type" => "RecurrenceRule",
          "frequency" => String.downcase(frequency),
          "interval" => interval
        }
        |> put_nonempty("byDay", by_day)
        |> put_optional("firstDayOfWeek", first_day_of_week)

      {:ok, rule}
    else
      _ -> {:error, :unsupported_google_recurrence}
    end
  end

  defp parse_week_start(nil, _frequency), do: {:ok, nil}

  defp parse_week_start(day, "WEEKLY")
       when day in ~w(MO TU WE TH FR SA SU),
       do: {:ok, String.downcase(day)}

  defp parse_week_start(_day, _frequency),
    do: {:error, :unsupported_google_recurrence}

  defp parse_by_day(nil), do: {:ok, []}

  defp parse_by_day(value) do
    days = %{
      "MO" => "mo",
      "TU" => "tu",
      "WE" => "we",
      "TH" => "th",
      "FR" => "fr",
      "SA" => "sa",
      "SU" => "su"
    }

    tokens = String.split(value, ",", trim: true)

    if tokens != [] and Enum.all?(tokens, &Map.has_key?(days, &1)),
      do: {:ok, Enum.map(tokens, &%{"@type" => "NDay", "day" => days[&1]})},
      else: {:error, :unsupported_google_recurrence}
  end

  defp parse_exdates(lines, time_zone) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      case parse_exdate(line, time_zone) do
        {:ok, keys} ->
          {:cont, {:ok, Enum.reduce(keys, acc, &Map.put(&2, &1, %{"excluded" => true}))}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp parse_exdate(line, master_time_zone) do
    case String.split(line, ":", parts: 2) do
      [prefix, values] ->
        value_time_zone = exdate_time_zone(prefix, master_time_zone)

        values
        |> String.split(",", trim: true)
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, keys} ->
          case google_recurrence_value(value, value_time_zone, master_time_zone) do
            {:ok, key} -> {:cont, {:ok, [key | keys]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, keys} -> {:ok, Enum.reverse(keys)}
          error -> error
        end

      _ ->
        {:error, :unsupported_google_recurrence}
    end
  end

  defp exdate_time_zone("EXDATE", master_time_zone), do: master_time_zone

  defp exdate_time_zone("EXDATE;TZID=" <> time_zone, _master_time_zone),
    do: time_zone

  defp exdate_time_zone(_prefix, _master_time_zone), do: :invalid

  defp google_recurrence_value(value, value_time_zone, master_time_zone) do
    cond do
      Regex.match?(~r/^\d{8}$/, value) ->
        with <<year::binary-size(4), month::binary-size(2), day::binary-size(2)>> <- value,
             {:ok, date} <- Date.from_iso8601("#{year}-#{month}-#{day}") do
          {:ok, NaiveDateTime.new!(date, ~T[00:00:00]) |> NaiveDateTime.to_iso8601()}
        end

      Regex.match?(~r/^\d{8}T\d{6}Z$/, value) ->
        with {:ok, naive} <- parse_basic_datetime(value),
             {:ok, shifted} <- shift_recurrence_value(naive, "Etc/UTC", master_time_zone) do
          {:ok, shifted}
        end

      Regex.match?(~r/^\d{8}T\d{6}$/, value) ->
        with {:ok, naive} <- parse_basic_datetime(value),
             {:ok, shifted} <-
               shift_recurrence_value(naive, value_time_zone, master_time_zone) do
          {:ok, shifted}
        end

      true ->
        {:error, :unsupported_google_recurrence}
    end
  end

  defp shift_recurrence_value(value, source_zone, target_zone)
       when is_binary(source_zone) and is_binary(target_zone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, %{unix_ms: unix_ms}} <- Recurrence.resolve_local_time(naive, source_zone),
         {:ok, datetime} <- DateTime.from_unix(unix_ms, :millisecond),
         {:ok, shifted} <- DateTime.shift_zone(datetime, target_zone) do
      {:ok,
       shifted
       |> DateTime.to_naive()
       |> NaiveDateTime.truncate(:second)
       |> NaiveDateTime.to_iso8601()}
    else
      _ -> {:error, :unsupported_google_recurrence}
    end
  end

  defp shift_recurrence_value(_value, _source_zone, _target_zone),
    do: {:error, :unsupported_google_recurrence}

  defp parse_basic_datetime(value) do
    value = String.trim_trailing(value, "Z")

    with <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T",
           hour::binary-size(2), minute::binary-size(2), second::binary-size(2)>> <- value,
         {:ok, naive} <-
           NaiveDateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}") do
      {:ok, NaiveDateTime.to_iso8601(naive)}
    else
      _ -> {:error, :unsupported_google_recurrence}
    end
  end

  defp original_start(event, default_time_zone) do
    value = event["originalStartTime"]

    with {:ok, temporal} <- temporal(value, default_time_zone) do
      key =
        if temporal.all_day,
          do: temporal.value <> "T00:00:00",
          else: canonical_naive(temporal)

      {:ok, Map.put(temporal, :key, key)}
    end
  end

  defp override_value(event, _original, default_time_zone) do
    if cancelled?(event) do
      {:ok, %{"excluded" => true}}
    else
      with {:ok, timing} <- timing(event, default_time_zone) do
        start = if timing.all_day, do: timing.start <> "T00:00:00", else: timing.start

        {:ok,
         %{
           "start" => start,
           "duration" => timing.duration,
           "virtualLocations" => virtual_locations(meet_url(event))
         }}
      end
    end
  end

  defp canonical_naive(%{value: value, time_zone: time_zone, ms: ms}) do
    cond do
      nonblank?(time_zone) ->
        value

      true ->
        {:ok, datetime} = DateTime.from_unix(ms, :millisecond)
        datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    end
  end

  defp source_version(event) do
    %{
      "etag" => event["etag"],
      "updated" => event["updated"],
      "sequence" => event["sequence"]
    }
    |> compact()
  end

  defp source_revision(event) do
    if Map.has_key?(event, "sequence") or nonblank?(event["updated"]) do
      [event["sequence"] || 0, timestamp_rank(event["updated"])]
    end
  end

  defp timestamp_rank(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> max(DateTime.to_unix(datetime, :microsecond), 0)
      _ -> 0
    end
  end

  defp timestamp_rank(_value), do: 0

  defp scheduling_revision(event, object) do
    source_version(event)
    |> Map.take(~w(sequence updated))
    |> Map.put("shared_fact_hash", shared_fact_hash(object))
  end

  defp shared_fact_hash(object) do
    object
    |> Map.take(
      ~w(@type uid title description start duration timeZone showWithoutTime status recurrenceRules recurrenceOverrides virtualLocations)
    )
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  defp scheduling_identity(event) do
    uid = trim(event["iCalUID"])
    authority = event |> get_in(["organizer", "email"]) |> trim() |> String.downcase()

    if uid != "" and authority != "" do
      %{
        "identity_version" => "google_ical_uid.v1",
        "namespace" => "ical_uid",
        "series_uid" => uid,
        "scheduling_authority_key" => authority
      }
    end
  end

  defp present_fields(event), do: Map.keys(event) |> Enum.sort()

  defp copy_role(event) do
    if get_in(event, ["organizer", "self"]) == true, do: "organizer", else: "attendee"
  end

  defp virtual_locations(nil), do: %{}
  defp virtual_locations(""), do: %{}

  defp virtual_locations(uri),
    do: %{"conference" => %{"@type" => "VirtualLocation", "uri" => uri}}

  defp event_links(html_link) do
    case safe_google_calendar_url(html_link) do
      nil ->
        nil

      href ->
        %{
          "event" => %{
            "@type" => "Link",
            "href" => href,
            "rel" => "alternate"
          }
        }
    end
  end

  defp safe_google_calendar_url(url) when is_binary(url) and byte_size(url) <= 4_096 do
    url = String.trim(url)

    with {:ok, %URI{} = uri} <- URI.new(url),
         "https" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- google_host?(host),
         nil <- uri.userinfo,
         443 <- uri.port do
      uri
      |> Map.put(:scheme, "https")
      |> Map.put(:host, String.downcase(host))
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp safe_google_calendar_url(_url), do: nil

  defp google_host?(host) do
    host = String.downcase(host)
    host == "google.com" or String.ends_with?(host, ".google.com")
  end

  defp meet_url(event) do
    trim(event["hangoutLink"] || conference_url(event["conferenceData"]))
  end

  defp conference_url(conference) when is_map(conference) do
    (conference["entryPoints"] || [])
    |> Enum.find_value(fn entry ->
      if entry["entryPointType"] == "video", do: entry["uri"]
    end)
  end

  defp conference_url(_conference), do: nil

  defp google_meet_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} -> String.downcase(host || "") == "meet.google.com"
      _ -> false
    end
  end

  defp google_meet_url?(_url), do: false

  defp cancelled?(event), do: String.downcase(trim(event["status"])) == "cancelled"

  defp event_items(data) do
    case data["items"] do
      values when is_list(values) ->
        if Enum.all?(values, &is_map/1),
          do: {:ok, values},
          else: {:error, :invalid_google_calendar_response}

      _ ->
        {:error, :invalid_google_calendar_response}
    end
  end

  defp encode_continuation(value),
    do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode_continuation(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{} = continuation} <- Jason.decode(decoded),
         true <- nonblank?(continuation["page_token"]) do
      {:ok, continuation}
    else
      _ -> {:error, :invalid_google_calendar_continuation}
    end
  end

  defp positive_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :unsupported_google_recurrence}
    end
  end

  defp shift_if_present(datetime, value) do
    if nonblank?(value), do: DateTime.shift_zone(datetime, value), else: {:ok, datetime}
  end

  defp default_time_zone(source),
    do: get_in(source, ["sync_policy", "default_time_zone"]) |> present_or_nil() || "UTC"

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp present_or_nil(value), do: if(nonblank?(value), do: trim(value), else: nil)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp trim(value), do: String.trim(to_string(value || ""))

  defp compact(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
end
