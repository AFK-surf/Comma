defmodule SalixWeb.Dashboard.ActivityTimelineTest do
  @moduledoc """
  Pure shaping of activity rows into activation lanes: gaps, chaining of
  continuation rounds, model-call verdicts, clipping and totals.
  """
  use SystemsClock.Case, async: true

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
end
