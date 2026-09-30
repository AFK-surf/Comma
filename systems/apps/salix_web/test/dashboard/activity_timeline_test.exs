defmodule SalixWeb.Dashboard.ActivityTimelineTest do
  @moduledoc """
  Pure shaping of activity rows into activation lanes: gaps, chaining of
  continuation rounds, model-call verdicts, clipping and totals.
  """
  use ExUnit.Case, async: true

  alias SalixWeb.Dashboard.ActivityTimeline

  defp at(offset_ms) do
    ~U[2026-09-04 10:00:00.000Z]
    |> DateTime.add(offset_ms, :millisecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S.%f")
    |> String.slice(0, 23)
  end

  defp row(kind, session, round, offset_ms, duration_ms, extra \\ %{}) do
    Map.merge(
      %{
        "event_kind" => kind,
        "tenant_id" => "t1",
        "group_id" => "g1",
        "salix_agent_id" => "ag-1",
        "session_id" => session,
        "round_id" => round,
        "started_at" => at(offset_ms),
        "duration_ms" => duration_ms,
        "status" => if(kind == "llm", do: "ok", else: "completed"),
        "attempts" => 1,
        "call_index" => nil,
        "name" => if(kind == "llm", do: "openrouter", else: "web_fetch"),
        "model" => if(kind == "llm", do: "haiku", else: nil)
      },
      extra
    )
  end

  defp shape(lane), do: Enum.map(lane.segments, &{&1.kind, &1.offset_ms, &1.duration_ms})

  defp phase(session, round, name, offset_ms, duration_ms, key \\ nil) do
    row("phase", session, round, offset_ms, duration_ms, %{
      "name" => name,
      "status" => "ok",
      "model" => nil,
      "activation_key" => key
    })
  end

  defp phases(lane),
    do: for(%{kind: :phase} = s <- lane.segments, do: {s.phase, s.offset_ms, s.duration_ms})

  test "miniskill time remains visible within overlapping activation work" do
    rows = [
      phase("s1", "r1", "activation", 0, 1_000, "m1"),
      phase("s1", "r1", "miniskill", 100, 600, "m1"),
      row("llm", "s1", "r1", 1_000, 1_000)
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)
    assert {"miniskill", 100, 600} in phases(lane)
    assert summary.miniskill_ms == 600
    assert summary.wall.miniskill_pct == 30.0
    assert summary.wall.activation_pct == 20.0
    assert summary.wall.llm_pct == 50.0
    assert summary.unknown_ms == 0
  end

  test "compaction keeps its own cursor when the containing activation is hidden" do
    rows = [
      row("phase", "old", "r0", 0, 10_000, %{"name" => "activation"}),
      row("compaction", "old", nil, 6_000, 3_000),
      row("llm", "new", "r1", 5_000, 1_000)
    ]

    page = ActivityTimeline.build(rows, lanes: 1)
    assert [%{kind: :session, segments: [%{kind: :compaction}]}] = page.lanes
    assert page.more?
    assert is_integer(page.next_before_ms)

    # The next SQL page retains the newer round and then the old activation,
    # while the compaction already shown is excluded by its own start.
    second = ActivityTimeline.build([Enum.at(rows, 0), Enum.at(rows, 2)], lanes: 1)
    assert [%{session_id: "new"}] = second.lanes
  end

  test "compaction joins its enclosing activation without adding a model round or double-counting wall time" do
    rows = [
      phase("s1", "r1", "activation", 0, 20_230, "input-1"),
      row("compaction", "s1", nil, 2_600, 16_044),
      row("llm", "s1", "r1", 20_230, 3_000)
    ]

    %{lanes: [lane], summary: summary, model_stats: stats} = ActivityTimeline.build(rows)
    assert lane.rounds == 1
    assert lane.total_ms == 23_230
    assert summary.llm_calls == 1
    assert stats["haiku"].n == 1
    assert lane.wall.compaction == 16_044
    assert lane.wall.activation == 4_186
    assert lane.wall.llm == 3_000
    assert Enum.sum(Map.values(lane.wall)) == lane.total_ms

    assert %{offset_ms: 2_600, duration_ms: 16_044, label: "Compaction · " <> _} =
             Enum.find(lane.segments, &(&1.kind == :compaction))
  end

  test "missing, ambiguous or foreign activation evidence leaves compaction explicitly unlinked" do
    compact = row("compaction", "s1", nil, 100, 500)

    for enclosing <- [
          [],
          [phase("s1", "r1", "activation", 0, 1_000), phase("s1", "r2", "activation", 0, 1_000)],
          [Map.put(phase("s1", "r1", "activation", 0, 1_000), "tenant_id", "foreign")]
        ] do
      result = ActivityTimeline.build([compact | enclosing])
      lane = Enum.find(result.lanes, &(&1.kind == :session))
      assert lane.rounds == 0
      assert [%{kind: :compaction, tooltip: tooltip}] = lane.segments
      assert Enum.any?(tooltip, &String.contains?(&1, "No unique containing activation"))
    end
  end

  test "a round lays calls at true offsets and draws the space between them as unknown" do
    rows = [
      row("llm", "s1", "r1", 0, 3_000),
      row("tool", "s1", "r1", 3_400, 200),
      # 50ms after the tool: too small to draw as a gap.
      row("tool", "s1", "r1", 3_650, 100),
      row("run", "s1", "r1", 0, 5_000, %{"status" => "completed"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert shape(lane) == [
             {:llm, 0, 3_000},
             {:gap, 3_000, 400},
             {:tool, 3_400, 200},
             {:tool, 3_650, 100},
             {:settle, 3_750, 1_250}
           ]

    assert lane.terminal == "completed"
    assert lane.rounds == 1
    assert lane.total_ms == 5_000
    assert lane.gap_ms == 400
    assert lane.settle_ms == 1_250
    assert summary.gap_ms == 400
    assert summary.between_ms == 0
    assert summary.settle_ms == 1_250
    # Unknown = gap + finishing: (400 + 1250) / 5000.
    assert summary.unknown_ms == 1_650
    assert summary.unknown_pct == 33.0
    assert summary.gap_pct == 8.0
    assert summary.settle_pct == 25.0
    assert summary.longest_unknown.kind == :settle
  end

  test "finishing alone is unknown time, not zero" do
    # A 1s model call whose round ending is recorded 10s after it started:
    # 9s of finishing that no call covers.
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      row("run", "s1", "r1", 0, 10_000, %{"status" => "completed"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert shape(lane) == [{:llm, 0, 1_000}, {:settle, 1_000, 9_000}]
    assert summary.unknown_pct == 90.0
    assert summary.settle_pct == 90.0
    assert summary.between_pct == 0.0
    assert summary.longest_unknown.kind == :settle
    assert summary.longest_unknown.ms == 9_000
  end

  test "a fast stale response is stale, not slow; a slow stale one is both" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000, %{"status" => "stale"}),
      row("llm", "s2", "r2", 10_000, 61_000, %{"status" => "stale"})
    ]

    %{lanes: lanes, summary: summary} = ActivityTimeline.build(rows)
    by_id = Map.new(lanes, &{hd(&1.round_ids), hd(&1.segments)})

    assert by_id["r1"].severity == :stale
    assert Enum.any?(by_id["r1"].tooltip, &(&1 =~ "discarded"))
    assert by_id["r2"].severity == :warn
    assert Enum.any?(by_id["r2"].tooltip, &(&1 =~ "SLOW"))
    assert Enum.any?(by_id["r2"].tooltip, &(&1 =~ "discarded"))

    assert summary.llm_slow == 1
    assert summary.llm_stale == 1
  end

  test "an unended round and its continuation within two minutes form one lane" do
    rows = [
      row("llm", "s1", "r1", 0, 2_000),
      row("tool", "s1", "r1", 2_000, 500),
      # 2.8s later the continuation call starts; r1 never records an ending.
      row("llm", "s1", "r2", 5_300, 4_000),
      row("run", "s1", "r2", 5_300, 4_100, %{"status" => "completed"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert lane.round_ids == ["r1", "r2"]
    assert lane.rounds == 2
    assert lane.terminal == "completed"
    assert lane.total_ms == 9_400

    assert shape(lane) == [
             {:llm, 0, 2_000},
             {:tool, 2_000, 500},
             {:between, 2_500, 2_800},
             {:llm, 5_300, 4_000},
             {:settle, 9_300, 100}
           ]

    assert lane.between_ms == 2_800
    assert summary.lanes == 1
    assert summary.rounds == 2
    assert summary.multi_round == 1
    assert summary.between_ms == 2_800
    assert summary.longest_unknown.kind == :between
    assert summary.longest_unknown.lane.lane_id == "r1"
  end

  test "no chaining across a recorded ending, beyond two minutes, or across sessions" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      row("run", "s1", "r1", 0, 1_000, %{"status" => "completed"}),
      row("llm", "s1", "r2", 2_000, 1_000),
      row("llm", "s1", "r3", 200_000, 1_000),
      row("llm", "s2", "r4", 3_500, 1_000)
    ]

    %{lanes: lanes} = ActivityTimeline.build(rows)

    assert lanes |> Enum.map(& &1.round_ids) |> Enum.sort() == [["r1"], ["r2"], ["r3"], ["r4"]]
  end

  test "model calls get mechanical verdicts: error, absolute slow, slow for the model" do
    baseline = for i <- 1..5, do: row("llm", "s#{i}", "b#{i}", i * 10_000, 2_000)

    rows =
      baseline ++
        [
          row("llm", "s-slow", "slow", 100_000, 6_000),
          row("llm", "s-verslow", "verslow", 200_000, 61_000),
          row("llm", "s-bad", "bad", 300_000, 500, %{
            "status" => "error",
            "error_type" => "rate_limited"
          }),
          row("llm", "s-retry", "retry", 400_000, 2_100, %{"attempts" => 3})
        ]

    %{lanes: lanes, summary: summary} = ActivityTimeline.build(rows, lanes: 100)
    seg = fn id -> lanes |> Enum.find(&(&1.lane_id == id)) |> Map.fetch!(:segments) |> hd() end
    tip = fn id -> Enum.join(seg.(id).tooltip, " | ") end

    assert seg.("b1").severity == :ok
    assert seg.("slow").severity == :warn
    assert tip.("slow") =~ "SLOW for this model"
    assert seg.("verslow").severity == :warn
    assert tip.("verslow") =~ "SLOW: over 1m 0s"
    assert seg.("bad").severity == :error
    assert tip.("bad") =~ "FAILED: rate_limited"
    assert seg.("retry").severity == :ok
    assert tip.("retry") =~ "3 attempts"

    # Block text is the duration only; the model lives in the hover card.
    assert seg.("slow").label == "6.0s"
    assert tip.("slow") =~ "Model call · haiku"

    assert summary.llm_slow == 2
    assert summary.llm_failed == 1
  end

  test "relative slow tooltip identifies the fetched sample, not only visible lanes" do
    rows =
      for i <- 1..5,
          do: row("llm", "s#{i}", "r#{i}", i * 10_000, if(i == 5, do: 6_000, else: 1_000))

    %{lanes: [lane]} = ActivityTimeline.build(rows, lanes: 1)
    [seg] = lane.segments
    assert seg.severity == :warn
    assert Enum.join(seg.tooltip, " ") =~ "5 calls in the fetched sample"
    refute Enum.join(seg.tooltip, " ") =~ "on this page"
  end

  test "fewer than five calls of a model never earns a relative slow verdict" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      row("llm", "s2", "r2", 10_000, 1_000),
      row("llm", "s3", "r3", 20_000, 30_000)
    ]

    %{lanes: lanes} = ActivityTimeline.build(rows)
    assert Enum.all?(lanes, fn l -> hd(l.segments).severity == :ok end)
  end

  test "tool verdicts: broke, sent back, cut short" do
    rows = [
      row("tool", "s1", "r1", 0, 100, %{"status" => "error", "error_type" => "exception"}),
      row("tool", "s1", "r1", 200, 100, %{
        "status" => "guidance",
        "guidance_reason" => "invalid_params"
      }),
      row("tool", "s1", "r1", 400, 100, %{"status" => "error", "error_type" => "capped"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)
    tools = Enum.filter(lane.segments, &(&1.kind == :tool))

    assert Enum.map(tools, & &1.severity) == [:error, :warn, :warn]
    assert Enum.join(Enum.at(tools, 1).tooltip, " ") =~ "sent back to the model: invalid_params"
    assert Enum.join(Enum.at(tools, 2).tooltip, " ") =~ "cut short"
    assert summary.tool_failed == 1
  end

  test "the lane scale is capped and long activations are flagged as wrapping" do
    rows = [
      row("tool", "s1", "r1", 0, 400_000, %{"async" => true}),
      row("llm", "s2", "r2", 1_000, 3_000)
    ]

    %{lanes: lanes, scale_ms: scale, cap_ms: cap} = ActivityTimeline.build(rows)

    assert scale == cap
    assert Enum.find(lanes, &(&1.lane_id == "r1")).wrapped?
    refute Enum.find(lanes, &(&1.lane_id == "r2")).wrapped?
  end

  test "keeps only the newest lanes and drops the oldest when the feed was truncated" do
    rows = for i <- 1..6, do: row("llm", "s#{i}", "r#{i}", i * 1_000, 500)

    %{lanes: lanes, truncated?: truncated?} = ActivityTimeline.build(rows, lanes: 3, limit: 6)

    assert truncated?
    # r1 (oldest, possibly partial) is dropped first, then the newest 3 kept.
    assert Enum.map(lanes, & &1.lane_id) == ["r6", "r5", "r4"]
  end

  test "reports an older page and hands back the oldest start shown as its cursor" do
    rows = for i <- 1..6, do: row("llm", "s#{i}", "r#{i}", i * 1_000, 500)
    t0_ms = DateTime.to_unix(~U[2026-09-04 10:00:00Z], :millisecond)

    # More lanes than fit: the next page starts before r4's start.
    built = ActivityTimeline.build(rows, lanes: 3)
    assert built.more?
    refute built.truncated?
    assert built.next_before_ms == t0_ms + 4_000

    # A feed that hit its limit has an older page even when every lane fits.
    built = ActivityTimeline.build(rows, lanes: 10, limit: 6)
    assert built.more?
    assert built.next_before_ms == t0_ms + 2_000

    # Everything fits and the feed was not cut: this is the last page.
    built = ActivityTimeline.build(rows, lanes: 10, limit: 100)
    refute built.more?
    assert built.next_before_ms == nil

    assert ActivityTimeline.build([], lanes: 3, limit: 0).next_before_ms == nil
  end

  test "rows without a session or a parseable start are ignored; a call without a round is a session lane" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      row("llm", nil, "r2", 0, 1_000),
      row("llm", "s3", nil, 0, 1_000),
      row("llm", "s4", "r4", 0, 1_000, %{"started_at" => "garbage"})
    ]

    %{lanes: lanes} = ActivityTimeline.build(rows)
    assert Enum.map(lanes, & &1.lane_id) == ["r1", "session:s3"]
    assert Enum.map(lanes, & &1.kind) == [:activation, :session]
  end

  test "an empty feed builds an empty view" do
    assert %{lanes: [], summary: %{lanes: 0, unknown_pct: nil}, scale_ms: 1} =
             ActivityTimeline.build([])
  end

  test "pct is relative to the lane scale" do
    assert ActivityTimeline.pct(500, 2_000) == 25.0
    assert ActivityTimeline.pct(500, 0) == 0.0
  end

  test "recorded phases replace the unknown stretches and lead the round" do
    rows = [
      # The actor woke the session 900ms before Round.run; prepare ran up
      # to the model call; the reply was stored, tools ran, results stored,
      # the round closed. Nothing is left unknown inside the round.
      phase("s1", "r1", "activation", 0, 900, "m1"),
      phase("s1", "r1", "prepare", 900, 300, "m1"),
      row("llm", "s1", "r1", 1_200, 3_000),
      phase("s1", "r1", "response_commit", 4_200, 150, "m1"),
      row("tool", "s1", "r1", 4_350, 500),
      phase("s1", "r1", "tool_batch", 4_350, 500, "m1"),
      phase("s1", "r1", "tool_commit", 4_850, 200, "m1"),
      phase("s1", "r1", "boundary", 5_050, 80, "m1")
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert phases(lane) == [
             {"activation", 0, 900},
             {"prepare", 900, 300},
             {"response_commit", 4_200, 150},
             {"tool_commit", 4_850, 200},
             {"boundary", 5_050, 80}
           ]

    # tool_batch is not drawn (it is the tool calls' own wall clock).
    refute Enum.any?(lane.segments, &(&1.phase == "tool_batch"))

    assert Enum.map(lane.segments, & &1.kind) == [
             :phase,
             :phase,
             :llm,
             :phase,
             :tool,
             :phase,
             :phase
           ]

    assert lane.gap_ms == 0
    assert lane.activation_key == "m1"
    assert lane.activation_ms == 900
    assert lane.prepare_ms == 300
    assert lane.commit_ms == 430
    assert summary.unknown_pct == 0.0
    assert summary.phase_pct == Float.round(1_630 * 100 / 5_130, 1)
    assert summary.keyed == 1
  end

  test "a finalize phase covers the finishing stretch; without it the stretch is unknown" do
    recorded = [
      row("llm", "s1", "r1", 0, 1_000),
      phase("s1", "r1", "finalize", 1_000, 400, "m1"),
      row("run", "s1", "r1", 0, 1_400, %{"status" => "completed"})
    ]

    %{lanes: [lane]} = ActivityTimeline.build(recorded)
    assert shape(lane) == [{:llm, 0, 1_000}, {:phase, 1_000, 400}]
    assert lane.finalize_ms == 400
    assert lane.settle_ms == 0

    unrecorded = [
      row("llm", "s2", "r2", 0, 1_000),
      row("run", "s2", "r2", 0, 1_400, %{"status" => "completed"})
    ]

    %{lanes: [lane]} = ActivityTimeline.build(unrecorded)
    assert shape(lane) == [{:llm, 0, 1_000}, {:settle, 1_000, 400}]
  end

  test "rounds sharing an activation key form one lane even past two minutes; different keys never join" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      phase("s1", "r1", "prepare", 0, 10, "input-A"),
      # Three minutes later but the same input: still one activation.
      row("llm", "s1", "r2", 180_000, 1_000),
      phase("s1", "r2", "activation", 179_500, 500, "input-A"),
      # Right after, a different input within the heuristic window.
      row("llm", "s1", "r3", 181_500, 1_000),
      phase("s1", "r3", "activation", 181_200, 300, "input-B")
    ]

    %{lanes: lanes} = ActivityTimeline.build(rows)

    assert lanes |> Enum.map(& &1.round_ids) |> Enum.sort() == [["r1", "r2"], ["r3"]]
    keyed = Enum.find(lanes, &(&1.rounds == 2))
    assert keyed.activation_key == "input-A"
    # The wait between r1's end and r2's activation is the only unknown.
    assert [%{kind: :between, offset_ms: 1_000, duration_ms: 178_500}] =
             Enum.filter(keyed.segments, &(&1.kind == :between))
  end

  test "a round without a key still joins by the time heuristic during rollout" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      phase("s1", "r1", "prepare", 0, 10, "input-A"),
      row("tool", "s1", "r1", 1_000, 200),
      # Continuation recorded by a build without phase rows.
      row("llm", "s1", "r2", 3_000, 1_000),
      row("run", "s1", "r2", 3_000, 1_100, %{"status" => "completed"})
    ]

    %{lanes: [lane]} = ActivityTimeline.build(rows)
    assert lane.round_ids == ["r1", "r2"]
    assert lane.activation_key == "input-A"
  end

  test "between rounds shrinks to the unrecorded remainder when phases are recorded" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      row("tool", "s1", "r1", 1_000, 200),
      phase("s1", "r1", "tool_commit", 1_200, 300, "k"),
      phase("s1", "r1", "boundary", 1_500, 100, "k"),
      # 400ms of scheduling wait, then the next activation.
      phase("s1", "r2", "activation", 2_000, 600, "k"),
      phase("s1", "r2", "prepare", 2_600, 100, "k"),
      row("llm", "s1", "r2", 2_700, 1_000)
    ]

    %{lanes: [lane]} = ActivityTimeline.build(rows)

    assert shape(lane) == [
             {:llm, 0, 1_000},
             {:tool, 1_000, 200},
             {:phase, 1_200, 300},
             {:phase, 1_500, 100},
             {:between, 1_600, 400},
             {:phase, 2_000, 600},
             {:phase, 2_600, 100},
             {:llm, 2_700, 1_000}
           ]

    assert lane.between_ms == 400

    overlapping = rows ++ [row("run", "s1", "r1", 0, 5_000, %{"status" => "completed"})]
    %{lanes: [overlapping_lane]} = ActivityTimeline.build(overlapping)
    assert overlapping_lane.between_ms == 0
    assert overlapping_lane.settle_ms == 1_700
    assert overlapping_lane.wall.unknown == 1_700
  end

  test "the wall-clock split counts overlapping records once and always adds up to the lane" do
    rows = [
      row("llm", "s1", "r1", 0, 4_000),
      # Two tools in parallel, one of them a long background call that also
      # overlaps the next model call — summed work is 183% of the lane.
      row("tool", "s1", "r1", 4_000, 40_000, %{"async" => true, "name" => "wait_for"}),
      row("tool", "s1", "r1", 22_000, 12_000, %{"name" => "js_run"}),
      row("llm", "s1", "r1", 20_000, 20_000),
      row("run", "s1", "r1", 0, 44_000, %{"status" => "completed"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert lane.total_ms == 44_000
    # Work sums exceed the lane; the wall split does not.
    assert lane.llm_ms + lane.tool_ms == 76_000
    # Model calls own their time (4s + 20s); tools get what is left of
    # the 4s..44s they span (44 - 4 - 20 = 20s); nothing is unknown.
    assert %{llm: 24_000, tool: 20_000, unknown: 0} = lane.wall

    assert Enum.sum(Map.values(lane.wall)) == lane.total_ms

    shares = summary.wall
    assert shares.llm_pct + shares.tool_pct == 100.0
    assert shares.unknown_pct == 0.0
    assert shares.overlap_ms == 76_000 - 44_000
    assert shares.parallel_ms == 20_000

    displayed = ActivityTimeline.rows(lane, 10_000)
    assert Enum.any?(displayed, &(&1.tracks == 3))

    for row <- displayed, {track, segments} <- Enum.group_by(row.segments, & &1.track) do
      assert track < row.tracks

      segments
      |> Enum.sort_by(& &1.offset_ms)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [left, right] ->
        assert left.offset_ms + left.duration_ms <= right.offset_ms
      end)
    end
  end

  test "no between block when a continuation follows within the gap threshold" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      phase("s1", "r1", "boundary", 1_000, 100, "k"),
      phase("s1", "r2", "activation", 1_150, 200, "k"),
      row("llm", "s1", "r2", 1_350, 500)
    ]

    %{lanes: [lane]} = ActivityTimeline.build(rows)
    refute Enum.any?(lane.segments, &(&1.kind == :between))
    assert lane.between_ms == 0
  end

  test "a delivery_wait phase leads the lane and is counted as a recorded phase" do
    rows = [
      phase("s1", "r1", "delivery_wait", 0, 1_500, "m1"),
      phase("s1", "r1", "activation", 1_500, 700, "m1"),
      row("llm", "s1", "r1", 2_200, 1_000),
      phase("s1", "r1", "finalize", 3_200, 200, "m1"),
      row("run", "s1", "r1", 2_200, 1_200, %{"status" => "completed"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert [{"delivery_wait", 0, 1_500}, {"activation", 1_500, 700} | _] = phases(lane)
    assert lane.delivery_ms == 1_500
    assert lane.gap_ms == 0
    assert summary.delivery_ms == 1_500
    assert summary.phase_ms == 1_500 + 700 + 200
    assert summary.wall.delivery_pct == Float.round(1_500 * 100 / 3_400, 1)
    assert summary.unknown_pct == 0.0
  end

  test "settling a background result is three named phases and one summary bucket" do
    # A tool round whose background tool finished at 3.3s: pickup, commit
    # and config cover the stretch up to the continuation's activation, so
    # nothing between the rounds is unknown.
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      phase("s1", "r1", "tool_commit", 1_000, 300, "m1"),
      row("tool", "s1", "r1", 1_300, 2_000, %{"async" => true}),
      phase("s1", "r1", "async_pickup", 3_300, 400, "m1"),
      phase("s1", "r1", "async_commit", 3_700, 1_200, "m1"),
      phase("s1", "r1", "async_config", 4_900, 600, "m1"),
      phase("s1", "r2", "activation", 5_500, 500, "m1"),
      row("llm", "s1", "r2", 6_000, 1_000),
      phase("s1", "r2", "finalize", 7_000, 200, "m1"),
      row("run", "s1", "r2", 6_000, 1_200, %{"status" => "completed"})
    ]

    %{lanes: [lane], summary: summary} = ActivityTimeline.build(rows)

    assert lane.rounds == 2
    assert {"async_pickup", 3_300, 400} in phases(lane)
    assert {"async_commit", 3_700, 1_200} in phases(lane)
    assert {"async_config", 4_900, 600} in phases(lane)
    assert lane.async_ms == 2_200
    assert lane.between_ms == 0
    assert lane.gap_ms == 0
    assert lane.wall.async == 2_200
    assert summary.async_ms == 2_200
    assert summary.async_pct == Float.round(2_200 * 100 / 7_200, 1)
    assert summary.wall.async_pct == summary.async_pct
    assert summary.phase_ms == 300 + 2_200 + 500 + 200
    assert summary.unknown_pct == 0.0

    tip = Enum.find(lane.segments, &(&1.phase == "async_commit")).tooltip
    assert hd(tip) =~ "Storing a background result"
  end

  test "calls take the top tracks and the runtime's phases stay under them" do
    rows = [
      # One round with its phases, then a background tool call that runs
      # across the next model call. The phases fall in holes on the call
      # tracks, and would have been packed into them before.
      phase("s1", "r1", "activation", 0, 500, "k"),
      phase("s1", "r1", "prepare", 500, 500, "k"),
      row("llm", "s1", "r1", 1_000, 4_000),
      row("tool", "s1", "r1", 5_000, 30_000, %{"async" => true, "name" => "wait_for"}),
      phase("s1", "r1", "tool_commit", 5_100, 200, "k"),
      phase("s1", "r2", "activation", 5_400, 300, "k"),
      row("llm", "s1", "r2", 6_000, 5_000),
      phase("s1", "r2", "finalize", 11_000, 400, "k"),
      row("run", "s1", "r2", 0, 36_000, %{"status" => "completed"})
    ]

    %{lanes: [lane]} = ActivityTimeline.build(rows)
    [row0] = ActivityTimeline.rows(lane, 60_000)

    tracks = Map.new(row0.segments, &{{&1.kind, &1.phase, &1.offset_ms}, &1.track})

    # Both model calls on the first track; the background tool that
    # overlaps the second one goes to the next track, never above a call.
    assert tracks[{:llm, nil, 1_000}] == 0
    assert tracks[{:llm, nil, 6_000}] == 0
    assert tracks[{:tool, nil, 5_000}] == 1

    # The band is those two tracks; every phase is drawn below it.
    band = row0.segments |> Enum.filter(&ActivityTimeline.band_kind?(&1.kind))
    band_depth = band |> Enum.map(&(&1.track + 1)) |> Enum.max()
    assert band_depth == 2
    assert row0.tracks > band_depth

    for %{kind: :phase} = seg <- row0.segments do
      assert seg.track >= band_depth
    end

    # Which layer a segment belongs to is public: the page stacks a
    # collapsed lane by it, calls over phases.
    assert ActivityTimeline.band_kind?(:llm)
    assert ActivityTimeline.band_kind?(:tool)
    assert ActivityTimeline.band_kind?(:gap)
    refute ActivityTimeline.band_kind?(:phase)
  end

  test "a lane of sequential calls and unknown stretches is one track deep" do
    rows = [
      row("llm", "s1", "r1", 0, 4_000),
      row("tool", "s1", "r1", 4_200, 2_000),
      row("llm", "s1", "r1", 9_000, 3_000),
      row("run", "s1", "r1", 0, 14_000, %{"status" => "completed"})
    ]

    %{lanes: [lane]} = ActivityTimeline.build(rows)
    [row0] = ActivityTimeline.rows(lane, 60_000)

    # The calls and the two unrecorded stretches between them all share
    # track 0: the lane reads as one strip.
    assert Enum.all?(row0.segments, &(&1.track == 0))
    assert row0.tracks == 1
  end

  test "rows wrap a lane at the scale and split the segment on the boundary" do
    lane = %{
      total_ms: 250_000,
      segments: [
        %{
          kind: :llm,
          phase: nil,
          offset_ms: 0,
          duration_ms: 50_000,
          label: "50.0s",
          tooltip: [],
          severity: :ok
        },
        %{
          kind: :tool,
          phase: nil,
          offset_ms: 50_000,
          duration_ms: 20_000,
          label: "20.0s",
          tooltip: [],
          severity: :ok
        },
        # Crosses the 100s boundary: 90s..130s.
        %{
          kind: :llm,
          phase: nil,
          offset_ms: 90_000,
          duration_ms: 40_000,
          label: "40.0s",
          tooltip: [],
          severity: :ok
        },
        # Zero-length record on the second row.
        %{
          kind: :phase,
          phase: "boundary",
          offset_ms: 150_000,
          duration_ms: 0,
          label: "0ms",
          tooltip: [],
          severity: :none
        },
        %{
          kind: :llm,
          phase: nil,
          offset_ms: 210_000,
          duration_ms: 40_000,
          label: "40.0s",
          tooltip: [],
          severity: :ok
        }
      ]
    }

    rows = ActivityTimeline.rows(lane, 100_000)

    assert Enum.map(rows, & &1.from_ms) == [0, 100_000, 200_000]

    assert Enum.map(Enum.at(rows, 0).segments, &{&1.offset_ms, &1.duration_ms, &1.continued?}) ==
             [{0, 50_000, false}, {50_000, 20_000, false}, {90_000, 10_000, false}]

    assert Enum.map(Enum.at(rows, 1).segments, &{&1.offset_ms, &1.duration_ms, &1.continued?}) ==
             [{0, 30_000, true}, {50_000, 0, false}]

    assert Enum.map(Enum.at(rows, 2).segments, &{&1.offset_ms, &1.duration_ms, &1.continued?}) ==
             [{10_000, 40_000, false}]

    # A lane inside the scale is one row; an empty lane is still one row.
    assert [%{index: 0}] = ActivityTimeline.rows(%{lane | total_ms: 80_000}, 100_000)

    assert [%{index: 0, segments: []}] =
             ActivityTimeline.rows(%{total_ms: 0, segments: []}, 100_000)
  end

  test "calls with a session but no round form an external-session lane, outside the activation totals" do
    rows = [
      row("llm", "s1", "r1", 0, 1_000),
      row("run", "s1", "r1", 0, 1_000, %{"status" => "completed"}),
      row("tool", "s-ext", nil, 200, 300, %{"salix_agent_id" => "ag-ext", "name" => "env.exec"}),
      row("tool", "s-ext", nil, 2_000, 500, %{
        "salix_agent_id" => "ag-ext",
        "name" => "im_api.internal.send_message"
      }),
      # A phase without a round is a malformed record, never a lane.
      phase("s-ext", nil, "activation", 100, 50)
    ]

    %{lanes: lanes, summary: summary} = ActivityTimeline.build(rows)

    # Newest first: the session's first call (200ms) is after the activation's start.
    assert [%{kind: :session} = session, %{kind: :activation} = activation] = lanes
    assert session.lane_id == "session:s-ext"
    assert session.agent_id == "ag-ext"
    assert session.calls == 2
    assert session.rounds == 0
    assert session.terminal == nil
    assert session.total_ms == 2_300
    # The calls at their offsets and nothing between them: no gap, no between, no settle.
    assert shape(session) == [{:tool, 0, 300}, {:tool, 1_800, 500}]
    assert session.tool_ms == 800 and session.llm_ms == 0

    # The activation totals ignore the session lane.
    assert activation.rounds == 1
    assert summary.lanes == 1
    assert summary.session_lanes == 1
    assert summary.session_tool_calls == 2
    assert summary.tool_calls == 0
    assert summary.unknown_ms == 0

    # Rows still wrap a session lane like any other.
    assert [%{index: 0, segments: [_, _]}] = ActivityTimeline.rows(session, 3_000)
  end

  test "an external session that fills the feed is shown as a slice and paged by its oldest call" do
    rows =
      for i <- 0..3_999 do
        row("tool", "s-ext", nil, i * 1_000, 200, %{
          "salix_agent_id" => "ag-ext",
          "name" => "env.exec"
        })
      end

    %{lanes: lanes, more?: more?, next_before_ms: cursor} =
      ActivityTimeline.build(rows, lanes: 40, limit: 4_000)

    # The one lane stays (a slice by design), all 4,000 fetched calls on it,
    # and the next page starts strictly below its oldest call.
    assert [%{kind: :session, calls: 4_000, partial?: true}] = lanes
    assert more?
    assert cursor == to_ms(0)
  end

  test "a feed cut inside an activation drops that activation and keeps the session slice" do
    rows = [
      row("llm", "s1", "r1", 0, 500),
      row("run", "s1", "r1", 0, 500, %{"status" => "completed"}),
      row("tool", "s-ext", nil, 1_000, 100, %{"salix_agent_id" => "ag-ext"}),
      row("tool", "s-ext", nil, 4_000, 100, %{"salix_agent_id" => "ag-ext"}),
      row("llm", "s2", "r2", 6_000, 500),
      row("run", "s2", "r2", 6_000, 500, %{"status" => "completed"})
    ]

    %{lanes: lanes, more?: more?, next_before_ms: cursor} =
      ActivityTimeline.build(rows, lanes: 40, limit: length(rows))

    assert more?
    # r1 owned the oldest row: dropped, back whole on the next page. The cursor
    # is the oldest activation shown (r2), and the session's two calls both lie
    # below it, so they are the next page's too — nothing is lost or doubled.
    assert Enum.map(lanes, & &1.lane_id) == ["r2"]
    assert cursor == to_ms(6_000)
  end

  test "the lane cap hides older activations and trims a session to the calls the next page does not owe" do
    rows = [
      row("tool", "s-ext", nil, 100, 100, %{"salix_agent_id" => "ag-ext"}),
      row("tool", "s-ext", nil, 5_000, 100, %{"salix_agent_id" => "ag-ext"}),
      row("llm", "s1", "r1", 4_000, 500),
      row("run", "s1", "r1", 4_000, 500, %{"status" => "completed"}),
      row("llm", "s2", "r2", 2_000, 500),
      row("run", "s2", "r2", 2_000, 500, %{"status" => "completed"}),
      row("llm", "s3", "r3", 0, 500),
      row("run", "s3", "r3", 0, 500, %{"status" => "completed"})
    ]

    %{lanes: lanes, more?: more?, next_before_ms: cursor} =
      ActivityTimeline.build(rows, lanes: 2, limit: 100)

    # Placed by its newest call (5,000ms) the session leads; r1 follows; r2
    # and r3 are hidden. The cursor is r1's start, the oldest activation shown.
    assert more?
    assert Enum.map(lanes, & &1.lane_id) == ["session:s-ext", "r1"]
    assert cursor == to_ms(4_000)

    # The session's call at 100ms is below the cursor: it belongs to the next
    # page, so this page's slice shows only the call at 5,000ms and says so.
    assert %{calls: 1, partial?: true, start_ms: start} = hd(lanes)
    assert start == to_ms(5_000)
    assert shape(hd(lanes)) == [{:tool, 0, 100}]
  end

  test "a session lane folds the empty rows between two calls a day apart" do
    rows = [
      row("tool", "s-ext", nil, 0, 1_000, %{"salix_agent_id" => "ag-ext"}),
      row("tool", "s-ext", nil, 86_400_000, 1_000, %{"salix_agent_id" => "ag-ext"})
    ]

    %{lanes: [lane]} = ActivityTimeline.build(rows)
    scale = 180_000

    # Two rows, not 481: the first call, then the second with the day folded.
    assert [
             %{index: 0, skipped_ms: 0, segments: [_]},
             %{index: 480, skipped_ms: skipped, segments: [_]}
           ] =
             ActivityTimeline.rows(lane, scale)

    assert skipped == 479 * scale

    # An activation lane still wraps every row.
    %{lanes: [activation]} =
      ActivityTimeline.build([
        row("llm", "s1", "r1", 0, 400_000),
        row("run", "s1", "r1", 0, 400_000, %{"status" => "completed"})
      ])

    assert length(ActivityTimeline.rows(activation, scale)) == 3
  end

  defp to_ms(offset_ms),
    do: DateTime.to_unix(~U[2026-09-04 10:00:00.000Z], :millisecond) + offset_ms
end
