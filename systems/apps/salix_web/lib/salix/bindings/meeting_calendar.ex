defmodule Salix.Bindings.MeetingCalendar do
  @moduledoc "Local Calendar occurrence coordinator used by meeting discovery."

  @behaviour SalixMeet.Ports.CalendarOccurrences

  alias SalixCalendar.{OccurrenceQualification, Occurrences, Server}
  alias SalixCalendar.OccurrenceQualification.Result
  alias SalixMeet.MeetingPlan
  alias SalixStore.{Crypto, Ids, JSON}

  @max_sources 10
  @max_events 50

  @impl true
  def list(group, range_start_ms, range_end_ms) do
    group = JSON.stringify(group)
    group_id = group["group_id"]
    calendar_id = group["calendar_id"]
    limit = min(group["max_events"] || @max_events, @max_events)

    with true <- Ids.valid_group_id?(group_id),
         true <- Ids.valid_calendar_id?(calendar_id),
         :ok <- SalixMeet.CalendarConfiguration.authorize_group(group),
         {:ok, source_ids} <- selected_source_ids(group),
         {:ok, entries} <-
           Occurrences.list(group_id, calendar_id, range_start_ms, range_end_ms,
             object_type: "Event",
             source_ids: source_ids,
             limit: limit
           ) do
      entries
      |> Enum.reduce({:ok, []}, fn entry, {:ok, events} ->
        case prepare_event(group, entry, source_ids) do
          {:ok, event} ->
            {:ok, [event | events]}

          {:skip, _reason} ->
            {:ok, events}

          {:error, reason} ->
            # One failing event no longer fails the whole group scan — and it
            # must not simply vanish either: absence from the fresh set is
            # what tells reconciliation "this event is really gone" and
            # starts the one-way 15-minute recovery/abandon clock. A
            # placeholder keeps the event's identity present (so a transient
            # storage error cannot be misread as a cancellation) while
            # carrying no Meet URL, which keeps it out of every join
            # candidate set. The scan surfaces it as a partial result.
            {:ok, [placeholder_event(entry, reason) | events]}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, events |> Enum.reverse() |> Enum.sort_by(& &1["start_ms"])}
      end
    else
      false -> {:error, :meeting_calendar_not_configured}
      {:error, _} = error -> error
    end
  end

  def authorize(group, event) do
    group = JSON.stringify(group)
    event = JSON.stringify(event)

    if Ids.valid_group_id?(group["group_id"]) and
         Ids.valid_calendar_id?(group["calendar_id"]) and
         event["calendar_id"] == group["calendar_id"] and
         Ids.valid_calendar_item_id?(event["calendar_item_id"]) and
         is_map(event["occurrence_ref"]),
       do: SalixMeet.CalendarConfiguration.authorize_group(group),
       else: {:error, :calendar_event_source_mismatch}
  end

  @impl true
  def revalidate(group, event) do
    group = JSON.stringify(group)
    event = JSON.stringify(event)

    group
    |> do_revalidate(event)
    |> cancel_invalid_plan(group, event)
  end

  defp do_revalidate(group, event) do
    group_id = group["group_id"]
    calendar_id = event["calendar_id"]
    item_id = event["calendar_item_id"]
    occurrence_ref = event["occurrence_ref"]

    with :ok <- authorize(group, event),
         {:ok, source_ids} <- selected_source_ids(group),
         {:ok, current} <-
           Occurrences.get(group_id, calendar_id, item_id, occurrence_ref, source_ids: source_ids),
         true <- selected_series?(group, current["item"]),
         {:ok, source_id} <- source_id(current["item"]),
         {:ok, _applied} <-
           Server.revalidate_source(
             group_id,
             calendar_id,
             source_id,
             current["item"],
             current["occurrence"]
           ),
         {:ok, refreshed} <-
           Occurrences.get(group_id, calendar_id, item_id, occurrence_ref, source_ids: source_ids),
         :ok <- unchanged_event(event, refreshed) do
      :ok
    else
      false -> {:error, :calendar_event_source_mismatch}
      {:error, :not_found} -> {:error, :calendar_event_not_found}
      {:error, :occurrence_not_found} -> {:error, :calendar_event_cancelled}
      {:error, :occurrence_copy_changed} -> {:error, :calendar_event_changed}
      {:error, {:ambiguous_scheduling_link, _link_id}} -> {:error, :calendar_event_changed}
      {:error, _} = error -> error
    end
  end

  defp cancel_invalid_plan({:error, reason} = result, group, event)
       when reason in [
              :calendar_event_not_found,
              :calendar_event_cancelled,
              :calendar_event_changed
            ] do
    case MeetingPlan.cancel(group["group_id"], event["occurrence_ref"]) do
      {:ok, _plan} -> result
      {:error, _} = error -> error
    end
  end

  defp cancel_invalid_plan(result, _group, _event), do: result

  defp selected_source_ids(group) do
    source_ids =
      group["calendars"]
      |> List.wrap()
      |> Enum.map(& &1["source_id"])

    if source_ids != [] and length(source_ids) <= @max_sources and
         length(source_ids) == length(Enum.uniq(source_ids)) and
         Enum.all?(source_ids, &Ids.valid_calendar_source_id?/1),
       do: {:ok, Enum.sort(source_ids)},
       else: {:error, :meeting_calendar_not_configured}
  end

  @doc false
  def cancel_scheduling_link(group_id, calendar_id, link_id, cursor) do
    case MeetingPlan.cancel_scheduling_link(group_id, calendar_id, link_id, cursor: cursor) do
      {:ok, %{"next_cursor" => next_cursor}} -> {:ok, next_cursor}
      {:error, _} = error -> error
    end
  end

  # Identity and presentation only — never a Meet URL or a plan id, so a
  # placeholder can never be dispatched. The bounded reason string is for the
  # scan's partial-result surfacing.
  defp placeholder_event(%{"item" => item, "occurrence" => occurrence}, reason) do
    object = item["object"] || %{}

    %{
      "event_id" => occurrence_id(occurrence["occurrence_ref"]),
      "calendar_id" => item["calendar_id"],
      "calendar_item_id" => item["calendar_item_id"],
      "occurrence_ref" => occurrence["occurrence_ref"],
      "calendar_revision" => item["revision"],
      "start_ms" => occurrence["start_ms"],
      "end_ms" => occurrence["end_ms"],
      "title" => object["title"] || "Calendar meeting",
      "prepare_error" => reason |> inspect(limit: 10) |> String.slice(0, 200)
    }
  end

  defp prepare_event(group, %{"item" => item, "occurrence" => occurrence}, source_ids) do
    if selected_series?(group, item) do
      prepare_selected_event(group, item, occurrence, source_ids)
    else
      case MeetingPlan.cancel(group["group_id"], occurrence["occurrence_ref"]) do
        {:ok, _} -> {:skip, :meeting_series_not_selected}
        {:error, _} = error -> error
      end
    end
  end

  defp selected_series?(%{"series" => [_ | _] = series} = group, item) do
    source =
      Enum.find(
        group["calendars"] || [],
        &(&1["source_id"] == get_in(item, ["origin", "source_id"]))
      )

    is_map(source) and
      Enum.any?(series, fn selected ->
        selected["account_id"] == source["account_id"] and
          selected["calendar_id"] == source["calendar_id"] and
          selected["event_id"] == get_in(item, ["origin", "external_locator", "event_id"])
      end)
  end

  defp selected_series?(_group, _item), do: true

  defp prepare_selected_event(group, item, occurrence, source_ids) do
    object = item["object"] || %{}
    qualification = OccurrenceQualification.evaluate(item, occurrence)

    with {:ok, publication_target} <- publication_target(group),
         {:ok, plan} <-
           MeetingPlan.ensure(
             group["group_id"],
             item,
             occurrence,
             source_ids: source_ids,
             calendar_writeback: group["calendar_writeback"] == true,
             managed_calendar: is_integer(group["settings_revision"]),
             policy_revision: group["settings_revision"] || 1,
             preparation_lead_minutes: group["preparation_lead_minutes"] || 10,
             research_enabled: group["research_enabled"] != false,
             personal_preparation: group["personal_preparation"] != false,
             publication_target: publication_target,
             occurrence_qualification: qualification
           ) do
      case {plan["status"], qualification} do
        {"planned", %Result{authorized: true, meet_url: meet_url}} ->
          {:ok,
           %{
             "event_id" => occurrence_id(occurrence["occurrence_ref"]),
             "calendar_id" => item["calendar_id"],
             "calendar_item_id" => item["calendar_item_id"],
             "occurrence_ref" => occurrence["occurrence_ref"],
             "meeting_plan_id" => plan["meeting_plan_id"],
             "calendar_revision" => item["revision"],
             "start_ms" => occurrence["start_ms"],
             "end_ms" => occurrence["end_ms"],
             "meet_url" => meet_url,
             "title" => object["title"] || "Calendar meeting"
           }}

        {"planned", _qualification} ->
          {:error, :meeting_qualification_mismatch}

        {status, _qualification} when status in ["not_qualified", "cancelled"] ->
          {:skip, plan["reason"] || status}

        {_status, _qualification} ->
          {:error, :invalid_meeting_plan_state}
      end
    end
  end

  defp publication_target(group) do
    provider = trim(group["provider"])
    connect_id = trim(group["connect_id"])

    case {provider, connect_id} do
      {"", ""} ->
        {:ok, nil}

      {"slack", connect_id} when connect_id != "" ->
        channel = trim(group["channel_id"])

        if channel == "" do
          {:error, :meeting_calendar_publication_target_invalid}
        else
          params =
            %{"connect_id" => connect_id, "channel" => channel}
            |> put_present("thread_ts", trim(group["thread_ts"]))

          {:ok,
           %{
             "provider" => "slack",
             "tool" => "im_api.slack.post_message",
             "params" => params
           }}
        end

      {"feishu", connect_id} when connect_id != "" ->
        chat_id = trim(group["chat_id"])

        if chat_id == "" do
          {:error, :meeting_calendar_publication_target_invalid}
        else
          {:ok,
           %{
             "provider" => "feishu",
             "tool" => "im_api.feishu.send_text",
             "params" =>
               %{
                 "connect_id" => connect_id,
                 "receive_id" => chat_id,
                 "receive_id_type" => "chat_id"
               }
               |> put_mentions(group["mentions"])
           }}
        end

      _incomplete ->
        {:error, :meeting_calendar_publication_target_invalid}
    end
  end

  defp put_mentions(params, %{"mode" => "users", "users" => users}) when is_list(users),
    do: Map.put(params, "mentions", users)

  defp put_mentions(params, %{"mode" => "all"}), do: Map.put(params, "mention_all", true)
  defp put_mentions(params, _mentions), do: params

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp unchanged_event(indexed, %{"item" => item, "occurrence" => occurrence}) do
    qualification = OccurrenceQualification.evaluate(item, occurrence)

    cond do
      qualification.reason == :cancelled ->
        {:error, :calendar_event_cancelled}

      not qualification.authorized ->
        {:error, :calendar_event_cancelled}

      occurrence["start_ms"] != indexed["start_ms"] or
        occurrence["end_ms"] != indexed["end_ms"] or
          qualification.meet_url != indexed["meet_url"] ->
        {:error, :calendar_event_changed}

      true ->
        :ok
    end
  end

  defp source_id(%{"origin" => %{"kind" => "source", "source_id" => source_id}})
       when is_binary(source_id),
       do: {:ok, source_id}

  defp source_id(_item), do: {:error, :calendar_event_source_mismatch}

  defp trim(value), do: value |> to_string() |> String.trim()

  defp occurrence_id(occurrence_ref) do
    digest = occurrence_ref |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()
    "occurrence:" <> digest
  end
end
