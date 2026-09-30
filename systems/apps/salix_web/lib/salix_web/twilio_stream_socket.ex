defmodule SalixWeb.TwilioStreamSocket do
  @moduledoc """
  Twilio Media Streams socket for one admitted call (docs/messaging-voice.md).

  The route verifies the stream token before the upgrade. The socket attaches
  to the call when Twilio's `start` message arrives, so `SalixVoice.attach/3`
  can check `start.callSid` against the admitted `CallSid`; a second socket
  or another call's token fails closed. Frames are translated by
  `SalixVoice.Carrier.Twilio`: caller audio, marks, DTMF and `stop` go to the
  `CallActor`; agent audio, `clear` and marks come back. Twilio buffers
  playback itself, so no pacing applies here.

  When the call ends the socket closes. `<Connect><Stream>` has no further
  TwiML verb, so Twilio ends the call; a best-effort Calls API hangup covers
  a call that Twilio would otherwise keep open.
  """

  @behaviour WebSock

  require Logger

  alias SalixVoice.Carrier.Twilio

  @start_timeout_ms 10_000

  @impl true
  def init(%{token: token} = args) do
    if SalixCluster.NodeLifecycle.draining?() do
      {:stop, :normal, {1001, "draining"}, %{token: token, call_id: args[:call_id], call: nil}}
    else
      Process.send_after(self(), :start_timeout, @start_timeout_ms)

      {:ok,
       %{
         token: token,
         call_id: args[:call_id],
         codec: Twilio.new(),
         call: nil,
         call_ref: nil,
         call_sid: nil,
         ended?: false
       }}
    end
  end

  @impl true
  def handle_in({frame, [opcode: :text]}, state) do
    case Twilio.decode({:text, frame}, state.codec) do
      {:ok, events, codec} ->
        Enum.reduce_while(events, {:ok, %{state | codec: codec}}, fn event, {:ok, state} ->
          case event(event, state) do
            {:ok, state} -> {:cont, {:ok, state}}
            stop -> {:halt, stop}
          end
        end)

      {:error, _reason} ->
        {:stop, :normal, {1003, "bad_frame"}, hangup_call(state, :carrier_error)}
    end
  end

  def handle_in({_frame, [opcode: _binary]}, state), do: {:ok, state}

  defp event({:start, info}, %{call: nil} = state) do
    case SalixVoice.attach(state.token, self(), carrier_call_id: info.call_sid) do
      {:ok, pid, _info} ->
        {:ok, %{state | call: pid, call_ref: Process.monitor(pid), call_sid: info.call_sid}}

      {:error, reason} ->
        Logger.warning("twilio stream attach refused reason=#{inspect(reason)}")
        {:stop, :normal, {1008, "attach_refused"}, state}
    end
  end

  defp event({:audio, audio}, %{call: pid} = state) when is_pid(pid) do
    send(pid, {:voice_carrier, :audio, audio})
    {:ok, state}
  end

  defp event({:mark_played, name}, %{call: pid} = state) when is_pid(pid) do
    send(pid, {:voice_carrier, :mark_played, name})
    {:ok, state}
  end

  defp event({:dtmf, digit}, %{call: pid} = state) when is_pid(pid) do
    send(pid, {:voice_carrier, :dtmf, digit})
    {:ok, state}
  end

  defp event({:hangup, reason}, %{call: pid} = state) when is_pid(pid) do
    send(pid, {:voice_carrier, :hangup, reason})
    {:ok, %{state | ended?: true}}
  end

  defp event(_event, state), do: {:ok, state}

  @impl true
  def handle_info({:voice_call, :end, _reason}, state) do
    unless state.ended?, do: maybe_rest_hangup(state)
    {:stop, :normal, 1000, %{state | ended?: true}}
  end

  def handle_info({:voice_call, command, value}, state),
    do: push(state, {command, value})

  def handle_info({:voice_call, :clear}, state), do: push(state, :clear)

  def handle_info({:voice_call, _command, _a, _b, _c}, state), do: {:ok, state}

  def handle_info(:start_timeout, %{call: nil} = state),
    do: {:stop, :normal, {1008, "start_timeout"}, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{call_ref: ref} = state) do
    unless state.ended?, do: maybe_rest_hangup(state)
    {:stop, :normal, 1000, %{state | call: nil, call_ref: nil, ended?: true}}
  end

  def handle_info(_message, state), do: {:ok, state}

  # A stream that closes before it attached (no `start`, or a refused one)
  # frees the admitted call's Group now instead of at the attach timeout.
  @impl true
  def terminate(_reason, %{call: nil, call_id: call_id}) when is_binary(call_id) do
    SalixVoice.abandon(call_id, :carrier_error)
  end

  def terminate(_reason, state) do
    _ = hangup_call(state, :carrier_closed)
    :ok
  end

  defp push(state, command) do
    case Twilio.encode(command, state.codec) do
      {[], codec} -> {:ok, %{state | codec: codec}}
      {frames, codec} -> {:push, frames, %{state | codec: codec}}
    end
  end

  defp hangup_call(%{call: pid, ended?: false} = state, reason) when is_pid(pid) do
    send(pid, {:voice_carrier, :hangup, reason})
    %{state | ended?: true}
  end

  defp hangup_call(state, _reason), do: state

  defp maybe_rest_hangup(%{call_sid: call_sid}) when is_binary(call_sid) do
    Task.Supervisor.start_child(SalixVoice.TaskSupervisor, fn ->
      with {:ok, settings} <- SalixVoice.Settings.get(),
           {:error, reason} <- SalixWeb.TwilioClient.hangup(settings, call_sid) do
        Logger.debug("twilio hangup skipped call=#{call_sid} reason=#{inspect(reason)}")
      end
    end)

    :ok
  catch
    _, _ -> :ok
  end

  defp maybe_rest_hangup(_state), do: :ok
end
