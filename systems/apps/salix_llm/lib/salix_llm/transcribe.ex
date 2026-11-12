defmodule SalixLlm.Transcribe do
  @moduledoc false

  require Logger
  require SystemsRuntime.Proc

  alias SalixAgent.AudioTranscriber
  alias SalixLlm.AudioChunker

  @receive_timeout 180_000
  @batch_timeout 600_000
  @max_chunk_concurrency 2
  # A chunk the model fails on is asked again as parts this long. On prod
  # (2026-11), a recording's failing 5-minute chunk failed again on every retry,
  # while the same audio cut into one-minute parts transcribed.
  @split_seconds 60
  # With `voice: true` (recordings), a chunk with less speech than this is not
  # asked: on silence or room noise the model writes whole made-up
  # conversations and ends with `stop`. `min_voiced_seconds:` names a lower
  # floor for dictation, where a whole clip can be one short word.
  @min_voiced_seconds 1.0
  # Words more than anyone says in a chunk's voiced time are made up. The
  # weight (`spoken_weight/1`) measured 15 to 19 for each voiced second of
  # dictation, and 40 leaves room for fast speakers.
  @max_weight_per_voiced_second 40
  # A transcript whose last timestamp is this far before the chunk's last
  # speech has left the end out (seen with `stop`: 1.5 minutes missing).
  @max_unwritten_tail_seconds 90
  # The model declines audio (`content_filter: OTHER`) at random: on prod
  # (2026-11, Cue #5089), the same minute was declined 3 times in 10 and the
  # 5-minute chunk around it once in 10, while `gemini-3.6-flash` declined
  # none of 30 (Cue #5094). A declined chunk or part goes to the tier's
  # `fallback_model`, else to the tier's model again, up to this many times
  # before it is cut or noted.
  @declined_attempts 3
  # Audio still declined after that is noted in the transcript with this line
  # instead of failing the recording.
  @declined_note "(Not transcribed: the transcription model declined this audio until "

  @type cfg :: %{optional(String.t()) => String.t()}
  @type chunk_manifest_entry :: %{
          index: non_neg_integer(),
          offset_seconds: non_neg_integer(),
          transcript: String.t()
        }
  @type audio_metadata :: %{
          transcript: String.t(),
          duration_seconds: pos_integer(),
          chunks: [chunk_manifest_entry()]
        }

  @spec transcribe(cfg(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def transcribe(cfg, audio_b64, format, prompt)
      when is_map(cfg) and is_binary(audio_b64) do
    base_url = cfg |> Map.get("base_url", "") |> to_string() |> String.trim()
    model = cfg |> Map.get("model", "") |> to_string() |> String.trim()
    key = api_key(cfg)

    cond do
      base_url == "" -> {:error, :asr_base_url_missing}
      model == "" -> {:error, :asr_model_missing}
      key == "" -> {:error, :asr_api_key_missing}
      audio_b64 == "" -> {:error, :asr_audio_empty}
      true -> do_transcribe(base_url, model, key, cfg, audio_b64, format, prompt)
    end
  end

  @spec transcribe_audio(cfg(), binary(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def transcribe_audio(cfg, audio, source_filename, prompt, opts \\ [])
      when is_map(cfg) and is_binary(audio) and is_binary(source_filename) do
    with {:ok, result} <-
           transcribe_audio_with_metadata(cfg, audio, source_filename, prompt, opts) do
      {:ok, result.transcript}
    end
  end

  @spec transcribe_audio_with_metadata(cfg(), binary(), String.t(), String.t(), keyword()) ::
          {:ok, audio_metadata()} | {:error, term()}
  def transcribe_audio_with_metadata(cfg, audio, source_filename, prompt, opts \\ [])
      when is_map(cfg) and is_binary(audio) and is_binary(source_filename) do
    chunker = opts[:chunker] || AudioChunker

    transcribe_audio_source_with_metadata(cfg, prompt, opts, fn callback, chunker_opts ->
      chunker.with_mp3_chunks(audio, source_filename, callback, chunker_opts)
    end)
  end

  @spec transcribe_audio_stream_with_metadata(
          cfg(),
          Enumerable.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, audio_metadata()} | {:error, term()}
  def transcribe_audio_stream_with_metadata(
        cfg,
        stream,
        source_size,
        source_filename,
        prompt,
        opts \\ []
      )
      when is_map(cfg) and is_integer(source_size) and is_binary(source_filename) do
    chunker = opts[:chunker] || AudioChunker

    transcribe_audio_source_with_metadata(cfg, prompt, opts, fn callback, chunker_opts ->
      chunker.with_mp3_chunks_stream(
        stream,
        source_size,
        source_filename,
        callback,
        chunker_opts
      )
    end)
  end

  defp transcribe_audio_source_with_metadata(cfg, prompt, opts, run_chunker) do
    deadline_ms =
      SystemsClock.monotonic_time(:millisecond) +
        positive_integer(opts[:batch_timeout_ms], @batch_timeout)

    opts = Keyword.put(opts, :deadline_ms, deadline_ms)

    run_chunker.(
      fn chunks ->
        with {:ok, duration_seconds} <- source_duration_seconds(chunks),
             {:ok, transcript, chunk_manifest} <-
               transcribe_chunks_with_manifest(cfg, chunks, prompt, opts) do
          {:ok,
           %{
             transcript: transcript,
             duration_seconds: duration_seconds,
             chunks: chunk_manifest
           }}
        end
      end,
      Keyword.take(opts, [
        :segment_seconds,
        :max_chunks,
        :timeout_ms,
        :deadline_ms,
        :ffmpeg,
        :ffprobe,
        :silk_decoder,
        :voice
      ])
    )
  end

  @spec transcribe_chunks(cfg(), [AudioChunker.chunk()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def transcribe_chunks(cfg, chunks, prompt, opts \\ []) when is_map(cfg) and is_list(chunks) do
    with {:ok, transcript, _chunk_manifest} <-
           transcribe_chunks_with_manifest(cfg, chunks, prompt, opts) do
      {:ok, transcript}
    end
  end

  defp transcribe_chunks_with_manifest(cfg, chunks, prompt, opts) do
    with {:ok, chunks} <- complete_ordered_chunks(chunks),
         chunks = with_end_seconds(chunks),
         {:ok, results} <- run_chunk_transcriptions_bounded(cfg, chunks, prompt, opts),
         {:ok, texts} <- collect_complete_results(chunks, results) do
      transcript =
        texts
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
        |> String.trim()

      cond do
        transcript == "" ->
          {:error, :asr_empty_transcript}

        only_declined_notes?(transcript) ->
          {:error, :asr_declined}

        true ->
          chunk_manifest =
            Enum.zip_with(chunks, texts, fn chunk, text ->
              %{
                index: chunk.index,
                offset_seconds: chunk.offset_seconds,
                transcript: text
              }
            end)

          {:ok, transcript, chunk_manifest}
      end
    end
  end

  defp only_declined_notes?(transcript) do
    transcript
    |> String.split("\n", trim: true)
    |> Enum.all?(&String.contains?(&1, @declined_note))
  end

  @doc false
  def rebase_timestamps(text, offset_seconds)
      when is_binary(text) and is_integer(offset_seconds) and offset_seconds >= 0 do
    rebased =
      Regex.replace(
        ~r/\[(\d+):([0-5]\d):([0-5]\d)\]/,
        text,
        fn _match, hours, minutes, seconds ->
          total =
            String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
              String.to_integer(seconds) + offset_seconds

          format_clock(total)
        end
      )

    Regex.replace(~r/\[(\d+):([0-5]\d)\]/, rebased, fn _match, minutes, seconds ->
      total = String.to_integer(minutes) * 60 + String.to_integer(seconds) + offset_seconds
      format_clock(total)
    end)
  end

  @doc """
  A `:transcribe_fun` that asks once more when the first request has not
  answered after `after_ms`, or failed, and returns the first complete
  transcript; the other request is stopped. At most two requests are made,
  and both failing returns the first failure.

  The provider's slow answers are independent of each other: on 2026-10-13,
  16% of dictation requests took over 10 s, while a second request sent
  alongside a slow one was no more likely to be slow than any other.
  """
  @spec hedged(
          (cfg(), String.t(), String.t(), String.t() -> {:ok, String.t()} | {:error, term()}),
          pos_integer()
        ) :: (cfg(), String.t(), String.t(), String.t() -> {:ok, String.t()} | {:error, term()})
  def hedged(transcribe_fun, after_ms) when is_function(transcribe_fun, 4) do
    fn cfg, audio_b64, format, prompt ->
      attempt = fn -> attempt(transcribe_fun, cfg, audio_b64, format, prompt) end
      first = SystemsRuntime.Task.async(attempt)

      case SystemsClock.yield(first, after_ms) do
        {:ok, {:ok, _text} = transcript} ->
          transcript

        {:ok, failure} ->
          first_transcript([SystemsRuntime.Task.async(attempt)], failure)

        {:exit, reason} ->
          first_transcript(
            [SystemsRuntime.Task.async(attempt)],
            {:error, {:asr_chunk_exit, :exit, reason}}
          )

        nil ->
          first_transcript([first, SystemsRuntime.Task.async(attempt)], nil)
      end
    end
  end

  # A failure is an answer: the request's process always replies.
  defp attempt(transcribe_fun, cfg, audio_b64, format, prompt) do
    transcribe_fun.(cfg, audio_b64, format, prompt)
  rescue
    error -> {:error, {:asr_chunk_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:asr_chunk_exit, kind, reason}}
  end

  defp first_transcript([], failure), do: failure

  defp first_transcript(tasks, failure) do
    refs = Map.new(tasks, &{&1.ref, &1})

    SystemsRuntime.Proc.receive do
      {ref, answer} when is_map_key(refs, ref) ->
        SystemsRuntime.Proc.demonitor(ref, [:flush])
        rest = refs |> Map.delete(ref) |> Map.values()

        case answer do
          {:ok, _text} ->
            Enum.each(rest, &SystemsRuntime.Task.shutdown(&1, :brutal_kill))
            answer

          _failure ->
            first_transcript(rest, failure || answer)
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(refs, ref) ->
        rest = refs |> Map.delete(ref) |> Map.values()
        first_transcript(rest, failure || {:error, {:asr_chunk_exit, :exit, reason}})
    end
  end

  defp do_transcribe(base_url, model, key, cfg, audio_b64, format, prompt) do
    url = String.trim_trailing(base_url, "/") <> "/chat/completions"
    body = request_body(model, cfg, audio_b64, format, prompt)

    headers =
      [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}] ++
        header_pairs(cfg["headers"])

    case Req.post(url, json: body, headers: headers, receive_timeout: @receive_timeout) do
      {:ok, %{status: 200, body: resp}} ->
        complete_content(resp)

      {:ok, %{status: status, body: resp}} ->
        {:error, {:asr_http, status, preview(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # The chat-completions request: the prompt, then the audio, at the reasoning
  # effort the tier names (`SalixAgent.PlatformModels`), if any.
  def request_body(model, cfg, audio_b64, format, prompt) do
    body = %{
      "model" => model,
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => prompt},
            %{
              "type" => "input_audio",
              "input_audio" => %{"data" => audio_b64, "format" => format}
            }
          ]
        }
      ]
    }

    case cfg["reasoning_effort"] do
      effort when is_binary(effort) and effort != "" -> Map.put(body, "reasoning_effort", effort)
      _none -> body
    end
  end

  defp complete_ordered_chunks([]), do: {:error, :asr_chunks_empty}

  defp complete_ordered_chunks(chunks) do
    chunks = Enum.sort_by(chunks, & &1.index)
    indexes = Enum.map(chunks, & &1.index)

    if indexes == Enum.to_list(0..(length(chunks) - 1)) and
         Enum.all?(chunks, &valid_chunk?/1) do
      {:ok, chunks}
    else
      {:error, :asr_chunks_incomplete}
    end
  end

  # Each chunk (or part) ends where the next one starts; the last one where
  # its source does.
  defp with_end_seconds(chunks) do
    ends =
      chunks
      |> Enum.drop(1)
      |> Enum.map(& &1.offset_seconds)
      |> Enum.concat([last_end_seconds(List.last(chunks))])

    Enum.zip_with(chunks, ends, &Map.put(&1, :end_seconds, &2))
  end

  defp last_end_seconds(%{source_duration_seconds: seconds, offset_seconds: offset})
       when is_integer(seconds) and seconds > offset,
       do: seconds

  defp last_end_seconds(chunk), do: chunk.offset_seconds + @split_seconds

  defp source_duration_seconds([%{source_duration_seconds: seconds} | _])
       when is_integer(seconds) and seconds > 0,
       do: {:ok, seconds}

  defp source_duration_seconds(_chunks), do: {:error, :asr_duration_missing}

  defp valid_chunk?(chunk) do
    is_integer(chunk.index) and chunk.index >= 0 and is_integer(chunk.offset_seconds) and
      chunk.offset_seconds >= 0 and is_binary(chunk.path) and chunk.path != "" and
      chunk.format == "mp3"
  end

  defp run_chunk_transcriptions(cfg, chunks, prompt, opts) do
    transcribe_fun = opts[:transcribe_fun] || (&transcribe/4)
    max_concurrency = opts |> Keyword.get(:max_concurrency, @max_chunk_concurrency) |> clamp(1, 2)
    # Each request is bounded by its receive timeout; a chunk asked again as
    # parts takes longer, so only the batch deadline bounds a chunk.
    task_timeout = opts[:task_timeout_ms] || opts[:batch_remaining_ms]

    chunks
    |> SystemsClock.async_stream(
      fn chunk -> transcribe_chunk(cfg, chunk, prompt, transcribe_fun, opts) end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp run_chunk_transcriptions_bounded(cfg, chunks, prompt, opts) do
    with {:ok, timeout} <- remaining_batch_timeout(opts) do
      task =
        SystemsRuntime.Task.async(fn ->
          run_chunk_transcriptions(
            cfg,
            chunks,
            prompt,
            Keyword.put(opts, :batch_remaining_ms, timeout)
          )
        end)

      case SystemsClock.yield(task, timeout) do
        {:ok, results} ->
          {:ok, results}

        {:exit, reason} ->
          {:error, {:asr_batch_exit, reason}}

        nil ->
          case SystemsRuntime.Task.shutdown(task, :brutal_kill) do
            {:ok, results} -> {:ok, results}
            _ -> {:error, :asr_batch_timeout}
          end
      end
    end
  end

  defp remaining_batch_timeout(opts) do
    case opts[:deadline_ms] do
      deadline_ms when is_integer(deadline_ms) ->
        remaining = deadline_ms - SystemsClock.monotonic_time(:millisecond)

        if remaining > 0,
          do: {:ok, remaining},
          else: {:error, :asr_batch_timeout}

      _ ->
        {:ok, positive_integer(opts[:batch_timeout_ms], @batch_timeout)}
    end
  end

  defp transcribe_chunk(cfg, chunk, prompt, transcribe_fun, opts) do
    floor = opts[:min_voiced_seconds] || @min_voiced_seconds

    if is_number(chunk[:voiced_seconds]) and chunk.voiced_seconds < floor do
      Logger.info("ASR chunk skipped without speech: index=#{chunk.index}")
      {:ok, ""}
    else
      transcribe_voiced_chunk(cfg, chunk, prompt, transcribe_fun, opts)
    end
  end

  defp transcribe_voiced_chunk(cfg, chunk, prompt, transcribe_fun, opts) do
    with {:ok, bytes} <- File.read(chunk.path) do
      case asked_until_not_declined(cfg, fn cfg ->
             checked_transcript(cfg, bytes, chunk, prompt, transcribe_fun)
           end) do
        {:ok, text} ->
          {:ok, rebase_timestamps(text, chunk.offset_seconds)}

        {:error, :asr_empty_transcript} ->
          {:ok, ""}

        answer ->
          reason = failure_reason(answer)

          Logger.warning(
            "ASR chunk failed: index=#{chunk.index} offset_seconds=#{chunk.offset_seconds} reason=#{AudioTranscriber.failure_reason(reason)}"
          )

          case transcribe_in_parts(cfg, bytes, prompt, transcribe_fun, opts) do
            {:ok, text} ->
              Logger.info("ASR chunk transcribed in parts: index=#{chunk.index}")
              {:ok, rebase_timestamps(text, chunk.offset_seconds)}

            {:error, :asr_empty_transcript} ->
              {:ok, ""}

            {:error, part_reason} = part_failure ->
              Logger.warning(
                "ASR chunk failed in parts: index=#{chunk.index} reason=#{AudioTranscriber.failure_reason(part_reason)}"
              )

              # A suspect answer is still an answer when its parts fail.
              if match?({:suspect, _, _}, answer),
                do: unsplit_result(answer, chunk),
                else: part_failure

            :unsplit ->
              if declined?(answer),
                do: {:ok, declined_line(chunk)},
                else: unsplit_result(answer, chunk)
          end
      end
    end
  rescue
    error -> {:error, {:asr_chunk_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:asr_chunk_exit, kind, reason}}
  end

  defp transcribe_bytes(cfg, bytes, format, prompt, transcribe_fun) do
    case transcribe_fun.(cfg, Base.encode64(bytes), format, prompt) do
      {:ok, text} when is_binary(text) -> clean_transcript(text)
      {:error, _} = error -> error
      other -> {:error, {:invalid_asr_chunk_response, other}}
    end
  end

  # A transcript that the audio's speech cannot hold is `{:suspect, reason,
  # text}`: more words than its voiced time (`:asr_words_exceed_audio`), or
  # ending long before its speech does (`:asr_transcript_ends_early`). Chunks
  # without voice facts are taken as they come.
  defp checked_transcript(cfg, bytes, chunk, prompt, transcribe_fun) do
    with {:ok, text} <- transcribe_bytes(cfg, bytes, chunk.format, prompt, transcribe_fun) do
      cond do
        not is_number(chunk[:voiced_seconds]) ->
          {:ok, text}

        spoken_weight(text) > 10 + @max_weight_per_voiced_second * chunk.voiced_seconds ->
          {:suspect, :asr_words_exceed_audio, text}

        ends_early?(text, chunk[:speech_end_seconds]) ->
          {:suspect, :asr_transcript_ends_early, text}

        true ->
          {:ok, text}
      end
    end
  end

  defp failure_reason({:suspect, reason, _text}), do: reason
  defp failure_reason({:error, reason}), do: reason

  # A chunk that cannot be cut (or whose parts fail) keeps what its one answer
  # gives: made-up words are dropped, a transcript that ends early is still
  # the best there is.
  defp unsplit_result({:suspect, :asr_words_exceed_audio, _text}, chunk) do
    Logger.warning("ASR chunk dropped as made up: index=#{chunk.index}")
    {:ok, ""}
  end

  defp unsplit_result({:suspect, _reason, text}, chunk),
    do: {:ok, rebase_timestamps(text, chunk.offset_seconds)}

  defp unsplit_result(failure, _chunk), do: failure

  defp ends_early?(text, speech_end) when is_number(speech_end) do
    case Regex.scan(~r/\[(?:(\d+):)?(\d+):([0-5]\d)\]/, text) do
      [] ->
        false

      stamps ->
        [_match, hours, minutes, seconds] = List.last(stamps)
        hours = if hours == "", do: 0, else: String.to_integer(hours)
        last = hours * 3600 + String.to_integer(minutes) * 60 + String.to_integer(seconds)
        speech_end - last > @max_unwritten_tail_seconds
    end
  end

  defp ends_early?(_text, _speech_end), do: false

  # About 3 for each Han, kana or Hangul character, which says a syllable or
  # more, and 1 for any other letter, digit or mark, as dictation counts.
  # Timestamps and speaker names at the start of a line are not speech.
  defp spoken_weight(text) do
    text
    |> String.replace(~r/^[ \t]*\[[\d:]+\][ \t]*(?:[^:：\n]{1,40}[:：])?/mu, "")
    |> String.to_charlist()
    |> Enum.reduce(0, fn
      c, sum when c in [?\s, ?\n, ?\t] -> sum
      c, sum when c in 0x3040..0x30FF or c in 0x3400..0x9FFF or c in 0xAC00..0xD7AF -> sum + 3
      _c, sum -> sum + 1
    end)
  end

  # Zero-width characters and an empty code fence are what the model answers
  # for music alone; they are no transcript.
  defp clean_transcript(text) do
    text = String.replace(text, ~r/[\x{200B}-\x{200D}\x{2060}\x{FEFF}]/u, "")

    text =
      case Regex.run(~r/\A\s*```[\w-]*[ \t]*\n?(.*?)\n?```\s*\z/s, text) do
        [_fence, inner] -> inner
        nil -> text
      end

    complete_transcript(text)
  end

  # The failed chunk cut into `@split_seconds` parts, asked in turn. `:unsplit`
  # when it cannot be cut or is a single part: the chunk's own failure stands.
  defp transcribe_in_parts(cfg, bytes, prompt, transcribe_fun, opts) do
    chunker = opts[:part_chunker] || AudioChunker

    chunker_opts =
      opts
      |> Keyword.take([:timeout_ms, :deadline_ms, :ffmpeg, :ffprobe, :voice])
      |> Keyword.put(:segment_seconds, opts[:split_seconds] || @split_seconds)

    chunker.with_mp3_chunks(
      bytes,
      "chunk.mp3",
      fn
        [_single] ->
          :unsplit

        parts ->
          parts
          |> Enum.sort_by(& &1.index)
          |> with_end_seconds()
          |> Enum.reduce_while({:ok, []}, fn part, {:ok, texts} ->
            case transcribe_part(cfg, part, prompt, transcribe_fun) do
              {:ok, ""} ->
                {:cont, {:ok, texts}}

              :declined ->
                Logger.warning("ASR part declined: index=#{part.index}")
                {:cont, {:ok, [declined_line(part) | texts]}}

              {:ok, text} ->
                {:cont, {:ok, [rebase_timestamps(text, part.offset_seconds) | texts]}}

              {:error, reason} ->
                {:halt, {:error, {:asr_part_failed, part.index, reason}}}
            end
          end)
          |> case do
            {:ok, []} -> {:error, :asr_empty_transcript}
            {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
            error -> error
          end
      end,
      chunker_opts
    )
    |> case do
      {:ok, _} = ok -> ok
      :unsplit -> :unsplit
      {:error, :asr_empty_transcript} = empty -> empty
      {:error, {:asr_part_failed, _, _}} = error -> error
      # The chunker could not cut it (or ran out of time): the chunk's own failure stands.
      {:error, _} -> :unsplit
    end
  end

  defp transcribe_part(_cfg, %{voiced_seconds: voiced}, _prompt, _fun)
       when voiced < @min_voiced_seconds,
       do: {:ok, ""}

  defp transcribe_part(cfg, part, prompt, transcribe_fun) do
    with {:ok, bytes} <- File.read(part.path) do
      case asked_until_not_declined(cfg, fn cfg ->
             checked_transcript(cfg, bytes, part, prompt, transcribe_fun)
           end) do
        {:ok, text} ->
          {:ok, text}

        {:error, :asr_empty_transcript} ->
          {:ok, ""}

        {:suspect, :asr_words_exceed_audio, _text} ->
          Logger.warning("ASR part dropped as made up: index=#{part.index}")
          {:ok, ""}

        {:suspect, _reason, text} ->
          {:ok, text}

        {:error, _reason} = error ->
          if declined?(error), do: :declined, else: error
      end
    end
  end

  # Declined audio goes at once to the tier's `fallback_model`, asked up to
  # `@declined_attempts` times; without one, the tier's model is asked again
  # that many times in all.
  defp asked_until_not_declined(cfg, ask) do
    case cfg["fallback_model"] do
      model when is_binary(model) and model != "" ->
        answer = ask.(cfg)

        if declined?(answer) do
          Logger.warning("ASR declined audio asked of the fallback model")
          asked(cfg |> Map.put("model", model) |> Map.delete("fallback_model"), ask, 1)
        else
          answer
        end

      _none ->
        asked(cfg, ask, 1)
    end
  end

  defp asked(cfg, ask, attempt) do
    answer = ask.(cfg)

    if declined?(answer) and attempt < @declined_attempts,
      do: asked(cfg, ask, attempt + 1),
      else: answer
  end

  defp declined?({:error, {:asr_incomplete_transcript, reason}}) when is_binary(reason),
    do: String.starts_with?(reason, "content_filter")

  defp declined?(_answer), do: false

  # Where a declined chunk or part starts and ends, in the time of the audio it
  # was cut from: a part's line is rebased with its chunk's words.
  defp declined_line(%{offset_seconds: start, end_seconds: stop}),
    do: "#{format_clock(start)} #{@declined_note}#{format_clock(stop)}.)"

  defp collect_complete_results(chunks, results) when length(chunks) == length(results) do
    chunks
    |> Enum.zip(results)
    |> Enum.reduce_while({:ok, []}, fn
      {_chunk, {:ok, {:ok, text}}}, {:ok, acc} ->
        {:cont, {:ok, [text | acc]}}

      {chunk, {:ok, {:error, reason}}}, _acc ->
        {:halt, {:error, {:asr_chunk_failed, chunk.index, reason}}}

      {chunk, {:exit, reason}}, _acc ->
        {:halt, {:error, {:asr_chunk_failed, chunk.index, reason}}}
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      error -> error
    end
  end

  defp collect_complete_results(_chunks, _results), do: {:error, :asr_chunks_incomplete}

  defp format_clock(total_seconds) do
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    "[#{pad(hours)}:#{pad(minutes)}:#{pad(seconds)}]"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  @spec accumulate_content(term()) :: String.t()
  def accumulate_content(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce("", fn line, acc ->
      case sse_data(line) do
        :skip -> acc
        {:ok, chunk} -> acc <> delta_content(chunk)
      end
    end)
    |> String.trim()
  end

  def accumulate_content(%{"choices" => choices}) when is_list(choices) do
    choices
    |> List.first(%{})
    |> get_in(["message", "content"])
    |> to_string()
    |> String.trim()
  end

  def accumulate_content(_), do: ""

  @doc false
  @spec complete_content(term()) :: {:ok, String.t()} | {:error, term()}
  def complete_content(body) when is_binary(body), do: complete_sse_content(body)

  def complete_content(body) do
    cond do
      provider_error_event?(body) ->
        {:error, :asr_provider_error}

      reason = incomplete_finish_reason(body) ->
        {:error, {:asr_incomplete_transcript, reason}}

      not successful_finish_reason?(body) ->
        {:error, :asr_response_incomplete}

      true ->
        complete_transcript(accumulate_content(body))
    end
  end

  defp complete_sse_content(body) do
    state =
      body
      |> String.split("\n")
      |> Enum.reduce(
        %{
          content: [],
          incomplete_reason: nil,
          malformed?: false,
          provider_error?: false,
          terminated?: false
        },
        &consume_sse_line/2
      )

    cond do
      state.provider_error? ->
        {:error, :asr_provider_error}

      state.malformed? ->
        {:error, :asr_malformed_sse}

      state.incomplete_reason ->
        {:error, {:asr_incomplete_transcript, state.incomplete_reason}}

      not state.terminated? ->
        {:error, :asr_stream_incomplete}

      true ->
        state.content
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> complete_transcript()
    end
  end

  defp consume_sse_line(line, state) do
    line = String.trim(line)

    cond do
      line == "" ->
        state

      String.starts_with?(line, "event:") ->
        event_name = line |> String.replace_prefix("event:", "") |> String.trim()

        %{state | provider_error?: state.provider_error? or provider_error_name?(event_name)}

      String.starts_with?(line, "data:") ->
        line
        |> String.replace_prefix("data:", "")
        |> String.trim()
        |> consume_sse_data(state)

      true ->
        state
    end
  end

  defp consume_sse_data("", state), do: state
  defp consume_sse_data("[DONE]", state), do: %{state | terminated?: true}

  defp consume_sse_data(payload, state) do
    case Jason.decode(payload) do
      {:ok, %{} = chunk} ->
        content = delta_content(chunk)

        %{
          state
          | content: if(content == "", do: state.content, else: [content | state.content]),
            incomplete_reason: incomplete_finish_reason(chunk) || state.incomplete_reason,
            provider_error?: state.provider_error? or provider_error_event?(chunk),
            terminated?: state.terminated? or successful_finish_reason?(chunk)
        }

      _ ->
        %{state | malformed?: true}
    end
  end

  defp complete_transcript(content) do
    case String.trim(content) do
      "" -> {:error, :asr_empty_transcript}
      text -> {:ok, text}
    end
  end

  defp successful_finish_reason?(%{"choices" => choices}) when is_list(choices) do
    Enum.any?(choices, fn
      %{"finish_reason" => reason} when is_binary(reason) ->
        reason |> String.trim() |> String.downcase() |> then(&(&1 in ["stop", "end_turn"]))

      _choice ->
        false
    end)
  end

  defp successful_finish_reason?(_body), do: false

  defp provider_error_event?(%{"error" => _error}), do: true

  defp provider_error_event?(%{"type" => type}) when is_binary(type),
    do: provider_error_name?(type)

  defp provider_error_event?(%{"object" => object}) when is_binary(object),
    do: provider_error_name?(object)

  defp provider_error_event?(_body), do: false

  defp provider_error_name?(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["error", "response.error"]))
  end

  defp provider_error_name?(_name), do: false

  defp incomplete_finish_reason(%{"choices" => choices}) when is_list(choices) do
    Enum.find_value(choices, fn
      %{"finish_reason" => reason} when is_binary(reason) ->
        case String.downcase(String.trim(reason)) do
          reason when reason in ["", "stop", "end_turn"] -> nil
          _reason -> reason
        end

      _choice ->
        nil
    end)
  end

  defp incomplete_finish_reason(_body), do: nil

  defp sse_data(line) do
    line = String.trim(line)

    cond do
      not String.starts_with?(line, "data:") ->
        :skip

      true ->
        payload = line |> String.replace_prefix("data:", "") |> String.trim()

        if payload == "" or payload == "[DONE]" do
          :skip
        else
          case Jason.decode(payload) do
            {:ok, chunk} -> {:ok, chunk}
            _ -> :skip
          end
        end
    end
  end

  defp delta_content(%{"choices" => [%{"delta" => %{"content" => c}} | _]}) when is_binary(c),
    do: c

  defp delta_content(_), do: ""

  defp api_key(cfg) do
    case cfg |> Map.get("api_key", "") |> to_string() |> String.trim() do
      "" ->
        cfg
        |> Map.get("api_key_env", "")
        |> to_string()
        |> String.trim()
        |> case do
          "" -> ""
          env -> env |> System.get_env() |> to_string() |> String.trim()
        end

      key ->
        key
    end
  end

  defp header_pairs(headers) when is_map(headers),
    do: Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp header_pairs(_), do: []

  defp preview(resp) when is_binary(resp), do: String.slice(resp, 0, 300)
  defp preview(resp), do: resp |> inspect() |> String.slice(0, 300)
end
