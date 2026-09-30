defmodule Salix.Bindings.MeetingSummary do
  @moduledoc false

  @behaviour SalixMeet.Ports.Summary

  require Logger
  alias SalixAgent.{AudioTranscriber, Templates}
  alias SalixWeb.LLMProxy

  @min_units 3
  @min_runes 40
  @calibration_max_tokens 8000
  @calibration_source_max_bytes 20_000
  @calibration_combined_max_bytes 30_000
  @calibration_chunk_caption_max_bytes 12_000
  @calibration_chunk_seconds 300
  @calibration_time_coverage_seconds 60
  @transcript_speaker_dedup_window_seconds 15 * 60

  @system_prompt """
  You are a meeting notes assistant. You may receive three views of the same evidence:

  1. **Canonical Transcript** — the primary transcript selected for downstream attribution. It may still be incomplete when only live captions are available; it can come from complete calibration, raw live captions, raw ASR, or a runtime transcript artifact.
  2. **Raw Live Captions** — the uncalibrated captions, including in-meeting chat when available. Speaker labels may be stale, partial, or wrong.
  3. **Raw ASR Transcript** — independently transcribed from complete audio chunks. It may have better content but weaker speaker identity.

  Your job: cross-reference the raw sources before stating facts. Use the Canonical Transcript as the primary source of record, but preserve disagreements instead of confidently normalizing garbled terms, names, ownership, or decisions. Do NOT treat every speaker label as a verified real person.

  Output ONLY valid JSON with EXACTLY these field names (do NOT rename or add fields):
  {
    "title": "concise meeting title",
    "attendees": ["name1", "name2"],
    "duration_minutes": 30,
    "timeline": [{"time": "00:13:27", "summary": "brief key moment"}],
    "key_points": ["point 1", "point 2"],
    "action_items": [{"description": "...", "owner": "name", "deadline": "..."}],
    "decisions": ["decision 1"],
    "open_questions": ["question 1"],
    "blockers": ["blocker 1"]
  }
  CRITICAL: Use "key_points" exactly. Do not rename or add fields.

  Rules:
  - Extract only concrete action items that are still open commitments at the end of the meeting.
  - Do not turn suggestions, options, exploratory questions, unresolved proposals, or unassigned ideas into action items or adopted decisions.
  - When rejecting a proposal is itself an explicit decision, preserve the negative polarity and exact scope; never rewrite rejection as adoption.
  - Do not carry an action item forward when later evidence says it was completed, cancelled, rejected, or superseded during the meeting.
  - Keep each decision within the explicit scope supported by the transcript; do not generalize it to other components, teams, phases, or follow-up work.
  - Preserve literal identifiers, issue keys, URLs, and explicit date/time values exactly.
  - If the transcript provides meaningful timestamps, include a concise timeline with 4-8 key moments using HH:MM:SS relative transcript times; otherwise leave timeline empty.
  - Keep key points concise (1-2 sentences each).
  - Output in the same language as the majority of the transcript content.
  - Use the provided meeting title as the default title; only rewrite it if the transcript clearly supports a more factual title.
  - Do NOT list attendees only because a speaker label appears in captions. Attendees should be conservative.
  - If identity grounding is provided, only use those real-person names for attendees or action-item owners.
  - If a speaker label is uncertain or not grounded to a real person, avoid naming them in attendees.
  - If an action item is explicitly assigned but the owner is only known via an unverified speaker label, keep that raw label in "owner" instead of erasing it. Do not upgrade it to a verified attendee.
  - If speakers are identified, attribute action items to them only when the assignment is explicit or clearly implied by a speaker volunteering to own it.
  - Use the provided actual duration rather than inferring duration from the transcript.
  - Leave owner empty if ownership is unclear.
  - Leave deadline empty unless a concrete date/time or clear deadline phrase is stated.
  - If evidence is insufficient, leave fields empty rather than inferring.
  - Leave arrays empty if no relevant items are found.
  - Do not fabricate information not present in the transcript.
  - If the transcript is very short (only a few sentences with no substantive discussion), keep title factual and leave key_points/action_items/decisions/open_questions/blockers arrays empty. Do not invent content.
  - If the transcript is clearly NOT a meeting (e.g. a monologue, video narration, podcast, or presentation with no interactive discussion), still output valid JSON. Set the title to describe what the content is, put a brief summary in key_points, and leave action_items/decisions/open_questions/blockers empty.
  - NEVER output anything other than a JSON object. No markdown, no explanation, no commentary.
  """

  @calibration_system_prompt """
  You are a transcript editor. You will receive two versions of the same meeting transcript:

  1. **Live Captions** — captured in real-time with speaker labels, but they may contain duplicates, fragments, recognition errors, or identity mistakes.
  2. **ASR Transcript** — from post-meeting audio transcription, more complete and coherent text, but speaker names may be generic (Speaker 1, Speaker 2, etc.) or inaccurate.

  Your task: produce a single, calibrated transcript that combines the best of both sources.

  Rules:
  - Prefer speaker labels from Live Captions (source 1) only as unverified labels; do not invent or over-confidently normalize identity beyond what the captions support
  - Use the content/text from ASR Transcript (source 2) — it is more complete and coherent
  - Maintain chronological order using timestamps
  - Output format: [HH:MM:SS] Speaker Name: text
  - Remove duplicate fragments and overlapping content
  - Preserve the original language (do not translate)
  - Output ONLY the calibrated transcript lines, no commentary or explanation
  """

  @impl true
  def summarize(state) when is_map(state) do
    with {:ok, context} <- prepare_context(state) do
      summarize(state, context)
    end
  end

  @impl true
  def summarize(state, context) when is_map(state) and is_map(context) do
    summarize_with_resolver(
      state,
      context,
      &resolve_llm/1,
      Application.get_env(:salix_web, :meeting_summary_skip_metering, false),
      true
    )
  end

  @doc false
  def replay_summary(state, context, llm)
      when is_map(state) and is_map(context) and is_map(llm) do
    summarize_with_resolver(state, context, fn _agent_id -> {:ok, llm} end, true, false)
  end

  @doc false
  def replay_summary(state, context) when is_map(state) and is_map(context) do
    summarize_with_resolver(state, context, &resolve_llm/1, false, false)
  end

  defp summarize_with_resolver(state, context, resolver, skip_metering, log?)
       when is_function(resolver, 1) do
    agent_id = trim(state["meeting_agent_id"])
    captions = List.wrap(state["captions"])

    cond do
      agent_id == "" ->
        :skip

      not sufficient_context_evidence?(context) ->
        :skip

      true ->
        case do_summarize(
               agent_id,
               state,
               captions,
               context,
               resolver,
               skip_metering,
               log?
             ) do
          {:ok, summary} = ok ->
            if log?, do: log_summary(state, summary)
            ok

          other ->
            other
        end
    end
  rescue
    e ->
      if log?, do: Logger.warning("meeting summary crashed: #{Exception.message(e)}")
      :skip
  end

  defp sufficient_context_evidence?(context) do
    Enum.any?(
      ~w(transcript captions_transcript asr_transcript),
      &sufficient_evidence?(trim_context_transcript(context[&1]))
    )
  end

  @impl true
  def prepare_context(state) when is_map(state) do
    prepare_context(state, &asr_transcript/1, &calibrate_asr/4)
  end

  @doc false
  def prepare_context(state, asr_fun, calibration_fun)
      when is_map(state) and is_function(asr_fun, 1) and is_function(calibration_fun, 4) do
    captions = List.wrap(state["captions"])

    caption_transcript =
      build_transcript(captions, positive_integer(get(state, "joined_at")))

    {transcript, source, asr_transcript, audio_duration_seconds, calibration} =
      resolve_transcript(state, captions, caption_transcript, asr_fun, calibration_fun)

    captions_with_chat = with_chat(caption_transcript, state["chats"])
    transcript = with_chat(transcript, state["chats"])
    duration_seconds = actual_duration_seconds(state, captions, audio_duration_seconds)
    log_transcript(state, source, transcript, captions_with_chat, asr_transcript)

    {:ok,
     %{
       "version" => 2,
       "source" => source,
       "transcript" => transcript,
       "transcript_fingerprint" => transcript_fingerprint(transcript),
       "captions_transcript" => captions_with_chat,
       "captions_fingerprint" => transcript_fingerprint(captions_with_chat),
       "asr_transcript" => asr_transcript,
       "asr_fingerprint" => transcript_fingerprint(asr_transcript),
       "calibration" => Map.delete(calibration, "transcript"),
       "duration_seconds" => duration_seconds
     }}
  rescue
    e ->
      Logger.warning("meeting summary context preparation crashed: #{Exception.message(e)}")
      :skip
  end

  defp log_transcript(state, source, transcript, captions, asr) do
    mid = trim(state["meeting_id"])

    Logger.info(
      "[meeting_summary] #{mid} transcript_source=#{source} chars=#{String.length(transcript)} " <>
        "caption_chars=#{String.length(captions)} asr_chars=#{String.length(asr)}"
    )

    if verbose?() and transcript != "" do
      Logger.info(
        "[meeting_summary] #{mid} transcript (#{source}): " <>
          inspect(transcript, printable_limit: :infinity, limit: :infinity) <>
          " captions=" <>
          inspect(captions, printable_limit: :infinity, limit: :infinity) <>
          " asr=" <> inspect(asr, printable_limit: :infinity, limit: :infinity)
      )
    end
  end

  defp log_summary(state, summary) do
    mid = trim(state["meeting_id"])

    Logger.info(
      "[meeting_summary] #{mid} summary title=#{inspect(summary["title"])} " <>
        "key_points=#{length(List.wrap(summary["key_points"]))} " <>
        "action_items=#{length(List.wrap(summary["action_items"]))}"
    )

    if verbose?() do
      Logger.info("[meeting_summary] #{mid} summary json:\n#{Jason.encode!(summary)}")
    end

    true
  end

  defp verbose?, do: Application.get_env(:salix_web, :meeting_summary_log_transcripts, false)

  defp resolve_transcript(state, captions, caption_transcript, asr_fun, calibration_fun) do
    case asr_fun.(state) do
      {:ok, %{transcript: asr, duration_seconds: duration_seconds} = asr_metadata}
      when is_binary(asr) and asr != "" and is_integer(duration_seconds) and
             duration_seconds > 0 ->
        if caption_transcript != "" do
          calibration = calibration_fun.(state, captions, caption_transcript, asr_metadata)

          {transcript, source} = select_canonical_asr(asr, calibration)
          {transcript, source, asr, duration_seconds, calibration}
        else
          {asr, "asr", asr, duration_seconds, calibration_not_applicable()}
        end

      _ when caption_transcript != "" ->
        {caption_transcript, "captions", "", 0, calibration_not_applicable()}

      _ ->
        case runtime_transcript(state) do
          {:ok, transcript} ->
            {transcript, "runtime_transcript", "", 0, calibration_not_applicable()}

          _ ->
            {"", "captions", "", 0, calibration_not_applicable()}
        end
    end
  end

  defp calibrate_asr(state, captions, caption_transcript, asr_metadata) do
    calibrate_transcript(
      captions,
      caption_transcript,
      asr_metadata,
      fn caption, asr ->
        calibrate(state, caption, asr)
      end,
      caption_anchor_seconds: positive_integer(get(state, "joined_at"))
    )
  end

  @doc false
  def select_canonical_asr(
        asr,
        %{"complete" => true, "transcript" => calibrated}
      )
      when is_binary(asr) and asr != "" and is_binary(calibrated) and calibrated != "",
      do: {calibrated, "calibrated"}

  def select_canonical_asr(asr, _calibration) when is_binary(asr) and asr != "",
    do: {asr, "asr"}

  # A runtime transcript artifact is the last canonical fallback when neither
  # complete ASR nor live captions are available.
  defp runtime_transcript(state) do
    with agent_id when agent_id != "" <- trim(state["meeting_agent_id"]),
         path when path != "" <- trim(get_in(state, ["artifacts", "transcript", "path"])),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 <-
           SalixMeet.Ports.AgentRuntime.read_workspace(agent_id, path),
         true <- String.valid?(bytes),
         transcript when transcript != "" <- String.trim(bytes) do
      {:ok, transcript}
    else
      _ -> :skip
    end
  end

  @doc false
  def with_chat(transcript, chats) do
    case chat_transcript(List.wrap(chats)) do
      "" ->
        transcript

      lines ->
        if String.trim(transcript) == "" do
          "In-meeting chat:\n" <> lines
        else
          transcript <> "\n\nIn-meeting chat:\n" <> lines
        end
    end
  end

  defp chat_transcript(chats) do
    chats
    |> Enum.reject(fn chat -> trim(chat["direction"]) == "outgoing" end)
    |> Enum.map(fn chat ->
      sender =
        case trim(chat["sender"]) do
          "" -> "Unknown"
          name -> name
        end

      sender <> ": " <> trim(chat["text"])
    end)
    |> Enum.reject(&String.ends_with?(&1, ": "))
    |> Enum.join("\n")
  end

  defp calibrate(state, caption_transcript, asr_transcript) do
    agent_id = trim(state["meeting_agent_id"])

    calibrate_with_resolver(
      agent_id,
      caption_transcript,
      asr_transcript,
      &resolve_llm/1,
      Application.get_env(:salix_web, :meeting_summary_skip_metering, false)
    )
  end

  @doc false
  def replay_calibrate(agent_id, caption_transcript, asr_transcript, llm)
      when is_binary(agent_id) and is_binary(caption_transcript) and
             is_binary(asr_transcript) and is_map(llm) do
    calibrate_with_resolver(
      agent_id,
      caption_transcript,
      asr_transcript,
      fn _agent_id -> {:ok, llm} end,
      true
    )
  end

  @doc false
  def replay_calibrate(agent_id, caption_transcript, asr_transcript)
      when is_binary(agent_id) and is_binary(caption_transcript) and
             is_binary(asr_transcript) do
    calibrate_with_resolver(
      agent_id,
      caption_transcript,
      asr_transcript,
      &resolve_llm/1,
      false
    )
  end

  defp calibrate_with_resolver(
         agent_id,
         caption_transcript,
         asr_transcript,
         resolver,
         skip_metering
       ) do
    user =
      "## Live Captions (speaker labels are unverified)\n" <>
        caption_transcript <>
        "\n\n## ASR Transcript (content is more complete)\n" <> asr_transcript

    case chat(
           agent_id,
           @calibration_system_prompt,
           user,
           @calibration_max_tokens,
           "meeting_calibration",
           resolver,
           skip_metering
         ) do
      {:ok, content} -> {:ok, String.trim(content)}
      other -> other
    end
  end

  @doc false
  def calibrate_transcript(captions, caption_transcript, asr_metadata, calibrate_fun, opts \\ [])
      when is_list(captions) and is_binary(caption_transcript) and is_map(asr_metadata) and
             is_function(calibrate_fun, 2) and is_list(opts) do
    asr_transcript = trim_context_transcript(get(asr_metadata, "transcript"))

    if opts[:force_chunk] == true or should_chunk_calibration?(caption_transcript, asr_transcript) do
      calibrate_transcript_chunks(captions, asr_metadata, calibrate_fun, opts)
    else
      calibrate_transcript_direct(caption_transcript, asr_transcript, calibrate_fun)
    end
  end

  @doc false
  def should_chunk_calibration?(caption_transcript, asr_transcript)
      when is_binary(caption_transcript) and is_binary(asr_transcript) do
    caption_bytes = byte_size(caption_transcript)
    asr_bytes = byte_size(asr_transcript)

    caption_bytes > @calibration_source_max_bytes or
      asr_bytes > @calibration_source_max_bytes or
      caption_bytes + asr_bytes > @calibration_combined_max_bytes
  end

  defp calibrate_transcript_direct(caption_transcript, asr_transcript, calibrate_fun) do
    case calibrate_fun.(caption_transcript, asr_transcript) do
      {:ok, calibrated} when is_binary(calibrated) ->
        calibrated = String.trim(calibrated)
        complete = complete_calibration?(calibrated, caption_transcript, asr_transcript)

        calibration_result(
          "direct",
          complete,
          if(complete, do: calibrated, else: ""),
          1,
          if(complete, do: 1, else: 0)
        )

      _ ->
        calibration_result("direct", false, "", 1, 0)
    end
  rescue
    _exception -> calibration_result("direct", false, "", 1, 0)
  catch
    _kind, _reason -> calibration_result("direct", false, "", 1, 0)
  end

  defp calibrate_transcript_chunks(captions, asr_metadata, calibrate_fun, opts) do
    case ordered_calibration_chunks(get(asr_metadata, "chunks")) do
      {:ok, chunks} ->
        duration_seconds = positive_integer(get(asr_metadata, "duration_seconds"))
        caption_anchor_seconds = positive_integer(opts[:caption_anchor_seconds])
        planned_chunks = length(chunks)

        case calibration_caption_windows(
               captions,
               caption_anchor_seconds,
               chunks,
               duration_seconds
             ) do
          {:ok, caption_windows} ->
            {parts, calibrated_chunks} =
              chunks
              |> Enum.zip(caption_windows)
              |> Enum.reduce({[], 0}, fn {chunk, caption_window}, {parts, calibrated_count} ->
                case calibrate_chunk(caption_window, chunk.transcript, calibrate_fun) do
                  {:ok, calibrated} -> {[calibrated | parts], calibrated_count + 1}
                  :fallback -> {parts, calibrated_count}
                end
              end)

            complete = calibrated_chunks == planned_chunks

            transcript =
              if complete do
                parts
                |> Enum.reverse()
                |> Enum.join("\n")
                |> String.trim()
              else
                ""
              end

            calibration_result(
              "chunked",
              complete and transcript != "",
              transcript,
              planned_chunks,
              calibrated_chunks
            )

          {:error, _reason} ->
            calibration_result("chunked", false, "", planned_chunks, 0)
        end

      {:error, _reason} ->
        calibration_result("chunked_unavailable", false, "", 0, 0)
    end
  end

  defp calibrate_chunk(caption_window, asr_window, calibrate_fun) do
    caption_window = String.trim(caption_window)
    asr_window = String.trim(asr_window)

    cond do
      caption_window == "" or asr_window == "" ->
        :fallback

      byte_size(caption_window) > @calibration_chunk_caption_max_bytes ->
        :fallback

      true ->
        case calibrate_fun.(caption_window, asr_window) do
          {:ok, calibrated} when is_binary(calibrated) ->
            calibrated = String.trim(calibrated)

            if complete_calibration?(calibrated, caption_window, asr_window),
              do: {:ok, calibrated},
              else: :fallback

          _ ->
            :fallback
        end
    end
  rescue
    _exception -> :fallback
  catch
    _kind, _reason -> :fallback
  end

  defp ordered_calibration_chunks(chunks) when is_list(chunks) and chunks != [] do
    normalized =
      chunks
      |> Enum.map(fn chunk ->
        %{
          index: non_negative_integer(get(chunk, "index")),
          offset_seconds: non_negative_integer(get(chunk, "offset_seconds")),
          transcript: trim_context_transcript(get(chunk, "transcript"))
        }
      end)
      |> Enum.sort_by(& &1.index)

    indexes = Enum.map(normalized, & &1.index)
    offsets = Enum.map(normalized, & &1.offset_seconds)

    expected_indexes = Enum.to_list(0..(length(normalized) - 1))
    expected_offsets = Enum.map(expected_indexes, &(&1 * @calibration_chunk_seconds))

    if indexes == expected_indexes and offsets == expected_offsets do
      {:ok, normalized}
    else
      {:error, :invalid_chunk_manifest}
    end
  end

  defp ordered_calibration_chunks(_chunks), do: {:error, :missing_chunk_manifest}

  @doc false
  def calibration_caption_windows(captions, anchor, chunks, duration_seconds) do
    captions = Enum.filter(captions, fn caption -> trim(get(caption, "text")) != "" end)
    last_index = length(chunks) - 1
    last_offset = List.last(chunks).offset_seconds

    with true <- anchor > 0,
         true <- duration_seconds > last_offset,
         true <- duration_seconds <= last_offset + @calibration_chunk_seconds,
         true <- captions != [],
         true <- Enum.all?(captions, &(timestamp(&1) > 0)),
         {:ok, grouped} <-
           group_captions_by_chunk(captions, anchor, duration_seconds, last_index) do
      windows =
        Enum.map(chunks, fn chunk ->
          grouped
          |> Map.get(chunk.index, [])
          |> Enum.sort_by(&timestamp/1)
          |> deduplicate_transcript_captions()
          |> Enum.map(&caption_line(&1, anchor))
          |> Enum.join("\n")
        end)

      {:ok, windows}
    else
      _ -> {:error, :unanchored_caption_evidence}
    end
  end

  defp group_captions_by_chunk(captions, anchor, duration_seconds, last_index) do
    Enum.reduce_while(captions, {:ok, %{}}, fn caption, {:ok, grouped} ->
      relative_seconds = timestamp(caption) - anchor

      cond do
        relative_seconds < 0 or relative_seconds > duration_seconds ->
          {:halt, {:error, :caption_outside_audio}}

        true ->
          index = min(div(relative_seconds, @calibration_chunk_seconds), last_index)
          {:cont, {:ok, Map.update(grouped, index, [caption], &[caption | &1])}}
      end
    end)
  end

  defp calibration_result(mode, complete, transcript, planned_chunks, calibrated_chunks) do
    %{
      "mode" => mode,
      "complete" => complete,
      "transcript" => transcript,
      "planned_chunks" => planned_chunks,
      "calibrated_chunks" => calibrated_chunks,
      "fallback_chunks" => max(planned_chunks - calibrated_chunks, 0)
    }
  end

  defp calibration_not_applicable do
    calibration_result("not_applicable", false, "", 0, 0)
  end

  defp asr_transcript(state) do
    agent_id = trim(state["meeting_agent_id"])
    path = trim(get_in(state, ["artifacts", "audio", "path"]))
    transcribe_asr_observed(agent_id, path)
  rescue
    exception ->
      Logger.warning(
        "meeting ASR crashed after observation, falling back to captions: " <>
          Exception.message(exception)
      )

      :skip
  catch
    kind, _reason ->
      Logger.warning(
        "meeting ASR exited after observation, falling back to captions: #{inspect(kind)}"
      )

      :skip
  end

  @doc false
  def transcribe_asr_observed(agent_id, path, transcriber \\ AudioTranscriber) do
    started_at = System.monotonic_time()

    try do
      result = transcriber.transcribe(agent_id, path)
      emit_asr_telemetry(result, System.monotonic_time() - started_at)

      case result do
        {:ok, _metadata} = ok -> ok
        other -> asr_unavailable(other, nil)
      end
    rescue
      exception ->
        emit_asr_telemetry(
          {:error, :asr_observer_exception},
          System.monotonic_time() - started_at
        )

        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_asr_telemetry(
          {:error, :asr_observer_exception},
          System.monotonic_time() - started_at
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp asr_unavailable(reason, duration) do
    if is_integer(duration), do: emit_asr_telemetry({:error, reason}, duration)
    Logger.info("meeting ASR unavailable, falling back to captions: #{inspect(reason)}")
    :skip
  end

  defp emit_asr_telemetry(result, duration) do
    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_asr",
      "system",
      asr_telemetry_outcome(result),
      duration
    )
  end

  @doc false
  def asr_telemetry_outcome({:ok, _result}), do: "ok"

  def asr_telemetry_outcome({:error, reason}) do
    if asr_unavailable_reason?(reason), do: "unavailable", else: "error"
  end

  def asr_telemetry_outcome(_result), do: "error"

  defp asr_unavailable_reason?(reason)
       when reason in [
              :ffmpeg_unavailable,
              :ffprobe_unavailable,
              :ffmpeg_timeout,
              :ffprobe_timeout,
              :asr_batch_timeout,
              :asr_not_configured,
              :not_found,
              :timeout,
              :unavailable
            ],
       do: true

  defp asr_unavailable_reason?({:asr_chunk_failed, _index, reason}),
    do: asr_unavailable_reason?(reason)

  defp asr_unavailable_reason?(%Req.TransportError{}), do: true

  defp asr_unavailable_reason?({:asr_http, status, _body})
       when status in [408, 425, 429] or status >= 500,
       do: true

  defp asr_unavailable_reason?({:http, status})
       when status in [408, 425, 429] or status >= 500,
       do: true

  defp asr_unavailable_reason?({:asr_template_unavailable, _reason}), do: true

  defp asr_unavailable_reason?({kind, _detail})
       when kind in [:ffmpeg_start_failed, :ffprobe_start_failed],
       do: true

  defp asr_unavailable_reason?(_reason), do: false

  defp do_summarize(agent_id, state, captions, context, resolver, skip_metering, log?) do
    user = build_user_prompt(state, captions, context)

    with {:ok, content} <-
           chat(
             agent_id,
             @system_prompt,
             user,
             nil,
             "meeting_summary",
             resolver,
             skip_metering
           ),
         {:ok, summary} <- parse_summary(content) do
      {:ok, Map.put(summary, "duration_minutes", duration_minutes(captions, context))}
    else
      other ->
        if log?, do: Logger.warning("meeting summary failed for #{agent_id}: #{inspect(other)}")
        :skip
    end
  end

  defp chat(agent_id, system, user, max_tokens, entrypoint, resolver, skip_metering)
       when is_function(resolver, 1) do
    req = %{
      "messages" => [
        %{"role" => "system", "content" => system},
        %{"role" => "user", "content" => user}
      ],
      "max_tokens" => max_tokens
    }

    opts = %{
      entrypoint: entrypoint,
      actor_type: "system",
      skip_metering: skip_metering == true
    }

    with {:ok, llm} when is_map(llm) <- resolver.(agent_id),
         {:ok, resp} <- LLMProxy.complete(agent_id, llm, req, opts),
         content when is_binary(content) <-
           get_in(resp, ["choices", Access.at(0), "message", "content"]) do
      {:ok, content}
    else
      other -> {:error, other}
    end
  end

  # Legacy Oneesama treats terminal meeting notes as their own LLM workload.
  # Resolve the optional summary template live so existing create-once meeting
  # agents can use it too. When it is absent, preserve the original meeting
  # agent -> default-template resolution exactly. A temporarily unavailable
  # explicit template logs and falls back instead of dropping the meeting
  # notes. Calibration intentionally shares this resolver, matching legacy's
  # SummaryModel default.
  defp resolve_llm(agent_id) do
    case Application.get_env(:salix_web, :meeting_summary_template) do
      ref when is_binary(ref) ->
        case String.trim(ref) do
          "" -> LLMProxy.resolve_llm(agent_id)
          ref -> resolve_configured_summary_llm(agent_id, ref)
        end

      _ ->
        LLMProxy.resolve_llm(agent_id)
    end
  end

  defp resolve_configured_summary_llm(agent_id, ref) do
    case Templates.resolve_llm_for_template_ref(ref) do
      {:ok, llm} when is_map(llm) ->
        {:ok, llm}

      unavailable ->
        Logger.warning(
          "meeting summary template #{inspect(ref)} unavailable; " <>
            "falling back to the meeting agent template: #{inspect(unavailable)}"
        )

        LLMProxy.resolve_llm(agent_id)
    end
  end

  @doc false
  def build_transcript(captions, anchor_seconds \\ 0) do
    captions =
      captions
      |> Enum.filter(fn c -> trim(get(c, "text")) != "" end)
      |> order_timestamped_captions()
      |> deduplicate_transcript_captions()

    case captions do
      [] ->
        ""

      _ ->
        base =
          case positive_integer(anchor_seconds) do
            anchor when anchor > 0 -> anchor
            _ -> base_timestamp(captions)
          end

        captions
        |> Enum.map(&caption_line(&1, base))
        |> Enum.join("\n")
    end
  end

  # Private legacy reads captions ordered by timestamp. Runtime event arrival
  # can be out of order, so preserve arrival order only when any timestamp is
  # unavailable and otherwise restore the same chronological invariant.
  defp order_timestamped_captions(captions) do
    if Enum.all?(captions, &(timestamp(&1) > 0)) do
      Enum.sort_by(captions, &timestamp/1)
    else
      captions
    end
  end

  # Google Meet can emit incremental caption revisions as separate runtime
  # events. Match private legacy's finalize-time invariant: for one speaker,
  # keep the newest/fullest equivalent revision inside a bounded window while
  # preserving distinct and interleaved speech.
  defp deduplicate_transcript_captions(captions) do
    if Enum.all?(captions, &(timestamp(&1) > 0)) do
      Enum.reduce(captions, [], &deduplicate_transcript_caption/2)
      |> Enum.reject(&is_nil/1)
    else
      captions
    end
  end

  defp deduplicate_transcript_caption(caption, kept) do
    match =
      kept
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {nil, _index} ->
          nil

        {previous, index} ->
          elapsed = timestamp(caption) - timestamp(previous)

          cond do
            elapsed > @transcript_speaker_dedup_window_seconds ->
              false

            elapsed < 0 or trim(get(previous, "speaker")) != trim(get(caption, "speaker")) ->
              nil

            caption_texts_equivalent?(get(previous, "text"), get(caption, "text")) or
                incremental_caption_update?(get(previous, "text"), get(caption, "text")) ->
              {:replace, index}

            incremental_caption_update?(get(caption, "text"), get(previous, "text")) ->
              :drop

            true ->
              nil
          end
      end)

    case match do
      {:replace, index} -> List.replace_at(kept, index, nil) ++ [caption]
      :drop -> kept
      _ -> kept ++ [caption]
    end
  end

  defp caption_texts_equivalent?(left, right),
    do: normalize_caption_compare_text(left) == normalize_caption_compare_text(right)

  defp incremental_caption_update?(shorter, longer) do
    shorter = shorter |> normalize_caption_compare_text() |> String.to_charlist()
    longer = longer |> normalize_caption_compare_text() |> String.to_charlist()

    cond do
      length(longer) <= length(shorter) ->
        false

      shorter == [] ->
        true

      true ->
        common =
          shorter
          |> Enum.zip(longer)
          |> Enum.count(fn {left, right} -> left == right end)

        common >= div(length(shorter), 2)
    end
  end

  defp normalize_caption_compare_text(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s\p{P}\p{S}]+/u, "")
  end

  defp base_timestamp(captions) do
    captions
    |> Enum.map(&timestamp/1)
    |> Enum.filter(&(&1 > 0))
    |> case do
      [] -> 0
      list -> Enum.min(list)
    end
  end

  defp caption_line(caption, base) do
    ts = timestamp(caption)

    prefix =
      if ts > 0 and base > 0 and ts >= base do
        "[" <> format_clock(ts - base) <> "] "
      else
        ""
      end

    speaker = trim(get(caption, "speaker"))
    speaker_prefix = if speaker == "", do: "", else: speaker <> ": "

    prefix <> speaker_prefix <> trim(get(caption, "text"))
  end

  defp format_clock(seconds) when is_integer(seconds) and seconds >= 0 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)

    if h > 0 do
      pad(h) <> ":" <> pad(m) <> ":" <> pad(s)
    else
      pad(m) <> ":" <> pad(s)
    end
  end

  defp format_clock(_), do: "00:00"

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp build_user_prompt(state, captions, context) do
    title = trim(state["title"])
    duration = duration_minutes(captions, context)
    canonical = trim_context_transcript(context["transcript"])
    raw_captions = trim_context_transcript(context["captions_transcript"])
    raw_asr = trim_context_transcript(context["asr_transcript"])

    duration_str =
      case duration do
        1 -> "1 minute"
        n -> "#{n} minutes"
      end

    [
      "Meeting: #{title}",
      "Actual duration: #{duration_str}",
      transcript_section("Canonical Transcript", canonical),
      evidence_section("Raw Live Captions", raw_captions, canonical),
      evidence_section("Raw ASR Transcript", raw_asr, canonical),
      "IMPORTANT: Reply with ONLY a JSON object. No markdown, no explanation."
    ]
    |> Enum.join("\n\n")
  end

  defp transcript_section(title, ""), do: "## #{title}\n(unavailable)"
  defp transcript_section(title, transcript), do: "## #{title}\n#{transcript}"

  defp evidence_section(title, "", _canonical), do: "## #{title}\n(unavailable)"

  defp evidence_section(title, transcript, transcript),
    do: "## #{title}\n(same exact evidence as Canonical Transcript)"

  defp evidence_section(title, transcript, _canonical), do: "## #{title}\n#{transcript}"

  @doc false
  def complete_calibration?(calibrated, captions, asr)
      when is_binary(calibrated) and is_binary(captions) and is_binary(asr) do
    source_length = max(String.length(captions), String.length(asr))
    minimum_length = max(@min_runes, div(source_length, 2))
    source_end = max(max_clock_seconds(captions), max_clock_seconds(asr))
    calibrated_end = max_clock_seconds(calibrated)

    String.length(String.trim(calibrated)) >= minimum_length and
      (source_end == 0 or calibrated_end >= max(source_end - 30, 0)) and
      complete_calibration_time_coverage?(calibrated, captions, asr)
  end

  defp complete_calibration_time_coverage?(calibrated, captions, asr) do
    source_times = clock_seconds(captions) ++ clock_seconds(asr)
    calibrated_times = clock_seconds(calibrated)

    case {source_times, calibrated_times} do
      {[], _calibrated_times} ->
        true

      {_source_times, []} ->
        false

      {source_times, calibrated_times} ->
        chronological? = calibrated_times == Enum.sort(calibrated_times)
        bounded? = calibrated_times_within_source?(calibrated_times, source_times)
        starts_near_source? = Enum.min(calibrated_times) <= Enum.min(source_times) + 30

        all_source_times_covered? =
          Enum.all?(source_times, fn source_time ->
            Enum.any?(calibrated_times, fn calibrated_time ->
              abs(calibrated_time - source_time) <= @calibration_time_coverage_seconds
            end)
          end)

        chronological? and bounded? and starts_near_source? and all_source_times_covered?
    end
  end

  defp calibrated_times_within_source?(calibrated_times, source_times) do
    lower = max(Enum.min(source_times) - @calibration_time_coverage_seconds, 0)
    upper = Enum.max(source_times) + @calibration_time_coverage_seconds
    Enum.all?(calibrated_times, &(&1 >= lower and &1 <= upper))
  end

  defp clock_seconds(transcript) do
    ~r/\[(\d+):([0-5]\d)(?::([0-5]\d))?\]/
    |> Regex.scan(transcript)
    |> Enum.map(&clock_match_seconds/1)
  end

  defp clock_match_seconds([_match, minutes, seconds]),
    do: String.to_integer(minutes) * 60 + String.to_integer(seconds)

  defp clock_match_seconds([_match, hours, minutes, seconds]),
    do:
      String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
        String.to_integer(seconds)

  defp max_clock_seconds(transcript) do
    transcript
    |> clock_seconds()
    |> Enum.max(fn -> 0 end)
  end

  defp duration_minutes(captions, context) do
    case context["duration_seconds"] do
      seconds when is_integer(seconds) and seconds > 0 -> minutes_from_seconds(seconds)
      _ -> captions |> caption_duration_seconds() |> minutes_from_seconds()
    end
  end

  defp actual_duration_seconds(_state, _captions, audio_duration_seconds)
       when is_integer(audio_duration_seconds) and audio_duration_seconds > 0,
       do: audio_duration_seconds

  defp actual_duration_seconds(state, captions, _audio_duration_seconds) do
    joined_at = state["joined_at"]
    left_at = state["left_at"]

    if is_integer(joined_at) and is_integer(left_at) and left_at > joined_at do
      left_at - joined_at
    else
      caption_duration_seconds(captions)
    end
  end

  defp caption_duration_seconds(captions) do
    ts = captions |> Enum.map(&timestamp/1) |> Enum.filter(&(&1 > 0))

    case ts do
      [] ->
        0

      _ ->
        max(Enum.max(ts) - Enum.min(ts), 0)
    end
  end

  defp minutes_from_seconds(seconds) when seconds > 0, do: max(1, div(seconds + 30, 60))
  defp minutes_from_seconds(_seconds), do: 0

  @doc false
  def sufficient_evidence?(transcript) do
    {units, runes} = evidence_metrics(transcript)
    units >= @min_units and runes >= @min_runes
  end

  defp evidence_metrics(text) do
    text
    |> String.split("\n")
    |> Enum.map(&strip_line_metadata/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({0, 0}, fn content, {units, runes} ->
      {units + max(1, sentence_units(content)), runes + String.length(content)}
    end)
  end

  defp strip_line_metadata(line) do
    content = String.trim(line)

    content =
      case Regex.run(~r/^\[[^\]]*\]\s*(.*)$/u, content) do
        [_, rest] -> String.trim(rest)
        _ -> content
      end

    case Regex.run(~r/^[^:：]+[:：]\s*(.+)$/u, content) do
      [_, rest] -> String.trim(rest)
      _ -> content
    end
  end

  defp sentence_units(text) do
    text
    |> String.graphemes()
    |> Enum.count(&(&1 in [".", "!", "?", "。", "！", "？", ";", "；"]))
  end

  @doc false
  def parse_summary(content) do
    content
    |> extract_json()
    |> Jason.decode()
    |> case do
      {:ok, map} when is_map(map) -> {:ok, normalize_summary(map)}
      _ -> {:error, :parse_failed}
    end
  end

  defp extract_json(text) do
    text = text |> String.trim() |> strip_code_fence()

    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      _ -> text
    end
  end

  defp strip_code_fence(text) do
    text = String.trim(text)

    cond do
      String.starts_with?(text, "```") ->
        text
        |> String.replace(~r/^```[a-zA-Z]*\n/, "")
        |> String.replace(~r/\n```$/, "")
        |> String.trim()

      true ->
        text
    end
  end

  defp normalize_summary(map) do
    %{
      "title" => trim(map["title"]),
      "attendees" => list_of_strings(map["attendees"]),
      "duration_minutes" => map["duration_minutes"],
      "timeline" => List.wrap(map["timeline"]),
      "key_points" => list_of_strings(map["key_points"]),
      "action_items" => normalize_action_items(map["action_items"]),
      "decisions" => list_of_strings(map["decisions"]),
      "open_questions" => list_of_strings(map["open_questions"]),
      "blockers" => list_of_strings(map["blockers"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp list_of_strings(list) do
    list
    |> List.wrap()
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_action_items(list) do
    list
    |> List.wrap()
    |> Enum.map(fn
      item when is_map(item) ->
        %{
          "description" => trim(item["description"]),
          "owner" => trim(item["owner"]),
          "deadline" => trim(item["deadline"])
        }

      item ->
        %{"description" => trim(item), "owner" => "", "deadline" => ""}
    end)
    |> Enum.reject(&(&1["description"] == ""))
  end

  defp trim_context_transcript(value) when is_binary(value), do: value
  defp trim_context_transcript(_), do: ""

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 0

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: -1

  defp transcript_fingerprint(transcript) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, transcript), case: :lower)
  end

  defp get(map, key) when is_map(map), do: map[key] || map[String.to_atom(key)]
  defp get(_, _), do: nil

  defp timestamp(caption) do
    case get(caption, "timestamp") do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      n when is_binary(n) -> String.to_integer(String.trim(n))
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp trim(nil), do: ""
  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v), do: v |> to_string() |> String.trim()
end
