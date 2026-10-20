defmodule SalixMeetNative.RecorderTest do
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Opus, RawAudio, Testing}
  alias SalixMeetNative.Recorder

  @frame_samples 960

  # The recorder reads arrival times from SystemsClock: a stopped clock that the
  # test moves gives every track the same offsets in every run. The mixer and
  # the files keep their own (Membrane) schedule; the test waits for their end.
  setup do
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
  end

  @tag :tmp_dir
  test "mixes every track onto the session timeline and keeps raw tracks and their routes", %{
    tmp_dir: dir
  } do
    {:ok, recorder} = Recorder.start_link(dir, meeting_code: "abc-defg-hij")
    Recorder.set_audio_source(recorder, "4242", "spaces/s/devices/1")
    Recorder.set_participant_name(recorder, "spaces/s/devices/1", "Alice")

    a = opus_packets(tone(440, 1.0, 2), 2)
    b = opus_packets(tone(660, 1.0, 1), 1)

    SystemsClock.advance(300)
    stream(recorder, [{:first, 1111, a, 0, [4242]}, {:first, 2222, b, 25, []}])
    Recorder.end_attempt(recorder, :first)
    stream(recorder, [{:second, 1111, Enum.take(a, 10), 0, []}])

    assert {:ok, %{audio: audio, timeline: timeline, tracks: tracks}} = Recorder.finish(recorder)
    assert audio == Path.join(dir, "audio.ogg")

    assert Enum.map(tracks, &Path.basename/1) == [
             "audio-1111-1.ogg",
             "audio-1111.ogg",
             "audio-2222.ogg"
           ]

    pcm = decode_file(audio)
    assert div(byte_size(pcm), 2) >= 48_000 * 1.9
    assert rms(pcm) > 500
    assert average_packet_bytes(audio) in 15..60

    assert decode_file(Path.join(dir, "audio-2222.ogg")) |> byte_size() |> div(2) >= 48_000 * 0.9

    doc = timeline |> File.read!() |> Jason.decode!()
    assert doc["meetingCode"] == "abc-defg-hij"
    [first, second, third] = doc["tracks"]
    assert {first["ssrc"], first["file"]} == {1111, "audio-1111.ogg"}
    assert first["startOffsetMs"] >= 300 and is_integer(first["endOffsetMs"])

    assert [
             %{
               "sourceStream" => "4242",
               "device" => "spaces/s/devices/1",
               "participant" => "Alice"
             }
           ] = first["routes"]

    assert second["startOffsetMs"] >= first["startOffsetMs"] + 400
    refute Map.has_key?(second, "routes")
    assert third["file"] == "audio-1111-1.ogg"
  end

  @tag :tmp_dir
  test "packets reordered by the network are recorded in timestamp order", %{tmp_dir: dir} do
    {:ok, recorder} = Recorder.start_link(dir, meeting_code: "abc-defg-hij")
    packets = opus_packets(tone(440, 1.0, 2), 2)

    arrival =
      packets
      |> Enum.with_index()
      |> Enum.chunk_every(2)
      |> Enum.flat_map(&Enum.reverse/1)

    for {packet, index} <- arrival do
      rtp = %ExRTP.Packet{
        payload_type: 111,
        sequence_number: index,
        timestamp: index * @frame_samples,
        ssrc: 3333,
        payload: packet
      }

      send(recorder, {:rtp, :only, ExRTP.Packet.encode(rtp)})
      tick(recorder)
    end

    assert {:ok, %{tracks: [track]}} = Recorder.finish(recorder)

    recorded =
      child(:source, %Membrane.File.Source{location: track})
      |> child(:demuxer, Membrane.Ogg.Demuxer)
      |> child(:sink, Testing.Sink)
      |> run()
      |> Enum.map(&IO.iodata_to_binary/1)
      |> Enum.reject(&String.starts_with?(&1, ["OpusHead", "OpusTags"]))

    assert recorded == packets
  end

  @tag :tmp_dir
  test "a recorder that never received audio leaves no files", %{tmp_dir: dir} do
    {:ok, recorder} = Recorder.start_link(dir)
    assert {:ok, nil} = Recorder.finish(recorder)
    assert File.ls!(dir) == []
  end

  defp stream(recorder, tracks) do
    total =
      tracks
      |> Enum.map(fn {_attempt, _ssrc, packets, delay, _csrc} -> length(packets) + delay end)
      |> Enum.max()

    for tick <- 0..(total - 1) do
      for {attempt, ssrc, packets, delay, csrc} <- tracks,
          tick >= delay,
          packet = Enum.at(packets, tick - delay),
          packet do
        rtp = %ExRTP.Packet{
          payload_type: 111,
          sequence_number: tick - delay,
          timestamp: rem(4_294_960_000 + (tick - delay) * @frame_samples, 4_294_967_296),
          ssrc: ssrc,
          csrc: csrc,
          payload: packet
        }

        send(recorder, {:rtp, attempt, ExRTP.Packet.encode(rtp)})
      end

      tick(recorder)
    end
  end

  # Lets the recorder handle every packet sent so far at the current clock
  # time, then moves the clock one 20 ms frame on.
  defp tick(recorder) do
    :sys.get_state(recorder, :infinity)
    SystemsClock.advance(20)
  end

  defp tone(freq, seconds, channels) do
    for i <- 0..(round(seconds * 48_000) - 1), into: <<>> do
      s = round(:math.sin(2 * :math.pi() * freq * i / 48_000) * 8_000)
      :binary.copy(<<s::signed-little-16>>, channels)
    end
  end

  defp opus_packets(pcm, channels) do
    format = %RawAudio{sample_format: :s16le, sample_rate: 48_000, channels: channels}
    frame_bytes = @frame_samples * 2 * channels
    chunks = for <<chunk::binary-size(^frame_bytes) <- pcm>>, do: %Buffer{payload: chunk}

    run(
      child(:source, %Testing.Source{output: chunks, stream_format: format})
      |> child(:encoder, %Opus.Encoder{application: :voip, input_stream_format: format})
      |> child(:sink, Testing.Sink)
    )
  end

  defp decode_file(path) do
    child(:source, %Membrane.File.Source{location: path})
    |> child(:demuxer, Membrane.Ogg.Demuxer)
    |> child(:decoder, Opus.Decoder)
    |> child(:sink, Testing.Sink)
    |> run()
    |> IO.iodata_to_binary()
  end

  defp average_packet_bytes(path) do
    sizes =
      child(:source, %Membrane.File.Source{location: path})
      |> child(:demuxer, Membrane.Ogg.Demuxer)
      |> child(:sink, Testing.Sink)
      |> run()
      |> Enum.map(&byte_size/1)
      |> Enum.filter(&(&1 > 12))

    div(Enum.sum(sizes), max(length(sizes), 1))
  end

  defp run(spec) do
    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    payloads = collect(pipeline, [])
    Testing.Pipeline.terminate(pipeline)
    payloads
  end

  defp collect(pipeline, acc) do
    receive do
      {Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {{:buffer, %Buffer{payload: payload}}, :sink}}} ->
        collect(pipeline, [payload | acc])

      {Testing.Pipeline, ^pipeline, {:handle_element_end_of_stream, {:sink, :input}}} ->
        Enum.reverse(acc)
    end
  end

  defp rms(pcm) do
    samples = for <<s::signed-little-16 <- pcm>>, do: s * s
    :math.sqrt(Enum.sum(samples) / max(length(samples), 1))
  end
end
