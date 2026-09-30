defmodule SalixLlm.AudioChunker do
  @moduledoc false

  @segment_seconds 300
  @max_chunks 48
  @max_audio_bytes 30 * 1024 * 1024
  @timeout_ms 300_000
  @probe_timeout_ms 30_000
  @stderr_limit 8_192
  @duration_boundary_tolerance_seconds 0.1
  @chunk_sample_rate_hz 16_000
  @minimum_mp3_playable_sample_count 47
  @sample_count_tolerance_per_chunk 1
  @sample_probe_remainder_limit 64

  @type chunk :: %{
          index: non_neg_integer(),
          offset_seconds: non_neg_integer(),
          path: String.t(),
          format: String.t(),
          source_duration_seconds: pos_integer()
        }

  @spec with_mp3_chunks(binary(), String.t(), ([chunk()] -> term()), keyword()) :: term()
  def with_mp3_chunks(audio, source_filename, callback, opts \\ [])
      when is_binary(audio) and is_binary(source_filename) and is_function(callback, 1) do
    cond do
      audio == "" ->
        {:error, :asr_audio_empty}

      byte_size(audio) > @max_audio_bytes ->
        {:error, :asr_audio_too_large}

      true ->
        do_with_mp3_chunks({:binary, audio}, source_filename, callback, opts)
    end
  end

  @spec with_mp3_chunks_stream(
          Enumerable.t(),
          non_neg_integer(),
          String.t(),
          ([chunk()] -> term()),
          keyword()
        ) :: term()
  def with_mp3_chunks_stream(stream, source_size, source_filename, callback, opts \\ [])
      when is_integer(source_size) and is_binary(source_filename) and is_function(callback, 1) do
    cond do
      source_size == 0 ->
        {:error, :asr_audio_empty}

      source_size < 0 ->
        {:error, :asr_audio_size_invalid}

      source_size > @max_audio_bytes ->
        {:error, :asr_audio_too_large}

      true ->
        do_with_mp3_chunks(
          {:stream, stream, source_size},
          source_filename,
          callback,
          opts
        )
    end
  end

  defp do_with_mp3_chunks(audio_source, source_filename, callback, opts) do
    segment_seconds = positive_integer(opts[:segment_seconds], @segment_seconds)
    max_chunks = positive_integer(opts[:max_chunks], @max_chunks)
    timeout_ms = positive_integer(opts[:timeout_ms], @timeout_ms)
    deadline_ms = opts[:deadline_ms]
    ffmpeg = opts[:ffmpeg] || System.find_executable("ffmpeg")
    ffprobe = opts[:ffprobe] || System.find_executable("ffprobe")

    with {:ok, ffmpeg} <- available_executable(ffmpeg, :ffmpeg_unavailable),
         {:ok, ffprobe} <- available_executable(ffprobe, :ffprobe_unavailable),
         {:ok, dir} <- make_temp_dir(),
         result <-
           transcode_in_temp(
             ffmpeg,
             ffprobe,
             dir,
             audio_source,
             source_filename,
             callback,
             segment_seconds,
             max_chunks,
             timeout_ms,
             deadline_ms
           ) do
      result
    else
      {:error, _} = error -> error
    end
  end

  defp transcode_in_temp(
         ffmpeg,
         ffprobe,
         dir,
         audio_source,
         source_filename,
         callback,
         segment_seconds,
         max_chunks,
         timeout_ms,
         deadline_ms
       ) do
    try do
      input = Path.join(dir, "source" <> safe_extension(source_filename))
      max_duration_seconds = segment_seconds * max_chunks

      with {:ok, input_timeout_ms} <- phase_timeout(timeout_ms, deadline_ms),
           :ok <- write_audio_input_bounded(input, audio_source, input_timeout_ms),
           {:ok, probe_timeout_ms} <- phase_timeout(timeout_ms, deadline_ms),
           {:ok, source_audio} <-
             probe_decoded_source_audio(ffprobe, input, probe_timeout_ms),
           duration_seconds = source_audio.duration_seconds,
           chunk_plan =
             chunk_sample_plan(segment_seconds, source_audio.target_sample_count),
           :ok <- enforce_duration_limit(duration_seconds, max_duration_seconds),
           :ok <- validate_planned_chunk_count(chunk_plan, max_chunks),
           :ok <-
             transcode_chunks(
               ffmpeg,
               input,
               dir,
               chunk_plan,
               timeout_ms,
               deadline_ms
             ),
           {:ok, chunks} <-
             collect_chunks(
               ffprobe,
               dir,
               segment_seconds,
               max_chunks,
               duration_seconds,
               chunk_plan,
               timeout_ms,
               deadline_ms
             ) do
        callback.(chunks)
      end
    after
      _ = File.rm_rf(dir)
    end
  end

  defp write_audio_input_bounded(input, audio_source, timeout_ms) do
    task = Task.async(fn -> write_audio_input(input, audio_source) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:asr_audio_stream_exit, reason}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :asr_batch_timeout}
    end
  end

  defp write_audio_input(input, {:binary, audio}), do: File.write(input, audio, [:binary])

  defp write_audio_input(input, {:stream, stream, expected_size}) do
    case File.open(input, [:write, :binary]) do
      {:ok, device} ->
        try do
          stream
          |> Enum.reduce_while({:ok, 0}, fn
            chunk, {:ok, received} when is_binary(chunk) ->
              next = received + byte_size(chunk)

              cond do
                next > @max_audio_bytes ->
                  {:halt, {:error, :asr_audio_too_large}}

                next > expected_size ->
                  {:halt, {:error, :asr_audio_size_mismatch}}

                true ->
                  :ok = IO.binwrite(device, chunk)
                  {:cont, {:ok, next}}
              end

            _chunk, _acc ->
              {:halt, {:error, :asr_audio_stream_invalid}}
          end)
          |> case do
            {:ok, ^expected_size} -> :ok
            {:ok, _received} -> {:error, :asr_audio_size_mismatch}
            {:error, _reason} = error -> error
          end
        rescue
          _exception -> {:error, :asr_audio_stream_failed}
        catch
          _kind, _reason -> {:error, :asr_audio_stream_failed}
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:asr_audio_write_failed, reason}}
    end
  end

  # Decode and resample once, then trim on the normalized PCM sample grid. Input
  # seeking each compressed slice independently loses samples at some Vorbis
  # boundaries on FFmpeg 6.1. One filter graph preserves the source sequence,
  # while encoding each mapped output independently keeps every MP3 decodable.
  defp transcode_chunks(
         ffmpeg,
         input,
         dir,
         chunk_plan,
         timeout_ms,
         deadline_ms
       ) do
    with {:ok, ffmpeg_timeout_ms} <- phase_timeout(timeout_ms, deadline_ms),
         {:ok, _output} <-
           run_ffmpeg(
             ffmpeg,
             [
               "-hide_banner",
               "-loglevel",
               "error",
               "-nostdin",
               "-y",
               "-i",
               input,
               "-filter_complex",
               chunk_filter_graph(chunk_plan)
             ] ++ chunk_output_args(dir, chunk_plan),
             ffmpeg_timeout_ms
           ) do
      :ok
    end
  end

  defp chunk_sample_plan(segment_seconds, source_target_sample_count) do
    segment_sample_count = segment_seconds * @chunk_sample_rate_hz
    natural_chunk_count = ceil_div(source_target_sample_count, segment_sample_count)
    tail_sample_count = rem(source_target_sample_count, segment_sample_count)

    # libmp3lame emits at least 47 playable samples at 16 kHz. Merge a shorter
    # real tail into the preceding slice instead of padding or dropping audio.
    merge_subframe_tail? =
      natural_chunk_count > 1 and
        tail_sample_count in 1..(@minimum_mp3_playable_sample_count - 1)

    chunk_count =
      if merge_subframe_tail?, do: natural_chunk_count - 1, else: natural_chunk_count

    Enum.map(0..(chunk_count - 1), fn index ->
      start_sample = index * segment_sample_count
      last? = index == chunk_count - 1

      end_sample =
        if last?,
          do: source_target_sample_count + @sample_count_tolerance_per_chunk,
          else: start_sample + segment_sample_count

      expected_sample_count =
        if last?,
          do: source_target_sample_count - start_sample,
          else: segment_sample_count

      %{
        index: index,
        start_sample: start_sample,
        end_sample: end_sample,
        expected_sample_count: expected_sample_count
      }
    end)
  end

  defp chunk_filter_graph(chunk_plan) do
    split_outputs = Enum.map_join(chunk_plan, "", fn chunk -> "[slice#{chunk.index}]" end)

    trims =
      Enum.map_join(chunk_plan, ";", fn chunk ->
        "[slice#{chunk.index}]atrim=start_sample=#{chunk.start_sample}:" <>
          "end_sample=#{chunk.end_sample},asetpts=N/SR/TB[chunk#{chunk.index}]"
      end)

    "[0:a:0]aformat=channel_layouts=mono,aresample=#{@chunk_sample_rate_hz}," <>
      "asetpts=N/SR/TB,asplit=#{length(chunk_plan)}#{split_outputs};#{trims}"
  end

  defp chunk_output_args(dir, chunk_plan) do
    Enum.flat_map(chunk_plan, fn chunk ->
      output =
        Path.join(
          dir,
          "chunk-#{String.pad_leading(Integer.to_string(chunk.index), 5, "0")}.mp3"
        )

      [
        "-map",
        "[chunk#{chunk.index}]",
        "-vn",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "32k",
        output
      ]
    end)
  end

  defp collect_chunks(
         ffprobe,
         dir,
         segment_seconds,
         max_chunks,
         duration_seconds,
         chunk_plan,
         timeout_ms,
         deadline_ms
       ) do
    paths = Path.wildcard(Path.join(dir, "chunk-*.mp3"))

    with {:ok, indexed} <- require_indexed_chunks(paths),
         {:ok, probed} <-
           probe_chunks(ffprobe, indexed, timeout_ms, deadline_ms),
         probed = drop_encoder_padding_tail(probed, segment_seconds, duration_seconds),
         :ok <- validate_decodable_chunks(probed),
         :ok <- validate_chunk_sample_coverage(probed, chunk_plan),
         indexed = Enum.map(probed, fn {index, path, _probe} -> {index, path} end),
         :ok <- validate_chunk_count(indexed, max_chunks),
         :ok <- validate_chunk_integrity(indexed) do
      {:ok,
       Enum.map(indexed, fn {index, path} ->
         %{
           index: index,
           offset_seconds: index * segment_seconds,
           path: path,
           format: "mp3",
           source_duration_seconds: rounded_duration_seconds(duration_seconds)
         }
       end)}
    end
  end

  defp require_indexed_chunks([]), do: {:error, :ffmpeg_no_audio_chunks}
  defp require_indexed_chunks(paths), do: index_chunks(paths)

  defp probe_chunks(ffprobe, indexed, timeout_ms, deadline_ms) do
    Enum.reduce_while(indexed, {:ok, []}, fn {index, path}, {:ok, acc} ->
      with {:ok, probe_timeout_ms} <- phase_timeout(timeout_ms, deadline_ms) do
        case probe_decoded_sample_count(ffprobe, path, probe_timeout_ms) do
          {:ok, sample_count} ->
            {:cont, {:ok, [{index, path, {:ok, sample_count}} | acc]}}

          {:error, :ffprobe_invalid_duration} = error ->
            {:cont, {:ok, [{index, path, error} | acc]}}

          {:error, {:ffprobe_failed, _status, _output}} = error ->
            {:cont, {:ok, [{index, path, error} | acc]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, probed} -> {:ok, Enum.reverse(probed)}
      error -> error
    end
  end

  # libmp3lame can emit a tiny undecodable padding-only segment when decoded
  # audio ends on a segment boundary. Drop only trailing invalid segments whose
  # offset is within encoder-padding tolerance of the probed source end. An
  # invalid middle or materially early final segment remains a hard failure.
  defp drop_encoder_padding_tail(probed, segment_seconds, duration_seconds) do
    case List.last(probed) do
      {index, _path, {:error, _reason}}
      when index * segment_seconds >=
             duration_seconds - @duration_boundary_tolerance_seconds ->
        probed
        |> Enum.drop(-1)
        |> drop_encoder_padding_tail(segment_seconds, duration_seconds)

      _ ->
        probed
    end
  end

  defp validate_decodable_chunks(probed) do
    if probed != [] and
         Enum.all?(probed, fn {_index, _path, probe} -> match?({:ok, _}, probe) end),
       do: :ok,
       else: {:error, :ffmpeg_incomplete_chunks}
  end

  # A successful ffmpeg exit and decodable files do not prove that every source
  # slice survived. Compare playable PCM samples, not padded MP3 durations. The
  # per-slice and total bounds reject missing or excess decoded samples; the
  # real-noise seam regression separately guards sample-grid alignment.
  defp validate_chunk_sample_coverage(probed, chunk_plan) do
    probes_by_index = Map.new(probed, fn {index, _path, probe} -> {index, probe} end)

    samples_cover_required_slices? =
      Enum.all?(chunk_plan, fn chunk ->
        case Map.get(probes_by_index, chunk.index) do
          {:ok, chunk_sample_count} ->
            abs(chunk_sample_count - chunk.expected_sample_count) <=
              @sample_count_tolerance_per_chunk

          _other ->
            false
        end
      end)

    decoded_sample_count =
      Enum.sum(for {_index, _path, {:ok, sample_count}} <- probed, do: sample_count)

    source_target_sample_count = Enum.sum(Enum.map(chunk_plan, & &1.expected_sample_count))
    total_tolerance = length(chunk_plan) * @sample_count_tolerance_per_chunk

    if length(probed) == length(chunk_plan) and samples_cover_required_slices? and
         abs(decoded_sample_count - source_target_sample_count) <= total_tolerance,
       do: :ok,
       else: {:error, :ffmpeg_incomplete_chunks}
  end

  defp validate_chunk_count([], _max_chunks), do: {:error, :ffmpeg_no_audio_chunks}

  defp validate_chunk_count(indexed, max_chunks) when length(indexed) > max_chunks,
    do: {:error, {:asr_too_many_chunks, length(indexed)}}

  defp validate_chunk_count(_indexed, _max_chunks), do: :ok

  defp validate_planned_chunk_count(chunk_plan, max_chunks) when length(chunk_plan) > max_chunks,
    do: {:error, {:asr_too_many_chunks, length(chunk_plan)}}

  defp validate_planned_chunk_count(_chunk_plan, _max_chunks), do: :ok

  defp validate_chunk_integrity(indexed) do
    indexes = Enum.map(indexed, &elem(&1, 0))

    if indexes == Enum.to_list(0..(length(indexed) - 1)) and
         Enum.all?(indexed, fn {_index, path} -> nonempty_file?(path) end) do
      :ok
    else
      {:error, :ffmpeg_incomplete_chunks}
    end
  end

  defp index_chunks(paths) do
    paths
    |> Enum.map(fn path ->
      case Regex.run(~r/^chunk-(\d{5})\.mp3$/, Path.basename(path)) do
        [_, index] -> {:ok, {String.to_integer(index), path}}
        _ -> {:error, :ffmpeg_invalid_chunk_name}
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, indexed}, {:ok, acc} -> {:cont, {:ok, [indexed | acc]}}
      {:error, _} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, indexed} -> {:ok, Enum.sort_by(indexed, &elem(&1, 0))}
      error -> error
    end
  end

  defp nonempty_file?(path) do
    match?({:ok, %{type: :regular, size: size}} when size > 0, File.stat(path))
  end

  defp probe_decoded_source_audio(ffprobe, input, timeout_ms) do
    probe_timeout = min(timeout_ms, @probe_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + probe_timeout

    with {:ok, sample_rate_timeout_ms} <- remaining_probe_timeout(deadline),
         {:ok, sample_rate} <- probe_sample_rate(ffprobe, input, sample_rate_timeout_ms),
         {:ok, sample_count_timeout_ms} <- remaining_probe_timeout(deadline),
         {:ok, sample_count} <-
           probe_decoded_sample_count(ffprobe, input, sample_count_timeout_ms) do
      target_sample_count =
        div(
          sample_count * @chunk_sample_rate_hz + div(sample_rate, 2),
          sample_rate
        )

      if target_sample_count > 0 do
        {:ok,
         %{
           duration_seconds: sample_count / sample_rate,
           target_sample_count: target_sample_count
         }}
      else
        {:error, :ffprobe_invalid_duration}
      end
    end
  end

  defp remaining_probe_timeout(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _remaining -> {:error, :ffprobe_timeout}
    end
  end

  defp probe_sample_rate(ffprobe, input, timeout_ms) do
    case run_executable(
           ffprobe,
           [
             "-v",
             "error",
             "-select_streams",
             "a:0",
             "-show_entries",
             "stream=sample_rate",
             "-of",
             "default=noprint_wrappers=1:nokey=1",
             input
           ],
           timeout_ms
         ) do
      {:ok, output} -> parse_positive_integer(output)
      {:error, :timeout} -> {:error, :ffprobe_timeout}
      {:error, {:exit_status, status, output}} -> {:error, {:ffprobe_failed, status, output}}
      {:error, {:start_failed, reason}} -> {:error, {:ffprobe_start_failed, reason}}
    end
  end

  defp parse_positive_integer(output) do
    case Integer.parse(String.trim(output)) do
      {value, ""} when value > 0 -> {:ok, value}
      _other -> {:error, :ffprobe_invalid_duration}
    end
  end

  defp ceil_div(dividend, divisor) when dividend > 0 and divisor > 0,
    do: div(dividend + divisor - 1, divisor)

  # MP3 container and stream durations include encoder delay/padding on the
  # ffprobe versions shipped by Ubuntu 24.04 and Debian Bookworm. Count decoded
  # frame samples instead: ffprobe applies the MP3 skip/discard metadata before
  # reporting each frame's nb_samples, so the sum is the playable ASR payload.
  # Reduce the output as it arrives because a five-minute chunk emits more than
  # the generic executable output cap.
  defp probe_decoded_sample_count(ffprobe, input, timeout_ms) do
    probe_timeout = min(timeout_ms, @probe_timeout_ms)

    port =
      Port.open({:spawn_executable, ffprobe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        :hide,
        args: [
          "-v",
          "error",
          "-select_streams",
          "a:0",
          "-show_frames",
          "-show_entries",
          "frame=nb_samples",
          "-of",
          "csv=p=0",
          input
        ]
      ])

    case collect_sample_count_port(
           port,
           System.monotonic_time(:millisecond) + probe_timeout,
           "",
           0,
           false
         ) do
      {:ok, sample_count} when sample_count > 0 ->
        {:ok, sample_count}

      {:ok, _sample_count} ->
        {:error, :ffprobe_invalid_duration}

      {:error, :timeout} ->
        {:error, :ffprobe_timeout}

      {:error, {:exit_status, status}} ->
        {:error, {:ffprobe_failed, status, ""}}

      {:error, :invalid_sample_count} ->
        {:error, :ffprobe_invalid_duration}
    end
  rescue
    error -> {:error, {:ffprobe_start_failed, Exception.message(error)}}
  end

  defp collect_sample_count_port(port, deadline, remainder, total, invalid?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        {next_remainder, next_total, next_invalid?} =
          reduce_sample_count_data(remainder <> data, total, invalid?)

        collect_sample_count_port(
          port,
          deadline,
          next_remainder,
          next_total,
          next_invalid?
        )

      {^port, {:exit_status, 0}} ->
        {_remainder, final_total, final_invalid?} =
          reduce_sample_count_data(remainder <> "\n", total, invalid?)

        if final_invalid?,
          do: {:error, :invalid_sample_count},
          else: {:ok, final_total}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      remaining ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp reduce_sample_count_data(data, total, invalid?) do
    {remainder, complete_lines} =
      data
      |> :binary.split("\n", [:global])
      |> List.pop_at(-1)

    {next_total, next_invalid?} =
      Enum.reduce(complete_lines, {total, invalid?}, fn line, {line_total, line_invalid?} ->
        case String.trim(line) do
          "" ->
            {line_total, line_invalid?}

          value ->
            case Integer.parse(value) do
              {sample_count, ""} when sample_count > 0 ->
                {line_total + sample_count, line_invalid?}

              _other ->
                {line_total, true}
            end
        end
      end)

    if byte_size(remainder) <= @sample_probe_remainder_limit do
      {remainder, next_total, next_invalid?}
    else
      {"", next_total, true}
    end
  end

  defp enforce_duration_limit(duration_seconds, max_duration_seconds)
       when duration_seconds <=
              max_duration_seconds + @duration_boundary_tolerance_seconds,
       do: :ok

  defp enforce_duration_limit(duration_seconds, max_duration_seconds),
    do: {:error, {:asr_audio_too_long, ceil(duration_seconds), max_duration_seconds}}

  defp rounded_duration_seconds(duration_seconds),
    do: duration_seconds |> round() |> max(1)

  defp phase_timeout(timeout_ms, nil), do: {:ok, timeout_ms}

  defp phase_timeout(timeout_ms, deadline_ms) when is_integer(deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: {:ok, min(timeout_ms, remaining)},
      else: {:error, :asr_batch_timeout}
  end

  defp phase_timeout(timeout_ms, _deadline_ms), do: {:ok, timeout_ms}

  defp run_ffmpeg(executable, args, timeout_ms) do
    case run_executable(executable, args, timeout_ms) do
      {:ok, output} -> {:ok, output}
      {:error, :timeout} -> {:error, :ffmpeg_timeout}
      {:error, {:exit_status, status, output}} -> {:error, {:ffmpeg_failed, status, output}}
      {:error, {:start_failed, reason}} -> {:error, {:ffmpeg_start_failed, reason}}
    end
  end

  defp run_executable(executable, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        :hide,
        args: args
      ])

    collect_port(port, System.monotonic_time(:millisecond) + timeout_ms, "")
  rescue
    error -> {:error, {:start_failed, Exception.message(error)}}
  end

  defp collect_port(port, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        collect_port(port, deadline, append_limited(output, data))

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status, output}}
    after
      remaining ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp append_limited(output, data) do
    remaining = max(@stderr_limit - byte_size(output), 0)

    if remaining == 0 do
      output
    else
      output <> binary_part(data, 0, min(byte_size(data), remaining))
    end
  end

  defp make_temp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-meeting-audio-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.mkdir(dir) do
      :ok ->
        case File.chmod(dir, 0o700) do
          :ok ->
            {:ok, dir}

          {:error, reason} ->
            _ = File.rm_rf(dir)
            {:error, {:audio_temp_dir_chmod_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:audio_temp_dir_failed, reason}}
    end
  end

  defp safe_extension(filename) do
    extension = filename |> Path.basename() |> Path.extname() |> String.downcase()

    if extension =~ ~r/^\.[a-z0-9]{1,8}$/ do
      extension
    else
      ".audio"
    end
  end

  defp available_executable(value, _error) when is_binary(value) and value != "",
    do: {:ok, value}

  defp available_executable(_value, error), do: {:error, error}

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
