defmodule Salix.Bindings.MeetingSummaryReplayTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.MeetingSummary
  alias Salix.Bindings.MeetingSummaryReplay, as: Replay

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_enabled = Application.get_env(:salix_web, :meeting_notes_online_replay_enabled)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous_backend)

      if is_nil(previous_enabled) do
        Application.delete_env(:salix_web, :meeting_notes_online_replay_enabled)
      else
        Application.put_env(:salix_web, :meeting_notes_online_replay_enabled, previous_enabled)
      end
    end)

    :ok
  end

  test "online replay is disabled unless the deployment explicitly enables it" do
    Application.put_env(:salix_web, :meeting_notes_online_replay_enabled, false)

    assert {:error, :online_replay_disabled} =
             Replay.run_existing("group-private", "meeting-private")
  end

  test "online plan replay reads only a terminal meeting in the requested group" do
    Application.put_env(:salix_web, :meeting_notes_online_replay_enabled, true)
    meeting_id = "meeting-private-#{System.unique_integer([:positive])}"
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

  test "model replay case starts from production canonical context, not captions" do
    state = %{
      "meeting_agent_id" => "meeting-agent",
      "title" => "Canonical replay",
      "captions" => [
        %{"timestamp" => 1_000, "speaker" => "Caption", "text" => "CAPTIONS_ONLY_SENTINEL"}
      ]
    }

    canonical = transcript_fixture("RAW_ASR_CANONICAL_SENTINEL", 15)

    context_fun = fn ^state ->
      {:ok,
       %{
         "source" => "raw_asr",
         "transcript" => canonical,
         "duration_seconds" => 900
       }}
    end

    assert {:ok, replay, context} =
             Replay.build_stored_model_case(state, "meeting-canonical", context_fun)

    assert context["source"] == "raw_asr"
    assert replay.state["meeting_id"] == "meeting-canonical"
    assert replay.report["source"]["fingerprint"] == fingerprint(canonical)
    refute replay.context["transcript"] =~ "CAPTIONS_ONLY_SENTINEL"
    assert replay.context["transcript"] =~ "RAW_ASR_CANONICAL_SENTINEL"
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
    assert replay.report["schema_version"] == 6
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

  test "fails calibration when sampled real source evidence is replaced by filler" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("SOURCE_EVIDENCE"),
               "duration_seconds" => 900
             })

    calibrated = Enum.join(replay.calibration_input.caption_windows, "\n")

    proof = replay.source_proofs |> Map.values() |> List.flatten() |> hd()
    [clock, body] = String.split(proof.line, "]", parts: 2)
    filler = clock <> "]" <> Regex.replace(~r/[^\s]/u, body, "x")

    evaluation =
      Replay.calibration_evaluation(
        %{
          "mode" => "chunked",
          "complete" => true,
          "transcript" => String.replace(calibrated, proof.line, filler),
          "planned_chunks" => 3,
          "calibrated_chunks" => 3,
          "fallback_chunks" => 0
        },
        replay
      )

    refute evaluation["passed"]

    assert %{"name" => "sampled_source_evidence_survived_exactly", "passed" => false} in evaluation[
             "checks"
           ]
  end

  test "samples source evidence after production windowing at a chunk boundary" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" =>
                 "[00:04:59] A: opening clause\n" <>
                   "[00:05:01] A: opening clause with continuation",
               "duration_seconds" => 600
             })

    calibration =
      MeetingSummary.calibrate_transcript(
        replay.calibration_input.captions,
        replay.calibration_input.caption_transcript,
        replay.calibration_input.asr_metadata,
        fn captions, _asr -> {:ok, captions} end,
        force_chunk: true,
        caption_anchor_seconds: replay.calibration_input.anchor_seconds
      )

    assert calibration["complete"]
    assert replay.source_proofs |> Map.keys() |> Enum.sort() == [0, 1]

    tampered =
      String.replace(
        calibration["transcript"],
        "[04:59] A: opening clause",
        "[04:59] A: xxxxxxxxxxxxxx"
      )

    refute Replay.calibration_evaluation(%{calibration | "transcript" => tampered}, replay)[
             "passed"
           ]
  end

  test "fails calibration when one planned chunk checkpoint disappears" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    calibrated = Enum.join(replay.calibration_input.caption_windows, "\n")

    missing_checkpoint =
      calibrated
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, replay.chunk_probes[1].tail))
      |> Enum.join("\n")

    evaluation =
      Replay.calibration_evaluation(
        %{
          "mode" => "chunked",
          "complete" => true,
          "transcript" => missing_checkpoint,
          "planned_chunks" => 3,
          "calibrated_chunks" => 3,
          "fallback_chunks" => 0
        },
        replay
      )

    refute evaluation["passed"]

    assert %{
             "name" => "every_chunk_head_middle_tail_checkpoint_survived_once",
             "passed" => false
           } in evaluation[
             "checks"
           ]
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

  test "fails when late evidence is lost or a weak suggestion becomes an action" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    summary = %{
      "title" => "Replay",
      "timeline" => [
        %{"time" => "00:13:30", "summary" => "tail"},
        %{"time" => "00:10:30", "summary" => "middle"},
        %{"time" => "00:05:30", "summary" => "middle"},
        %{"time" => "00:01:30", "summary" => "head"}
      ],
      "action_items" => [
        %{
          "description" => "Promoted #{replay.probes.weak_suggestion}",
          "owner" => "REPLAY_OWNER_ID",
          "deadline" => "2099-12-31T17:00:00Z"
        }
      ],
      "decisions" => valid_decisions(replay)
    }

    evaluation = Replay.evaluate(summary, replay)
    refute evaluation["passed"]

    failed =
      evaluation["checks"]
      |> Enum.reject(& &1["passed"])
      |> Enum.map(& &1["name"])

    assert "middle_action_retained_once" in failed
    assert "late_action_retained_once" in failed
    assert "weak_suggestion_not_promoted" in failed
    assert "timeline_chronological_and_bounded" in failed
  end

  test "fails when any terminal action or rejected proposal survives the meeting end" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    summary = %{
      "title" => "Replay",
      "timeline" => valid_timeline(),
      "action_items" =>
        valid_actions(replay) ++
          [
            %{
              "description" => "Carry forward #{replay.probes.resolved_action}",
              "owner" => "REPLAY_OWNER_ID",
              "deadline" => "2099-12-31T17:00:00Z"
            },
            %{
              "description" => "Carry forward #{replay.probes.cancelled_action}",
              "owner" => "REPLAY_OWNER_ID",
              "deadline" => "2099-12-31T17:00:00Z"
            },
            %{
              "description" => "Carry forward #{replay.probes.rejected_action}",
              "owner" => "REPLAY_OWNER_ID",
              "deadline" => "2099-12-31T17:00:00Z"
            },
            %{
              "description" => "Carry forward #{replay.probes.superseded_action}",
              "owner" => "REPLAY_OWNER_ID",
              "deadline" => "2099-12-31T17:00:00Z"
            }
          ],
      "decisions" => valid_decisions(replay) ++ ["Approved #{replay.probes.rejected_decision}"]
    }

    evaluation = Replay.evaluate(summary, replay)
    refute evaluation["passed"]

    failed =
      evaluation["checks"]
      |> Enum.reject(& &1["passed"])
      |> Enum.map(& &1["name"])

    assert "resolved_action_not_carried_forward" in failed
    assert "cancelled_action_not_carried_forward" in failed
    assert "explicitly_rejected_action_not_carried_forward" in failed
    assert "superseded_action_not_carried_forward" in failed
    assert "rejected_proposal_not_recorded_as_decision" in failed
  end

  test "rejects weak suggestions and rejected proposals promoted across output categories" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    summary = %{
      "title" => "Replay",
      "timeline" => valid_timeline(),
      "action_items" =>
        valid_actions(replay) ++
          [
            %{
              "description" => "Promoted #{replay.probes.rejected_decision}",
              "owner" => "",
              "deadline" => ""
            }
          ],
      "decisions" => valid_decisions(replay) ++ ["Adopted #{replay.probes.weak_suggestion}"]
    }

    evaluation = Replay.evaluate(summary, replay)
    refute evaluation["passed"]

    failed =
      evaluation["checks"]
      |> Enum.reject(& &1["passed"])
      |> Enum.map(& &1["name"])

    assert "weak_suggestion_not_promoted" in failed
    assert "rejected_proposal_not_recorded_as_decision" in failed
  end

  test "fails when the retained decision loses or broadens its explicit scope" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    base = %{
      "title" => "Replay",
      "timeline" => valid_timeline(),
      "action_items" => valid_actions(replay)
    }

    for decision <- [
          "Approved #{replay.probes.head_decision}",
          "Approved #{replay.probes.head_decision} for REPLAY_SCOPE_BLUE_ONLY and " <>
            "REPLAY_SCOPE_ALL_COMPONENTS"
        ] do
      decisions = [decision, valid_negative_decision(replay)]
      evaluation = Replay.evaluate(Map.put(base, "decisions", decisions), replay)
      refute evaluation["passed"]

      assert %{"name" => "head_decision_scope_grounded", "passed" => false} in evaluation[
               "checks"
             ]
    end
  end

  test "fails when a negative decision loses or flips its explicit polarity" do
    assert {:ok, replay} =
             Replay.build_case(%{
               "transcript" => transcript_fixture("ordinary evidence"),
               "duration_seconds" => 900
             })

    base = %{
      "title" => "Replay",
      "timeline" => valid_timeline(),
      "action_items" => valid_actions(replay)
    }

    for negative_decision <- [
          "#{replay.probes.negative_decision} REPLAY_SCOPE_DISABLED",
          "#{replay.probes.negative_decision} REPLAY_SCOPE_DISABLED REPLAY_POLARITY_ADOPT"
        ] do
      decisions = [valid_head_decision(replay), negative_decision]
      evaluation = Replay.evaluate(Map.put(base, "decisions", decisions), replay)
      refute evaluation["passed"]

      assert %{"name" => "negative_decision_polarity_retained", "passed" => false} in evaluation[
               "checks"
             ]
    end
  end

  test "rejects source timecodes that are out of order or outside the declared duration" do
    assert {:error, :transcript_timecodes_invalid} =
             Replay.build_case(%{
               "transcript" => "[00:10] A: later\n[00:05] B: earlier",
               "duration_seconds" => 20
             })

    assert {:error, :transcript_timecodes_invalid} =
             Replay.build_case(%{
               "transcript" => "[00:21] A: outside",
               "duration_seconds" => 20
             })
  end

  test "rebases a monotonic wall-clock transcript to relative meeting time" do
    transcript =
      "[08:25:36] A: opening\n" <>
        "[08:45:00] B: middle\n" <>
        "[09:59:17] A: closing"

    assert {:ok, replay} =
             Replay.build_case(%{"transcript" => transcript, "duration_seconds" => 5_621})

    assert replay.report["source"]["timecode_mode"] == "rebased_absolute"
    assert replay.context["transcript"] =~ "[00:00:00] A: opening"
    assert replay.context["transcript"] =~ "[01:33:41] A: closing"
    refute replay.context["transcript"] =~ "[08:25:36]"

    assert replay.source_proofs
           |> Map.values()
           |> List.flatten()
           |> Enum.any?(&(&1.line == "[00:00] A: opening"))
  end

  test "rejects a duration that could exceed the production chunk cap" do
    assert {:error, :duration_too_large} =
             Replay.build_case(%{
               "transcript" => "[00:00] A: bounded",
               "duration_seconds" => 14_401
             })
  end

  for {label, step_seconds, duration_seconds, timeline} <- [
        {"an empty or undersized timeline cannot pass a timestamped replay", 15, 900, :empty},
        {"a timeline clustered near the start cannot pass a long replay", 100, 6_000,
         :clustered_at_start},
        {"timeline entries require a nonempty moment summary", 15, 900, :empty_moment_summary}
      ] do
    @step_seconds step_seconds
    @duration_seconds duration_seconds
    @timeline timeline
    test label do
      assert {:ok, replay} =
               Replay.build_case(%{
                 "transcript" => transcript_fixture("ordinary evidence", @step_seconds),
                 "duration_seconds" => @duration_seconds
               })

      summary = %{
        "title" => "Replay",
        "timeline" => invalid_timeline(@timeline),
        "action_items" => valid_actions(replay),
        "decisions" => valid_decisions(replay)
      }

      evaluation = Replay.evaluate(summary, replay)
      refute evaluation["passed"]

      assert %{"name" => "timeline_chronological_and_bounded", "passed" => false} in evaluation[
               "checks"
             ]
    end
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

  defp invalid_timeline(:empty), do: []

  defp invalid_timeline(:clustered_at_start) do
    [
      %{"time" => "00:00:10", "summary" => "head"},
      %{"time" => "00:00:20", "summary" => "head"},
      %{"time" => "00:00:30", "summary" => "head"},
      %{"time" => "00:00:40", "summary" => "head"}
    ]
  end

  defp invalid_timeline(:empty_moment_summary) do
    List.replace_at(valid_timeline(), 2, %{"time" => "00:10:30", "summary" => ""})
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
