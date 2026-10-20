defmodule SalixMeetNative.Recorder.Downmix do
  @moduledoc false
  use Membrane.Filter

  @mono %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 48_000}

  def_input_pad(:input,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, sample_rate: 48_000}
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1, sample_rate: 48_000}
  )

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{channels: nil, announced?: false}}

  @impl true
  def handle_stream_format(
        :input,
        %Membrane.RawAudio{channels: channels},
        _ctx,
        %{announced?: true} = state
      ),
      do: {[], %{state | channels: channels}}

  def handle_stream_format(:input, %Membrane.RawAudio{channels: channels}, _ctx, state),
    do: {[stream_format: {:output, @mono}], %{state | channels: channels, announced?: true}}

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: pcm} = buffer, _ctx, %{channels: 2} = state) do
    mono =
      for <<l::signed-little-16, r::signed-little-16 <- pcm>>,
        into: <<>>,
        do: <<div(l + r, 2)::signed-little-16>>

    {[buffer: {:output, %{buffer | payload: mono}}], state}
  end

  def handle_buffer(:input, buffer, _ctx, state), do: {[buffer: {:output, buffer}], state}
end
