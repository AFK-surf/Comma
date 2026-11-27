defmodule CommaWeb.ProactiveMeetingPrep do
  @moduledoc """
  Time-driven pre-meeting preparation trigger.

  Reads already-collected calendar items (`googlecalendar` and `outlook`) from
  `Comma.MemberSourceItems` (zero extra provider API calls), selects non-solo
  meetings starting within 5..35 minutes via
  `SalixStore.ProactiveKernel.upcoming_meetings/3`, skips any occurrence already
  prep-checked (`attention["prep_start_ms"] == start_ms`), and emits bounded
  synthetic candidates for `CommaWeb.ProactiveCheck` screening.

  Screening pairs each meeting with zero-cost local cross-source context
  (`memory` + `pool`: attendee notes, recent emails, open PRs/drafts). Routine
  or context-free meetings settle quietly (`briefing`); meetings with concrete
  cross-source prep context deliver once through the capped `signal` pool.
  """

  alias Comma.Data.MemberSourceItem
  alias Comma.MemberSourceItems
  alias SalixStore.ProactiveKernel

  @max_per_check 4

  @doc "Whether `profile_id` has any non-solo meeting due for pre-meeting prep now."
  def due?(profile_id, now_ms \\ SystemsClock.system_time(:millisecond))
      when is_binary(profile_id) and is_integer(now_ms) do
    candidates(profile_id, now_ms) != []
  end

  @doc "Upcoming non-solo meetings in `profile_id`'s pool not yet prep-checked for this start time."
  def candidates(profile_id, now_ms, opts \\ [])
      when is_binary(profile_id) and is_integer(now_ms) do
    entries =
      for %{collected: true, items: items} <- MemberSourceItems.current(profile_id),
          %MemberSourceItem{toolkit: toolkit, facts: facts} = item <- items,
          toolkit in ~w(googlecalendar outlook),
          is_map(facts),
          Map.has_key?(facts, "start") and Map.has_key?(facts, "end") do
        context = if is_map(item.context), do: item.context, else: %{}

        event =
          context
          |> Map.take(~w(status attendeeCount attendees))
          |> Map.merge(facts)
          |> Map.put("record", item)

        event
      end

    entries
    |> ProactiveKernel.upcoming_meetings(now_ms, opts)
    |> Enum.reject(fn %{event: %{"record" => record}, start_ms: start_ms} ->
      skip_occurrence?(record, start_ms, now_ms)
    end)
    |> Enum.take(@max_per_check)
    |> Enum.map(&build_candidate(&1, now_ms))
  rescue
    _ -> []
  end

  @doc "Pure variant over plain event maps, used by `CommaWeb.ProactiveReplay` and tests."
  def from_events(events, now_ms, opts \\ []) when is_list(events) and is_integer(now_ms) do
    events
    |> ProactiveKernel.upcoming_meetings(now_ms, opts)
    |> Enum.take(@max_per_check)
    |> Enum.map(fn %{event: event, start_ms: start_ms, starts_in_min: mins} ->
      url = event["htmlLink"] || event["webUrl"] || event["url"] || "calendar://#{event["id"]}"
      title = event["summary"] || event["subject"] || event["title"] || "Upcoming meeting"
      attendees = format_attendees(event["attendees"])
      desc = event["description"] || event["bodyPreview"] || ""
      start_iso = DateTime.from_unix!(start_ms, :millisecond) |> DateTime.to_iso8601()

      excerpt =
        [
          "Starts in #{mins} minutes (#{start_iso})",
          if(attendees != "", do: "Attendees: #{attendees}"),
          if(is_binary(desc) and String.trim(desc) != "", do: String.trim(desc))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      %{
        "id" => "mp:#{event["id"] || start_ms}:#{start_ms}",
        "sourceId" => "meeting_prep",
        "toolkit" => "googlecalendar",
        "app" => "Calendar",
        "title" => title,
        "url" => url,
        "excerpt" => excerpt,
        "context" => %{
          "text" => excerpt,
          "attendeeCount" => event["attendeeCount"] || length(List.wrap(event["attendees"]))
        },
        "relationship" => "upcoming_meeting_prep",
        "facts" => %{
          "start" => event["start"],
          "end" => event["end"],
          "startsInMinutes" => mins
        },
        "arrivedAt" => DateTime.from_unix!(now_ms, :millisecond),
        "meeting_prep" => true,
        "prep_start_ms" => start_ms,
        "members" => []
      }
      |> then(&Map.put(&1, "members", [&1]))
    end)
  end

  @doc "Atomically marks the calendar item's occurrence as prep-checked without overwriting its primary attention."
  def mark_checked(
        %{"record" => %MemberSourceItem{} = record, "prep_start_ms" => start_ms},
        now_ms
      ) do
    MemberSourceItems.merge_attention(record, %{
      "prep_start_ms" => start_ms,
      "prep_checked_at" => now_ms,
      "prep_deferred_until" => nil
    })
  end

  def mark_checked(_item, _now_ms), do: :ok

  @doc "Atomically records a temporary prep deferral so the occurrence retries before meeting start."
  def mark_deferred(
        %{"record" => %MemberSourceItem{} = record, "prep_start_ms" => start_ms},
        next_at_ms,
        now_ms
      )
      when is_integer(next_at_ms) do
    MemberSourceItems.merge_attention(record, %{
      "prep_deferred_start_ms" => start_ms,
      "prep_deferred_until" => next_at_ms,
      "prep_checked_at" => now_ms
    })
  end

  def mark_deferred(_item, _next_at_ms, _now_ms), do: :ok

  defp skip_occurrence?(%MemberSourceItem{attention: %{} = attention}, start_ms, now_ms) do
    cond do
      attention["prep_start_ms"] == start_ms ->
        true

      attention["prep_deferred_start_ms"] == start_ms and
        is_integer(attention["prep_deferred_until"]) and
          now_ms < attention["prep_deferred_until"] ->
        true

      true ->
        false
    end
  end

  defp skip_occurrence?(_record, _start_ms, _now_ms), do: false

  defp build_candidate(
         %{event: %{"record" => record}, start_ms: start_ms, starts_in_min: mins},
         now_ms
       ) do
    start_iso = DateTime.from_unix!(start_ms, :millisecond) |> DateTime.to_iso8601()
    ctx_text = get_in(record.context || %{}, ["text"]) || ""
    attendees_summary = get_in(record.facts || %{}, ["attendeesSummary"]) || ""

    excerpt =
      [
        "Starts in #{mins} minutes (#{start_iso})",
        if(is_binary(attendees_summary) and attendees_summary != "",
          do: "Attendees: #{attendees_summary}"
        ),
        if(is_binary(record.excerpt) and record.excerpt != "" and record.excerpt != record.title,
          do: record.excerpt
        ),
        if(is_binary(ctx_text) and ctx_text != "", do: ctx_text)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.slice(0, 1_200)

    item = %{
      "record" => record,
      "sourceVersion" => "prep:" <> Integer.to_string(start_ms),
      "id" => "mp:#{record.id}:#{start_ms}",
      "sourceId" => record.source_id,
      "app" => record.app || "Calendar",
      "title" => record.title || "Upcoming meeting",
      "url" => record.url,
      "excerpt" => excerpt,
      "context" =>
        (record.context || %{})
        |> Map.put("text", excerpt),
      "promptContext" => record.prompt_context,
      "relationship" => "upcoming_meeting_prep",
      "recipient" => record.recipient,
      "facts" =>
        (record.facts || %{})
        |> Map.put("startsInMinutes", mins),
      "toolkit" => record.toolkit,
      "arrivedAt" => DateTime.from_unix!(now_ms, :millisecond),
      "meeting_prep" => true,
      "prep_start_ms" => start_ms
    }

    Map.put(item, "members", [item])
  end

  defp format_attendees(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(12)
    |> Enum.join(", ")
  end

  defp format_attendees(_other), do: ""
end
