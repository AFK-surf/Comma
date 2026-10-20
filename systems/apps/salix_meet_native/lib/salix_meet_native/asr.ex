defmodule SalixMeetNative.ASR do
  @moduledoc false
  use GenServer

  require Logger

  alias SalixMeetNative.ASR.{Segment, Segmenter}

  @idle_ms 800

  @spec provider() :: {module(), map()} | nil
  def provider do
    with cfg when is_list(cfg) <- SystemsRuntime.get_env(:salix_meet_native, :live_asr),
         name when is_binary(name) and name != "" <- cfg[:provider] do
      module = Module.concat([name])

      if Code.ensure_loaded?(module) and function_exported?(module, :recognize, 3) do
        {module, Map.new(cfg[:config] || %{})}
      else
        Logger.warning("meet asr: provider #{name} is not in this build")
        nil
      end
    else
      _ -> nil
    end
  end

  def start(opts), do: GenServer.start(__MODULE__, opts)

  def pcm(asr, track, start, pcm), do: send(asr, {:pcm, track, start, pcm})
  def route(asr, track, device), do: send(asr, {:route, track, device})
  def participant_name(asr, device, name), do: send(asr, {:name, device, name})
  def track_end(asr, track), do: send(asr, {:track_end, track})

  @spec drain(pid(), timeout()) :: :ok | {:error, :timeout}
  def drain(asr, timeout) do
    SystemsClock.call(asr, :drain, timeout)
  catch
    :exit, _ ->
      Process.exit(asr, :kill)
      {:error, :timeout}
  end

  @impl true
  def init(opts) do
    {provider, config} = Keyword.fetch!(opts, :provider)
    Process.monitor(Keyword.fetch!(opts, :owner))

    {:ok,
     %{
       provider: provider,
       config: config,
       subscriber: Keyword.fetch!(opts, :subscriber),
       started_unix_ms: Keyword.fetch!(opts, :started_unix_ms),
       tracks: %{},
       names: %{},
       segments: %{},
       drain: nil
     }}
  end

  @impl true
  def handle_call(:drain, from, state) do
    state = Enum.reduce(Map.keys(state.tracks), state, &flush(&2, &1))
    maybe_drained(%{state | drain: from})
  end

  @impl true
  def handle_info({:pcm, id, start, pcm}, state) do
    track = track(state, id)
    {segmenter, actions} = Segmenter.push(track.segmenter, start, pcm)
    if track.idle, do: SystemsClock.cancel_timer(elem(track.idle, 0))
    token = make_ref()
    idle = SystemsClock.send_after(self(), {:idle, id, token}, @idle_ms)

    {:noreply,
     apply_actions(state, id, %{track | segmenter: segmenter, idle: {idle, token}}, actions)}
  end

  def handle_info({:route, id, device}, state) do
    state = flush(state, id)
    {:noreply, put_in(state.tracks[id].device, device)}
  end

  def handle_info({:name, device, name}, state),
    do: {:noreply, put_in(state.names[device], name)}

  def handle_info({:track_end, id}, state), do: {:noreply, flush(state, id)}

  def handle_info({:idle, id, token}, state) do
    case state.tracks[id] do
      %{idle: {_timer, ^token}} -> {:noreply, flush(state, id)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:final, segment, result}, state) do
    case state.segments[segment] do
      %{} = meta -> send(state.subscriber, {:meet_asr, caption(state, meta, result)})
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if Map.has_key?(state.segments, pid),
      do: maybe_drained(%{state | segments: Map.delete(state.segments, pid)}),
      else: {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_drained(%{drain: from, segments: segments} = state)
       when from != nil and map_size(segments) == 0 do
    GenServer.reply(from, :ok)
    {:noreply, %{state | drain: nil}}
  end

  defp maybe_drained(state), do: {:noreply, state}

  defp track(state, id),
    do:
      Map.get(state.tracks, id, %{segmenter: %Segmenter{}, segment: nil, device: nil, idle: nil})

  defp flush(state, id) do
    track = track(state, id)
    if track.idle, do: SystemsClock.cancel_timer(elem(track.idle, 0))
    {segmenter, actions} = Segmenter.flush(track.segmenter)
    apply_actions(state, id, %{track | segmenter: segmenter, idle: nil}, actions)
  end

  defp apply_actions(state, id, track, actions) do
    {track, state} =
      Enum.reduce(actions, {track, state}, fn
        {:open, start}, {track, state} ->
          {:ok, segment} = Segment.start(provider: state.provider, config: state.config)
          Process.monitor(segment)
          meta = %{device: track.device, start: start}
          {%{track | segment: segment}, put_in(state.segments[segment], meta)}

        {:audio, pcm}, {%{segment: segment}, _} = acc when is_pid(segment) ->
          Segment.audio(segment, pcm)
          acc

        :seal, {%{segment: segment} = track, state} when is_pid(segment) ->
          Segment.seal(segment)
          {%{track | segment: nil}, state}

        _action, acc ->
          acc
      end)

    put_in(state.tracks[id], track)
  end

  defp caption(state, meta, result) do
    at =
      state.started_unix_ms + div(meta.start * 1_000, Segmenter.sample_rate()) + result.start_ms

    %{
      "speaker" => Map.get(state.names, meta.device, ""),
      "text" => result.text,
      "timestamp" => div(at, 1_000),
      "timestamp_ms" => at,
      "source" => state.provider.name()
    }
  end
end
