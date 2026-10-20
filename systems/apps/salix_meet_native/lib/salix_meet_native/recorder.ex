defmodule SalixMeetNative.Recorder do
  @moduledoc false
  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.{Buffer, Opus, RawAudio, Time}
  alias SalixMeetNative.ASR
  alias SalixMeetNative.Recorder.{ASRTap, Downmix, Encoder, GapFiller, Source, Timeline}

  @opus_payload_type 111
  @sample_rate 48_000
  @reorder_ms 500
  @reorder_ns @reorder_ms * 1_000_000
  @reorder_samples div(@reorder_ms * @sample_rate, 1_000)
  @mix_format %RawAudio{sample_format: :s16le, channels: 1, sample_rate: @sample_rate}
  @lookahead Time.seconds(3)
  @asr_drain_ms 60_000

  @spec start_link(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(dir, opts \\ []) do
    case Membrane.Pipeline.start_link(__MODULE__, Keyword.put(opts, :dir, dir)) do
      {:ok, _supervisor, pipeline} -> {:ok, pipeline}
      {:error, _} = error -> error
    end
  end

  @spec start(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(dir, opts \\ []) do
    case Membrane.Pipeline.start(__MODULE__, Keyword.put(opts, :dir, dir)) do
      {:ok, _supervisor, pipeline} -> {:ok, pipeline}
      {:error, _} = error -> error
    end
  end

  def end_attempt(recorder, attempt), do: send(recorder, {:end_attempt, attempt})

  def set_audio_source(recorder, stream, device),
    do: send(recorder, {:audio_source, stream, device})

  def set_participant_name(recorder, device, name),
    do: send(recorder, {:participant_name, device, name})

  @spec finish(pid(), timeout()) :: {:ok, map() | nil} | {:error, :timeout}
  def finish(recorder, timeout \\ 300_000) do
    ref = make_ref()
    monitor = Process.monitor(recorder)
    send(recorder, {:finish, self(), ref})
    SystemsClock.awaiting({__MODULE__, ref})

    reply =
      receive do
        {^ref, result, asr} -> {:finished, result, asr}
        {:DOWN, ^monitor, :process, ^recorder, _reason} -> :down
      after
        SystemsClock.timeout(timeout) -> :timeout
      end

    SystemsClock.replied({__MODULE__, ref})

    case reply do
      {:finished, result, asr} ->
        Process.demonitor(monitor, [:flush])
        if asr, do: ASR.drain(asr, @asr_drain_ms)
        Membrane.Pipeline.terminate(recorder, asynchronous?: true)
        {:ok, result}

      :down ->
        {:ok, nil}

      :timeout ->
        {:error, :timeout}
    end
  end

  @impl true
  def handle_init(_ctx, opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    mixed = Path.join(dir, "audio.ogg")

    spec =
      child(:mixer, %Membrane.LiveAudioMixer{latency: nil, stream_format: @mix_format})
      |> child(:encoder, %Encoder{bitrate: Keyword.get(opts, :bitrate, 12_000)})
      |> child(:muxer, Membrane.Ogg.Muxer)
      |> child(:mixed_sink, %Membrane.File.Sink{location: mixed})

    owner = Keyword.get(opts, :owner)
    if owner, do: Process.monitor(owner)
    timeline = Timeline.new(dir, Keyword.get(opts, :meeting_code, ""))

    state = %{
      owner: owner,
      dir: dir,
      mixed: mixed,
      started_at: SystemsClock.monotonic_time(:nanosecond),
      timeline: timeline,
      asr: start_asr(Keyword.get(opts, :asr_subscriber), timeline),
      tracks: %{},
      files: MapSet.new(),
      sources: %{},
      names: %{},
      pending_sinks: MapSet.new(),
      # Tracks whose mixer input is not linked yet, and whether the mixer's
      # end of stream waits for them: a pad added after it raises.
      unlinked: MapSet.new(),
      mixer_eos: :none,
      finishing: nil
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_playing(_ctx, state),
    do: {[notify_child: {:mixer, {:start_mixing, @lookahead}}], state}

  @impl true
  def handle_info({:rtp, attempt, raw}, _ctx, %{finishing: nil} = state) do
    with {:ok, %ExRTP.Packet{payload_type: @opus_payload_type, payload: payload} = packet}
         when payload != "" <-
           ExRTP.Packet.decode(raw) do
      key = {attempt, packet.ssrc}
      {actions, state} = ensure_track(state, key, packet.ssrc)
      %{id: id} = track = state.tracks[key]

      if track.ended? do
        {actions, state}
      else
        {offset, unwrap} = unwrap(track.unwrap, packet.timestamp)

        buffer = %Buffer{
          payload: payload,
          pts: div(offset * 1_000_000_000, @sample_rate),
          metadata: %{duration: duration(payload)}
        }

        state = state |> put_in([:tracks, key, :unwrap], unwrap) |> route(key, packet.csrc)

        {actions ++
           [
             notify_child: {{:mix_source, id}, {:buffer, buffer}},
             notify_child: {{:raw_source, id}, {:buffer, buffer}}
           ], state}
      end
    else
      _ -> {[], state}
    end
  end

  def handle_info({:end_attempt, attempt}, _ctx, %{finishing: nil} = state) do
    keys = for {{^attempt, _ssrc} = key, %{ended?: false}} <- state.tracks, do: key
    end_tracks(state, keys)
  end

  def handle_info({:audio_source, stream, device}, _ctx, state) do
    case Integer.parse(stream) do
      {ssrc, ""} when ssrc in 0..0xFFFFFFFF and device != "" ->
        {[], put_in(state.sources[ssrc], %{stream: stream, device: device})}

      _ ->
        {[], state}
    end
  end

  def handle_info({:participant_name, device, name}, _ctx, state)
      when device != "" and name != "" do
    if state.asr, do: ASR.participant_name(state.asr, device, name)

    {[],
     %{
       state
       | names: Map.put(state.names, device, name),
         timeline: Timeline.set_participant(state.timeline, device, name)
     }}
  end

  def handle_info({:finish, from, ref}, _ctx, %{finishing: nil, tracks: tracks} = state)
      when map_size(tracks) == 0 do
    Enum.each([state.mixed, Timeline.path(state.timeline)], &File.rm/1)
    send(from, {ref, nil, nil})
    {[], %{state | finishing: :done}}
  end

  def handle_info({:finish, from, ref}, _ctx, %{finishing: nil} = state) do
    open = for {key, %{ended?: false}} <- state.tracks, do: key
    {actions, state} = end_tracks(state, open)
    state = %{state | timeline: Timeline.flush(state.timeline)}
    pending = MapSet.put(state.pending_sinks, :mixed_sink)

    {eos, state} = schedule_mixer_eos(%{state | mixer_eos: :pending})
    {actions ++ eos, %{state | finishing: {from, ref}, pending_sinks: pending}}
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, _ctx, %{owner: owner} = state),
    do: {[terminate: :normal], state}

  def handle_info(_msg, _ctx, state), do: {[], state}

  @impl true
  def handle_child_playing({:downmix, id}, _ctx, state),
    do: schedule_mixer_eos(%{state | unlinked: MapSet.delete(state.unlinked, id)})

  def handle_child_playing(_child, _ctx, state), do: {[], state}

  @impl true
  def handle_element_end_of_stream(sink, :input, _ctx, state) do
    state = %{state | pending_sinks: MapSet.delete(state.pending_sinks, sink)}

    case state.finishing do
      {from, ref} ->
        if MapSet.size(state.pending_sinks) == 0 do
          send(from, {ref, result(state), state.asr})
          {[], %{state | finishing: :done}}
        else
          {[], state}
        end

      _ ->
        {[], state}
    end
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, state), do: {[], state}

  # A child of a track's spec plays only once the spec is linked, so the
  # mixer has every input pad when it is told to end.
  defp schedule_mixer_eos(%{mixer_eos: :pending} = state) do
    if MapSet.size(state.unlinked) == 0,
      do: {[notify_child: {:mixer, :schedule_eos}], %{state | mixer_eos: :sent}},
      else: {[], state}
  end

  defp schedule_mixer_eos(state), do: {[], state}

  defp result(state) do
    %{
      audio: state.mixed,
      timeline: Timeline.path(state.timeline),
      tracks:
        state.tracks |> Map.values() |> Enum.map(&Path.join(state.dir, &1.file)) |> Enum.sort()
    }
  end

  defp ensure_track(state, key, ssrc) do
    if Map.has_key?(state.tracks, key) do
      {[], state}
    else
      id = map_size(state.tracks)
      file = unique_file(state.files, ssrc)

      Membrane.Logger.debug(
        "recorder: new track #{inspect(key)} known sources #{inspect(Map.keys(state.sources))}"
      )

      offset = max(SystemsClock.monotonic_time(:nanosecond) - state.started_at - @reorder_ns, 0)
      {timeline, entry} = Timeline.add_track(state.timeline, ssrc, file)

      mix =
        child({:mix_source, id}, %Source{reorder_window_ns: @reorder_ns})
        |> child({:decoder, id}, %Opus.Decoder{sample_rate: @sample_rate})
        |> child({:downmix, id}, Downmix)
        |> asr_tap(state.asr, id, offset)
        |> via_in(Pad.ref(:input, id), options: [offset: offset])
        |> get_child(:mixer)

      raw =
        child({:raw_source, id}, %Source{reorder_window_ns: @reorder_ns})
        |> child({:raw_gaps, id}, GapFiller)
        |> child({:raw_muxer, id}, Membrane.Ogg.Muxer)
        |> child({:raw_sink, id}, %Membrane.File.Sink{location: Path.join(state.dir, file)})

      track = %{id: id, file: file, unwrap: nil, entry: entry, route: nil, ended?: false}

      {[spec: [mix, raw]],
       %{
         state
         | timeline: timeline,
           files: MapSet.put(state.files, file),
           unlinked: MapSet.put(state.unlinked, id),
           tracks: Map.put(state.tracks, key, track)
       }}
    end
  end

  defp end_tracks(state, keys) do
    Enum.reduce(keys, {[], state}, fn key, {actions, state} ->
      %{id: id, entry: entry} = state.tracks[key]

      eos = [
        notify_child: {{:mix_source, id}, :end_of_stream},
        notify_child: {{:raw_source, id}, :end_of_stream}
      ]

      state =
        %{
          state
          | timeline: Timeline.end_track(state.timeline, entry),
            pending_sinks: MapSet.put(state.pending_sinks, {:raw_sink, id})
        }
        |> put_in([:tracks, key, :ended?], true)

      {actions ++ eos, state}
    end)
  end

  defp route(state, key, csrcs) do
    if state.tracks[key].route == nil and csrcs != [],
      do: Membrane.Logger.debug("recorder: track #{inspect(key)} csrc #{inspect(csrcs)}")

    case Enum.find_value(csrcs, &Map.get(state.sources, &1)) do
      nil ->
        state

      source ->
        if state.tracks[key].route == source do
          state
        else
          name = Map.get(state.names, source.device, "")

          timeline =
            Timeline.set_route(
              state.timeline,
              state.tracks[key].entry,
              source.stream,
              source.device,
              name
            )

          if state.asr, do: ASR.route(state.asr, state.tracks[key].id, source.device)
          put_in(%{state | timeline: timeline}, [:tracks, key, :route], source)
        end
    end
  end

  defp start_asr(nil, _timeline), do: nil

  defp start_asr(subscriber, timeline) do
    with {_module, _config} = provider <- ASR.provider(),
         {:ok, asr} <-
           ASR.start(
             provider: provider,
             owner: self(),
             subscriber: subscriber,
             started_unix_ms: timeline.doc["startedUnixMs"]
           ) do
      asr
    else
      _ -> nil
    end
  end

  defp asr_tap(spec, nil, _id, _offset), do: spec

  defp asr_tap(spec, asr, id, offset),
    do: child(spec, {:asr_tap, id}, %ASRTap{asr: asr, track: id, offset: offset})

  defp unique_file(files, ssrc) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> "audio-#{ssrc}.ogg"
      n -> "audio-#{ssrc}-#{n}.ogg"
    end)
    |> Enum.find(&(not MapSet.member?(files, &1)))
  end

  defp duration(<<config::5, _stereo::1, code::2, rest::binary>>) do
    frame_us =
      cond do
        config < 12 -> Enum.at([10_000, 20_000, 40_000, 60_000], rem(config, 4))
        config < 16 -> Enum.at([10_000, 20_000], rem(config, 2))
        true -> Enum.at([2_500, 5_000, 10_000, 20_000], rem(config, 4))
      end

    frames =
      case {code, rest} do
        {0, _} -> 1
        {3, <<_vbr::1, _padding::1, count::6, _::binary>>} -> count
        {3, _} -> 1
        _ -> 2
      end

    Time.microseconds(frame_us * frames)
  end

  defp unwrap(nil, ts), do: {@reorder_samples, {ts, @reorder_samples}}

  defp unwrap({prev, offset}, ts) do
    <<delta::signed-32>> = <<ts - prev::32>>
    offset = offset + delta
    {max(offset, 0), {ts, offset}}
  end
end
