defmodule SalixIM.Triage.StillfailCoordinationTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.StillfailCoordination

  @target %{
    "connect_id" => "conn_1",
    "workspace_id" => "T_AFK",
    "channel_id" => "C0BEVT4QPC7",
    "thread_ts" => "1795064843.000100"
  }

  test "defers with already_handled silence when a connected still.fail session is working the same Slack thread" do
    rows = [
      %{
        station_id: "st_1",
        thread: "SLACK/C0BEVT4QPC7/1795064843.000100",
        title: "Investigate prod latency",
        status: "in_progress",
        attention: nil,
        labels: []
      }
    ]

    result = StillfailCoordination.evaluate(rows, @target, ["Any update?"], false)
    assert result.disposition == :defer_silence_already_handled
    assert result.matched_task_id == "station:st_1:SLACK/C0BEVT4QPC7/1795064843.000100"
    assert result.recommended_recheck_hours == nil
  end

  test "surfaces blocker with bounded follow_up when an overlapping PR session is stopped in need or failed" do
    rows = [
      %{
        "task_id" => "station:st_1:CHAT/1795056015.342000",
        "title" => "Fix PR https://github.com/AFK-surf/Cue/pull/5451",
        "status" => "needs_review",
        "attention" => "need",
        "card_kind" => "login",
        "labels" => ["card:login"]
      }
    ]

    result =
      StillfailCoordination.evaluate(
        rows,
        @target,
        ["Did https://github.com/afk-surf/cue/pull/5451 land yet?"],
        true
      )

    assert result.disposition == :surface_blocker_with_follow_up
    assert result.matched_task_id == "station:st_1:CHAT/1795056015.342000"
    assert result.card_kind == "login"
    assert result.recommended_recheck_hours == 1
  end

  test "returns verify_public_evidence for completed PR sessions and no_overlap for unrelated tasks" do
    rows = [
      %{
        "task_id" => "station:st_1:CHAT/1",
        "title" => "Merged https://github.com/AFK-surf/Cue/pull/5451",
        "status" => "done",
        "attention" => "done",
        "labels" => []
      }
    ]

    assert %{disposition: :verify_public_evidence} =
             StillfailCoordination.evaluate(
               rows,
               @target,
               ["Checking https://github.com/AFK-surf/Cue/pull/5451"],
               true
             )

    assert %{disposition: :no_overlap, matched_task_id: nil} =
             StillfailCoordination.evaluate(
               rows,
               @target,
               ["Checking https://github.com/AFK-surf/Cue/pull/9999"],
               true
             )

    assert StillfailCoordination.clamp_recheck_hours(-5) == 1
    assert StillfailCoordination.clamp_recheck_hours(12) == 12
    assert StillfailCoordination.clamp_recheck_hours(1_200) == 720
  end
end
