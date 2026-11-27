defmodule Salix.Bindings.MeetingCalendar do
  @moduledoc "Local Calendar occurrence coordinator used by meeting discovery."

  @behaviour SalixMeet.Ports.CalendarOccurrences

  alias SalixCalendar.{OccurrenceQualification, Occurrences, Server}
  alias SalixCalendar.OccurrenceQualification.Result
  alias SalixMeet.MeetingPlan
  alias SalixStore.{CasRecord, Crypto, Ids, JSON, Keys}

  @max_sources 50
  @max_events 50

  @impl true
  def list(group, range_start_ms, range_end_ms) do
    group = JSON.stringify(group)
    group_id = group["group_id"]
    calendar_id = group["calendar_id"]
    limit = min(group["max_events"] || @max_events, @max_events)

    paged? = group["paged"] == true

    with true <- Ids.valid_group_id?(group_id),
         true <- Ids.valid_calendar_id?(calendar_id),
         :ok <- SalixMeet.CalendarConfiguration.authorize_group(group),
         {:ok, source_ids} <- selected_source_ids(group),
         {:ok, page, next} <-
           read_entries(
             group,
             group_id,
             calendar_id,
             range_start_ms,
             range_end_ms,
             source_ids,
             limit
           ) do
      page
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
        {:ok, events} when paged? ->
          {:ok, events |> Enum.reverse() |> Enum.sort_by(& &1["start_ms"]), next}

        {:ok, events} ->
          {:ok, events |> Enum.reverse() |> Enum.sort_by(& &1["start_ms"])}
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
           get_occurrence(group_id, calendar_id, item_id, occurrence_ref, source_ids),
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
           get_occurrence(group_id, calendar_id, item_id, occurrence_ref, source_ids),
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

  # An occurrence lookup reads at most @max_sources sources; a member with more
  # calendars is looked up batch by batch.
  defp get_occurrence(group_id, calendar_id, item_id, occurrence_ref, source_ids) do
    source_ids
    |> Enum.chunk_every(@max_sources)
    |> Enum.reduce_while({:error, :not_found}, fn batch, missing ->
      case Occurrences.get(group_id, calendar_id, item_id, occurrence_ref, source_ids: batch) do
        {:ok, _current} = found ->
          {:halt, found}

        {:error, reason} = error when reason in [:not_found, :occurrence_not_found] ->
          {:cont, if(missing == {:error, :not_found}, do: error, else: missing)}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp cancel_invalid_plan({:error, reason} = result, group, event)
       when reason in [
              :calendar_event_not_found,
              :calendar_event_cancelled,
              :calendar_event_changed
            ] do
    with {:ok, _plan} <- MeetingPlan.cancel(group["group_id"], event["occurrence_ref"]),
         :ok <- leave_holders(group, event),
         do: result
  end

  defp cancel_invalid_plan(result, _group, _event), do: result

  defp selected_source_ids(group) do
    source_ids =
      group["calendars"]
      |> List.wrap()
      |> Enum.map(& &1["source_id"])

    if source_ids != [] and
         length(source_ids) == length(Enum.uniq(source_ids)) and
         Enum.all?(source_ids, &Ids.valid_calendar_source_id?/1),
       do: {:ok, Enum.sort(source_ids)},
       else: {:error, :meeting_calendar_not_configured}
  end

  defp read_entries(%{"paged" => true} = group, group_id, calendar_id, t0, t1, source_ids, limit),
    do: list_page(group_id, calendar_id, t0, t1, source_ids, limit, group["page_after"])

  defp read_entries(group, group_id, calendar_id, t0, t1, source_ids, limit) do
    with {:ok, entries} <-
           list_entries(group_id, calendar_id, t0, t1, source_ids, limit, item_filter(group)),
         do: {:ok, entries, nil}
  end

  # A paged member scan prepares the occurrences of one page of calendar items
  # (in item id order, after the item the last page ended with), across all
  # of the member's calendars, and returns where the next page starts (nil at
  # the end). Each pass's work is bounded by the page, however many meetings
  # the calendar holds.
  defp list_page(group_id, calendar_id, t0, t1, source_ids, limit, after_item) do
    after_item = if is_binary(after_item), do: after_item, else: nil

    source_ids
    |> Enum.chunk_every(@max_sources)
    |> Enum.reduce_while({:ok, [], []}, fn batch, {:ok, acc, nexts} ->
      case Occurrences.list_page(group_id, calendar_id, t0, t1,
             object_type: "Event",
             source_ids: batch,
             limit: limit,
             after_item: after_item,
             item_filter: &OccurrenceQualification.may_qualify?/1
           ) do
        {:ok, entries, nil} -> {:cont, {:ok, acc ++ entries, nexts}}
        {:ok, entries, next} -> {:cont, {:ok, acc ++ entries, [next | nexts]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, nexts} ->
        # A batch with items left ends where its page ended; the merged page
        # stops at the earliest such end, so no batch's items are skipped.
        boundary = if nexts == [], do: nil, else: Enum.min(nexts)

        item_ids =
          entries
          |> Enum.map(&get_in(&1, ["item", "calendar_item_id"]))
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.filter(&(is_nil(boundary) or &1 <= boundary))

        {kept, dropped} = Enum.split(item_ids, limit)
        kept_set = MapSet.new(kept)

        page =
          Enum.filter(
            entries,
            &MapSet.member?(kept_set, get_in(&1, ["item", "calendar_item_id"]))
          )

        # The page covers every item up to its last kept item, or up to the
        # batches' earliest end when fewer items had occurrences in range.
        next = if dropped == [], do: boundary, else: List.last(kept)
        {:ok, Enum.sort_by(page, &get_in(&1, ["occurrence", "start_ms"])), next}

      error ->
        error
    end
  end

  # A member's own calendar is mostly events that never qualify (all-day,
  # free, no meeting link); they are left out before the occurrence limit counts.
  defp item_filter(%{"calendar_scope" => "members"}),
    do: &OccurrenceQualification.may_qualify?/1

  defp item_filter(_group), do: fn _item -> true end

  # A calendar query reads at most @max_sources sources, so a member with more
  # calendars is read in batches and the batches are merged by start time.
  defp list_entries(
         group_id,
         calendar_id,
         range_start_ms,
         range_end_ms,
         source_ids,
         limit,
         item_filter
       ) do
    source_ids
    |> Enum.chunk_every(@max_sources)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case Occurrences.list(group_id, calendar_id, range_start_ms, range_end_ms,
             object_type: "Event",
             source_ids: batch,
             limit: limit,
             item_filter: item_filter
           ) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} when length(entries) > limit -> {:error, :occurrence_limit_exceeded}
      {:ok, entries} -> {:ok, Enum.sort_by(entries, &get_in(&1, ["occurrence", "start_ms"]))}
      error -> error
    end
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

  # A member unit's copy that stops qualifying here (cancelled, declined, no
  # meeting link) names no meeting link, so this unit leaves the meeting's
  # holders when the scan finds the copy gone (`SalixMeet.CalendarAutojoin`
  # calls release/2 with the indexed copy).
  defp prepare_selected_event(group, item, occurrence, source_ids) do
    object = item["object"] || %{}
    qualification = OccurrenceQualification.evaluate(item, occurrence)

    with {:ok, publication_target} <- publication_target(group),
         {:ok, preparation} <- preparation(group, item, occurrence, qualification),
         {:ok, plan} <-
           MeetingPlan.ensure(
             group["group_id"],
             item,
             occurrence,
             # The members' choice comes first: Keyword.get reads the first key.
             preparation ++
               [
                 source_ids: source_ids,
                 calendar_writeback: group["calendar_writeback"] == true,
                 managed_calendar: is_integer(group["settings_revision"]),
                 policy_revision: group["settings_revision"] || 1,
                 preparation_lead_minutes: group["preparation_lead_minutes"] || 10,
                 research_enabled: group["research_enabled"] != false,
                 personal_preparation: group["personal_preparation"] != false,
                 channel_notice: group["channel_notice"] != false,
                 publication_target: publication_target,
                 occurrence_qualification: qualification
               ]
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
           }
           |> put_present("organizer_email", organizer_email(item))
           |> put_meeting_identity(group)}

        {"planned", _qualification} ->
          {:error, :meeting_qualification_mismatch}

        {status, _qualification} when status in ["not_qualified", "cancelled"] ->
          {:skip, plan["reason"] || status}

        {_status, _qualification} ->
          {:error, :invalid_meeting_plan_state}
      end
    end
  end

  # A meeting on members' calendars is researched once, by one preparer, and
  # every member whose own calendar holds it gets a direct message. One record
  # per meeting names the preparer (its member and its copy) and the holders.
  # Each unit that sees the meeting adds its member to the holders. The
  # preparer stays while it is a member with usable calendars; otherwise the
  # unit that scans now takes over and first cancels the former preparer's
  # plan, so that plan sends no second reminder. The preparer's plan names the
  # current holders as its recipients (MeetingPersonalPreparation.roster/1).
  # A Feishu/Lark meeting names its people by open_id: its preparer reminds
  # every current attendee, as a team calendar's meeting does.
  defp preparation(%{"calendar_scope" => "members"} = group, _item, occurrence, qualification) do
    me = member_email(group["account_email"])

    open_id_attendees? =
      group["provider"] in ["feishu", "lark"] and group["calendar_source"] != "google"

    if me == "" or group["personal_preparation"] != true do
      {:ok, [personal_preparation: false, research_enabled: false]}
    else
      case hold_preparation(group, me, usable_members(group, me), qualification, occurrence) do
        {:ok, true, _holders} when open_id_attendees? ->
          {:ok, [personal_preparation: true]}

        {:ok, true, holders} ->
          {:ok, [personal_preparation: true, personal_recipients: holders]}

        {:ok, false, _holders} ->
          {:ok, [personal_preparation: false, research_enabled: false]}

        {:error, _} = error ->
          error
      end
    end
  end

  defp preparation(_group, _item, _occurrence, _qualification), do: {:ok, []}

  # Members whose units have usable calendars (`member_emails`), and this
  # unit's own member, which is scanning now.
  defp usable_members(group, me) do
    group["member_emails"]
    |> List.wrap()
    |> Enum.map(&member_email/1)
    |> Enum.reject(&(&1 == ""))
    |> Kernel.++([me])
    |> Enum.uniq()
  end

  # Returns whether this copy prepares the meeting, and the holders.
  defp hold_preparation(group, me, members, %Result{meet_url: meet_url}, occurrence)
       when is_binary(meet_url) do
    key = preparation_key(meet_url, group, occurrence["start_ms"])
    ref = JSON.stringify(occurrence["occurrence_ref"])

    with {:ok, current} <- read_preparation(key),
         replaced = replaced_preparer(preparation_record(current), members),
         :ok <- stop_preparer(group, replaced),
         {:ok, record} <-
           CasRecord.update(key, fn current ->
             record = preparation_record(current)

             if replaced_preparer(record, members) == replaced do
               next = hold(record, me, ref, members)
               if next == current, do: {:unchanged, next}, else: next
             else
               # Another unit changed the preparer since the read: the next
               # scan pass decides again.
               {:error, :member_preparer_changed}
             end
           end) do
      {:ok, record["preparer"] == me and record["preparer_ref"] == ref, record["holders"]}
    end
  end

  defp hold_preparation(_group, _me, _members, _qualification, _occurrence),
    do: {:ok, false, []}

  defp hold(record, me, ref, members) do
    preparer = record["preparer"]

    {preparer, preparer_ref} =
      cond do
        # A record written before copies were named: the member's copy that
        # scans first is its preparer's copy.
        preparer == me and is_nil(record["preparer_ref"]) -> {me, ref}
        preparer in members -> {preparer, record["preparer_ref"]}
        true -> {me, ref}
      end

    %{
      "preparer" => preparer,
      "preparer_ref" => preparer_ref,
      "holders" =>
        (Enum.filter(record["holders"], &(&1 in members)) ++ [me]) |> Enum.uniq() |> Enum.sort()
    }
  end

  # The preparer this scan replaces: one that is set and no longer a member
  # with usable calendars.
  defp replaced_preparer(%{"preparer" => preparer} = record, members)
       when is_binary(preparer) do
    if preparer in members, do: nil, else: {preparer, record["preparer_ref"]}
  end

  defp replaced_preparer(_record, _members), do: nil

  # The replaced preparer's unit may not scan again (its calendars are not
  # usable): its plan is cancelled here. A record written before copies were
  # named does not name that plan.
  defp stop_preparer(group, {_preparer, ref}) when is_map(ref) do
    case MeetingPlan.cancel(group["group_id"], ref) do
      {:ok, _plan} -> :ok
      {:error, _} = error -> error
    end
  end

  defp stop_preparer(_group, _replaced), do: :ok

  defp read_preparation(key) do
    case CasRecord.get(key) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc """
  The copy that prepares a meeting on members' calendars: the occurrence ref
  (string keys) the meeting's preparer record names, or nil when there is no
  record or it was written before copies were named. One read.
  """
  @spec preparer_ref(String.t(), String.t(), integer()) :: {:ok, map() | nil} | {:error, term()}
  def preparer_ref(group_id, meet_url, start_ms)
      when is_binary(meet_url) and is_integer(start_ms) do
    with {:ok, current} <-
           read_preparation(preparation_key(meet_url, %{"group_id" => group_id}, start_ms)),
         do: {:ok, preparation_record(current)["preparer_ref"]}
  end

  def preparer_ref(_group_id, _meet_url, _start_ms), do: {:ok, nil}

  @doc """
  This member unit's copy of a meeting left its calendar or stopped
  qualifying: its plan is cancelled, the member is no longer a holder, and as
  preparer it hands the meeting to the next unit that scans it.
  """
  @impl true
  def release(group, event) do
    group = JSON.stringify(group)
    event = JSON.stringify(event)

    with "members" <- group["calendar_scope"],
         ref when is_map(ref) <- event["occurrence_ref"],
         {:ok, _plan} <- MeetingPlan.cancel(group["group_id"], ref) do
      leave_holders(group, event)
    else
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp leave_holders(group, event) do
    me = member_email(group["account_email"])
    ref = event["occurrence_ref"]

    with "members" <- group["calendar_scope"],
         true <- me != "",
         meet_url when is_binary(meet_url) <- event["meet_url"],
         start_ms when is_integer(start_ms) <- event["start_ms"] do
      meet_url
      |> preparation_key(group, start_ms)
      |> CasRecord.update(
        fn current ->
          record = preparation_record(current)
          mine? = record["preparer"] == me and record["preparer_ref"] in [nil, ref]

          next = %{
            "preparer" => if(mine?, do: nil, else: record["preparer"]),
            "preparer_ref" => if(mine?, do: nil, else: record["preparer_ref"]),
            "holders" => List.delete(record["holders"], me)
          }

          if next == current, do: {:unchanged, next}, else: next
        end,
        create: false
      )
      |> case do
        {:ok, _record} -> :ok
        {:error, :not_found} -> :ok
        {:error, _} = error -> error
      end
    else
      _ -> :ok
    end
  end

  defp preparation_key(meet_url, group, start_ms),
    do:
      Keys.ctl_meet_member_preparer(
        group["group_id"],
        Crypto.hex(meet_url <> "|" <> to_string(start_ms))
      )

  # A record written before holders were kept names only its preparer.
  defp preparation_record(%{"account_email" => email}) when is_binary(email),
    do: %{"preparer" => email, "preparer_ref" => nil, "holders" => [email]}

  defp preparation_record(%{} = record),
    do: %{
      "preparer" => if(is_binary(record["preparer"]), do: record["preparer"]),
      "preparer_ref" => if(is_map(record["preparer_ref"]), do: record["preparer_ref"]),
      "holders" => record["holders"] |> List.wrap() |> Enum.filter(&is_binary/1)
    }

  defp preparation_record(nil), do: %{"preparer" => nil, "preparer_ref" => nil, "holders" => []}

  defp member_email(value), do: value |> trim() |> String.downcase()

  defp publication_target(group) do
    provider = trim(group["provider"])
    connect_id = trim(group["connect_id"])
    # Also a meeting that is joined: its notices are the join notice and
    # the minutes (`Salix.Bindings.MeetingChannel`), not a team notice.
    personal_only? = group["mode"] in ["prepare", "join"] and group["channel_notice"] == false

    case {provider, connect_id} do
      {"", ""} ->
        {:ok, nil}

      {"slack", connect_id} when connect_id != "" ->
        channel = trim(group["channel_id"])

        cond do
          # A Slack team preparation without a team channel sends only
          # personal notices: its target names the connect and no channel.
          channel == "" and group["channel_notice"] == false ->
            {:ok,
             %{"provider" => "slack", "tool" => "none", "params" => %{"connect_id" => connect_id}}}

          channel == "" ->
            {:error, :meeting_calendar_publication_target_invalid}

          true ->
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

      # A Feishu/Lark team preparation without its shared notice sends only
      # personal notices: its target names the connect and no chat.
      {provider, connect_id}
      when provider in ["feishu", "lark"] and connect_id != "" and personal_only? ->
        {:ok,
         %{
           "provider" => provider,
           "tool" => "none",
           "params" =>
             put_present(%{"connect_id" => connect_id}, "chat_id", trim(group["chat_id"]))
         }}

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

      {"lark", connect_id} when connect_id != "" ->
        chat_id = trim(group["chat_id"])

        if chat_id == "" do
          {:error, :meeting_calendar_publication_target_invalid}
        else
          {:ok,
           %{
             "provider" => "lark",
             "tool" => "im_api.lark.send_message",
             "params" =>
               %{"connect_id" => connect_id, "chat_id" => chat_id}
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

  # A member calendar's copy names the meeting by its room, not by the copy.
  defp put_meeting_identity(event, %{"calendar_scope" => "members"}),
    do: Map.put(event, "meeting_identity", "meet")

  defp put_meeting_identity(event, _group), do: event

  defp organizer_email(item),
    do:
      item
      |> get_in(["scheduling_identity", "scheduling_authority_key"])
      |> trim()
      |> String.downcase()

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
