defmodule SalixMeetNative.ASRTest.Provider do
  def name, do: "live"

  def retryable?(:flaky), do: true
  def retryable?(_reason), do: false

  def recognize(audio, emit, %{"test" => test, "failures" => failures}) do
    bytes = Enum.reduce(audio, 0, &(byte_size(&1) + &2))
    send(test, {:recognized, bytes})

    if :counters.get(failures, 1) > 0 do
      :counters.sub(failures, 1, 1)
      {:error, :flaky}
    else
      emit.(%{text: "hel", start_ms: 100, end_ms: 500, final: false})
      emit.(%{text: "hello", start_ms: 100, end_ms: 900, final: true})
      :ok
    end
  end
end

defmodule SalixMeetNative.ASRTest do
  use ExUnit.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixMeetNative"]

  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Opus, RawAudio, Testing}
  alias SalixMeetNative.{ASR, Recorder}
  alias SalixMeetNative.ASR.Segmenter

  @device "spaces/s/devices/1"
  @frame_bytes 1_280

  setup do
    previous = SystemsRuntime.get_env(:salix_meet_native, :live_asr)
    on_exit(fn -> SystemsRuntime.put_env(:salix_meet_native, :live_asr, previous) end)
  end

  test "a participant's speech becomes one caption at its meeting time" do
    asr = start_asr(0)
    ASR.route(asr, 7, @device)
    ASR.participant_name(asr, @device, "Alice")

    fed_at = SystemsClock.monotonic_time(:millisecond)
    feed(asr, 7, 16_000, silence(0.4) <> tone(1.0) <> silence(1.0))

    assert {:meet_asr, caption} = settle_receive_caption()
    # The first attempt reads audio as it arrives and does not wait out its length again.
    assert SystemsClock.monotonic_time(:millisecond) - fed_at < 800

    # Eight pre-roll frames before the speech, the speech, then 20 silent frames.
    assert_received {:recognized, bytes}
    assert bytes == (8 + 25 + 20) * @frame_bytes

    assert caption == %{
             "speaker" => "Alice",
             "text" => "hello",
             "source" => "live",
             "timestamp" => 1_001,
             "timestamp_ms" => 1_000_000 + 1_080 + 100
           }

    assert :ok = ASR.drain(asr, 5_000)
  end

  test "a failed attempt replays the whole segment once it is sealed" do
    asr = start_asr(1)
    feed(asr, 1, 0, tone(0.5))
    assert :ok = settled_await(Task.async(fn -> ASR.drain(asr, 60_000) end))

    assert_received {:recognized, first}
    assert_received {:recognized, ^first}
    assert_received {:meet_asr, %{"text" => "hello", "speaker" => ""}}
    refute_received {:meet_asr, _}
  end

  test "a gap longer than 800 ms ends the segment and anchors the next at the new audio" do
    {s, opened} = Segmenter.push(%Segmenter{}, 0, tone(0.08))
    assert [{:open, 0}, {:audio, _}, {:audio, _}] = opened

    {_s, actions} = Segmenter.push(s, 32_000, tone(0.04))
    assert [:seal, {:open, 32_000}, {:audio, _}] = actions
  end

  @tag :tmp_dir
  test "the recorder hands each track's speech to the provider under its participant", %{
    tmp_dir: dir
  } do
    start_asr(0)
    {:ok, recorder} = Recorder.start_link(dir, asr_subscriber: self())
    Recorder.set_audio_source(recorder, "4242", @device)
    Recorder.set_participant_name(recorder, @device, "Alice")

    packets = opus_packets(silence48(0.2) <> tone48(1.0) <> silence48(1.2))

    for {packet, i} <- Enum.with_index(packets) do
      rtp = %ExRTP.Packet{
        payload_type: 111,
        sequence_number: i,
        timestamp: i * 960,
        ssrc: 1111,
        csrc: [4242],
        payload: packet
      }

      send(recorder, {:rtp, :only, ExRTP.Packet.encode(rtp)})
    end

    assert {:ok, %{audio: _}} = settled_await(Task.async(fn -> Recorder.finish(recorder) end))
    assert_received {:meet_asr, %{"speaker" => "Alice", "text" => "hello", "source" => "live"}}
    refute_received {:meet_asr, _}
  end

  defp start_asr(failures) do
    counter = :counters.new(1, [])
    :counters.add(counter, 1, failures)

    SystemsRuntime.put_env(:salix_meet_native, :live_asr,
      provider: "SalixMeetNative.ASRTest.Provider",
      config: %{"test" => self(), "failures" => counter}
    )

    {:ok, asr} =
      ASR.start(
        provider: ASR.provider(),
        owner: self(),
        subscriber: self(),
        started_unix_ms: 1_000_000
      )

    asr
  end

  defp feed(asr, track, start, pcm) do
    for <<chunk::binary-size(640) <- pcm>>, reduce: start do
      at ->
        ASR.pcm(asr, track, at, chunk)
        at + 320
    end
  end

  defp settle_receive_caption do
    settle_until(fn ->
      receive do
        {:meet_asr, _} = msg -> msg
      after
        0 -> nil
      end
    end)
  end

  defp tone(seconds) do
    for i <- 0..(round(seconds * 16_000) - 1), into: <<>> do
      <<round(:math.sin(2 * :math.pi() * 440 * i / 16_000) * 8_000)::signed-little-16>>
    end
  end

  defp silence(seconds), do: :binary.copy(<<0, 0>>, round(seconds * 16_000))

  defp tone48(seconds) do
    for i <- 0..(round(seconds * 48_000) - 1), into: <<>> do
      <<round(:math.sin(2 * :math.pi() * 440 * i / 48_000) * 8_000)::signed-little-16>>
    end
  end

  defp silence48(seconds), do: :binary.copy(<<0, 0>>, round(seconds * 48_000))

  defp opus_packets(pcm) do
    format = %RawAudio{sample_format: :s16le, sample_rate: 48_000, channels: 1}
    chunks = for <<chunk::binary-size(1_920) <- pcm>>, do: %Buffer{payload: chunk}

    spec =
      child(:source, %Testing.Source{output: chunks, stream_format: format})
      |> child(:encoder, %Opus.Encoder{application: :voip, input_stream_format: format})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    packets = collect(pipeline, [])
    Testing.Pipeline.terminate(pipeline)
    packets
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
end
