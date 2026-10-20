defmodule SalixMeetNative.Recorder.Encoder do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.Opus.Encoder.Native

  @frame_samples 960
  @frame_bytes @frame_samples * 2
  @frame_duration Membrane.Time.milliseconds(20)
  @application_voip 2048
  @signal_auto -1000

  def_options(bitrate: [spec: 500..512_000, default: 12_000])

  def_input_pad(:input,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 48_000}
  )

  def_output_pad(:output, accepted_format: %Membrane.Opus{self_delimiting?: false})

  @impl true
  def handle_init(_ctx, opts),
    do: {[], %{bitrate: opts.bitrate, native: nil, queue: <<>>, pts: 0}}

  @impl true
  def handle_setup(_ctx, state),
    do:
      {[],
       %{state | native: Native.create(48_000, 1, @application_voip, state.bitrate, @signal_auto)}}

  @impl true
  def handle_stream_format(:input, _format, _ctx, state),
    do: {[stream_format: {:output, %Membrane.Opus{channels: 1, self_delimiting?: false}}], state}

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: pcm}, _ctx, state) do
    {buffers, state} = encode(state.queue <> pcm, state, [])
    {[buffer: {:output, buffers}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{queue: <<>>} = state),
    do: {[end_of_stream: :output], state}

  def handle_end_of_stream(:input, _ctx, state) do
    {buffers, state} = encode(String.pad_trailing(state.queue, @frame_bytes, <<0>>), state, [])
    {[buffer: {:output, buffers}, end_of_stream: :output], state}
  end

  defp encode(<<frame::binary-size(@frame_bytes), rest::binary>>, state, acc) do
    {:ok, packet} = Native.encode_packet(state.native, frame, @frame_samples)

    buffer = %Membrane.Buffer{
      payload: packet,
      pts: state.pts,
      metadata: %{duration: @frame_duration}
    }

    encode(rest, %{state | pts: state.pts + @frame_duration}, [buffer | acc])
  end

  defp encode(rest, state, acc), do: {Enum.reverse(acc), %{state | queue: rest}}
end
