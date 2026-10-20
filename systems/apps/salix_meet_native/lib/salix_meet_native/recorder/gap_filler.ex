defmodule SalixMeetNative.Recorder.GapFiller do
  @moduledoc false
  use Membrane.Filter

  @plc_20ms {<<19::5, 0::1, 0::2>>, Membrane.Time.milliseconds(20)}
  @plc_2_5ms {<<16::5, 0::1, 0::2>>, Membrane.Time.microseconds(2_500)}

  def_input_pad(:input, accepted_format: %Membrane.Opus{self_delimiting?: false})
  def_output_pad(:output, accepted_format: %Membrane.Opus{self_delimiting?: false})

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{base: nil, next_pts: 0}}

  @impl true
  def handle_buffer(
        :input,
        %Membrane.Buffer{pts: pts, metadata: %{duration: duration}} = buffer,
        _ctx,
        state
      ) do
    base = state.base || pts
    pts = pts - base
    {fillers, filled_to} = fill(state.next_pts, pts + Membrane.Time.millisecond(), [])

    {[buffer: {:output, fillers ++ [%{buffer | pts: max(pts, filled_to)}]}],
     %{state | base: base, next_pts: max(pts, filled_to) + duration}}
  end

  defp fill(at, until, acc) do
    case Enum.find([@plc_20ms, @plc_2_5ms], fn {_packet, d} -> at + d <= until end) do
      {packet, d} ->
        fill(at + d, until, [
          %Membrane.Buffer{payload: packet, pts: at, metadata: %{duration: d}} | acc
        ])

      nil ->
        {Enum.reverse(acc), at}
    end
  end
end
