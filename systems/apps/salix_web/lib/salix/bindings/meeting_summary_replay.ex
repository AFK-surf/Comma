defmodule Salix.Bindings.MeetingSummaryReplay do
  @moduledoc """
  Privacy-safe, no-delivery replay helpers for terminal meeting-note quality.

  Raw input and generated summaries remain in memory. Reports contain only
  fingerprints, bounded metrics, synthetic probe ids, and pass/fail checks.
  """

  alias Salix.Bindings.MeetingSummary
  alias SalixMeet.Store

  @calibration_chunk_seconds 300
  @max_calibration_chunks 48
  @max_duration_seconds @calibration_chunk_seconds * @max_calibration_chunks
  @max_transcript_bytes 2_000_000
  @max_transcript_lines 50_000
  @replay_anchor_seconds 1_000_000

  @probe_owner "REPLAY_OWNER_ID"
  @probe_deadline "2099-12-31T17:00:00Z"
  @probe_decision_scope "REPLAY_SCOPE_BLUE_ONLY"
  @probe_rejected_scope "REPLAY_SCOPE_ALL_COMPONENTS"
  @probe_negative_scope "REPLAY_SCOPE_DISABLED"
  @probe_negative_polarity "REPLAY_POLARITY_REJECT"

  @type replay_case :: %{
          state: map(),
          context: map(),
          calibration_input: map(),
          report: map(),
          probes: map(),
          chunk_probes: map(),
          source_proofs: map()
        }

  @doc "Run a privacy-safe replay for one stored meeting without delivery writes."
  @spec run_existing(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_existing(group_id, meeting_id, opts \\ [])

  def run_existing(group_id, meeting_id, opts)
      when is_binary(group_id) and is_binary(meeting_id) and is_list(opts) do
    with :ok <- ensure_online_replay_enabled(),
         {:ok, doc, _etag} <- Store.get(meeting_id),
         state when is_map(state) <- doc["state"],
         :ok <- validate_stored_meeting(state, group_id) do
      if Keyword.get(opts, :run_model, false) do
        run_production_context_model(state, meeting_id)
      else
        with {:ok, replay_case} <- build_stored_case(state, meeting_id) do
          {:ok,
           replay_case.report
           |> Map.put("mode", "plan_only")
           |> Map.put("source_mode", "stored_captions_structure_only")
           |> put_plan_outcome()}
        end
      end
    else
      {:error, :not_found} -> {:error, :meeting_not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_meeting_state}
    end
  end

  def run_existing(_group_id, _meeting_id, _opts), do: {:error, :invalid_request}

  defp ensure_online_replay_enabled do
    if Application.get_env(:salix_web, :meeting_notes_online_replay_enabled, false) do
      :ok
    else
      {:error, :online_replay_disabled}
    end
  end

  defp validate_stored_meeting(state, group_id) do
    cond do
      text(state, "group_id") != group_id -> {:error, :meeting_not_found}
      text(state, "status") not in ~w(done failed cancelled) -> {:error, :meeting_not_terminal}
      true -> :ok
    end
  end

  defp build_stored_case(state, meeting_id) do
    transcript =
      state
      |> Map.get("captions", [])
      |> List.wrap()
      |> MeetingSummary.build_transcript(positive_integer(state["joined_at"]))

    duration_seconds = stored_duration_seconds(state)

    build_case(
      %{"transcript" => transcript, "duration_seconds" => duration_seconds},
      agent_id: text(state, "meeting_agent_id"),
      title: text(state, "title")
    )
    |> case do
      {:ok, replay_case} ->
        {:ok, put_in(replay_case.state["meeting_id"], meeting_id)}

      error ->
        error
    end
  end

  # Model replay must begin at the production transcript-selection seam. In
  # particular, successful raw/calibrated ASR remains canonical and captions
  # are only validation evidence; using stored captions directly here would
  # reintroduce the ASR fallback regression this acceptance path guards.
  defp run_production_context_model(state, meeting_id) do
    with {:ok, replay_case, context} <- build_stored_model_case(state, meeting_id) do
      {:ok, report} = run_runtime_model(replay_case)

      {:ok,
       report
       |> Map.put("source_mode", "production_context")
       |> Map.put("production_source", text(context, "source"))}
    end
  end

  @doc false
  def build_stored_model_case(state, meeting_id, context_fun \\ &MeetingSummary.prepare_context/1)
      when is_map(state) and is_binary(meeting_id) and is_function(context_fun, 1) do
    with {:ok, context} <- context_fun.(state),
         transcript when is_binary(transcript) <- context["transcript"],
         {:ok, replay_case} <-
           build_case(
             %{
               "transcript" => transcript,
               "duration_seconds" => context["duration_seconds"]
             },
             agent_id: text(state, "meeting_agent_id"),
             title: text(state, "title")
           ) do
      {:ok, put_in(replay_case.state["meeting_id"], meeting_id), context}
    else
      :skip -> {:error, :production_context_unavailable}
      {:error, _reason} = error -> error
      _invalid -> {:error, :production_context_unavailable}
    end
  end

  defp stored_duration_seconds(state) do
    joined_at = positive_integer(state["joined_at"])
    left_at = positive_integer(state["left_at"])

    cond do
      left_at > joined_at -> left_at - joined_at
      true -> caption_duration_seconds(List.wrap(state["captions"]))
    end
  end

  defp caption_duration_seconds(captions) do
    timestamps =
      captions
      |> Enum.map(&positive_integer(value(&1, "timestamp")))
      |> Enum.filter(&(&1 > 0))

    case timestamps do
      [] -> 0
      [_one] -> 1
      values -> max(Enum.max(values) - Enum.min(values), 1)
    end
  end

  defp run_runtime_model(replay_case) do
    input = replay_case.calibration_input
    agent_id = replay_case.state["meeting_agent_id"]

    calibration =
      MeetingSummary.calibrate_transcript(
        input.captions,
        input.caption_transcript,
        input.asr_metadata,
        fn captions, asr -> MeetingSummary.replay_calibrate(agent_id, captions, asr) end,
        caption_anchor_seconds: input.anchor_seconds,
        force_chunk: true
      )

    calibration_evaluation = calibration_evaluation(calibration, replay_case)

    report =
      replay_case.report
      |> Map.put("mode", "model_replay")
      |> Map.put("calibration_evaluation", calibration_evaluation)

    if calibration_evaluation["passed"] do
      context = summary_context(replay_case, calibration)

      case MeetingSummary.replay_summary(replay_case.state, context) do
        {:ok, summary} when is_map(summary) ->
          summary_evaluation = evaluate(summary, replay_case)

          {:ok,
           report
           |> Map.put("summary_evaluation", summary_evaluation)
           |> Map.put("passed", summary_evaluation["passed"] == true)}

        _other ->
          {:ok,
           report
           |> Map.put("passed", false)
           |> Map.put("summary_evaluation", %{
             "passed" => false,
             "outcome" => "invalid_structured_response"
           })}
      end
    else
      {:ok, Map.put(report, "passed", false)}
    end
  end

  defp put_plan_outcome(report) do
    Map.put(report, "passed", get_in(report, ["slicing", "passed"]) == true)
  end

  @doc false
  @spec build_case(map(), keyword()) :: {:ok, replay_case()} | {:error, term()}
  def build_case(input, opts \\ []) when is_map(input) do
    transcript = text(input, "transcript")
    duration_seconds = positive_integer(value(input, "duration_seconds"))
    timecode_normalization = normalize_source_timecodes(transcript, duration_seconds)

    cond do
      transcript == "" ->
        {:error, :transcript_missing}

      duration_seconds == 0 ->
        {:error, :duration_missing}

      duration_seconds > @max_duration_seconds ->
        {:error, :duration_too_large}

      byte_size(transcript) > @max_transcript_bytes or
          line_count(transcript) > @max_transcript_lines ->
        {:error, :transcript_too_large}

      match?({:error, _reason}, timecode_normalization) ->
        {:error, :transcript_timecodes_invalid}

      true ->
        {:ok, normalized_transcript, timecode_mode} = timecode_normalization
        source_fingerprint = fingerprint(transcript)

        probe_suffix =
          source_fingerprint |> String.replace_prefix("sha256:", "") |> binary_part(0, 12)

        probes = probes(probe_suffix)
        chunk_probes = chunk_probes(probe_suffix, duration_seconds)

        # Production assigns captions to five-minute windows before it
        # deduplicates and renders each window. Sample proofs from that exact
        # owner seam so replay cannot silently change chunk ownership, while
        # presentation-only normalization (for example [00:04:30] -> [04:30])
        # still cannot look like evidence loss.
        source_proofs =
          normalized_transcript
          |> build_calibration_input(duration_seconds)
          |> Map.fetch!(:caption_windows)
          |> source_proofs()

        augmented =
          normalized_transcript
          |> inject_probes(duration_seconds, probes)
          |> inject_chunk_probes(duration_seconds, chunk_probes)

        calibration_input = build_calibration_input(augmented, duration_seconds)

        title =
          Keyword.get(opts, :title, "Private meeting replay") |> to_string() |> String.trim()

        context = %{
          "version" => 2,
          "source" => "replay_transcript",
          "transcript" => augmented,
          "transcript_fingerprint" => fingerprint(augmented),
          "captions_transcript" => augmented,
          "captions_fingerprint" => fingerprint(augmented),
          "asr_transcript" => "",
          "asr_fingerprint" => fingerprint(""),
          "duration_seconds" => duration_seconds
        }

        report = %{
          "schema_version" => 6,
          "source" => %{
            "fingerprint" => source_fingerprint,
            "characters" => String.length(transcript),
            "bytes" => byte_size(transcript),
            "lines" => line_count(transcript),
            "timecodes" => timecode_count(transcript),
            "timecode_mode" => timecode_mode,
            "duration_seconds" => duration_seconds
          },
          "replay" => %{
            "fingerprint" => context["transcript_fingerprint"],
            "characters" => String.length(augmented),
            "lines" => line_count(augmented),
            "probe_ids" => probes |> Map.values() |> Enum.sort(),
            "chunk_probe_ids" => chunk_probe_markers(chunk_probes) |> Enum.sort(),
            "source_proof_ids" => source_proof_ids(source_proofs)
          },
          "slicing" => slicing_report(calibration_input, probes, chunk_probes)
        }

        {:ok,
         %{
           state: %{
             "meeting_id" => "meeting-notes-replay-#{probe_suffix}",
             "meeting_agent_id" => Keyword.get(opts, :agent_id, ""),
             "title" => if(title == "", do: "Private meeting replay", else: title),
             "captions" => []
           },
           context: context,
           calibration_input: calibration_input,
           report: report,
           probes: probes,
           chunk_probes: chunk_probes,
           source_proofs: source_proofs
         }}
    end
  end

  @doc false
  def calibration_evaluation(calibration, replay_case)
      when is_map(calibration) and is_map(replay_case) do
    transcript = text(calibration, "transcript")
    probes = replay_case.probes
    expected_chunks = length(replay_case.calibration_input.asr_metadata.chunks)

    checks = [
      check("forced_chunk_calibration_used", calibration["mode"] == "chunked"),
      check("all_chunks_calibrated", calibration["complete"] == true),
      check(
        "chunk_accounting_complete",
        positive_integer(calibration["planned_chunks"]) == expected_chunks and
          calibration["planned_chunks"] == calibration["calibrated_chunks"] and
          calibration["fallback_chunks"] == 0
      ),
      check(
        "all_probe_evidence_survived_calibration",
        Enum.all?(probes, fn {name, marker} ->
          count_occurrences(transcript, marker) == expected_probe_occurrences(name)
        end)
      ),
      check(
        "sampled_source_evidence_survived_exactly",
        Enum.all?(source_proof_entries(replay_case.source_proofs), fn proof ->
          exact_line_count(transcript, proof.line) == proof.occurrences
        end)
      ),
      check(
        "every_chunk_head_middle_tail_checkpoint_survived_once",
        Enum.all?(chunk_probe_markers(replay_case.chunk_probes), fn marker ->
          chunk_probe_line_count(transcript, marker) == 1
        end)
      ),
      check(
        "calibrated_timeline_chronological_and_bounded",
        transcript_timecodes_valid?(transcript, replay_case.context["duration_seconds"])
      )
    ]

    %{
      "passed" => Enum.all?(checks, & &1["passed"]),
      "checks" => checks,
      "mode" => text(calibration, "mode"),
      "planned_chunks" => calibration["planned_chunks"] || 0,
      "calibrated_chunks" => calibration["calibrated_chunks"] || 0,
      "fallback_chunks" => calibration["fallback_chunks"] || 0,
      "transcript_fingerprint" => fingerprint(transcript),
      "characters" => String.length(transcript),
      "lines" => line_count(transcript)
    }
  end

  @doc false
  def summary_context(replay_case, calibration)
      when is_map(replay_case) and is_map(calibration) do
    input = replay_case.calibration_input

    transcript =
      strip_chunk_probe_lines(text(calibration, "transcript"), replay_case.chunk_probes)

    captions = strip_chunk_probe_lines(input.caption_transcript, replay_case.chunk_probes)
    asr = strip_chunk_probe_lines(input.asr_metadata.transcript, replay_case.chunk_probes)

    replay_case.context
    |> Map.merge(%{
      "source" => "replay_calibrated",
      "transcript" => transcript,
      "transcript_fingerprint" => fingerprint(transcript),
      "captions_transcript" => captions,
      "captions_fingerprint" => fingerprint(captions),
      "asr_transcript" => asr,
      "asr_fingerprint" => fingerprint(asr),
      "calibration" => Map.delete(calibration, "transcript")
    })
  end

  defp build_calibration_input(transcript, duration_seconds) do
    entries = timestamped_entries(transcript)

    captions =
      Enum.map(entries, fn entry ->
        {speaker, text} = caption_parts(entry.line)

        %{
          "speaker" => speaker,
          "text" => text,
          "timestamp" => @replay_anchor_seconds + entry.seconds,
          "source" => "replay_caption"
        }
      end)

    chunks = calibration_chunks(entries, duration_seconds)

    {:ok, caption_windows} =
      MeetingSummary.calibration_caption_windows(
        captions,
        @replay_anchor_seconds,
        chunks,
        duration_seconds
      )

    %{
      anchor_seconds: @replay_anchor_seconds,
      entries: entries,
      captions: captions,
      caption_transcript: MeetingSummary.build_transcript(captions, @replay_anchor_seconds),
      caption_windows: caption_windows,
      asr_metadata: %{
        transcript: entries |> Enum.map_join("\n", & &1.line),
        duration_seconds: duration_seconds,
        chunks: chunks
      }
    }
  end

  defp timestamped_entries(transcript) do
    {entries, _last_seconds} =
      transcript
      |> String.split("\n")
      |> Enum.reduce({[], 0}, fn line, {entries, last_seconds} ->
        line = String.trim(line)
        seconds = line_timecode(line) || last_seconds

        if line == "" do
          {entries, seconds}
        else
          {[%{line: line, seconds: seconds} | entries], seconds}
        end
      end)

    Enum.reverse(entries)
  end

  defp caption_parts(line) do
    body = Regex.replace(~r/^\s*\[(?:\d+:)?[0-5]\d:[0-5]\d\]\s*/, line, "")

    case String.split(body, ":", parts: 2) do
      [speaker, text] when byte_size(text) > 0 ->
        {blank_default(String.trim(speaker), "Replay Source"), String.trim(text)}

      _ ->
        {"Replay Source", body}
    end
  end

  defp calibration_chunks(entries, duration_seconds) do
    chunk_count = planned_chunk_count(duration_seconds)
    last_index = chunk_count - 1

    grouped =
      Enum.group_by(entries, fn entry ->
        min(div(entry.seconds, @calibration_chunk_seconds), last_index)
      end)

    Enum.map(0..last_index, fn index ->
      %{
        index: index,
        offset_seconds: index * @calibration_chunk_seconds,
        transcript: grouped |> Map.get(index, []) |> Enum.map_join("\n", & &1.line)
      }
    end)
  end

  defp slicing_report(input, probes, chunk_probes) do
    chunks = input.asr_metadata.chunks

    manifest_text =
      Enum.map_join(chunks, "\n", fn chunk ->
        "#{chunk.index}:#{chunk.offset_seconds}:#{fingerprint(chunk.transcript)}"
      end)

    assigned_lines =
      chunks
      |> Enum.map(&line_count(&1.transcript))
      |> Enum.sum()

    expected_indexes = Enum.to_list(0..(length(chunks) - 1))

    checks = [
      check(
        "manifest_contiguous",
        Enum.map(chunks, & &1.index) == expected_indexes and
          Enum.map(chunks, & &1.offset_seconds) ==
            Enum.map(expected_indexes, &(&1 * @calibration_chunk_seconds))
      ),
      check("every_replay_line_assigned_once", assigned_lines == length(input.entries)),
      check(
        "all_probe_evidence_assigned",
        Enum.all?(probes, fn {name, marker} ->
          count_chunk_occurrences(chunks, marker) == expected_probe_occurrences(name)
        end)
      ),
      check(
        "every_planned_chunk_has_head_middle_tail_checkpoints",
        Enum.all?(chunk_probes, fn {index, markers} ->
          Enum.all?(Map.values(markers), fn marker ->
            count_occurrences(Enum.at(chunks, index).transcript, marker) == 1 and
              count_chunk_occurrences(chunks, marker) == 1
          end)
        end)
      )
    ]

    %{
      "passed" => Enum.all?(checks, & &1["passed"]),
      "chunk_seconds" => @calibration_chunk_seconds,
      "planned_chunks" => length(chunks),
      "nonempty_chunks" => Enum.count(chunks, &(String.trim(&1.transcript) != "")),
      "assigned_lines" => assigned_lines,
      "caption_lines" => line_count(input.caption_transcript),
      "manifest_fingerprint" => fingerprint(manifest_text),
      "checks" => checks
    }
  end

  defp count_chunk_occurrences(chunks, marker) do
    chunks
    |> Enum.map(&count_occurrences(&1.transcript, marker))
    |> Enum.sum()
  end

  @doc false
  @spec evaluate(map(), replay_case()) :: map()
  def evaluate(summary, replay_case) when is_map(summary) and is_map(replay_case) do
    probes = replay_case.probes
    decisions = text_list(summary["decisions"])
    decision_text = Enum.join(decisions, "\n")
    actions = action_items(summary["action_items"])
    all_summary_text = summary_text(summary)

    checks = [
      check(
        "head_decision_retained_once",
        count_occurrences(decision_text, probes.head_decision) == 1
      ),
      check(
        "head_decision_scope_grounded",
        decision_scope_grounded?(decisions, probes.head_decision)
      ),
      check(
        "middle_action_retained_once",
        count_action_marker(actions, probes.middle_action) == 1
      ),
      check(
        "late_action_retained_once",
        count_action_marker(actions, probes.late_action) == 1
      ),
      check(
        "replacement_action_retained_once",
        count_action_marker(actions, probes.replacement_action) == 1
      ),
      check(
        "action_owner_grounded",
        action_field_matches?(actions, probes.middle_action, "owner", @probe_owner) and
          action_field_matches?(actions, probes.late_action, "owner", @probe_owner) and
          action_field_matches?(actions, probes.replacement_action, "owner", @probe_owner)
      ),
      check(
        "action_deadline_grounded",
        action_field_matches?(actions, probes.middle_action, "deadline", @probe_deadline) and
          action_field_matches?(actions, probes.late_action, "deadline", @probe_deadline) and
          action_field_matches?(actions, probes.replacement_action, "deadline", @probe_deadline)
      ),
      check(
        "weak_suggestion_not_promoted",
        count_action_marker(actions, probes.weak_suggestion) == 0 and
          count_occurrences(decision_text, probes.weak_suggestion) == 0
      ),
      check(
        "resolved_action_not_carried_forward",
        count_action_marker(actions, probes.resolved_action) == 0
      ),
      check(
        "cancelled_action_not_carried_forward",
        count_action_marker(actions, probes.cancelled_action) == 0
      ),
      check(
        "explicitly_rejected_action_not_carried_forward",
        count_action_marker(actions, probes.rejected_action) == 0
      ),
      check(
        "superseded_action_not_carried_forward",
        count_action_marker(actions, probes.superseded_action) == 0
      ),
      check(
        "rejected_proposal_not_recorded_as_decision",
        count_occurrences(decision_text, probes.rejected_decision) == 0 and
          count_action_marker(actions, probes.rejected_decision) == 0
      ),
      check(
        "negative_decision_polarity_retained",
        negative_decision_grounded?(decisions, probes.negative_decision)
      ),
      check(
        "synthetic_probes_not_duplicated",
        Enum.all?(Map.values(probes), &(count_occurrences(all_summary_text, &1) <= 1))
      ),
      check(
        "timeline_chronological_and_bounded",
        valid_timeline?(summary["timeline"], replay_case.context["duration_seconds"])
      )
    ]

    %{
      "passed" => Enum.all?(checks, & &1["passed"]),
      "checks" => checks,
      "summary" => %{
        "fingerprint" => fingerprint(Jason.encode!(summary)),
        "key_points" => length(List.wrap(summary["key_points"])),
        "action_items" => length(actions),
        "decisions" => length(decisions),
        "open_questions" => length(List.wrap(summary["open_questions"])),
        "blockers" => length(List.wrap(summary["blockers"])),
        "timeline" => length(List.wrap(summary["timeline"]))
      }
    }
  end

  defp probes(suffix) do
    %{
      head_decision: "REPLAY_HEAD_DECISION_#{suffix}",
      middle_action: "REPLAY_MIDDLE_ACTION_#{suffix}",
      late_action: "REPLAY_LATE_ACTION_#{suffix}",
      weak_suggestion: "REPLAY_WEAK_SUGGESTION_#{suffix}",
      resolved_action: "REPLAY_RESOLVED_ACTION_#{suffix}",
      rejected_decision: "REPLAY_REJECTED_DECISION_#{suffix}",
      negative_decision: "REPLAY_NEGATIVE_DECISION_#{suffix}",
      cancelled_action: "REPLAY_CANCELLED_ACTION_#{suffix}",
      rejected_action: "REPLAY_REJECTED_ACTION_#{suffix}",
      superseded_action: "REPLAY_SUPERSEDED_ACTION_#{suffix}",
      replacement_action: "REPLAY_REPLACEMENT_ACTION_#{suffix}"
    }
  end

  defp chunk_probes(suffix, duration_seconds) do
    last_index = planned_chunk_count(duration_seconds) - 1

    Map.new(0..last_index, fn index ->
      padded_index = index |> Integer.to_string() |> String.pad_leading(2, "0")

      {index,
       %{
         head: "REPLAY_CHUNK_#{padded_index}_HEAD_#{suffix}",
         middle: "REPLAY_CHUNK_#{padded_index}_MIDDLE_#{suffix}",
         tail: "REPLAY_CHUNK_#{padded_index}_TAIL_#{suffix}"
       }}
    end)
  end

  defp chunk_probe_markers(chunk_probes) do
    chunk_probes
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
  end

  defp source_proofs(caption_windows) do
    canonical_transcript = Enum.join(caption_windows, "\n")

    caption_windows
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {window, index}, proofs_by_chunk ->
      lines = window |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

      if lines == [] do
        proofs_by_chunk
      else
        last = length(lines) - 1

        proofs =
          [{:head, 0}, {:middle, div(last, 2)}, {:tail, last}]
          |> Enum.map(fn {position, line_index} ->
            line = Enum.at(lines, line_index)

            %{
              id: fingerprint("#{index}:#{position}:#{line}"),
              line: line,
              occurrences: exact_line_count(canonical_transcript, line)
            }
          end)
          |> Enum.uniq_by(& &1.line)

        Map.put(proofs_by_chunk, index, proofs)
      end
    end)
  end

  defp source_proof_entries(source_proofs) do
    source_proofs
    |> Map.values()
    |> List.flatten()
  end

  defp source_proof_ids(source_proofs) do
    source_proofs
    |> source_proof_entries()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp inject_probes(transcript, duration_seconds, probes) do
    lines = String.split(transcript, "\n")

    specs = probe_specs(duration_seconds, probes)

    augmented =
      if Enum.any?(lines, &is_integer(line_timecode(&1))) do
        specs
        |> Enum.sort_by(& &1.seconds)
        |> Enum.reduce(lines, &insert_probe_by_time/2)
      else
        specs
        |> Enum.map(&Map.put(&1, :index, round(length(lines) * &1.fraction)))
        |> Enum.sort_by(& &1.index, :desc)
        |> Enum.reduce(lines, fn spec, acc -> List.insert_at(acc, spec.index, spec.line) end)
      end

    Enum.join(augmented, "\n")
  end

  defp inject_chunk_probes(transcript, duration_seconds, chunk_probes) do
    lines = String.split(transcript, "\n")

    chunk_probes
    |> Enum.flat_map(fn {index, markers} ->
      start_seconds = index * @calibration_chunk_seconds
      end_seconds = min(start_seconds + @calibration_chunk_seconds - 1, duration_seconds)
      span = max(end_seconds - start_seconds, 0)

      [
        {:head, start_seconds + div(span, 10), markers.head},
        {:middle, start_seconds + div(span, 2), markers.middle},
        {:tail, start_seconds + div(span * 9, 10), markers.tail}
      ]
      |> Enum.map(fn {position, seconds, marker} ->
        %{
          seconds: seconds,
          line:
            probe_line(
              seconds,
              "Replay Calibration #{position |> Atom.to_string() |> String.capitalize()} Auditor",
              marker
            )
        }
      end)
    end)
    |> Enum.sort_by(& &1.seconds)
    |> Enum.reduce(lines, &insert_probe_by_time/2)
    |> Enum.join("\n")
  end

  defp probe_specs(duration_seconds, probes) do
    [
      probe_spec(
        0.1,
        duration_seconds,
        "Explicit decision: #{probes.head_decision}. Exact scope identifier: #{@probe_decision_scope}."
      ),
      probe_spec(
        0.2,
        duration_seconds,
        "Temporary action: #{probes.resolved_action}. #{@probe_owner} initially owns the compatibility check, due #{@probe_deadline}."
      ),
      probe_spec(
        0.23,
        duration_seconds,
        "Explicit action: #{probes.cancelled_action}. #{@probe_owner} owns the cancellation candidate, due #{@probe_deadline}."
      ),
      probe_spec(
        0.27,
        duration_seconds,
        "Explicit action: #{probes.rejected_action}. #{@probe_owner} owns the rejection candidate, due #{@probe_deadline}."
      ),
      probe_spec(
        0.31,
        duration_seconds,
        "Explicit action: #{probes.superseded_action}. #{@probe_owner} owns the original implementation, due #{@probe_deadline}."
      ),
      probe_spec(
        0.35,
        duration_seconds,
        "Explicit negative decision: #{probes.negative_decision}. Exact scope #{@probe_negative_scope}; exact polarity #{@probe_negative_polarity}; it was not adopted."
      ),
      probe_spec(
        0.5,
        duration_seconds,
        "Explicit action: #{probes.middle_action}. #{@probe_owner} owns the rollout checklist, due #{@probe_deadline}."
      ),
      probe_spec(
        0.7,
        duration_seconds,
        "Unresolved proposal, not a decision: #{probes.rejected_decision}. Proposed scope #{@probe_rejected_scope} was not accepted."
      ),
      probe_spec(
        0.82,
        duration_seconds,
        "Status update: #{probes.resolved_action} was completed during this meeting and is closed; do not carry it forward as an action item."
      ),
      probe_spec(
        0.84,
        duration_seconds,
        "Terminal update: #{probes.cancelled_action} was explicitly cancelled and must not remain an action item."
      ),
      probe_spec(
        0.86,
        duration_seconds,
        "Terminal update: #{probes.rejected_action} was explicitly rejected and must not remain an action item."
      ),
      probe_spec(
        0.88,
        duration_seconds,
        "Terminal update: #{probes.superseded_action} was superseded by #{probes.replacement_action}. #{@probe_owner} owns the replacement, due #{@probe_deadline}."
      ),
      probe_spec(
        0.9,
        duration_seconds,
        "Explicit action: #{probes.late_action}. #{@probe_owner} owns the final verification, due #{@probe_deadline}."
      ),
      probe_spec(
        0.91,
        duration_seconds,
        "Weak suggestion only, not assigned and not accepted: #{probes.weak_suggestion}. A future option could be explored later."
      )
    ]
  end

  defp probe_spec(fraction, duration_seconds, text) do
    seconds = min(round(duration_seconds * fraction), duration_seconds)
    %{fraction: fraction, seconds: seconds, line: probe_line(seconds, text)}
  end

  defp insert_probe_by_time(spec, lines) do
    index =
      Enum.find_index(lines, fn line ->
        case line_timecode(line) do
          seconds when is_integer(seconds) -> seconds > spec.seconds
          _ -> false
        end
      end) || length(lines)

    List.insert_at(lines, index, spec.line)
  end

  defp probe_line(seconds, text), do: probe_line(seconds, "Replay Auditor", text)

  defp probe_line(seconds, speaker, text),
    do: "[#{format_clock(seconds)}] #{speaker}: #{text}"

  defp planned_chunk_count(duration_seconds),
    do: max(div(duration_seconds - 1, @calibration_chunk_seconds) + 1, 1)

  defp chunk_probe_line_count(transcript, marker) do
    transcript
    |> String.split("\n")
    |> Enum.count(&chunk_probe_line?(&1, marker))
  end

  defp strip_chunk_probe_lines(transcript, chunk_probes) do
    markers = chunk_probes |> chunk_probe_markers() |> MapSet.new()

    transcript
    |> String.split("\n")
    |> Enum.reject(fn line -> Enum.any?(markers, &chunk_probe_line?(line, &1)) end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp chunk_probe_line?(line, marker) do
    Regex.match?(
      ~r/^\[(?:\d+:)?[0-5]\d:[0-5]\d\] Replay Calibration (?:Head|Middle|Tail) Auditor: #{Regex.escape(marker)}$/,
      line
    )
  end

  defp expected_probe_occurrences(name)
       when name in [:resolved_action, :cancelled_action, :rejected_action, :superseded_action],
       do: 2

  defp expected_probe_occurrences(_name), do: 1

  defp format_clock(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    seconds = rem(seconds, 60)

    [hours, minutes, seconds]
    |> Enum.map_join(":", &(Integer.to_string(&1) |> String.pad_leading(2, "0")))
  end

  defp valid_timeline?(timeline, duration_seconds) do
    entries = List.wrap(timeline)

    seconds =
      Enum.map(entries, fn entry ->
        entry
        |> value("time")
        |> parse_clock()
      end)

    length(entries) in 4..8 and
      Enum.all?(entries, &(is_map(&1) and text(&1, "summary") != "")) and
      Enum.all?(seconds, &is_integer/1) and
      seconds == Enum.sort(seconds) and
      Enum.all?(seconds, &(&1 >= 0 and &1 <= duration_seconds)) and
      timeline_covers_duration?(seconds, duration_seconds)
  end

  defp timeline_covers_duration?(seconds, duration_seconds)
       when is_list(seconds) and is_integer(duration_seconds) and duration_seconds > 0 do
    first_third = duration_seconds / 3
    last_third = duration_seconds * 2 / 3
    gaps = Enum.zip([0 | seconds], seconds ++ [duration_seconds])
    max_gap = gaps |> Enum.map(fn {left, right} -> right - left end) |> Enum.max(fn -> 0 end)

    Enum.any?(seconds, &(&1 <= first_third)) and
      Enum.any?(seconds, &(&1 >= first_third and &1 <= last_third)) and
      Enum.any?(seconds, &(&1 >= last_third)) and
      max_gap <= ceil(duration_seconds * 0.4)
  end

  defp timeline_covers_duration?(_seconds, _duration_seconds), do: false

  defp normalize_source_timecodes(transcript, duration_seconds) do
    seconds = transcript |> line_timecodes() |> Enum.filter(&is_integer/1)

    cond do
      seconds == [] ->
        {:ok, transcript, "none"}

      seconds != Enum.sort(seconds) ->
        {:error, :non_monotonic_timecodes}

      Enum.all?(seconds, &(&1 >= 0 and &1 <= duration_seconds)) ->
        {:ok, transcript, "relative"}

      length(seconds) >= 2 and duration_seconds > 0 and
          List.last(seconds) - hd(seconds) <= duration_seconds ->
        {:ok, rebase_source_timecodes(transcript, hd(seconds)), "rebased_absolute"}

      true ->
        {:error, :out_of_bounds_timecodes}
    end
  end

  defp rebase_source_timecodes(transcript, base_seconds) do
    transcript
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      case line_timecode(line) do
        seconds when is_integer(seconds) ->
          Regex.replace(
            ~r/^\s*\[(?:\d+:)?[0-5]\d:[0-5]\d\]/,
            line,
            "[#{format_clock(seconds - base_seconds)}]",
            global: false
          )

        _ ->
          line
      end
    end)
  end

  defp transcript_timecodes_valid?(transcript, duration_seconds) do
    seconds = line_timecodes(transcript)

    seconds != [] and Enum.all?(seconds, &is_integer/1) and
      seconds == Enum.sort(seconds) and
      Enum.all?(seconds, &(&1 >= 0 and &1 <= duration_seconds))
  end

  defp line_timecodes(transcript) do
    transcript
    |> String.split("\n")
    |> Enum.map(&line_timecode/1)
  end

  defp line_timecode(line) do
    case Regex.run(~r/^\s*\[((?:\d+:)?[0-5]\d:[0-5]\d)\]/, line) do
      [_match, clock] -> parse_clock(clock)
      _match -> nil
    end
  end

  defp parse_clock(value) when is_binary(value) do
    case value |> String.trim() |> String.split(":") |> Enum.map(&Integer.parse/1) do
      [{hours, ""}, {minutes, ""}, {seconds, ""}]
      when minutes in 0..59 and seconds in 0..59 ->
        hours * 3_600 + minutes * 60 + seconds

      [{minutes, ""}, {seconds, ""}] when seconds in 0..59 ->
        minutes * 60 + seconds

      _ ->
        nil
    end
  end

  defp parse_clock(_value), do: nil

  defp action_field_matches?(actions, marker, field, expected) do
    Enum.any?(actions, fn action ->
      String.contains?(action["description"], marker) and action[field] == expected
    end)
  end

  defp decision_scope_grounded?(decisions, marker) do
    Enum.any?(decisions, fn decision ->
      String.contains?(decision, marker) and
        String.contains?(decision, @probe_decision_scope) and
        not String.contains?(decision, @probe_rejected_scope)
    end)
  end

  defp negative_decision_grounded?(decisions, marker) do
    count_occurrences(Enum.join(decisions, "\n"), marker) == 1 and
      Enum.any?(decisions, fn decision ->
        String.contains?(decision, marker) and
          String.contains?(decision, @probe_negative_scope) and
          String.contains?(decision, @probe_negative_polarity) and
          not String.contains?(decision, "REPLAY_POLARITY_ADOPT")
      end)
  end

  defp count_action_marker(actions, marker) do
    Enum.count(actions, &String.contains?(&1["description"], marker))
  end

  defp action_items(items) do
    items
    |> List.wrap()
    |> Enum.map(fn
      item when is_map(item) ->
        %{
          "description" => text(item, "description"),
          "owner" => text(item, "owner"),
          "deadline" => text(item, "deadline")
        }

      _item ->
        %{"description" => "", "owner" => "", "deadline" => ""}
    end)
  end

  defp summary_text(summary) do
    [
      summary["title"],
      summary["attendees"],
      summary["timeline"],
      summary["key_points"],
      summary["action_items"],
      summary["decisions"],
      summary["open_questions"],
      summary["blockers"]
    ]
    |> Jason.encode!()
  end

  defp text_list(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp check(name, passed), do: %{"name" => name, "passed" => passed == true}

  defp count_occurrences(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> length()
  end

  defp exact_line_count(transcript, expected_line) do
    transcript
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) == expected_line))
  end

  defp line_count(""), do: 0
  defp line_count(text), do: text |> String.split("\n") |> length()

  defp timecode_count(text) do
    ~r/\[(?:\d+:)?[0-5]\d:[0-5]\d\]/
    |> Regex.scan(text)
    |> length()
  end

  defp fingerprint(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp text(map, key) do
    case value(map, key) do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp value(map, key) when is_map(map), do: map[key] || map[String.to_atom(key)]
  defp value(_map, _key), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 0

  defp blank_default("", default), do: default
  defp blank_default(value, _default), do: value
end
