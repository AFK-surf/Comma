defmodule SalixLlm.AudioChunkerTest do
  use SystemsClock.Case, async: false

  alias SalixLlm.AudioChunker

  @tag :ffmpeg
  test "normalizes OGG into complete independently decodable MP3 chunks" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required for meeting audio")
    ffprobe = System.find_executable("ffprobe") || flunk("ffprobe is required for this test")

    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-fixture-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    source = Path.join(dir, "source.ogg")

    on_exit(fn -> File.rm_rf!(dir) end)

    {_output, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "anoisesrc=color=white:seed=20260826:duration=2.2:sample_rate=44100",
          "-ar",
          "44100",
          "-ac",
          "2",
          "-c:a",
          "vorbis",
          "-strict",
          "experimental",
          source
        ],
        stderr_to_stdout: true
      )

    source_pcm = decoded_mono_16k_pcm(ffmpeg, source)
    source_sample_count = pcm_sample_count(source_pcm)
    assert source_sample_count == 35_202

    audio = File.read!(source)

    assert {:ok, chunk_paths} =
             AudioChunker.with_mp3_chunks(
               audio,
               "audio.ogg",
               fn chunks ->
                 assert Enum.map(chunks, & &1.index) == [0, 1, 2]
                 assert Enum.map(chunks, & &1.offset_seconds) == [0, 1, 2]
                 assert Enum.all?(chunks, &(&1.format == "mp3"))
                 assert Enum.all?(chunks, &(&1.source_duration_seconds == 2))

                 decoded_pcms =
                   for chunk <- chunks do
                     {probe, 0} =
                       System.cmd(
                         ffprobe,
                         [
                           "-v",
                           "error",
                           "-select_streams",
                           "a:0",
                           "-show_entries",
                           "stream=sample_rate,channels:format=format_name",
                           "-of",
                           "json",
                           chunk.path
                         ],
                         stderr_to_stdout: true
                       )

                     decoded = Jason.decode!(probe)
                     assert get_in(decoded, ["streams", Access.at(0), "sample_rate"]) == "16000"
                     assert get_in(decoded, ["streams", Access.at(0), "channels"]) == 1
                     assert get_in(decoded, ["format", "format_name"]) =~ "mp3"

                     decoded_mono_16k_pcm(ffmpeg, chunk.path)
                   end

                 decoded_sample_counts = Enum.map(decoded_pcms, &pcm_sample_count/1)
                 assert decoded_sample_counts == [16_000, 16_000, 3_202]
                 assert Enum.sum(decoded_sample_counts) == source_sample_count

                 assert best_pcm_alignment_lag(
                          source_pcm,
                          Enum.at(decoded_pcms, 1),
                          16_000
                        ) in -1..1

                 {:ok, Enum.map(chunks, & &1.path)}
               end,
               segment_seconds: 1,
               max_chunks: 5,
               timeout_ms: 30_000
             )

    assert Enum.all?(chunk_paths, &(not File.exists?(&1)))

    midpoint = div(byte_size(audio), 2)

    audio_stream = [
      binary_part(audio, 0, midpoint),
      binary_part(audio, midpoint, byte_size(audio) - midpoint)
    ]

    assert {:ok, :streamed} =
             AudioChunker.with_mp3_chunks_stream(
               audio_stream,
               byte_size(audio),
               "audio.ogg",
               fn chunks ->
                 assert Enum.map(chunks, & &1.index) == [0, 1, 2]
                 {:ok, :streamed}
               end,
               segment_seconds: 1,
               max_chunks: 5,
               timeout_ms: 30_000
             )

    assert {:error, :asr_audio_size_mismatch} =
             AudioChunker.with_mp3_chunks_stream(
               audio_stream,
               byte_size(audio) - 1,
               "audio.ogg",
               fn _chunks -> flunk("a mismatched stream must fail before the callback") end,
               segment_seconds: 1,
               max_chunks: 5,
               timeout_ms: 30_000
             )
  end

  @tag :ffmpeg
  test "merges an MP3-subframe tail into the preceding chunk" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required for meeting audio")

    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-short-tail-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    source = Path.join(dir, "source.ogg")
    on_exit(fn -> File.rm_rf!(dir) end)

    {_output, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "anoisesrc=color=white:seed=20260827:duration=2.00127:sample_rate=44100",
          "-ar",
          "44100",
          "-ac",
          "2",
          "-c:a",
          "vorbis",
          "-strict",
          "experimental",
          source
        ],
        stderr_to_stdout: true
      )

    source_sample_count = ffmpeg |> decoded_mono_16k_pcm(source) |> pcm_sample_count()
    assert source_sample_count == 32_020

    assert {:ok, [16_000, 16_020]} =
             AudioChunker.with_mp3_chunks(
               File.read!(source),
               "audio.ogg",
               fn chunks ->
                 assert Enum.map(chunks, & &1.index) == [0, 1]

                 {:ok,
                  Enum.map(chunks, fn chunk ->
                    ffmpeg
                    |> decoded_mono_16k_pcm(chunk.path)
                    |> pcm_sample_count()
                  end)}
               end,
               segment_seconds: 1,
               max_chunks: 3,
               timeout_ms: 30_000
             )
  end

  test "uses decoded source samples instead of padded MP3 duration" do
    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-padded-source-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_dir)
    fake_ffmpeg = Path.join(fixture_dir, "ffmpeg")
    fake_ffprobe = Path.join(fixture_dir, "ffprobe")
    chunk_fixture = Path.join(fixture_dir, "chunk.mp3")
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    File.write!(chunk_fixture, "nonempty decoded chunk")

    File.write!(
      fake_ffmpeg,
      """
      #!/bin/sh
      output=

      for arg in "$@"; do
        output="$arg"
      done

      cp "$(dirname "$0")/chunk.mp3" "$output"
      """
    )

    File.write!(
      fake_ffprobe,
      """
      #!/bin/sh
      probe_mode=duration

      for arg in "$@"; do
        case "$arg" in
          frame=nb_samples) probe_mode=decoded_samples ;;
          stream=sample_rate) probe_mode=sample_rate ;;
        esac
      done

      case "$probe_mode" in
        decoded_samples) printf '14720\n' ;;
        sample_rate) printf '16000\n' ;;
        *) printf '1.008000\n' ;;
      esac
      """
    )

    File.chmod!(fake_ffmpeg, 0o700)
    File.chmod!(fake_ffprobe, 0o700)

    assert {:ok, [0]} =
             AudioChunker.with_mp3_chunks(
               "synthetic padded MP3 source",
               "audio.mp3",
               fn chunks -> {:ok, Enum.map(chunks, & &1.index)} end,
               ffmpeg: fake_ffmpeg,
               ffprobe: fake_ffprobe,
               segment_seconds: 1,
               max_chunks: 2,
               timeout_ms: 30_000
             )
  end

  @tag :ffmpeg
  test "rejects decodable chunks that do not cover their source time slices" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required for meeting audio")

    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-truncated-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_dir)
    source = Path.join(fixture_dir, "source.ogg")
    truncated_chunk = Path.join(fixture_dir, "truncated.mp3")
    truncating_ffmpeg = Path.join(fixture_dir, "ffmpeg")
    padded_duration_ffprobe = Path.join(fixture_dir, "ffprobe")
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    {_output, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=880:duration=2.2",
          "-c:a",
          "libopus",
          source
        ],
        stderr_to_stdout: true
      )

    {_output, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          # A per-chunk 100ms allowance would accept this 0.92s payload for
          # every full slice and accumulate the gap across a batch.
          "sine=frequency=440:duration=0.92",
          "-ac",
          "1",
          "-ar",
          "16000",
          "-c:a",
          "libmp3lame",
          "-b:a",
          "32k",
          truncated_chunk
        ],
        stderr_to_stdout: true
      )

    File.write!(
      truncating_ffmpeg,
      """
      #!/bin/sh
      for arg in "$@"; do
        case "$arg" in
          *.mp3) cp "$(dirname "$0")/truncated.mp3" "$arg" ;;
        esac
      done
      """
    )

    File.chmod!(truncating_ffmpeg, 0o700)

    # Ubuntu's ffprobe 6.1 can report both the MP3 container and stream as
    # 1.008s even though decoding yields only 14,720 samples (0.92s at 16 kHz).
    # Make that cross-version discrepancy deterministic: the old duration
    # probe accepts every full slice, while a decoded-sample probe rejects it.
    File.write!(
      padded_duration_ffprobe,
      """
      #!/bin/sh
      input=
      probe_mode=duration

      for arg in "$@"; do
        input="$arg"

        case "$arg" in
          frame=nb_samples) probe_mode=decoded_samples ;;
          stream=sample_rate) probe_mode=sample_rate ;;
        esac
      done

      case "$probe_mode:$input" in
        sample_rate:*)
          printf '48000\n'
          ;;
        decoded_samples:*/source.*)
          printf '105600\n'
          ;;
        duration:*/source.*)
          printf '2.206500\n'
          ;;
        *)
          if [ "$probe_mode" = "decoded_samples" ]; then
            printf '47\n'
            frame=0

            while [ "$frame" -lt 25 ]; do
              printf '576\n'
              frame=$((frame + 1))
            done

            printf '273\n'
          else
            printf '1.008000\n'
          fi
          ;;
      esac
      """
    )

    File.chmod!(padded_duration_ffprobe, 0o700)

    assert {:error, :ffmpeg_incomplete_chunks} =
             AudioChunker.with_mp3_chunks(
               File.read!(source),
               "audio.ogg",
               fn _chunks -> flunk("truncated chunks must fail before the callback") end,
               ffmpeg: truncating_ffmpeg,
               ffprobe: padded_duration_ffprobe,
               segment_seconds: 1,
               max_chunks: 5,
               timeout_ms: 30_000
             )
  end

  test "streams a full five-minute decoded-sample probe without truncation" do
    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-sample-stream-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_dir)
    fake_ffmpeg = Path.join(fixture_dir, "ffmpeg")
    fake_ffprobe = Path.join(fixture_dir, "ffprobe")
    chunk_fixture = Path.join(fixture_dir, "chunk.mp3")
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    File.write!(chunk_fixture, "nonempty decoded chunk")

    File.write!(
      fake_ffmpeg,
      """
      #!/bin/sh
      output=

      for arg in "$@"; do
        output="$arg"
      done

      cp "$(dirname "$0")/chunk.mp3" "$output"
      """
    )

    File.write!(
      fake_ffprobe,
      """
      #!/bin/sh
      input=
      probe_mode=duration

      for arg in "$@"; do
        input="$arg"

        case "$arg" in
          frame=nb_samples) probe_mode=decoded_samples ;;
          stream=sample_rate) probe_mode=sample_rate ;;
        esac
      done

      case "$probe_mode:$input" in
        sample_rate:*)
          printf '16000\n'
          ;;
        duration:*/source.*)
          printf '300.000000\n'
          ;;
        *)
          if [ "$probe_mode" = "decoded_samples" ]; then
            printf '47\n'
            frame=0

            while [ "$frame" -lt 8333 ]; do
              printf '576\n'
              frame=$((frame + 1))
            done

            printf '145\n'
          else
            printf '300.096000\n'
          fi
          ;;
      esac
      """
    )

    File.chmod!(fake_ffmpeg, 0o700)
    File.chmod!(fake_ffprobe, 0o700)

    assert {:ok, [0]} =
             AudioChunker.with_mp3_chunks(
               "synthetic source",
               "audio.ogg",
               fn chunks -> {:ok, Enum.map(chunks, & &1.index)} end,
               ffmpeg: fake_ffmpeg,
               ffprobe: fake_ffprobe,
               segment_seconds: 300,
               max_chunks: 1,
               timeout_ms: 30_000
             )
  end

  @tag :ffmpeg
  test "rejects over-duration audio before ffmpeg can expand it to excess chunks" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required for meeting audio")
    before_dirs = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "salix-meeting-audio-*")))

    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-limit-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_dir)
    source = Path.join(fixture_dir, "source.ogg")
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    {_output, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=2.2",
          "-c:a",
          "libopus",
          source
        ],
        stderr_to_stdout: true
      )

    callback = fn _chunks -> flunk("over-duration audio must fail before chunk callback") end

    assert {:error, {:asr_audio_too_long, 3, 1}} =
             AudioChunker.with_mp3_chunks(File.read!(source), "source.ogg", callback,
               segment_seconds: 1,
               max_chunks: 1
             )

    after_dirs = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "salix-meeting-audio-*")))
    assert after_dirs == before_dirs
  end

  @tag :ffmpeg
  test "the whole-job deadline can stop a blocked workspace audio stream" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required for meeting audio")
    ffprobe = System.find_executable("ffprobe") || flunk("ffprobe is required for this test")
    before_dirs = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "salix-meeting-audio-*")))

    blocked_stream =
      Stream.map(["x"], fn chunk ->
        SystemsRuntime.Proc.sleep(1_000)
        chunk
      end)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :asr_batch_timeout} =
             AudioChunker.with_mp3_chunks_stream(
               blocked_stream,
               1,
               "audio.ogg",
               fn _chunks -> flunk("a timed-out input stream must not reach the callback") end,
               ffmpeg: ffmpeg,
               ffprobe: ffprobe,
               deadline_ms: started_at + 20,
               timeout_ms: 30_000
             )

    assert System.monotonic_time(:millisecond) - started_at < 500

    after_dirs = MapSet.new(Path.wildcard(Path.join(System.tmp_dir!(), "salix-meeting-audio-*")))
    assert after_dirs == before_dirs
  end

  # The decoder is a stand-in with kn007/silk-v3-decoder's command line and
  # exit status 0 on errors.
  @tag :ffmpeg
  test "decodes a SILK voice message through the SILK decoder before ffmpeg" do
    ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg is required for meeting audio")

    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-audio-silk-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    pcm = Path.join(dir, "speech.pcm")

    {_output, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=2:sample_rate=24000",
          "-f",
          "s16le",
          pcm
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(dir, "header"), <<2, "#!SILK_V3">>)

    decoder =
      fake_silk_decoder(dir, "decoder", """
      [ "$*" = "silk pcm -Fs_API 24000 -quiet" ] || exit 2
      head -c 10 silk | cmp -s - #{dir}/header || { echo "Error: no SILK header"; exit 0; }
      cp #{pcm} pcm
      """)

    for silk <- [<<"#!SILK_V3", 1::little-16, "f">>, <<2, "#!SILK_V3", 1::little-16, "f">>] do
      assert {:ok, [%{source_duration_seconds: 2}, %{source_duration_seconds: 2}]} =
               AudioChunker.with_mp3_chunks(silk, "voice.silk", &{:ok, &1},
                 segment_seconds: 1,
                 silk_decoder: decoder
               )
    end

    received = Path.join(dir, "received")
    recorder = fake_silk_decoder(dir, "recorder", "cp silk #{received}\ncp #{pcm} pcm")

    decode =
      &AudioChunker.with_mp3_chunks(&1, "voice.silk", fn _ -> :ok end, silk_decoder: recorder)

    frame = fn bytes -> <<byte_size(bytes)::little-16, bytes::binary>> end
    rebuilt = <<2, "#!SILK_V3">> <> frame.("abc") <> frame.("") <> frame.("de")

    # WeChat's end marker, a truncated last frame and trailing bytes are not
    # passed on; every frame before them is.
    for tail <- [<<-1::little-signed-16, "trailing">>, <<5::little-16, "abc">>, <<9>>, ""] do
      assert :ok =
               decode.(<<2, "#!SILK_V3">> <> frame.("abc") <> frame.("") <> frame.("de") <> tail)

      assert File.read!(received) == rebuilt
    end

    File.rm!(received)
    too_large = frame.(:binary.copy("x", 1_025))

    assert {:error, :silk_packet_too_large} = decode.("#!SILK_V3" <> frame.("abc") <> too_large)
    assert {:error, :silk_no_packets} = decode.(<<"#!SILK_V3", -1::little-signed-16, "abc">>)
    assert {:error, :silk_no_packets} = decode.("#!SILK_V3" <> <<3::little-16, "ab">>)
    # Every packet is at least 20 ms, so more than 50 a second over the
    # longest audio taken is refused before decoding.
    assert {:error, {:asr_audio_too_long, 2, 1}} =
             AudioChunker.with_mp3_chunks(
               "#!SILK_V3" <> :binary.copy(frame.("a"), 101),
               "voice.silk",
               fn _ -> :ok end,
               silk_decoder: recorder,
               segment_seconds: 1,
               max_chunks: 1
             )

    refute File.exists?(received)

    # The 2 s of decoded PCM is over a 1 s limit: refused before it is read.
    assert {:error, {:asr_audio_too_long, 2, 1}} =
             AudioChunker.with_mp3_chunks(
               <<"#!SILK_V3", 1::little-16, "f">>,
               "voice.silk",
               fn _ -> :ok end,
               silk_decoder: recorder,
               segment_seconds: 1,
               max_chunks: 1
             )

    broken = fake_silk_decoder(dir, "broken", "echo 'Error: bad frame'")

    assert {:error, {:silk_decode_failed, 0, "Error: bad frame\n"}} =
             AudioChunker.with_mp3_chunks(
               <<"#!SILK_V3", 1::little-16, "f">>,
               "voice.silk",
               &{:ok, &1},
               silk_decoder: broken
             )
  end

  defp fake_silk_decoder(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp decoded_mono_16k_pcm(ffmpeg, path) do
    {pcm, 0} =
      System.cmd(
        ffmpeg,
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-i",
          path,
          "-map",
          "0:a:0",
          "-ac",
          "1",
          "-ar",
          "16000",
          "-f",
          "s16le",
          "-"
        ],
        stderr_to_stdout: true
      )

    pcm
  end

  defp pcm_sample_count(pcm), do: div(byte_size(pcm), 2)

  defp best_pcm_alignment_lag(reference_pcm, chunk_pcm, reference_start_sample) do
    reference = for <<sample::little-signed-16 <- reference_pcm>>, do: sample
    chunk = for <<sample::little-signed-16 <- chunk_pcm>>, do: sample
    window_offset = 1_024
    window_size = 4_096
    chunk_window = Enum.slice(chunk, window_offset, window_size)

    Enum.max_by(-128..128, fn lag ->
      reference
      |> Enum.slice(reference_start_sample + window_offset + lag, window_size)
      |> Enum.zip_reduce(chunk_window, 0, fn source_sample, chunk_sample, score ->
        score + source_sample * chunk_sample
      end)
    end)
  end
end
