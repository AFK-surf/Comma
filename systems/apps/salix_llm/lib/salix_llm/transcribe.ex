defmodule SalixLlm.Transcribe do
  @moduledoc false

  alias SalixLlm.AudioChunker

  @receive_timeout 180_000
  @chunk_task_timeout 190_000
  @batch_timeout 600_000
  @max_chunk_concurrency 2

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
      System.monotonic_time(:millisecond) +
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
        :ffprobe
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
         {:ok, results} <- run_chunk_transcriptions_bounded(cfg, chunks, prompt, opts),
         {:ok, texts} <- collect_complete_results(chunks, results) do
      transcript =
        texts
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
        |> String.trim()

      if transcript == "" do
        {:error, :asr_empty_transcript}
      else
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

  defp do_transcribe(base_url, model, key, cfg, audio_b64, format, prompt) do
    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

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
    task_timeout = opts[:task_timeout_ms] || @chunk_task_timeout

    chunks
    |> Task.async_stream(
      fn chunk -> transcribe_chunk(cfg, chunk, prompt, transcribe_fun) end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp run_chunk_transcriptions_bounded(cfg, chunks, prompt, opts) do
    with {:ok, timeout} <- remaining_batch_timeout(opts) do
      task = Task.async(fn -> run_chunk_transcriptions(cfg, chunks, prompt, opts) end)

      case Task.yield(task, timeout) do
        {:ok, results} ->
          {:ok, results}

        {:exit, reason} ->
          {:error, {:asr_batch_exit, reason}}

        nil ->
          case Task.shutdown(task, :brutal_kill) do
            {:ok, results} -> {:ok, results}
            _ -> {:error, :asr_batch_timeout}
          end
      end
    end
  end

  defp remaining_batch_timeout(opts) do
    case opts[:deadline_ms] do
      deadline_ms when is_integer(deadline_ms) ->
        remaining = deadline_ms - System.monotonic_time(:millisecond)

        if remaining > 0,
          do: {:ok, remaining},
          else: {:error, :asr_batch_timeout}

      _ ->
        {:ok, positive_integer(opts[:batch_timeout_ms], @batch_timeout)}
    end
  end

  defp transcribe_chunk(cfg, chunk, prompt, transcribe_fun) do
    with {:ok, bytes} <- File.read(chunk.path) do
      case transcribe_fun.(cfg, Base.encode64(bytes), chunk.format, prompt) do
        {:ok, text} when is_binary(text) ->
          {:ok, rebase_timestamps(String.trim(text), chunk.offset_seconds)}

        {:error, :asr_empty_transcript} ->
          {:ok, ""}

        {:error, _} = error ->
          error

        other ->
          {:error, {:invalid_asr_chunk_response, other}}
      end
    end
  rescue
    error -> {:error, {:asr_chunk_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:asr_chunk_exit, kind, reason}}
  end

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
