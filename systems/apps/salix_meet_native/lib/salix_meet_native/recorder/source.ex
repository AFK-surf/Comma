defmodule SalixMeetNative.Recorder.Source do
  @moduledoc false
  use Membrane.Source

  def_options(reorder_window_ns: [spec: non_neg_integer(), default: 500_000_000])

  def_output_pad(:output,
    accepted_format: %Membrane.Opus{self_delimiting?: false},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts),
    do: {[], %{window: opts.reorder_window_ns, held: [], ready: [], last_pts: nil, eos?: false}}

  @impl true
  def handle_playing(_ctx, state) do
    format = [stream_format: {:output, %Membrane.Opus{channels: 2, self_delimiting?: false}}]
    {format ++ release(state), %{state | ready: []}}
  end

  @impl true
  def handle_parent_notification({:buffer, buffer}, ctx, state) do
    state = hold(state, buffer)
    emit(ctx, state)
  end

  def handle_parent_notification(:end_of_stream, ctx, state) do
    state = %{state | ready: state.ready ++ state.held, held: [], eos?: true}
    emit(ctx, state)
  end

  def handle_parent_notification(_msg, _ctx, state), do: {[], state}

  defp hold(%{last_pts: last} = state, %{pts: pts}) when last != nil and pts <= last, do: state

  defp hold(state, buffer) do
    if Enum.any?(state.held, &(&1.pts == buffer.pts)), do: state, else: hold_new(state, buffer)
  end

  defp hold_new(state, buffer) do
    held = Enum.sort_by([buffer | state.held], & &1.pts)
    newest = List.last(held).pts
    {due, held} = Enum.split_while(held, &(&1.pts <= newest - state.window))
    last_pts = if due == [], do: state.last_pts, else: List.last(due).pts
    %{state | held: held, ready: state.ready ++ due, last_pts: last_pts}
  end

  defp emit(%{playback: :playing}, state), do: {release(state), %{state | ready: []}}
  defp emit(_ctx, state), do: {[], state}

  defp release(state) do
    buffers = if state.ready == [], do: [], else: [buffer: {:output, state.ready}]
    eos = if state.eos? and state.held == [], do: [end_of_stream: :output], else: []
    buffers ++ eos
  end
end
