defmodule SalixWeb.VoiceSocket do
  @moduledoc """
  `comma.voice.v1` session callbacks (docs/messaging-voice.md).

  VoiceHTTP runs the same callbacks in its streaming request process. Accepted
  uploads replace WebSocket pongs. Both carriers use the same CallActor,
  admission, media pacing, revocation and billing identity.

  The route authenticates the voice agent key, checks that its Group is the
  path Group, and ensures the Group's voice connect before the upgrade. The
  first client frame must be `session.start`; the socket then admits the call
  (`SalixVoice.admit/1`), attaches to it, and answers `session.started`.
  Framing is `SalixVoice.Carrier.WebSocket`; limits are enforced here:

    * no `session.start` within 10 s, no caller audio for 60 s, or no pong
      within 45 s of the last one (pings every 15 s): close 4408;
    * caller audio faster than 1.25x real time beyond a 5 s catch-up burst
      after a stall, or a bad frame: close 4400;
    * agent audio is written at most 500 ms ahead of playback; a client more
      than `slow_reader_ms` (8 s) behind (`output.played` for the pacing
      marks): close 4410;
    * the Group already has a call: close 4409; draining or an unavailable
      model: close 4503; the key disabled, deleted or expired, or its Group
      deleted: close 4401.

  A refusal or limit sends `error {code, message}` before the close. A call
  that ends sends `session.ended {reason, duration_s}`, then closes with the
  reason's code (1000 for a normal end).

  Each `session.ended` or `error` close logs the call id, pod, app revision, raw reason and code. A 4410
  also logs the pacing diagnostics: the cause, the threshold, held audio, the oldest
  unconfirmed mark and its deadline, the last confirmed mark, and a bounded
  trail of mark, played and clear events. Times are milliseconds since
  `session.started`. Trail entries are `m<seq>@<sent>/d<deadline>+<written ms>`,
  `p<seq>@<at>` (`?` when no pending mark matched) and `c<dropped marks>@<at>`.
  Logs hold no audio, transcript or key material.
  """

  @behaviour WebSock

  require Logger

  alias SalixVoice.Carrier.{Pacing, WebSocket}

  @default_timers %{
    start_timeout_ms: 10_000,
    idle_ms: 60_000,
    ping_ms: 15_000,
    pong_timeout_ms: 45_000,
    ending_ms: 3_000,
    mark_check_ms: 500,
    slow_reader_ms: 8_000
  }

  @impl true
  def init(args) do
    timers =
      Map.merge(
        @default_timers,
        Map.new(SystemsRuntime.get_env(:salix_web, :voice_socket_timers, []))
      )

    state = %{
      tenant_id: args.tenant_id,
      group_id: args.group_id,
      connect_id: args.connect_id,
      key: args.key,
      transport: Map.get(args, :transport, :websocket),
      timers: timers,
      codec: WebSocket.new(),
      phase: :await_start,
      call_id: nil,
      call: nil,
      call_ref: nil,
      audio_format: nil,
      inbound: nil,
      outbound: nil,
      pace_ref: nil,
      attached_mono: nil,
      last_audio_mono: now(),
      last_pong_mono: now()
    }

    if SalixCluster.NodeLifecycle.draining?() do
      close_error(state, :draining, "the node is draining; reconnect")
    else
      SystemsClock.send_after(self(), :start_timeout, timers.start_timeout_ms)
      SystemsClock.send_after(self(), :ping, timers.ping_ms)
      {:ok, state}
    end
  end

  # -- Client frames -----------------------------------------------------------

  @impl true
  def handle_in({frame, [opcode: opcode]}, state) when opcode in [:text, :binary] do
    case WebSocket.decode({opcode, frame}, state.codec) do
      {:ok, events, codec} ->
        Enum.reduce_while(events, {:ok, %{state | codec: codec}}, fn event, {:ok, state} ->
          case event(event, state) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:push, frames, state} -> {:halt, {:push, frames, state}}
            stop -> {:halt, stop}
          end
        end)

      {:error, {:bad_frame, message}} ->
        close_error(state, :bad_frame, message)
    end
  end

  @impl true
  def handle_control({_payload, [opcode: :pong]}, state),
    do: {:ok, %{state | last_pong_mono: now()}}

  def handle_control(_frame, state), do: {:ok, state}

  defp event({:start, start}, state), do: start_call(start, state)

  defp event({:audio, audio}, %{phase: :live} = state) do
    case Pacing.ingest(state.inbound, byte_size(audio), now_ms()) do
      {:ok, inbound} ->
        send(state.call, {:voice_carrier, :audio, audio})
        {:ok, %{state | inbound: inbound, last_audio_mono: now()}}

      {:error, :too_fast} ->
        close_error(state, :too_fast, "caller audio arrived faster than 1.25x real time")
    end
  end

  defp event({:mark_played, name}, %{phase: :live} = state) do
    if Pacing.pacing_mark?(name) do
      {:ok, %{state | outbound: Pacing.played(state.outbound, name, now_ms())}}
    else
      send(state.call, {:voice_carrier, :mark_played, name})
      {:ok, state}
    end
  end

  defp event({:hangup, reason}, %{phase: :live} = state) do
    send(state.call, {:voice_carrier, :hangup, reason})
    SystemsClock.send_after(self(), :ending_timeout, state.timers.ending_ms)
    {:ok, %{state | phase: :ending}}
  end

  defp event({:hangup, _reason}, %{phase: :ending} = state), do: {:ok, state}

  defp event({:hangup, _reason}, state),
    do: {:stop, :normal, {1000, "caller_hangup"}, state}

  defp event(_event, state), do: {:ok, state}

  defp start_call(start, state) do
    key = state.key

    attrs = %{
      carrier: :websocket,
      tenant_id: state.tenant_id,
      group_id: state.group_id,
      connect_id: state.connect_id,
      caller: %{"kind" => "api_key", "value" => key["key_id"]},
      carrier_call_id: nil,
      audio_format: start.audio_format,
      key_id: key["key_id"],
      key_expires_at: expires_at_ms(key["expires_at"]),
      display_name: start.display_name || key["name"],
      principal: Salix.Control.GroupApiKeys.principal(key),
      key_name: key["name"]
    }

    with {:ok, %{call_id: call_id}} <- SalixVoice.admit(attrs),
         {:ok, current} <- current_key(state, call_id),
         {:ok, pid, info} <- attach(call_id) do
      Salix.Control.GroupApiKeys.touch_last_used(key["key_id"])

      if current["expires_at"] != key["expires_at"],
        do: send(pid, {:voice_key_expiry, key["key_id"], expires_at_ms(current["expires_at"])})

      state = %{
        state
        | phase: :live,
          call_id: call_id,
          call: pid,
          call_ref: Process.monitor(pid),
          audio_format: start.audio_format,
          inbound: Pacing.inbound(start.audio_format),
          outbound:
            Pacing.outbound(start.audio_format, slow_reader_ms: state.timers.slow_reader_ms),
          attached_mono: now(),
          last_audio_mono: now()
      }

      {frames, codec} =
        WebSocket.encode(
          {:started,
           %{
             call_id: call_id,
             audio_format: start.audio_format,
             max_duration_s: info[:max_duration_s]
           }},
          state.codec
        )

      {:push, frames, %{state | codec: codec}}
    else
      {:error, :busy} ->
        close_error(state, :busy, "the Group already has an active call")

      {:error, :revoked} ->
        close_error(state, :revoked, "the voice API key was disabled, deleted or expired")

      {:error, reason} ->
        close_error(state, admit_reason(reason), admit_message(reason))
    end
  end

  # The upgrade authenticated the key, but it may have changed before
  # `session.start`. The call has joined `{:voice_key, key_id}` by now, so a
  # later change reaches it; this read catches an earlier one.
  defp current_key(state, call_id) do
    case Salix.Control.GroupApiKeys.current_voice_key(
           state.group_id,
           state.tenant_id,
           state.key["key_id"]
         ) do
      {:ok, current} ->
        {:ok, current}

      {:error, :unauthorized} ->
        SalixVoice.abandon(call_id, :revoked)
        {:error, :revoked}

      {:error, _reason} ->
        SalixVoice.abandon(call_id, :other)
        {:error, :unavailable}
    end
  end

  # A failed attach frees the Group now rather than at the attach timeout.
  defp attach(call_id) do
    case SalixVoice.attach(call_id, self()) do
      {:ok, pid, info} ->
        {:ok, pid, info}

      {:error, _reason} ->
        SalixVoice.abandon(call_id, :carrier_error)
        {:error, :unavailable}
    end
  end

  # -- Call messages and timers ------------------------------------------------

  @impl true
  def handle_info({:voice_call, :audio, audio}, %{phase: phase} = state)
      when phase in [:live, :ending] do
    # Held in 100 ms pieces, so pacing writes a large model burst gradually.
    piece = div(SalixVoice.Carrier.bytes_per_second(state.audio_format), 10)
    outbound = audio |> pieces(piece, []) |> Enum.reduce(state.outbound, &Pacing.push(&2, &1))
    flush(%{state | outbound: outbound}, [])
  end

  def handle_info({:voice_call, :clear}, %{phase: phase} = state)
      when phase in [:live, :ending] do
    state = %{state | outbound: Pacing.clear(state.outbound, now_ms())}
    push(state, [:clear])
  end

  def handle_info({:voice_call, :mark, name}, %{phase: phase} = state)
      when phase in [:live, :ending],
      do: push(state, [{:mark, name}])

  def handle_info({:voice_call, :transcript, role, text, final?}, %{phase: phase} = state)
      when phase in [:live, :ending],
      do: push(state, [{:transcript, role, text, final?}])

  def handle_info({:voice_call, :end, reason}, %{call: pid} = state) when is_pid(pid) do
    log_close(state, "session ended", reason)
    {frames, codec} = WebSocket.encode({:end, reason, duration_s(state)}, state.codec)

    {:stop, :normal, {WebSocket.close_code(reason), WebSocket.reason_name(reason)}, frames,
     %{state | codec: codec, phase: :ended, call: nil}}
  end

  def handle_info(:pace, state), do: flush(%{state | pace_ref: nil}, [])

  def handle_info(:start_timeout, %{phase: :await_start} = state),
    do: close_error(state, :start_timeout, "no session.start within 10 s")

  def handle_info(:ping, state) do
    cond do
      state.phase in [:live, :ending] and
          elapsed_ms(state.last_audio_mono) > state.timers.idle_ms ->
        close_error(state, :idle_timeout, "no caller audio for 60 s")

      elapsed_ms(state.last_pong_mono) > state.timers.pong_timeout_ms ->
        close_error(state, :pong_timeout, "no pong for 45 s")

      true ->
        SystemsClock.send_after(self(), :ping, state.timers.ping_ms)
        {:push, {:ping, ""}, state}
    end
  end

  def handle_info(:ending_timeout, %{phase: :ending} = state),
    do: {:stop, :normal, {1000, "caller_hangup"}, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{call_ref: ref} = state) do
    if state.phase != :ended,
      do:
        Logger.info(
          "voice call exited call=#{state.call_id || "none"} #{identity()} exit=#{exit_class(reason)}"
        )

    state = %{state | call: nil, call_ref: nil}
    close_error(state, :unavailable, "the call ended unexpectedly")
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{call: pid}) when is_pid(pid) do
    send(pid, {:voice_carrier, :hangup, :carrier_closed})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Outbound pacing ---------------------------------------------------------

  defp flush(state, extra) do
    now = now_ms()
    {chunks, mark, outbound} = Pacing.take(state.outbound, now)
    state = %{state | outbound: outbound}

    if Pacing.slow_reader?(outbound, now) do
      log_slow_reader(state, now)
      close_error(state, :slow_reader, "the client stopped reading agent audio")
    else
      commands =
        Enum.map(chunks, &{:audio, &1}) ++
          if(mark, do: [{:mark, mark}], else: []) ++ extra

      state |> schedule_pace(now) |> push(commands)
    end
  end

  defp schedule_pace(%{pace_ref: nil} = state, now) do
    delay =
      case Pacing.next_due_ms(state.outbound, now) do
        nil -> if :queue.is_empty(state.outbound.marks), do: nil, else: state.timers.mark_check_ms
        due -> max(due, 10)
      end

    if delay,
      do: %{state | pace_ref: SystemsClock.send_after(self(), :pace, delay)},
      else: state
  end

  defp schedule_pace(state, _now), do: state

  # -- Helpers -----------------------------------------------------------------

  defp pieces(audio, size, acc) when byte_size(audio) > size do
    piece = binary_part(audio, 0, size)
    rest = binary_part(audio, size, byte_size(audio) - size)
    pieces(rest, size, [piece | acc])
  end

  defp pieces(audio, _size, acc), do: Enum.reverse([audio | acc])

  defp push(state, []), do: {:ok, state}

  defp push(state, commands) do
    {frames, codec} =
      Enum.reduce(commands, {[], state.codec}, fn command, {acc, codec} ->
        {frames, codec} = WebSocket.encode(command, codec)
        {acc ++ frames, codec}
      end)

    case frames do
      [] -> {:ok, %{state | codec: codec}}
      frames -> {:push, frames, %{state | codec: codec}}
    end
  end

  # `error {code, message}` (the codec writes the close code as an integer),
  # then the close. The call hears a hangup first so its end reason reaches
  # billing promptly.
  defp close_error(state, reason, message) do
    # The call's exit can still arrive after the close; that end is already
    # logged.
    if state.phase != :ended, do: log_close(state, "socket closed", reason)
    if is_pid(state.call), do: send(state.call, {:voice_carrier, :hangup, reason})

    {frames, codec} = WebSocket.encode({:error, reason, message}, state.codec)

    {:stop, :normal, {WebSocket.close_code(reason), WebSocket.reason_name(reason)}, frames,
     %{state | call: nil, codec: codec, phase: :ended}}
  end

  defp log_close(state, event, reason) do
    Logger.info(
      "voice #{event} call=#{state.call_id || "none"} #{identity()} " <>
        "reason=#{WebSocket.reason_name(reason)} code=#{WebSocket.close_code(reason)} " <>
        "duration_s=#{duration_s(state)} transport=#{state.transport}"
    )
  end

  defp log_slow_reader(state, now) do
    d = Pacing.diagnostics(state.outbound, now)
    start = System.convert_time_unit(state.attached_mono, :native, :millisecond)
    t = fn ms -> ms - start end

    {oldest, overdue} =
      case d.oldest_mark do
        {seq, deadline} -> {"pace:#{seq} oldest_deadline_ms=#{t.(deadline)}", now - deadline}
        nil -> {"none", 0}
      end

    last_played =
      case d.last_played do
        {seq, at} -> "pace:#{seq}@#{t.(at)}"
        nil -> "none"
      end

    trail =
      Enum.map_join(d.trail, " ", fn
        {:mark, seq, sent, deadline, written} -> "m#{seq}@#{t.(sent)}/d#{t.(deadline)}+#{written}"
        {:played, seq, at, true} -> "p#{seq}@#{t.(at)}"
        {:played, seq, at, false} -> "p#{seq}?@#{t.(at)}"
        {:clear, dropped, at} -> "c#{dropped}@#{t.(at)}"
      end)

    started_at =
      (SystemsClock.system_time(:millisecond) - (now - start))
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.to_iso8601()

    Logger.warning(
      "voice slow reader call=#{state.call_id} #{identity()} cause=#{d.cause} " <>
        "slow_reader_ms=#{d.slow_reader_ms} " <>
        "started_at=#{started_at} at_ms=#{t.(now)} held_ms=#{d.held_ms} " <>
        "pending_marks=#{d.pending_marks} last_sent=pace:#{d.last_sent_seq} " <>
        "oldest_mark=#{oldest} overdue_ms=#{overdue} last_played=#{last_played} " <>
        "trail=#{trail} transport=#{state.transport}"
    )
  end

  # The exit's class only: the full term can hold call state.
  defp exit_class(reason) when reason in [:normal, :shutdown, :killed, :noproc, :noconnection],
    do: reason

  defp exit_class({:shutdown, _detail}), do: "shutdown"
  defp exit_class({%{__exception__: true} = error, _stack}), do: inspect(error.__struct__)
  defp exit_class(%{__exception__: true} = error), do: inspect(error.__struct__)
  defp exit_class({reason, _stack}) when is_atom(reason), do: reason
  defp exit_class(_reason), do: "other"

  defp identity,
    do:
      "pod=#{SystemsObservability.Resource.current().pod} app_revision=#{SalixAgent.AppRevision.value()}"

  defp admit_reason(%{"error_class" => "billing_unavailable"}), do: :billing_unavailable

  defp admit_reason(reason) when reason in [:disabled, :node_full, :draining, :not_configured],
    do: reason

  defp admit_reason(_reason), do: :unavailable

  defp admit_message(%{"error_class" => "billing_unavailable", "message" => message}), do: message

  defp admit_message(:disabled), do: "voice calls are disabled"
  defp admit_message(:node_full), do: "this node has no free call capacity; reconnect"
  defp admit_message(:draining), do: "the node is draining; reconnect"
  defp admit_message(:not_configured), do: "voice calls are not configured"
  defp admit_message(_reason), do: "the voice call could not start"

  defp duration_s(%{attached_mono: nil}), do: 0

  defp duration_s(%{attached_mono: start}),
    do: Float.round(elapsed_ms(start) / 1000, 1)

  defp expires_at_ms(seconds) when is_integer(seconds), do: seconds * 1000
  defp expires_at_ms(_seconds), do: nil

  defp elapsed_ms(mono), do: System.convert_time_unit(now() - mono, :native, :millisecond)
  defp now, do: SystemsClock.monotonic_time()
  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
