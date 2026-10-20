defmodule Salix.Bindings.MeetingSummaryReplayTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.MeetingSummary
  alias Salix.Bindings.MeetingSummaryReplay, as: Replay

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_enabled = SystemsRuntime.get_env(:salix_web, :meeting_notes_online_replay_enabled)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)

      if is_nil(previous_enabled) do
        SystemsRuntime.delete_env(:salix_web, :meeting_notes_online_replay_enabled)
      else
        SystemsRuntime.put_env(:salix_web, :meeting_notes_online_replay_enabled, previous_enabled)
      end
    end)

    :ok
  end

  test "online plan replay reads only a terminal meeting in the requested group" do
    SystemsRuntime.put_env(:salix_web, :meeting_notes_online_replay_enabled, true)
    meeting_id = "meeting-private-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    sentinel = "PRIVATE_ONLINE_REPLAY_SENTINEL"

    assert {:ok, _doc, _etag} =
             SalixMeet.Store.create_once(meeting_id,
               state: %{
                 "group_id" => "group-private",
                 "status" => "done",
                 "meeting_agent_id" => "meeting-agent",
                 "title" => "Private replay",
                 "joined_at" => 1_000,
                 "left_at" => 1_900,
                 "captions" =>
                   for index <- 0..59 do
                     %{
                       "timestamp" => 1_000 + index * 15,
                       "speaker" => "Speaker #{rem(index, 3) + 1}",
                       "text" => "line #{index} #{sentinel}"
                     }
                   end
               }
             )

    assert {:ok, report} = Replay.run_existing("group-private", meeting_id)
    assert report["mode"] == "plan_only"
    assert report["source_mode"] == "stored_captions_structure_only"
    assert report["passed"]
    assert report["slicing"]["planned_chunks"] == 3
    refute Jason.encode!(report) =~ sentinel

    assert {:error, :meeting_not_found} = Replay.run_existing("other-group", meeting_id)

    assert {:error, :meeting_not_found} =
             Replay.run_existing("group-private", "meeting-does-not-exist")
  end

  test "builds a production-shaped replay without copying raw text into its report" do
    transcript = transcript_fixture("PRIVATE_NEVER_REPORT_THIS", 90)

    assert {:ok, replay} =
             Replay.build_case(%{"transcript" => transcript, "duration_seconds" => 5_621},
               agent_id: "replay-agent"
             )

    report_json = Jason.encode!(replay.report)
    refute report_json =~ "PRIVATE_NEVER_REPORT_THIS"
    assert replay.report["source"]["characters"] == String.length(transcript)
    assert replay.report["source"]["lines"] == 60
    assert replay.report["source"]["timecodes"] == 60
    assert replay.report["source"]["duration_seconds"] == 5_621
    assert replay.report["source"]["fingerprint"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert replay.report["slicing"]["passed"]
    assert replay.report["slicing"]["planned_chunks"] == 19
    assert replay.report["slicing"]["assigned_lines"] == 131
    assert replay.report["slicing"]["manifest_fingerprint"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert Enum.all?(replay.report["slicing"]["checks"], & &1["passed"])
    assert length(replay.report["replay"]["chunk_probe_ids"]) == 57
    assert length(replay.report["replay"]["source_proof_ids"]) == 54

    augmented = replay.context["transcript"]
    assert augmented =~ replay.probes.head_decision
    assert augmented =~ replay.probes.middle_action
    assert augmented =~ replay.probes.late_action
    assert augmented =~ replay.probes.weak_suggestion
    assert augmented =~ replay.probes.resolved_action
    assert augmented =~ replay.probes.rejected_decision
    assert augmented =~ replay.probes.negative_decision
    assert augmented =~ replay.probes.cancelled_action
    assert augmented =~ replay.probes.rejected_action
    assert augmented =~ replay.probes.superseded_action
    assert augmented =~ replay.probes.replacement_action
    assert augmented =~ replay.chunk_probes[0].head
    assert augmented =~ replay.chunk_probes[0].middle
    assert augmented =~ replay.chunk_probes[0].tail
    assert augmented =~ replay.chunk_probes[18].head
    assert augmented =~ replay.chunk_probes[18].middle
    assert augmented =~ replay.chunk_probes[18].tail

    assert :binary.match(augmented, replay.probes.head_decision) <
             :binary.match(augmented, replay.probes.middle_action)

    assert :binary.match(augmented, replay.probes.middle_action) <
             :binary.match(augmented, replay.probes.late_action)

    assert replay.context["captions_transcript"] == augmented
    assert replay.context["asr_transcript"] == ""
    assert replay.state["meeting_agent_id"] == "replay-agent"

    chunks = replay.calibration_input.asr_metadata.chunks
    assert Enum.map(chunks, & &1.index) == Enum.to_list(0..18)
    assert Enum.map(chunks, & &1.offset_seconds) == Enum.map(0..18, &(&1 * 300))

    assert Enum.sum(Enum.map(chunks, &line_count(&1.transcript))) ==
             replay.report["slicing"]["assigned_lines"]
  end

  test "requires every chunk and every synthetic probe to survive calibration" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    calibrated = Enum.join(replay.calibration_input.caption_windows, "\n")

    calibration = %{
      "mode" => "chunked",
      "complete" => true,
      "transcript" => calibrated,
      "planned_chunks" => 3,
      "calibrated_chunks" => 3,
      "fallback_chunks" => 0
    }

    evaluation = Replay.calibration_evaluation(calibration, replay)
    assert evaluation["passed"]
    assert Enum.all?(evaluation["checks"], & &1["passed"])
    refute Jason.encode!(evaluation) =~ "ordinary evidence"

    context = Replay.summary_context(replay, calibration)
    assert context["source"] == "replay_calibrated"
    refute context["transcript"] =~ "REPLAY_CHUNK_"
    refute context["captions_transcript"] =~ "REPLAY_CHUNK_"
    refute context["asr_transcript"] =~ "REPLAY_CHUNK_"
    assert context["transcript"] =~ replay.probes.middle_action
    assert context["captions_transcript"] =~ replay.probes.middle_action
    assert context["asr_transcript"] =~ replay.probes.middle_action
    refute Map.has_key?(context["calibration"], "transcript")

    missing_middle = String.replace(calibrated, replay.probes.middle_action, "", global: true)

    failed =
      Replay.calibration_evaluation(
        %{calibration | "transcript" => missing_middle},
        replay
      )

    refute failed["passed"]

    assert %{"name" => "all_probe_evidence_survived_calibration", "passed" => false} in failed[
             "checks"
           ]

    wrong_mode =
      Replay.calibration_evaluation(
        %{calibration | "mode" => "direct", "planned_chunks" => 1, "calibrated_chunks" => 1},
        replay
      )

    refute wrong_mode["passed"]
    assert %{"name" => "forced_chunk_calibration_used", "passed" => false} in wrong_mode["checks"]
    assert %{"name" => "chunk_accounting_complete", "passed" => false} in wrong_mode["checks"]
  end

  test "accepts grounded head, middle, and tail evidence without promoting a weak suggestion" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    summary = %{
      "title" => "Replay",
      "timeline" => valid_timeline(),
      "key_points" => [],
      "action_items" => valid_actions(replay),
      "decisions" => valid_decisions(replay),
      "open_questions" => [],
      "blockers" => []
    }

    evaluation = Replay.evaluate(summary, replay)
    assert evaluation["passed"]
    assert Enum.all?(evaluation["checks"], & &1["passed"])
    assert evaluation["summary"]["action_items"] == 3
    assert evaluation["summary"]["fingerprint"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    refute Jason.encode!(evaluation) =~ "ordinary evidence"
  end

  for {label, step_seconds, duration_seconds, timeline} <- [
        {"an empty or undersized timeline cannot pass a timestamped replay", 15, 900, :empty},
        {"a timeline clustered near the start cannot pass a long replay", 100, 6_000,
         :clustered_at_start},
        {"timeline entries require a nonempty moment summary", 15, 900, :empty_moment_summary}
      ] do
  end

  defp valid_actions(replay) do
    [
      %{
        "description" => "Complete #{replay.probes.middle_action}",
        "owner" => "REPLAY_OWNER_ID",
        "deadline" => "2099-12-31T17:00:00Z"
      },
      %{
        "description" => "Complete #{replay.probes.late_action}",
        "owner" => "REPLAY_OWNER_ID",
        "deadline" => "2099-12-31T17:00:00Z"
      },
      %{
        "description" => "Complete #{replay.probes.replacement_action}",
        "owner" => "REPLAY_OWNER_ID",
        "deadline" => "2099-12-31T17:00:00Z"
      }
    ]
  end

  defp valid_decisions(replay) do
    [valid_head_decision(replay), valid_negative_decision(replay)]
  end

  defp valid_head_decision(replay) do
    "Approved #{replay.probes.head_decision} for REPLAY_SCOPE_BLUE_ONLY"
  end

  defp valid_negative_decision(replay) do
    "#{replay.probes.negative_decision} REPLAY_SCOPE_DISABLED REPLAY_POLARITY_REJECT"
  end

  defp valid_timeline do
    [
      %{"time" => "00:01:30", "summary" => "head"},
      %{"time" => "00:05:30", "summary" => "middle"},
      %{"time" => "00:10:30", "summary" => "middle"},
      %{"time" => "00:13:30", "summary" => "tail"}
    ]
  end

  defp transcript_fixture(secret, step_seconds \\ 15) do
    0..59
    |> Enum.map(fn index ->
      seconds = index * step_seconds
      hours = div(seconds, 3_600)
      minutes = div(rem(seconds, 3_600), 60)
      seconds = rem(seconds, 60)

      time =
        [hours, minutes, seconds]
        |> Enum.map_join(":", &(Integer.to_string(&1) |> String.pad_leading(2, "0")))

      "[#{time}] Speaker #{rem(index, 3) + 1}: line #{index} #{secret}"
    end)
    |> Enum.join("\n")
  end

  defp line_count(""), do: 0
  defp line_count(text), do: text |> String.split("\n") |> length()

  defp fingerprint(text) do
    "sha256:" <> (:crypto.hash(:sha256, text) |> Base.encode16(case: :lower))
  end
end
