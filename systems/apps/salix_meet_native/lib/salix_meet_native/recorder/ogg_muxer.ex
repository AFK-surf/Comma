defmodule SalixMeetNative.Recorder.OggMuxer do
  @moduledoc false
  # `Membrane.Ogg.Muxer` opens its first page when the stream format comes and
  # closes that page at end of stream. Membrane ends the input of a playing
  # element when the element or its upstream stops, also before any stream
  # format came: the muxer then had no page to close and crashed. A stream
  # that ends before its format has no Ogg output, so this element only ends.
  use Membrane.Filter

  alias Membrane.Ogg.Muxer

  def_input_pad(:input, accepted_format: %Membrane.Opus{self_delimiting?: false})

  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: Membrane.Ogg}
  )

  @impl true
  defdelegate handle_init(ctx, opts), to: Muxer

  @impl true
  defdelegate handle_stream_format(pad, format, ctx, state), to: Muxer

  @impl true
  defdelegate handle_buffer(pad, buffer, ctx, state), to: Muxer

  @impl true
  def handle_end_of_stream(:input, _ctx, %Muxer.State{current_page: nil} = state),
    do: {[end_of_stream: :output], state}

  def handle_end_of_stream(pad, ctx, state), do: Muxer.handle_end_of_stream(pad, ctx, state)
end
