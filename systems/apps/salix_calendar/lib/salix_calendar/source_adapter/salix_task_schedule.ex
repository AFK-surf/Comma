defmodule SalixCalendar.SourceAdapter.SalixTaskSchedule do
  @moduledoc "Read-only normalization of a public scheduled-Task projection."

  @behaviour SalixCalendar.SourceAdapter

  alias SalixCalendar.Item
  alias SalixStore.{Crypto, JSON}

  @impl true
  def adapter_contract_id, do: "salix_task_schedule.v1"

  @impl true
  def capabilities do
    %{
      "object_types" => ["Task"],
      "sync_mode" => "collection_delta",
      "change_feed" => true,
      "exact_read" => false,
      "max_page_size" => 200,
      "source_writes" => false
    }
  end

  @impl true
  def start_sync(source, query_contract, completed_cursor) do
    read_page(source, query_contract, start_after: completed_cursor)
  end

  @impl true
  def continue_sync(source, query_contract, continuation) when is_binary(continuation) do
    read_page(source, query_contract, continuation: continuation)
  end

  @impl true
  def normalize(projection, opts \\ [])

  def normalize(projection, _opts) when is_map(projection) do
    projection = JSON.stringify(projection)
    conversation_id = projection["conversation_id"]
    task_schedule = projection["schedule"] || %{}
    definition = projection["schedule_definition"] || %{}
    schedule_id = task_schedule["schedule_id"]
    source_revision = source_revision(projection)

    cond do
      not nonblank?(conversation_id) ->
        {:error, :invalid_task_projection}

      not Item.valid_source_revision?(source_revision) ->
        {:error, :invalid_task_projection}

      projection["kind"] != "agent_task" ->
        {:error, :not_a_task}

      tombstone?(projection, schedule_id) ->
        {:ok,
         %{
           "external_locator" => %{"conversation_id" => conversation_id},
           "tombstone" => true,
           "source_revision" => source_revision
         }}

      definition["id"] != schedule_id or definition["receiver"] != "task" ->
        {:error, :schedule_projection_mismatch}

      get_in(definition, ["payload", "conversation_id"]) != conversation_id ->
        {:error, :schedule_projection_mismatch}

      true ->
        normalize_live(projection, conversation_id, schedule_id, definition)
    end
  end

  def normalize(_projection, _opts), do: {:error, :invalid_task_projection}

  defp normalize_live(projection, conversation_id, schedule_id, definition) do
    object = task_object(projection, conversation_id)

    with {:ok, recurrence} <- recurrence(definition),
         {:ok, due, time_zone} <- due(definition, projection["recurrence_anchor_at"]) do
      object =
        object
        |> Map.put("timeZone", time_zone)
        |> Map.put("recurrenceRules", recurrence)
        |> maybe_put("due", due)

      {:ok,
       normalized_record(
         projection,
         conversation_id,
         schedule_id,
         definition,
         object,
         "complete"
       )}
    else
      {:error, _} ->
        {:ok,
         normalized_record(
           projection,
           conversation_id,
           schedule_id,
           definition,
           object,
           "unsupported_timing"
         )}
    end
  end

  defp normalized_record(
         projection,
         conversation_id,
         schedule_id,
         definition,
         object,
         normalization_state
       ) do
    %{
      "external_locator" => %{"conversation_id" => conversation_id},
      "copy_role" => "owner",
      "object" => object,
      "source_version" => %{
        "change_id" => projection["change_id"],
        "task_updated_at" => projection["source_updated_at"],
        "schedule_id" => schedule_id,
        "schedule_definition_hash" => timing_hash(definition)
      },
      "source_revision" => source_revision(projection),
      "normalization_state" => normalization_state
    }
  end

  defp source_revision(%{
         "source_updated_at" => source_updated_at,
         "created_at" => created_at,
         "change_id" => change_id
       })
       when is_integer(source_updated_at) and source_updated_at >= 0 and
              is_integer(created_at) and created_at >= 0 and is_binary(change_id) and
              change_id != "",
       do: [source_updated_at, created_at, change_id]

  defp source_revision(%{"revision" => revision}) when is_integer(revision) and revision >= 0,
    do: [revision]

  defp source_revision(_projection), do: nil

  defp task_object(projection, conversation_id) do
    %{
      "@type" => "Task",
      "uid" => "urn:salix:agent-task:" <> conversation_id,
      "title" => projection["title"] || "Scheduled task",
      "status" => task_status(projection["status"]),
      "freeBusyStatus" => "free",
      "links" => %{
        "task" => %{
          "href" => "salix-resource:agent-task:" <> conversation_id,
          "rel" => "describedby"
        }
      }
    }
  end

  defp read_page(source, query_contract, opts) do
    source = JSON.stringify(source)
    query_contract = JSON.stringify(query_contract)
    group_id = get_in(source, ["source_locator", "group_id"])
    limit = query_contract["page_size"] || 100

    with true <- group_id == query_contract["group_id"],
         true <- query_contract["object_type"] in [nil, "Task"],
         mod when is_atom(mod) and not is_nil(mod) <-
           Application.get_env(:salix_calendar, :task_change_feed_mod),
         {:ok, page} <-
           mod.page(group_id,
             continuation: opts[:continuation],
             start_after: opts[:start_after],
             limit: limit
           ),
         {:ok, changes} <- normalize_changes(page["changes"] || []) do
      {:ok,
       %{
         "changes" => changes,
         "next_continuation" => page["next_continuation"],
         "completed_cursor" => page["completed_cursor"]
       }}
    else
      false -> {:error, :task_query_contract_mismatch}
      nil -> {:error, :task_change_feed_not_configured}
      {:error, _} = error -> error
      _ -> {:error, :invalid_task_change_feed}
    end
  end

  defp normalize_changes(changes) when is_list(changes) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, records} ->
      case normalize(change) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, {change["change_id"], reason}}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp recurrence(%{"interval_minutes" => minutes}) when is_integer(minutes) and minutes > 0 do
    {:ok,
     [
       %{
         "@type" => "RecurrenceRule",
         "frequency" => "minutely",
         "interval" => minutes
       }
     ]}
  end

  defp recurrence(%{"cron" => cron}) when is_binary(cron) do
    case String.split(cron) do
      [minute, hour, "*", "*", days] -> cron_recurrence(minute, hour, days)
      _ -> {:error, :unsupported_timing}
    end
  end

  defp recurrence(_definition), do: {:error, :unsupported_timing}

  defp cron_recurrence(minute, hour, days) do
    with {minute, ""} when minute in 0..59 <- Integer.parse(minute),
         {hour, ""} when hour in 0..23 <- Integer.parse(hour),
         {:ok, by_day} <- cron_days(days) do
      frequency = if by_day == [], do: "daily", else: "weekly"

      rule =
        %{
          "@type" => "RecurrenceRule",
          "frequency" => frequency,
          "byHour" => [hour],
          "byMinute" => [minute]
        }
        |> maybe_put("byDay", if(by_day == [], do: nil, else: by_day))

      {:ok, [rule]}
    else
      _ -> {:error, :unsupported_timing}
    end
  end

  defp cron_days("*"), do: {:ok, []}

  defp cron_days("1-5"),
    do: {:ok, Enum.map(~w(mo tu we th fr), &%{"@type" => "NDay", "day" => &1})}

  defp cron_days(value) do
    day_map = %{
      "0" => "su",
      "1" => "mo",
      "2" => "tu",
      "3" => "we",
      "4" => "th",
      "5" => "fr",
      "6" => "sa",
      "7" => "su"
    }

    days = String.split(value, ",", trim: true)

    if days != [] and Enum.all?(days, &Map.has_key?(day_map, &1)) do
      {:ok, Enum.map(days, &%{"@type" => "NDay", "day" => day_map[&1]})}
    else
      {:error, :unsupported_timing}
    end
  end

  defp due(%{"interval_minutes" => minutes}, value)
       when is_integer(minutes) and minutes > 0 and is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime), "UTC"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp due(definition, value) when is_integer(value) do
    time_zone = definition["timezone"] || "UTC"

    case value |> DateTime.from_unix(:millisecond) |> shift_zone(time_zone) do
      {:ok, datetime} ->
        {:ok, datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601(), time_zone}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp due(_definition, nil), do: {:ok, nil, "UTC"}
  defp due(_definition, _value), do: {:error, :invalid_next_fire_at}

  defp shift_zone({:ok, datetime}, time_zone), do: DateTime.shift_zone(datetime, time_zone)
  defp shift_zone({:error, reason}, _time_zone), do: {:error, reason}

  defp timing_hash(definition) do
    definition
    |> Map.take(~w(id interval_minutes cron timezone created_at))
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  defp tombstone?(projection, schedule_id),
    do:
      not nonblank?(schedule_id) or
        projection["status"] in ~w(archived cancelled canceled terminal)

  defp task_status(status) when status in ~w(done completed), do: "completed"
  defp task_status(_status), do: "in-process"

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
