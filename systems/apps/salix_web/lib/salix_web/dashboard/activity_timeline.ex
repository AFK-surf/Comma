defmodule SalixWeb.Dashboard.ActivityTimeline do
  @moduledoc """
  Shapes `SalixAnalytics.AgentTelemetryQueries.activity_trace/2` rows into
  the Runtime Health "Activity" tab: one lane per activation, every
  recorded call and every recorded runtime phase placed at its true
  offset, and every stretch of time with NO record drawn explicitly as
  unknown.

  ## Activations, not rounds

  A round is one `round_id`: one model call plus the tool calls it asked
  for. A round that asked for tools records no ending; the runtime
  re-activates the session and the continuation call is a NEW round in
  the same session. So one input is handled by a *chain* of rounds. The
  lane is that chain. Rounds are joined by `activation_key` — the
  runtime's own identity for the input a round answers, carried on its
  phase rows — when both rounds have one; rounds recorded before phase
  telemetry (or by a build without it) fall back to the heuristic: same
  session, the earlier round recorded no ending, the next started within
  two minutes.

  ## Segments (flat, end to end)

    * `:compaction` — a recorded compression provider call, not an extra
      model round. Preparation and commit remain in the activation envelope.
      A round-less call joins only a unique, fully containing activation phase
      in the same scope. Otherwise it remains an explicitly unlinked call.
    * `:llm` / `:tool` — recorded calls, at `started_at` for `duration_ms`.
    * `:phase` — recorded runtime phases from `agent_phase_events`, each
      with its `phase` name: `delivery_wait` (the input's arrival at the
      runtime up to the actor waking for it), `activation` (the session
      actor waking the session up to `Round.run`), `prepare` (up to the provider dispatch),
      `response_commit` (the model's reply stored, tool rounds),
      `tool_commit` (tool results stored), `boundary` (the status write
      ending a tool round), `finalize` (the final message stored).
      `tool_batch` is not drawn: it is the wall clock of the tool calls
      already on the lane.
    * `:between` — time between two rounds of one activation that no
      record covers. With phases recorded this is what is left after
      the previous round's commits and the next round's activation: the
      actor being re-scheduled.
    * `:gap` — ≥100ms inside one round that no call or phase covers.
    * `:settle` — from the last record to the round's recorded ending
      when nothing recorded covers it (rounds without a `finalize` row).

  ## Verdicts on model calls

  Purely mechanical, stated in the legend: `error` when the row's status
  is error; `slow` when the call took ≥60s, or — measured against the
  other calls of the same model in the fetched sample, our own rows, never a
  vendor figure, and only once the fetched sample holds at least five of them —
  in the slowest 10% (≥ the model's p90 here) AND ≥ twice its median.
  A slow verdict is a hint to look, not a judgement of the model. A
  response the runtime discarded because newer input arrived is `stale`:
  its own verdict, never counted as slow unless it also met a slow
  threshold.

  ## Unknown time

  Every stretch no record covers counts: `:between`, `:gap` AND
  `:settle`. Recorded phases are NOT unknown — they are named runtime
  work and get their own share in the summary.

  ## External runtime sessions

  A worker on an external runtime (Codex, Claude Code, ... on a device)
  runs its model loop off-platform; the only records it leaves here are the
  tool calls it proxies through the runtime, carrying a session id but no
  round id. Those calls form a second kind of lane, `kind: :session`: one
  per session, the tool calls drawn at their true offsets, nothing else.
  It has no rounds, no ending and no unknown time — the space between two
  calls is the external model working, which is simply not recorded, not
  a gap in our own runtime — and it stays out of the activation totals
  (`summary`) so the unknown share keeps meaning what it says.

  A session can run for days and outgrow a page, so a session lane is the
  session's calls ON THIS PAGE, never the whole session: the lane is placed
  by its newest call, a truncated feed keeps it (marked `partial?`) instead
  of dropping it, and the page cursor is chosen so that every call below
  it — including the session's earlier calls — is served by the next page
  exactly once (see `cursor/5`). The query pages round-less calls by their
  own `started_at` for the same reason.

  ## Honesty notes

  Cancelled background tool calls never emit a row. The sink is
  best-effort, so a lane can be missing a call or a phase that did run.
  An activation whose last round is still running (or whose ending was
  lost) simply shows "no ending recorded".
  """

  import SalixWeb.Dashboard.AgentTelemetry, only: [num: 1, fnum: 1, fmt_ms: 1]

  @gap_min_ms 100
  @continuation_max_gap_ms 120_000
  @slow_abs_ms 60_000
  @slow_min_samples 5
  @default_lanes 40
  # Row width: lanes longer than this wrap onto more rows (see rows/2) so
  # one long activation can't squash every other lane to a sliver.
  @cap_ms 180_000

  # Phases drawn on the lane, in the order they occur in a round.
  @drawn_phases ~w(miniskill delivery_wait activation prepare response_commit tool_commit boundary finalize async_pickup async_commit async_config)
  # Summary buckets: the three commit-shaped phases roll up into one, and
  # so do the three steps of settling a background tool's result.
  @commit_phases ~w(response_commit tool_commit boundary)
  @async_phases ~w(async_pickup async_commit async_config)

  # The lane's top band, in the order tracks are claimed: model calls
  # first, then tool calls, then the unknown stretches, which fill what is
  # left of those tracks.
  @call_kinds [:llm, :compaction]
  @unknown_kinds [:between, :gap, :settle]
  @band_kinds @call_kinds ++ [:tool] ++ @unknown_kinds

  @type segment :: %{
          kind: :llm | :compaction | :tool | :phase | :between | :gap | :settle,
          phase: String.t() | nil,
          offset_ms: non_neg_integer(),
          duration_ms: non_neg_integer(),
          label: String.t(),
          tooltip: [String.t()],
          severity: :ok | :warn | :error | :stale | :none
        }

  @doc "Phases drawn on a lane, in round order."
  def drawn_phases, do: @drawn_phases

  @doc """
  Whether a segment kind belongs to a lane's top band.

  A lane is drawn in two layers. The band — the model and tool calls,
  plus the unknown stretches between them — takes the lane's first
  tracks, so calls start at the same height on every lane. The runtime's
  own recorded phases are the rest: they always sit below the band, never
  in a hole inside it. A collapsed lane squashes every track onto one
  row, and this is what decides the stacking order there: the calls are
  drawn over the phases, never under them.
  """
  @spec band_kind?(atom()) :: boolean()
  def band_kind?(kind), do: kind in @band_kinds

  @doc """
  Build the tab's view model from query rows.

  Options: `lanes` (activations to keep, newest first; default 40) and
  `limit` (the query's row limit — when the row count reaches it the
  oldest activation is dropped because it may be partial).

  The result's `more?` says whether older activations exist beyond the
  ones kept (either more lanes than fit, or a feed that hit its limit),
  and `next_before_ms` is then the start of the oldest lane shown — the
  cursor to pass as `before` to `activity_trace/2` for the next page.
  """
  @spec build([map()], keyword()) :: map()
  def build(rows, opts \\ []) do
    # The query pages round-less calls by their own start, not their inferred
    # activation's start. First select a page with those cursor owners intact;
    # only then link calls to activations already visible on that page.
    page = build_page(rows, opts, MapSet.new())

    if Enum.any?(rows, &(&1["event_kind"] == "compaction")) do
      visible_rounds = page.lanes |> Enum.flat_map(& &1.round_ids) |> MapSet.new()
      build_page(rows, opts, visible_rounds)
    else
      page
    end
  end

  defp build_page(rows, opts, visible_rounds) do
    max_lanes = opts[:lanes] || @default_lanes
    limit = opts[:limit]

    events = rows |> Enum.map(&parse/1) |> Enum.reject(&is_nil/1)
    calls = rows |> Enum.map(&parse_unrounded/1) |> Enum.reject(&is_nil/1)
    {compactions, calls} = Enum.split_with(calls, &(&1.kind == :compaction))
    {matched, unmatched} = link_compactions(compactions, events, visible_rounds)
    events = events ++ matched
    calls = calls ++ unmatched
    stats = model_stats(events)

    activations =
      events
      |> Enum.group_by(&{&1.session_id, &1.round_id})
      |> Enum.map(fn {_key, round_events} -> shape_round(round_events, stats) end)
      |> chains()

    # Calls recorded against a session but no round: an external runtime's
    # tool calls (see "External runtime sessions" above).
    sessions =
      calls
      |> Enum.group_by(& &1.session_id)
      |> Enum.map(fn {_session, session_calls} -> session_lane(session_calls, stats, false) end)

    truncated? = is_integer(limit) and length(rows) >= limit
    oldest_ms = (events ++ calls) |> Enum.map(& &1.start_ms) |> Enum.min(fn -> nil end)

    # A feed that filled its limit was cut at its oldest row. If that row is
    # an activation's, the chain may be missing rounds: drop it, it comes back
    # whole on the next page. If it is a session's, the lane stays — it is a
    # page-sized slice by design — and says its earlier calls follow.
    {activations, dropped_start} =
      case truncated? and Enum.find(activations, &(&1.start_ms == oldest_ms)) do
        %{start_ms: start} = cut -> {List.delete(activations, cut), start}
        _ -> {activations, nil}
      end

    sessions =
      if truncated?,
        do:
          Enum.map(sessions, &if(&1.start_ms == oldest_ms, do: %{&1 | partial?: true}, else: &1)),
        else: sessions

    sorted = Enum.sort_by(activations ++ sessions, &{-sort_key(&1), &1.lane_id})
    more? = truncated? or length(sorted) > max_lanes
    {kept, hidden} = Enum.split(sorted, max_lanes)
    cursor = if more?, do: cursor(kept, hidden, dropped_start, oldest_ms, truncated?)

    lanes =
      if cursor,
        do: kept |> Enum.map(&trim_session(&1, cursor, stats)) |> Enum.reject(&is_nil/1),
        else: kept

    next_before_ms = if lanes == [], do: nil, else: cursor

    scale_ms =
      lanes
      |> Enum.map(& &1.total_ms)
      |> Enum.max(fn -> 1 end)
      |> min(@cap_ms)
      |> max(1)

    %{
      lanes: lanes,
      summary: summary(lanes),
      model_stats: stats,
      scale_ms: scale_ms,
      cap_ms: @cap_ms,
      truncated?: truncated?,
      more?: more?,
      next_before_ms: next_before_ms
    }
  end

  # Lanes are placed newest first: an activation by its start, a session by
  # its newest call, so a long-running external session is never pushed off
  # the page by its own age (and never has newer calls hidden below the
  # cursor).
  defp sort_key(%{kind: :session, last_call_ms: ms}), do: ms
  defp sort_key(%{start_ms: ms}), do: ms

  # The next page's cursor (`round_start < before`) must be above every row
  # this page owes to it and not above any row it shows. With activations on
  # the page it is what it always was: the start of the oldest activation
  # shown — every hidden lane and every unfetched row lies below it (up to a
  # same-millisecond tie, as before), and session lanes kept on the page are
  # trimmed to calls at or after it (`trim_session/3`), so a call shows on
  # exactly one page. A page of sessions alone has no such start; there the
  # cursor is the lowest value above everything owed to the next page:
  #   - rows the feed did not fetch start before its oldest fetched row;
  #   - a dropped partial activation reappears once its start is below;
  #   - a hidden session is reached once its newest call is below.
  defp cursor(kept, hidden, dropped_start, oldest_ms, truncated?) do
    case kept |> Enum.filter(&(&1.kind == :activation)) |> Enum.map(& &1.start_ms) do
      [_ | _] = starts ->
        Enum.min(starts)

      [] ->
        floors =
          [truncated? && oldest_ms, dropped_start && dropped_start + 1] ++
            Enum.map(hidden, &(sort_key(&1) + 1))

        case Enum.filter(floors, &is_integer/1) do
          [] -> kept |> Enum.map(&sort_key/1) |> Enum.min(fn -> nil end)
          list -> Enum.max(list)
        end
    end
  end

  defp trim_session(%{kind: :session, events: calls} = lane, cursor, stats) do
    case Enum.filter(calls, &(&1.start_ms >= cursor)) do
      [] -> nil
      ^calls -> lane
      later -> session_lane(later, stats, true)
    end
  end

  defp trim_session(lane, _cursor, _stats), do: lane

  @doc """
  Wrap a lane onto rows of `scale_ms` each, the way text wraps: row 0 is
  the first `scale_ms` of the activation, row 1 the next, and so on. A
  segment crossing a row boundary is split; both pieces keep the hover
  card and the later piece is marked `continued?: true` so it draws no
  duration label twice. Nothing is ever cut — a long activation just
  takes more rows at the same scale as every other lane.

  Within a row, the model and tool calls take the topmost tracks and the
  runtime's phases stay underneath them; `band_kind?/1` says which layer
  a segment belongs to, and the page uses it to stack a collapsed lane.

  A session lane can idle for hours between two calls, which at this
  scale would be hundreds of empty rows. Its rows with no call are folded
  away and the next row carries `skipped_ms`, the folded stretch.

  Each row carries `tracks`, how many tracks it needs.
  """
  @spec rows(map(), pos_integer()) :: [
          %{
            index: non_neg_integer(),
            from_ms: non_neg_integer(),
            segments: [segment()],
            tracks: pos_integer()
          }
        ]
  def rows(%{kind: :session} = lane, scale_ms) when scale_ms > 0 do
    lane
    |> lane_rows(scale_ms)
    |> Enum.filter(&(&1.segments != []))
    |> Enum.map_reduce(nil, fn row, prev ->
      skipped = if is_integer(prev), do: row.index - prev - 1, else: 0
      {Map.put(row, :skipped_ms, skipped * scale_ms), row.index}
    end)
    |> elem(0)
  end

  def rows(lane, scale_ms) when scale_ms > 0, do: lane_rows(lane, scale_ms)

  defp lane_rows(%{segments: segments, total_ms: total}, scale_ms) do
    count = max(div(max(total, 1) - 1, scale_ms) + 1, 1)
    segments = assign_tracks(segments, scale_ms)

    for index <- 0..(count - 1) do
      from = index * scale_ms
      to = from + scale_ms

      pieces =
        Enum.flat_map(segments, fn seg ->
          start = seg.offset_ms
          stop = seg.offset_ms + seg.duration_ms
          a = max(start, from)
          b = min(stop, to)

          cond do
            b > a ->
              [
                Map.merge(seg, %{
                  offset_ms: a - from,
                  duration_ms: b - a,
                  continued?: start < from
                })
              ]

            seg.duration_ms == 0 and start >= from and start < to ->
              [Map.merge(seg, %{offset_ms: start - from, continued?: false})]

            true ->
              []
          end
        end)

      tracks = pieces |> Enum.map(&(&1.track + 1)) |> Enum.max(fn -> 1 end)
      %{index: index, from_ms: from, segments: pieces, tracks: tracks}
    end
  end

  # Assign before wrapping so a long record keeps its track across rows.
  #
  # Three passes over one set of tracks, then a fourth below them: model
  # calls claim the lowest free track, tool calls the lowest one left,
  # the unknown stretches whatever hole remains — and the runtime's
  # phases start on a fresh track under the whole band. That is what
  # makes the calls line up across lanes and keeps them in place when the
  # phases are hidden.
  defp assign_tracks(segments, scale_ms) do
    {calls, rest} = Enum.split_with(segments, &(&1.kind in @call_kinds))
    {tools, rest} = Enum.split_with(rest, &(&1.kind == :tool))
    {unknown, phases} = Enum.split_with(rest, &band_kind?(&1.kind))

    {calls, tracks} = pack(calls, scale_ms, [], 0)
    {tools, tracks} = pack(tools, scale_ms, tracks, 0)
    {unknown, tracks} = pack(unknown, scale_ms, tracks, 0)
    {phases, _} = pack(phases, scale_ms, [], length(tracks))

    # Back into reading order: the tracks are what changed, not the story
    # the row tells left to right.
    (calls ++ tools ++ unknown ++ phases) |> Enum.sort_by(&{&1.offset_ms, &1.track})
  end

  # First fit into `tracks` — each an ordered list of the spans already
  # painted on it — starting at track number `base`. A record reserves the
  # minimum painted width, so a short or zero-duration one still takes
  # room instead of vanishing under its neighbour.
  #
  # The unknown stretches are the exception: they are what the records do
  # NOT cover, so nothing is lost when a call's minimum width paints over
  # a sliver of one, and a 150ms gap between two calls must not cost the
  # lane a whole extra track.
  defp pack(segments, scale_ms, tracks, base) do
    min_width = div(scale_ms + 249, 250)

    segments
    |> Enum.with_index()
    |> Enum.sort_by(fn {seg, index} -> {seg.offset_ms, -seg.duration_ms, index} end)
    |> Enum.map_reduce(tracks, fn {seg, _index}, tracks ->
      width =
        if seg.kind in @unknown_kinds,
          do: max(seg.duration_ms, 1),
          else: max(seg.duration_ms, min_width)

      span = {seg.offset_ms, seg.offset_ms + width}
      index = Enum.find_index(tracks, &free?(&1, span)) || length(tracks)

      tracks =
        if index == length(tracks),
          do: tracks ++ [[span]],
          else: List.update_at(tracks, index, &[span | &1])

      {Map.put(seg, :track, base + index), tracks}
    end)
  end

  defp free?(spans, {from, to}), do: Enum.all?(spans, fn {a, b} -> b <= from or a >= to end)

  # Wall-clock time with at least two records, not summed excess work. With
  # three simultaneous records, the shared second must still count once.
  defp parallel_ms(segments) do
    segments
    |> Enum.flat_map(fn seg ->
      if seg.duration_ms > 0,
        do: [{seg.offset_ms, 1}, {seg.offset_ms + seg.duration_ms, -1}],
        else: []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({0, 0, nil}, fn {time, deltas}, {total, count, previous} ->
      total = if count >= 2 and previous != nil, do: total + time - previous, else: total
      {total, count + Enum.sum(deltas), time}
    end)
    |> elem(0)
  end

  @doc "Percent of the lane width a millisecond offset or duration occupies."
  def pct(ms, scale_ms) when scale_ms > 0, do: Float.round(ms * 100 / scale_ms, 2)
  def pct(_ms, _scale_ms), do: 0.0

  # ------------------------------------------------------------------ parse

  defp parse(row) do
    with round_id when is_binary(round_id) and round_id != "" <- row["round_id"],
         kind when kind != nil <- kind(row["event_kind"]) do
      parse_fields(row, kind, round_id)
    else
      _ -> nil
    end
  end

  # A call with a session but no round. Only calls: a phase or run row
  # without a round would be a malformed record, not an external session.
  defp parse_unrounded(row) do
    with nil <- present(row["round_id"]),
         kind when kind in [:llm, :compaction, :tool] <- kind(row["event_kind"]) do
      parse_fields(row, kind, nil)
    else
      _ -> nil
    end
  end

  # Older compaction calls have no round ID. Link only when one recorded
  # activation fully contains the call in the same ownership scope. Missing or
  # ambiguous evidence stays in the unrounded lane, never a guessed new round.
  defp link_compactions(calls, events, visible_rounds) do
    activations =
      events
      |> Enum.filter(&(&1.kind == :phase and &1.name == "activation"))
      |> Enum.group_by(&scope/1)

    Enum.reduce(calls, {[], []}, fn call, {matched, unmatched} ->
      candidates =
        Map.get(activations, scope(call), [])
        |> Enum.filter(&(call.start_ms >= &1.start_ms and call.end_ms <= &1.end_ms))
        |> Enum.uniq_by(& &1.round_id)

      case candidates do
        [activation] ->
          if MapSet.member?(visible_rounds, activation.round_id),
            do: {[%{call | round_id: activation.round_id} | matched], unmatched},
            else: {matched, [call | unmatched]}

        _ ->
          {matched, [call | unmatched]}
      end
    end)
  end

  defp scope(event), do: {event.tenant_id, event.group_id, event.agent_id, event.session_id}

  defp parse_fields(row, kind, round_id) do
    with start when is_integer(start) <- to_ms(row["started_at"]),
         session_id when is_binary(session_id) and session_id != "" <- row["session_id"] do
      duration = num(row["duration_ms"])

      %{
        kind: kind,
        session_id: session_id,
        round_id: round_id,
        tenant_id: row["tenant_id"],
        group_id: row["group_id"],
        agent_id: row["salix_agent_id"],
        start_ms: start,
        duration_ms: duration,
        end_ms: start + duration,
        name: row["name"],
        model: row["model"],
        detail: row["detail"],
        status: row["status"],
        error_type: row["error_type"],
        guidance_reason: row["guidance_reason"],
        first_token_ms: fnum(row["first_token_ms"]),
        attempts: max(num(row["attempts"]), 1),
        tokens: num(row["tokens"]),
        async: row["async"] in [true, 1, "true"],
        call_index: num(row["call_index"]),
        activation_key: present(row["activation_key"])
      }
    else
      _ -> nil
    end
  end

  # One external session's proxied calls on this page as a lane of their own
  # kind: the calls at their true offsets and nothing between them.
  # `partial?` says earlier calls of the session continue on the next page.
  defp session_lane(calls, stats, partial?) do
    calls = Enum.sort_by(calls, &{&1.start_ms, &1.call_index})
    first = List.first(calls)
    start_ms = calls |> Enum.map(& &1.start_ms) |> Enum.min()
    end_ms = calls |> Enum.map(& &1.end_ms) |> Enum.max()
    segments = Enum.map(calls, &call_segment(&1, start_ms, stats))
    total = end_ms - start_ms
    sum = fn kind -> segments |> Enum.filter(&(&1.kind == kind)) |> sum_ms() end

    %{
      kind: :session,
      lane_id: "session:" <> first.session_id,
      session_id: first.session_id,
      tenant_id: first.tenant_id,
      group_id: first.group_id,
      agent_id: first.agent_id,
      start_ms: start_ms,
      end_ms: end_ms,
      last_call_ms: calls |> Enum.map(& &1.start_ms) |> Enum.max(),
      partial?: partial?,
      events: calls,
      terminal: nil,
      activation_key: nil,
      round_ids: [],
      rounds: 0,
      calls: length(calls),
      segments: segments,
      total_ms: total,
      llm_ms: sum.(:llm),
      tool_ms: sum.(:tool),
      between_ms: 0,
      gap_ms: 0,
      settle_ms: 0,
      delivery_ms: 0,
      activation_ms: 0,
      prepare_ms: 0,
      miniskill_ms: 0,
      commit_ms: 0,
      finalize_ms: 0,
      async_ms: 0,
      wall: wall_partition(segments),
      wrapped?: total > @cap_ms
    }
  end

  defp kind("compaction"), do: :compaction
  defp kind("llm"), do: :llm
  defp kind("tool"), do: :tool
  defp kind("run"), do: :run
  defp kind("phase"), do: :phase
  defp kind(_), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp to_ms(value), do: SalixWeb.Dashboard.AgentTelemetry.ch_ms(value)

  # ------------------------------------------------------------ per model

  # Median and p90 of model-call durations per model, over the rows in view.
  # The verdict baseline is the view itself so it needs no second query and
  # always compares like with like (same window, same filters).
  defp model_stats(events) do
    events
    |> Enum.filter(&(&1.kind == :llm and &1.status != "error"))
    |> Enum.group_by(&model_key/1)
    |> Map.new(fn {model, calls} ->
      sorted = calls |> Enum.map(& &1.duration_ms) |> Enum.sort()
      {model, %{n: length(sorted), median: quantile(sorted, 0.5), p90: quantile(sorted, 0.9)}}
    end)
  end

  defp model_key(event), do: event.model || event.name || "unknown model"

  defp quantile([], _p), do: 0

  defp quantile(sorted, p) do
    index = round((length(sorted) - 1) * p)
    Enum.at(sorted, index)
  end

  # ------------------------------------------------------------ per round

  # One round's flat segment run, offsets relative to the round's start —
  # which is its earliest record of any kind, so a recorded `activation`
  # phase leads the round.
  defp shape_round(events, stats) do
    calls =
      events
      |> Enum.filter(&(&1.kind in [:llm, :compaction, :tool]))
      |> Enum.sort_by(&{&1.start_ms, &1.call_index})

    phases = Enum.filter(events, &(&1.kind == :phase and &1.name in @drawn_phases))

    terminal =
      events |> Enum.filter(&(&1.kind == :run)) |> Enum.max_by(& &1.start_ms, fn -> nil end)

    first = List.first(events)
    start_ms = events |> Enum.map(& &1.start_ms) |> Enum.min()

    blocks =
      (Enum.map(calls, &call_segment(&1, start_ms, stats)) ++
         Enum.map(phases, &phase_segment(&1, start_ms)))
      |> Enum.sort_by(&{&1.offset_ms, -&1.duration_ms})

    # Walk the recorded blocks in time order; whatever the coverage front
    # has not reached when the next block starts is unknown.
    {segments, cursor} =
      Enum.reduce(blocks, {[], 0}, fn block, {acc, cursor} ->
        acc =
          if block.offset_ms - cursor >= @gap_min_ms,
            do: [gap_segment(cursor, block.offset_ms - cursor) | acc],
            else: acc

        {[block | acc], max(cursor, block.offset_ms + block.duration_ms)}
      end)

    {segments, end_ms} =
      case terminal do
        %{end_ms: term_end} when term_end - start_ms - cursor >= @gap_min_ms ->
          {[settle_segment(cursor, term_end - start_ms - cursor) | segments], term_end}

        %{end_ms: term_end} ->
          {segments, max(start_ms + cursor, term_end)}

        nil ->
          {segments, start_ms + cursor}
      end

    %{
      round_id: first.round_id,
      session_id: first.session_id,
      tenant_id: first.tenant_id,
      group_id: first.group_id,
      agent_id: first.agent_id,
      start_ms: start_ms,
      end_ms: end_ms,
      terminal: terminal && terminal.status,
      activation_key: phases |> Enum.map(& &1.activation_key) |> Enum.find(&is_binary/1),
      segments: Enum.reverse(segments)
    }
  end

  defp call_segment(%{kind: :llm} = call, start_ms, stats) do
    {severity, notes} = llm_verdict(call, stats)

    tooltip =
      [
        "Model call · #{model_key(call)}",
        "took #{fmt_ms(call.duration_ms)}",
        call.first_token_ms && "first token after #{fmt_ms(call.first_token_ms)}",
        call.attempts > 1 && "#{call.attempts} attempts (retries fold into one call)",
        call.tokens > 0 && "#{call.tokens} tokens in + out"
      ]
      |> Enum.filter(& &1)
      |> Kernel.++(notes)

    %{
      kind: :llm,
      phase: nil,
      offset_ms: call.start_ms - start_ms,
      duration_ms: call.duration_ms,
      label: fmt_ms(call.duration_ms),
      tooltip: tooltip,
      severity: severity
    }
  end

  defp call_segment(%{kind: :compaction} = call, start_ms, _stats) do
    %{
      kind: :compaction,
      phase: nil,
      offset_ms: call.start_ms - start_ms,
      duration_ms: call.duration_ms,
      label: "Compaction · #{fmt_ms(call.duration_ms)}",
      tooltip: [
        "Compaction model call · #{model_key(call)}",
        "took #{fmt_ms(call.duration_ms)}",
        "Provider call only; compaction preparation and commit are not included.",
        "An enclosing activation includes this interval; wall-clock totals count it once.",
        if(call.round_id,
          do: "Linked to the containing activation interval.",
          else: "No unique containing activation recorded on this page."
        ),
        "status: #{call.status || "unknown"}"
      ],
      severity: if(call.status == "error", do: :error, else: :ok)
    }
  end

  defp call_segment(%{kind: :tool} = call, start_ms, _stats) do
    {severity, notes} = tool_verdict(call)

    tooltip =
      [
        "Tool call · #{call.name}" <> if(call.detail, do: " (#{call.detail})", else: ""),
        "took #{fmt_ms(call.duration_ms)}",
        call.async && "ran in the background"
      ]
      |> Enum.filter(& &1)
      |> Kernel.++(notes)

    %{
      kind: :tool,
      phase: nil,
      offset_ms: call.start_ms - start_ms,
      duration_ms: call.duration_ms,
      label: fmt_ms(call.duration_ms),
      tooltip: tooltip,
      severity: severity
    }
  end

  defp phase_segment(phase, start_ms) do
    %{
      kind: :phase,
      phase: phase.name,
      offset_ms: phase.start_ms - start_ms,
      duration_ms: phase.duration_ms,
      label: fmt_ms(phase.duration_ms),
      tooltip: phase_tooltip(phase.name, phase.duration_ms),
      severity: :none
    }
  end

  @doc "Human name of a recorded phase, for legends and summaries."
  def phase_title("delivery_wait"), do: "Waiting for activation"
  def phase_title("activation"), do: "Activation"
  def phase_title("miniskill"), do: "Miniskill selection"
  def phase_title("prepare"), do: "Preparing the model call"
  def phase_title("response_commit"), do: "Storing the model's reply"
  def phase_title("tool_commit"), do: "Storing tool results"
  def phase_title("boundary"), do: "Closing the round"
  def phase_title("finalize"), do: "Finishing"
  def phase_title("async_pickup"), do: "Picking up a background result"
  def phase_title("async_commit"), do: "Storing a background result"
  def phase_title("async_config"), do: "Preparing the next round's config"
  def phase_title(other), do: to_string(other)

  defp phase_tooltip("delivery_wait", ms) do
    [
      "#{phase_title("delivery_wait")} · #{fmt_ms(ms)}",
      "from the input's arrival at the runtime to the session actor picking it up"
    ]
  end

  defp phase_tooltip("activation", ms) do
    [
      "#{phase_title("activation")} · #{fmt_ms(ms)}",
      "the session actor waking the session: repair, re-reading it, materializing input, " <>
        "rebuilding the runtime config, committing the activation"
    ]
  end

  defp phase_tooltip("miniskill", ms) do
    [
      "Miniskill selection · #{fmt_ms(ms)}",
      "Decision inference and selected instruction reads. Overlaps configuration refresh; excludes cold catalog prewarming."
    ]
  end

  defp phase_tooltip("prepare", ms) do
    [
      "#{phase_title("prepare")} · #{fmt_ms(ms)}",
      "prompt snapshot, context providers, request assembly, fee-control check — " <>
        "up to the provider dispatch"
    ]
  end

  defp phase_tooltip("response_commit", ms) do
    [
      "#{phase_title("response_commit")} · #{fmt_ms(ms)}",
      "from the model's completion to the assistant turn stored " <>
        "(includes the actor mailbox wait); the tool calls run next"
    ]
  end

  defp phase_tooltip("tool_commit", ms) do
    ["#{phase_title("tool_commit")} · #{fmt_ms(ms)}", "tool results written to the session"]
  end

  defp phase_tooltip("boundary", ms) do
    [
      "#{phase_title("boundary")} · #{fmt_ms(ms)}",
      "the status=idle write that ends a tool round; the continuation is a new round"
    ]
  end

  defp phase_tooltip("finalize", ms) do
    [
      "#{phase_title("finalize")} · #{fmt_ms(ms)} (recorded)",
      "from the model's completion to the final message stored " <>
        "(includes the actor mailbox wait)"
    ]
  end

  defp phase_tooltip("async_pickup", ms) do
    [
      "#{phase_title("async_pickup")} · #{fmt_ms(ms)}",
      "from the background tool finishing to the session read back " <>
        "(includes the actor mailbox wait)"
    ]
  end

  defp phase_tooltip("async_commit", ms) do
    [
      "#{phase_title("async_commit")} · #{fmt_ms(ms)}",
      "the result staged, the workspace committed, the session revision written"
    ]
  end

  defp phase_tooltip("async_config", ms) do
    [
      "#{phase_title("async_config")} · #{fmt_ms(ms)}",
      "waiting for the next round's config build, started alongside the commit, to finish"
    ]
  end

  defp phase_tooltip(other, ms), do: ["#{phase_title(other)} · #{fmt_ms(ms)}"]

  defp gap_segment(offset_ms, duration_ms) do
    %{
      kind: :gap,
      phase: nil,
      offset_ms: offset_ms,
      duration_ms: duration_ms,
      label: fmt_ms(duration_ms),
      tooltip: [
        "Unknown, inside a round · #{fmt_ms(duration_ms)}",
        "between two records of the same round",
        "nothing recorded covers it"
      ],
      severity: :none
    }
  end

  defp settle_segment(offset_ms, duration_ms) do
    %{
      kind: :settle,
      phase: nil,
      offset_ms: offset_ms,
      duration_ms: duration_ms,
      label: fmt_ms(duration_ms),
      tooltip: [
        "Finishing, unrecorded · #{fmt_ms(duration_ms)}",
        "from the last record to the recorded round ending",
        "no finalize phase was recorded for this round"
      ],
      severity: :none
    }
  end

  defp between_segment(offset_ms, duration_ms) do
    %{
      kind: :between,
      phase: nil,
      offset_ms: offset_ms,
      duration_ms: duration_ms,
      label: fmt_ms(duration_ms),
      tooltip: [
        "Between rounds · #{fmt_ms(duration_ms)}",
        "from the previous round's last record to the next round's first",
        "with phases recorded this is the actor being re-scheduled; without them it also " <>
          "hides the commits and the next activation"
      ],
      severity: :none
    }
  end

  defp llm_verdict(call, stats) do
    cond do
      call.status == "error" ->
        {:error, ["FAILED: #{call.error_type || "unknown"}"]}

      call.duration_ms >= @slow_abs_ms ->
        {:warn, ["SLOW: over #{fmt_ms(@slow_abs_ms)}"] ++ stale_note(call)}

      slow_for_model?(call, stats) ->
        %{n: n, median: median, p90: p90} = Map.fetch!(stats, model_key(call))

        {:warn,
         [
           "SLOW for this model: in the slowest 10% of its #{n} calls in the fetched sample " <>
             "(over #{fmt_ms(p90)}) and more than twice the typical #{fmt_ms(median)}"
         ] ++ stale_note(call)}

      # Discarded, not slow: it met neither slow threshold above.
      call.status == "stale" ->
        {:stale, stale_note(call)}

      true ->
        {:ok, []}
    end
  end

  defp stale_note(%{status: "stale"}), do: ["response discarded: newer input arrived"]
  defp stale_note(_), do: []

  defp slow_for_model?(call, stats) do
    case Map.get(stats, model_key(call)) do
      %{n: n, median: median, p90: p90} when n >= @slow_min_samples ->
        call.duration_ms >= p90 and call.duration_ms >= 2 * median

      _ ->
        false
    end
  end

  defp tool_verdict(call) do
    cond do
      call.status == "error" and call.error_type == "capped" ->
        {:warn, ["result cut short (capped)"]}

      call.status == "error" ->
        {:error, ["BROKE: #{call.error_type || "error"}"]}

      call.status == "guidance" ->
        {:warn, ["sent back to the model: #{call.guidance_reason || "guidance"}"]}

      call.status == "cancelled" ->
        {:warn, ["cancelled"]}

      true ->
        {:ok, []}
    end
  end

  # ------------------------------------------------------------- chains

  # Within a session, sort rounds by start and link each to the chain it
  # belongs to. Each chain becomes one lane; time between two linked rounds
  # that no record covers is a `:between` segment.
  defp chains(rounds) do
    rounds
    |> Enum.group_by(& &1.session_id)
    |> Enum.flat_map(fn {_session, session_rounds} ->
      session_rounds
      |> Enum.sort_by(&{&1.start_ms, &1.round_id})
      |> Enum.reduce([], fn round, acc ->
        case acc do
          [chain | rest] ->
            if linked?(chain, round),
              do: [append_round(chain, round) | rest],
              else: [new_chain(round) | acc]

          [] ->
            [new_chain(round)]
        end
      end)
      |> Enum.map(&finish_chain/1)
    end)
  end

  # Two keys decide exactly. A missing key on either side (rows from before
  # phase telemetry, or a lost phase row) falls back to the time heuristic.
  defp linked?(%{activation_key: chain_key}, %{activation_key: round_key})
       when is_binary(chain_key) and is_binary(round_key),
       do: chain_key == round_key

  defp linked?(%{terminal: nil, end_ms: prev_end}, round),
    do: round.start_ms >= prev_end and round.start_ms - prev_end <= @continuation_max_gap_ms

  defp linked?(_chain, _round), do: false

  defp new_chain(round) do
    %{
      lane_id: round.round_id,
      session_id: round.session_id,
      tenant_id: round.tenant_id,
      group_id: round.group_id,
      agent_id: round.agent_id,
      start_ms: round.start_ms,
      end_ms: round.end_ms,
      terminal: round.terminal,
      activation_key: round.activation_key,
      round_ids: [round.round_id],
      segments: round.segments
    }
  end

  defp append_round(chain, round) do
    lead = round.start_ms - chain.end_ms
    shift = round.start_ms - chain.start_ms

    shifted = Enum.map(round.segments, &%{&1 | offset_ms: &1.offset_ms + shift})

    between = if lead >= @gap_min_ms, do: [between_segment(shift - lead, lead)], else: []

    %{
      chain
      | end_ms: max(chain.end_ms, round.end_ms),
        terminal: round.terminal,
        activation_key: chain.activation_key || round.activation_key,
        round_ids: [round.round_id | chain.round_ids],
        segments: chain.segments ++ between ++ shifted
    }
  end

  # An unrecorded tail of one round can overlap a recorded next round.
  # Unknown means uncovered in the whole activation, not just that round.
  defp uncovered_unknowns(segments) do
    {unknown, recorded} = Enum.split_with(segments, &(&1.kind in [:gap, :between, :settle]))
    covered = Enum.map(recorded, &{&1.offset_ms, &1.offset_ms + &1.duration_ms})

    {unknown, _} =
      Enum.map_reduce(unknown, covered, fn seg, covered ->
        pieces =
          Enum.reduce(covered, [{seg.offset_ms, seg.offset_ms + seg.duration_ms}], fn {a, b},
                                                                                      pieces ->
            Enum.flat_map(pieces, fn {from, to} ->
              if b <= from or a >= to do
                [{from, to}]
              else
                Enum.filter([{from, max(from, a)}, {min(to, b), to}], fn {x, y} -> y > x end)
              end
            end)
          end)

        shaped =
          Enum.map(pieces, fn {from, to} ->
            case seg.kind do
              :gap -> gap_segment(from, to - from)
              :between -> between_segment(from, to - from)
              :settle -> settle_segment(from, to - from)
            end
          end)

        {shaped, pieces ++ covered}
      end)

    Enum.sort_by(recorded ++ List.flatten(unknown), &{&1.offset_ms, -&1.duration_ms})
  end

  defp finish_chain(chain) do
    chain = %{chain | segments: uncovered_unknowns(chain.segments)}
    total = chain.end_ms - chain.start_ms
    sum = fn kind -> chain.segments |> Enum.filter(&(&1.kind == kind)) |> sum_ms() end

    Map.merge(chain, %{
      kind: :activation,
      round_ids: Enum.reverse(chain.round_ids),
      rounds: length(chain.round_ids),
      total_ms: total,
      llm_ms: sum.(:llm),
      tool_ms: sum.(:tool),
      between_ms: sum.(:between),
      gap_ms: sum.(:gap),
      settle_ms: sum.(:settle),
      delivery_ms: phase_ms(chain.segments, ["delivery_wait"]),
      activation_ms: phase_ms(chain.segments, ["activation"]),
      prepare_ms: phase_ms(chain.segments, ["prepare"]),
      miniskill_ms: phase_ms(chain.segments, ["miniskill"]),
      commit_ms: phase_ms(chain.segments, @commit_phases),
      finalize_ms: phase_ms(chain.segments, ["finalize"]),
      async_ms: phase_ms(chain.segments, @async_phases),
      wall: wall_partition(chain.segments),
      wrapped?: total > @cap_ms
    })
  end

  defp phase_ms(segments, names),
    do: segments |> Enum.filter(&(&1.kind == :phase and &1.phase in names)) |> sum_ms()

  # Wall clock split by category: every millisecond of the lane counted
  # ONCE. Records can overlap (a background tool under a model call, two
  # parallel tools), and their summed durations — the "work" figures
  # above — legitimately exceed the lane. Overlaps are settled by priority:
  # a model call owns its time over anything else, then the runtime's own
  # phases, then tool calls (background waits are what usually overlap),
  # and the unknown stretches last (exclusive by construction anyway). So
  # the parts always add up to the lane's total.
  @wall_categories ~w(miniskill compaction llm tool delivery activation prepare commit finalize async unknown)a
  @wall_priority %{
    miniskill: 0.5,
    compaction: -1,
    llm: 0,
    delivery: 1,
    activation: 1,
    prepare: 1,
    commit: 1,
    finalize: 1,
    async: 1,
    tool: 2,
    unknown: 3
  }

  defp wall_partition(segments) do
    empty = Map.new(@wall_categories, &{&1, 0})

    segments
    |> Enum.map(&{wall_category(&1), &1.offset_ms, &1.offset_ms + &1.duration_ms})
    |> Enum.sort_by(fn {cat, from, _to} -> {@wall_priority[cat], from} end)
    |> Enum.reduce({empty, []}, fn {cat, from, to}, {acc, claimed} ->
      {owned, claimed} = claim(claimed, from, to)
      {Map.update!(acc, cat, &(&1 + owned)), claimed}
    end)
    |> elem(0)
  end

  # Take [from, to) minus the already-claimed intervals: returns the length
  # actually owned and the claimed list with this interval merged in.
  defp claim(claimed, from, to) when to <= from, do: {0, claimed}

  defp claim(claimed, from, to) do
    overlap =
      claimed
      |> Enum.map(fn {a, b} -> max(min(b, to) - max(a, from), 0) end)
      |> Enum.sum()

    {max(to - from - overlap, 0), merge_interval(claimed, {from, to})}
  end

  # Claimed intervals stay disjoint and sorted, so the overlap sum above is
  # exact (no double counting between claimed pieces).
  defp merge_interval(claimed, {from, to}) do
    {touching, apart} = Enum.split_with(claimed, fn {a, b} -> a <= to and b >= from end)

    merged =
      {Enum.min([from | Enum.map(touching, &elem(&1, 0))]),
       Enum.max([to | Enum.map(touching, &elem(&1, 1))])}

    Enum.sort([merged | apart])
  end

  defp wall_category(%{kind: :phase, phase: "miniskill"}), do: :miniskill
  defp wall_category(%{kind: :compaction}), do: :compaction
  defp wall_category(%{kind: :llm}), do: :llm
  defp wall_category(%{kind: :tool}), do: :tool
  defp wall_category(%{kind: :phase, phase: "delivery_wait"}), do: :delivery
  defp wall_category(%{kind: :phase, phase: "activation"}), do: :activation
  defp wall_category(%{kind: :phase, phase: "prepare"}), do: :prepare
  defp wall_category(%{kind: :phase, phase: "finalize"}), do: :finalize
  defp wall_category(%{kind: :phase, phase: phase}) when phase in @async_phases, do: :async
  defp wall_category(%{kind: :phase}), do: :commit
  defp wall_category(_unknown), do: :unknown

  defp sum_ms(segments), do: segments |> Enum.map(& &1.duration_ms) |> Enum.sum()

  # ----------------------------------------------------------------- totals

  # Activation lanes only: an external session has no rounds, no ending
  # and no unknown time to account for, so it is counted apart.
  defp summary(all_lanes) do
    {sessions, lanes} = Enum.split_with(all_lanes, &(&1.kind == :session))
    segments = Enum.flat_map(lanes, & &1.segments)
    llm = Enum.filter(segments, &(&1.kind == :llm))
    tools = Enum.filter(segments, &(&1.kind == :tool))
    total_ms = lanes |> Enum.map(& &1.total_ms) |> Enum.sum()
    lane_sum = fn key -> lanes |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end
    between_ms = lane_sum.(:between_ms)
    gap_ms = lane_sum.(:gap_ms)
    settle_ms = lane_sum.(:settle_ms)
    unknown_ms = between_ms + gap_ms + settle_ms
    delivery_ms = lane_sum.(:delivery_ms)
    activation_ms = lane_sum.(:activation_ms)
    prepare_ms = lane_sum.(:prepare_ms)
    miniskill_ms = lane_sum.(:miniskill_ms)
    commit_ms = lane_sum.(:commit_ms)
    finalize_ms = lane_sum.(:finalize_ms)
    async_ms = lane_sum.(:async_ms)
    llm_ms = sum_ms(llm)
    tool_ms = sum_ms(tools)

    # Exclusive wall-clock split for the breakdown bar (see wall_partition/1);
    # the *_ms figures above are summed work and may exceed total_ms.
    wall =
      Enum.reduce(lanes, %{}, fn lane, acc ->
        Map.merge(acc, lane.wall, fn _k, a, b -> a + b end)
      end)

    wall_pct = fn key -> share(Map.get(wall, key, 0), total_ms) end

    # Every unrecorded kind competes for "longest": finishing included.
    longest =
      lanes
      |> Enum.flat_map(fn lane ->
        lane.segments
        |> Enum.filter(&(&1.kind in [:between, :gap, :settle]))
        |> Enum.map(&{&1.duration_ms, &1.kind, lane})
      end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    %{
      lanes: length(lanes),
      session_lanes: length(sessions),
      session_tool_calls:
        sessions |> Enum.flat_map(& &1.segments) |> Enum.count(&(&1.kind == :tool)),
      rounds: lanes |> Enum.map(& &1.rounds) |> Enum.sum(),
      multi_round: Enum.count(lanes, &(&1.rounds > 1)),
      keyed: Enum.count(lanes, &is_binary(&1.activation_key)),
      llm_calls: length(llm),
      # :warn on a model call means exactly "slow"; stale has its own verdict.
      llm_slow: Enum.count(llm, &(&1.severity == :warn)),
      llm_stale: Enum.count(llm, &(&1.severity == :stale)),
      llm_failed: Enum.count(llm, &(&1.severity == :error)),
      tool_calls: length(tools),
      tool_failed: Enum.count(tools, &(&1.severity == :error)),
      total_ms: total_ms,
      llm_ms: llm_ms,
      tool_ms: tool_ms,
      between_ms: between_ms,
      gap_ms: gap_ms,
      settle_ms: settle_ms,
      unknown_ms: unknown_ms,
      delivery_ms: delivery_ms,
      activation_ms: activation_ms,
      prepare_ms: prepare_ms,
      miniskill_ms: miniskill_ms,
      commit_ms: commit_ms,
      finalize_ms: finalize_ms,
      async_ms: async_ms,
      phase_ms:
        miniskill_ms + delivery_ms + activation_ms + prepare_ms + commit_ms + finalize_ms +
          async_ms,
      llm_pct: share(llm_ms, total_ms),
      tool_pct: share(tool_ms, total_ms),
      unknown_pct: share(unknown_ms, total_ms),
      between_pct: share(between_ms, total_ms),
      gap_pct: share(gap_ms, total_ms),
      settle_pct: share(settle_ms, total_ms),
      delivery_pct: share(delivery_ms, total_ms),
      activation_pct: share(activation_ms, total_ms),
      prepare_pct: share(prepare_ms, total_ms),
      miniskill_pct: share(miniskill_ms, total_ms),
      commit_pct: share(commit_ms, total_ms),
      finalize_pct: share(finalize_ms, total_ms),
      async_pct: share(async_ms, total_ms),
      phase_pct:
        share(
          miniskill_ms + delivery_ms + activation_ms + prepare_ms + commit_ms + finalize_ms +
            async_ms,
          total_ms
        ),
      wall: %{
        parallel_ms: lanes |> Enum.map(&parallel_ms(&1.segments)) |> Enum.sum(),
        compaction_pct: wall_pct.(:compaction),
        llm_pct: wall_pct.(:llm),
        tool_pct: wall_pct.(:tool),
        delivery_pct: wall_pct.(:delivery),
        activation_pct: wall_pct.(:activation),
        prepare_pct: wall_pct.(:prepare),
        miniskill_pct: wall_pct.(:miniskill),
        commit_pct: wall_pct.(:commit),
        finalize_pct: wall_pct.(:finalize),
        async_pct: wall_pct.(:async),
        unknown_pct: wall_pct.(:unknown),
        # Summed work minus wall clock: the overlap parallel records hide.
        overlap_ms:
          max(
            llm_ms + tool_ms + miniskill_ms + delivery_ms + activation_ms + prepare_ms + commit_ms +
              finalize_ms + async_ms + unknown_ms - total_ms,
            0
          )
      },
      longest_unknown:
        case longest do
          {ms, kind, lane} -> %{ms: ms, kind: kind, lane: lane}
          nil -> nil
        end
    }
  end

  defp share(_part, 0), do: nil
  defp share(part, total), do: Float.round(part * 100 / total, 1)
end
