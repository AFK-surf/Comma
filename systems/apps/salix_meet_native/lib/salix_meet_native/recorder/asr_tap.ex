defmodule SalixMeetNative.Recorder.ASRTap do
  @moduledoc false
  use Membrane.Filter

  alias SalixMeetNative.ASR

  def_options(asr: [spec: pid()], track: [spec: term()], offset: [spec: non_neg_integer()])

  def_input_pad(:input,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 48_000}
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 48_000}
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], Map.from_struct(opts)}

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{pts: pts, payload: pcm} = buffer, _ctx, state) do
    start = div((state.offset + pts) * 16_000, 1_000_000_000)

    pcm16 =
      for <<a::signed-little-16, b::signed-little-16, c::signed-little-16 <- pcm>>,
        into: <<>>,
        do: <<div(a + b + c, 3)::signed-little-16>>

    ASR.pcm(state.asr, state.track, start, pcm16)
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    ASR.track_end(state.asr, state.track)
    {[end_of_stream: :output], state}
  end
end
