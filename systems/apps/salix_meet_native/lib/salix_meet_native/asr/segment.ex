defmodule SalixMeetNative.ASR.Segment do
  @moduledoc false
  use GenServer

  require Logger

  alias SalixMeetNative.ASR.Segmenter

  @chunk_bytes div(Segmenter.sample_rate() * 2 * 40, 1_000)
  @attempt_timeout_ms 60_000
  @max_retries 10

  def start(opts), do: GenServer.start(__MODULE__, Keyword.put(opts, :owner, self()))

  def audio(segment, pcm), do: send(segment, {:audio, pcm})
  def seal(segment), do: send(segment, :seal)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    state = %{
      owner: owner,
      provider: Keyword.fetch!(opts, :provider),
      config: Keyword.fetch!(opts, :config),
      pcm: <<>>,
      sealed?: false,
      reader: nil,
      attempt: nil,
      retries: 0,
      final: nil,
      read_to: 0,
      replay?: false
    }

    {:ok, start_attempt(state)}
  end

  @impl true
  def handle_call({:read, id, offset}, from, %{attempt: %{id: id}} = state) do
    state = %{state | read_to: max(state.read_to, offset)}

    case chunk(state, offset) do
      :wait -> {:noreply, %{state | reader: {from, offset}}}
      reply -> {:reply, reply, state}
    end
  end

  def handle_call({:read, _id, _offset}, _from, state), do: {:reply, :eof, state}

  @impl true
  def handle_info({:audio, pcm}, state), do: {:noreply, wake(%{state | pcm: state.pcm <> pcm})}

  def handle_info(:seal, state) do
    state = wake(%{state | sealed?: true})
    {:noreply, if(state.replay?, do: schedule_retry(state), else: state)}
  end

  def handle_info({:result, id, %{final: true} = result}, %{attempt: %{id: id}} = state),
    do: {:noreply, %{state | final: result}}

  def handle_info({:result, _id, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{attempt: %{ref: ref}} = state) do
    SystemsClock.cancel_timer(state.attempt.timer)
    finished(%{state | attempt: nil}, outcome(reason))
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:attempt_timeout, id}, %{attempt: %{id: id, pid: pid}} = state) do
    Process.demonitor(state.attempt.ref, [:flush])
    Process.exit(pid, :kill)
    finished(%{state | attempt: nil}, {:error, :timeout})
  end

  def handle_info(:retry, state), do: {:noreply, start_attempt(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  defp finished(state, :ok) do
    if state.sealed? and state.read_to >= byte_size(state.pcm),
      do: deliver(state),
      else: retry(state, :unconsumed_audio)
  end

  defp finished(state, {:error, reason}), do: retry(state, reason)

  defp deliver(state) do
    if state.final, do: send(state.owner, {:final, self(), state.final})
    {:stop, :normal, state}
  end

  defp retry(state, reason) do
    if state.retries < @max_retries and retryable?(state, reason) do
      state = %{state | retries: state.retries + 1, final: nil, replay?: true}
      {:noreply, if(state.sealed?, do: schedule_retry(state), else: state)}
    else
      Logger.warning("meet asr: segment failed #{inspect(reason)}")
      {:stop, :normal, state}
    end
  end

  defp retryable?(_state, reason) when reason in [:timeout, :unconsumed_audio], do: true
  defp retryable?(state, reason), do: state.provider.retryable?(reason)

  defp schedule_retry(state) do
    delay = Bitwise.bsl(500, min(state.retries - 1, 4))
    SystemsClock.send_after(self(), :retry, delay)
    %{state | replay?: false}
  end

  defp start_attempt(state) do
    segment = self()
    id = make_ref()
    %{provider: provider, config: config} = state
    # A first attempt reads the audio as it arrives. A replay starts after the
    # seal with all audio present, so it sends that audio at real-time speed.
    replay? = state.retries > 0

    {pid, ref} =
      spawn_monitor(fn ->
        emit = fn result -> send(segment, {:result, id, result}) end
        exit(provider.recognize(pcm_stream(segment, id, replay?), emit, config))
      end)

    timer = SystemsClock.send_after(self(), {:attempt_timeout, id}, @attempt_timeout_ms)
    %{state | attempt: %{id: id, pid: pid, ref: ref, timer: timer}, reader: nil, read_to: 0}
  end

  defp pcm_stream(segment, id, pace?) do
    Stream.resource(
      fn -> {0, 0} end,
      fn {offset, pace_ms} ->
        if pace_ms > 0, do: SystemsClock.sleep(pace_ms)

        case GenServer.call(segment, {:read, id, offset}, :infinity) do
          {:ok, pcm} -> {[pcm], {offset + byte_size(pcm), pace_ms(pace?, pcm)}}
          :eof -> {:halt, {offset, 0}}
        end
      end,
      fn _ -> :ok end
    )
  end

  defp pace_ms(false, _pcm), do: 0
  defp pace_ms(true, pcm), do: div(byte_size(pcm) * 1_000, Segmenter.sample_rate() * 2)

  defp outcome(:ok), do: :ok
  defp outcome({:error, _} = error), do: error
  defp outcome(other), do: {:error, other}

  defp chunk(state, offset) do
    cond do
      offset < byte_size(state.pcm) ->
        {:ok, binary_part(state.pcm, offset, min(@chunk_bytes, byte_size(state.pcm) - offset))}

      state.sealed? ->
        :eof

      true ->
        :wait
    end
  end

  defp wake(%{reader: nil} = state), do: state

  defp wake(%{reader: {from, offset}} = state) do
    case chunk(state, offset) do
      :wait ->
        state

      reply ->
        GenServer.reply(from, reply)
        %{state | reader: nil}
    end
  end
end
