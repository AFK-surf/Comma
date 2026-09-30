defmodule SalixSignal.CallMedia.Connection do
  @moduledoc """
  One 1:1 call media connection to one remote device (CRS-13).

  The process owns an ICE agent (`ExICE`), the SRTP contexts of both
  directions, the in-band control channel, the Opus codec, a jitter buffer
  and the RTCP reports. It runs on the node that holds the call's
  `SalixVoice.CallActor` (PLAN "Design rules": call media is node-local).

  ## Owner

  The owner is the call-signaling process (CRS-12). It passes what the
  offer and answer carry and receives `{:signal_call_media, pid, event}`:

    * `{:local_candidate, candidate}`: an ICE candidate string
      (`candidate:...`) to send in an ICE update
    * `{:ice, state}`: `:checking | :connected | :completed | :failed | :closed`
    * `:accepted`: (caller role) the callee device accepted in-band
    * `{:remote_hangup, type, device_id}`: an in-band hangup (CRS-13 9.4)
    * `{:protocol_error, reason}`: the peer broke a CRS-13 rule; the
      connection stops
    * `{:remote_status, map}`: a sender or receiver status (CRS-13 9.5, 9.6)
    * `{:call_ended, reason}`: the attached voice call ended; the owner sends
      the signaling hangup (CRS-12 section 7.3)

  In-band hangups follow the signaling rules (CRS-12 section 7): a caller
  ignores types 1 to 3, a callee ignores type 4 and any hangup about its own
  device (`local_device_id`).

  The connection stops after a remote hangup, a local `hangup/3`, an ICE
  failure, or the exit of its owner or its voice call. It never sends a
  signaling message itself.

  ## Media gating (CRS-13 section 8)

  No audio is sent or played before acceptance. The callee enables media and
  sends "accepted" at `accept/1`. The caller enables media when "accepted"
  for its call ID arrives on the ICE-connected connection. Control messages,
  RTCP and STUN flow before acceptance.

  ## Voice call

  After `attach_call/2` the connection is the carrier socket of a
  `SalixVoice.CallActor` (see `SalixVoice`): decoded caller audio goes to
  the call as `{:voice_carrier, :audio, pcm16_24k}`, and the call's
  `{:voice_call, ...}` messages come back here. Agent audio is sent as one
  60 ms Opus packet every 60 ms. At most `max_held_ms` of it waits here.
  After acceptance, caller PCM flows at the playout rate even during DTX
  silence. This keeps the voice model's timeline running before speech.
  The decoded input queue keeps at most the newest two seconds.

  ## Roles and forks

  The callee role is complete. In the caller role the ICE credentials come
  from this connection's ICE agent, so one connection serves one answering
  device: the owner starts the connection before the offer and binds it to
  the first answer with `set_remote/2`.
  """

  use GenServer, restart: :temporary

  alias SalixSignal.CallMedia.{JitterBuffer, Opus}
  alias SalixSignalProto.CallMedia
  alias SalixSignalProto.CallMedia.{Control, Keys, Rtcp, Rtp, Srtp}

  # Remote ICE candidates held or given to the ICE agent per connection. The
  # peer chooses every candidate address, and each one adds candidate pairs
  # and outgoing connectivity checks, so the count is bounded. Signal
  # clients send a few host, server-reflexive and relay candidates.
  @max_remote_candidates 64

  # At most two seconds (96 KB) of decoded caller audio per connection,
  # matching the call core's prebuffer. The existing 20 ms playout timer
  # feeds a continuous stream, including silence during Opus DTX gaps.
  @max_input_pcm_bytes 96_000

  @defaults %{
    control_repeat_ms: 1_000,
    rtcp_interval_ms: 5_000,
    playout_tick_ms: 20,
    jitter_delay_ms: 60,
    max_held_ms: 120_000,
    hangup_linger_ms: 200,
    max_conceal_ms: 120
  }

  # -- API ---------------------------------------------------------------------

  @doc """
  Starts a connection. Required: `role` (`:caller | :callee`), `call_id`
  (unsigned 64-bit), `owner` (pid), `caller_identity_key` and
  `callee_identity_key` (32 bytes each, without the type byte). Optional:
  `remote` (`%{public_key, ice_ufrag, ice_pwd}` from the peer's connection
  parameters; required for the callee), `ice_servers` (from
  `SalixSignal.CallMedia.Relays.ice_servers/1`), `relay_only` (send only
  relay candidates), `keypair` (`{public, private}`), `local_device_id`
  (this account's Signal device ID), `ice_opts` (extra
  `ExICE.ICEAgent` options) and timer overrides.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc """
  This side's connection parameters for the offer or answer:
  `%{public_key, ice_ufrag, ice_pwd}`.
  """
  def local_parameters(pid), do: GenServer.call(pid, :local_parameters)

  @doc "Caller role: binds the connection to the answering device's parameters."
  def set_remote(pid, remote), do: GenServer.call(pid, {:set_remote, remote})

  @doc """
  Adds a remote ICE candidate (`candidate:...`, from an ICE update). After
  `max_remote_candidates/0` candidates, further ones are dropped.
  """
  def add_remote_candidate(pid, candidate),
    do: GenServer.cast(pid, {:remote_candidate, candidate})

  @doc """
  Removes a remote candidate (CRS-12 section 5.3.2). The ICE library cannot
  remove a remote candidate, so this has no effect; a removed candidate's
  pair fails its checks instead.
  """
  def remove_remote_candidate(_pid, _address), do: :ok

  @doc "The most remote ICE candidates one connection accepts."
  def max_remote_candidates, do: @max_remote_candidates

  @doc "Callee role: the local user accepted. Sends \"accepted\" and enables media."
  def accept(pid), do: GenServer.call(pid, :accept)

  @doc """
  Sends an in-band hangup (CRS-13 section 9.4) and stops the connection.
  `type` is the CRS-12 hangup type (0 normal) and `device_id` its device
  field.
  """
  def hangup(pid, type \\ 0, device_id \\ nil),
    do: GenServer.cast(pid, {:hangup, type, device_id})

  @doc "Makes this connection the carrier socket of the voice call `call_id`."
  def attach_call(pid, call_id), do: GenServer.call(pid, {:attach_call, call_id}, 10_000)

  @doc "Queues agent audio (PCM16 mono 24 kHz) for sending."
  def send_audio(pid, pcm), do: send(pid, {:voice_call, :audio, pcm})

  @doc "Counters for tests and diagnostics."
  def stats(pid), do: GenServer.call(pid, :stats)

  # -- Init --------------------------------------------------------------------

  @impl GenServer
  def init(%{role: role, call_id: call_id, owner: owner} = opts)
      when role in [:caller, :callee] and is_integer(call_id) and is_pid(owner) do
    Process.flag(:trap_exit, true)
    timers = Map.merge(@defaults, Map.take(opts, Map.keys(@defaults)))
    {public, private} = opts[:keypair] || Keys.generate_keypair()
    {:ok, encoder} = Opus.encoder()
    {:ok, decoder} = Opus.decoder()

    ice_opts =
      [
        role: if(role == :caller, do: :controlling, else: :controlled),
        ice_servers: opts[:ice_servers] || [],
        ice_transport_policy: if(opts[:relay_only], do: :relay, else: :all),
        on_new_candidate: self(),
        on_connection_state_change: self(),
        on_gathering_state_change: self(),
        on_data: self()
      ] ++ (opts[:ice_opts] || [])

    {:ok, ice} = ExICE.ICEAgent.start_link(ice_opts)
    {:ok, ufrag, pwd} = ExICE.ICEAgent.get_local_credentials(ice)
    :ok = ExICE.ICEAgent.gather_candidates(ice)

    state = %{
      role: role,
      call_id: call_id,
      owner: owner,
      owner_ref: Process.monitor(owner),
      identity: {opts.caller_identity_key, opts.callee_identity_key},
      local_device_id: opts[:local_device_id],
      private: private,
      local: %{public_key: public, ice_ufrag: ufrag, ice_pwd: pwd},
      remote: nil,
      pending_candidates: [],
      remote_candidates: 0,
      ice: ice,
      tls_relay: opts[:tls_relay],
      ice_state: :new,
      tx: nil,
      rx: nil,
      control_tx: Control.sender(),
      control_rx: Control.receiver(),
      accepted: false,
      encoder: encoder,
      decoder: decoder,
      jitter: JitterBuffer.new(delay_ms: timers.jitter_delay_ms),
      last_played_samples: nil,
      input_pcm: <<>>,
      audio_seq: :rand.uniform(0x7FFF),
      audio_ts: :rand.uniform(0x7FFFFFFF),
      talking: false,
      held: <<>>,
      held_consumed: 0,
      marks: [],
      recv_stats: Rtcp.receive_stats(CallMedia.peer_audio_ssrc(role)),
      sent_packets: 0,
      sent_octets: 0,
      sent_since_report: false,
      counters: %{rtp_in: 0, audio_in: 0, audio_out: 0, dropped_in: 0, auth_failed: 0},
      call: nil,
      call_ref: nil,
      next_send_ms: nil,
      timers: timers,
      closing: false
    }

    state =
      case opts[:remote] do
        nil -> state
        remote -> bind_remote(state, remote)
      end

    if role == :callee and state.remote == nil, do: raise(ArgumentError, "callee needs :remote")

    schedule(:control_repeat, timers.control_repeat_ms)
    schedule(:rtcp, timers.rtcp_interval_ms)
    schedule(:playout, timers.playout_tick_ms)
    {:ok, state}
  catch
    :error, reason -> {:stop, reason}
  end

  # -- Calls -------------------------------------------------------------------

  @impl GenServer
  def handle_call(:local_parameters, _from, state), do: {:reply, state.local, state}

  def handle_call({:set_remote, remote}, _from, %{remote: nil} = state) do
    {:reply, :ok, bind_remote(state, remote)}
  catch
    :error, reason -> {:reply, {:error, reason}, state}
  end

  def handle_call({:set_remote, _remote}, _from, state),
    do: {:reply, {:error, :already_set}, state}

  def handle_call(:accept, _from, %{role: :callee, accepted: false} = state) do
    {packet, control_tx} = Control.send_event(state.control_tx, {:accepted, state.call_id})
    state = send_rtp(%{state | control_tx: control_tx, accepted: true}, packet)
    state = start_sending(state)
    {:reply, :ok, state}
  end

  def handle_call(:accept, _from, state), do: {:reply, {:error, :not_acceptable}, state}

  def handle_call({:attach_call, call_id}, _from, %{call: nil} = state) do
    case SalixVoice.attach(call_id, self()) do
      {:ok, call, info} ->
        {:reply, {:ok, info}, %{state | call: call, call_ref: Process.monitor(call)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:attach_call, _call_id}, _from, state),
    do: {:reply, {:error, :already_attached}, state}

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.counters, %{
        ice_state: state.ice_state,
        accepted: state.accepted,
        late: JitterBuffer.late_count(state.jitter),
        held_ms: held_ms(state)
      })

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:remote_candidate, _candidate}, %{remote_candidates: count} = state)
      when count >= @max_remote_candidates,
      do: {:noreply, state}

  def handle_cast({:remote_candidate, candidate}, state) when is_binary(candidate) do
    state = %{state | remote_candidates: state.remote_candidates + 1}

    case state.remote do
      nil -> {:noreply, %{state | pending_candidates: [candidate | state.pending_candidates]}}
      _ -> {:noreply, add_candidate(state, candidate)}
    end
  end

  def handle_cast({:hangup, type, device_id}, state),
    do: {:noreply, local_hangup(state, type, device_id)}

  # -- ICE ---------------------------------------------------------------------

  @impl GenServer
  def handle_info({:ex_ice, ice, {:data, packet}}, %{ice: ice} = state),
    do: {:noreply, receive_packet(state, packet)}

  def handle_info({:ex_ice, ice, {:new_candidate, candidate}}, %{ice: ice} = state) do
    notify(state, {:local_candidate, "candidate:" <> candidate})
    {:noreply, state}
  end

  def handle_info({:ex_ice, ice, {:connection_state_change, ice_state}}, %{ice: ice} = state) do
    notify(state, {:ice, ice_state})
    state = %{state | ice_state: ice_state}

    case ice_state do
      :connected ->
        # Deliver an accumulated control message at once instead of at the
        # next repeat.
        {:noreply, repeat_control(state)}

      :failed ->
        {:stop, {:shutdown, :ice_failed}, state}

      :closed ->
        {:stop, {:shutdown, :ice_closed}, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:ex_ice, _ice, _event}, state), do: {:noreply, state}

  # -- Timers ------------------------------------------------------------------

  def handle_info(:control_repeat, state) do
    schedule(:control_repeat, state.timers.control_repeat_ms)
    {:noreply, repeat_control(state)}
  end

  def handle_info(:rtcp, state) do
    schedule(:rtcp, state.timers.rtcp_interval_ms)
    {:noreply, send_report(state)}
  end

  def handle_info(:playout, state) do
    schedule(:playout, state.timers.playout_tick_ms)
    {:noreply, playout(state)}
  end

  def handle_info(:send_tick, state), do: {:noreply, send_tick(state)}

  def handle_info(:linger_done, state), do: {:stop, :normal, state}

  # -- Voice call (carrier socket) ---------------------------------------------

  def handle_info({:voice_call, :audio, pcm}, state) when is_binary(pcm),
    do: {:noreply, hold_audio(state, pcm)}

  def handle_info({:voice_call, :clear}, state), do: {:noreply, clear_audio(state)}

  def handle_info({:voice_call, :mark, name}, state) do
    position = state.held_consumed + byte_size(state.held)
    {:noreply, %{state | marks: state.marks ++ [{position, name}]} |> flush_marks()}
  end

  def handle_info({:voice_call, :end, reason}, state) do
    if state.call_ref, do: Process.demonitor(state.call_ref, [:flush])
    notify(state, {:call_ended, reason})
    {:noreply, local_hangup(%{state | call: nil, call_ref: nil}, 0, nil)}
  end

  def handle_info({:voice_call, _kind, _a, _b, _c}, state), do: {:noreply, state}
  def handle_info({:voice_call, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{call_ref: ref} = state) do
    notify(state, {:call_ended, reason})
    {:noreply, local_hangup(%{state | call: nil, call_ref: nil}, 0, nil)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:noreply, local_hangup(%{state | owner: nil}, 0, nil)}

  def handle_info({:EXIT, ice, reason}, %{ice: ice} = state),
    do: {:stop, {:shutdown, {:ice_exit, reason}}, %{state | ice: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    SalixSignal.CallMedia.TLSRelay.stop(state.tls_relay)
    if state.call, do: send(state.call, {:voice_carrier, :hangup, :remote})

    if state.ice do
      try do
        ExICE.ICEAgent.stop(state.ice)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # -- Setup -------------------------------------------------------------------

  defp bind_remote(state, %{public_key: peer, ice_ufrag: ufrag, ice_pwd: pwd})
       when is_binary(ufrag) and is_binary(pwd) do
    {caller_ik, callee_ik} = state.identity

    case Keys.derive(state.role, state.private, peer, caller_ik, callee_ik) do
      {:ok, keys} ->
        :ok = ExICE.ICEAgent.set_remote_credentials(state.ice, ufrag, pwd)

        state = %{
          state
          | remote: %{ice_ufrag: ufrag, ice_pwd: pwd},
            private: nil,
            tx: Srtp.new(keys.send.key, keys.send.salt),
            rx: Srtp.new(keys.receive.key, keys.receive.salt)
        }

        state.pending_candidates
        |> Enum.reverse()
        |> Enum.reduce(%{state | pending_candidates: []}, &add_candidate(&2, &1))

      {:error, reason} ->
        raise ArgumentError, "invalid remote parameters: #{inspect(reason)}"
    end
  end

  defp add_candidate(state, "candidate:" <> candidate) do
    ExICE.ICEAgent.add_remote_candidate(state.ice, candidate)
    state
  end

  defp add_candidate(state, _candidate), do: state

  # -- Receive -----------------------------------------------------------------

  defp receive_packet(%{rx: nil} = state, _packet), do: state

  defp receive_packet(state, packet) do
    cond do
      not Rtp.rtp_or_rtcp?(packet) -> state
      Rtp.rtcp?(packet) -> receive_rtcp(state, packet)
      true -> receive_rtp(state, packet)
    end
  end

  defp receive_rtcp(state, packet) do
    with {:ok, plain, rx} <- Srtp.unprotect_rtcp(state.rx, packet),
         {:ok, entries} <- Rtcp.parse(plain) do
      stats =
        Enum.reduce(entries, state.recv_stats, fn
          {:sender_report, _ssrc, ntp}, stats -> Rtcp.record_sender_report(stats, ntp, now_ms())
          _entry, stats -> stats
        end)

      %{state | rx: rx, recv_stats: stats}
    else
      _ -> count(state, :auth_failed)
    end
  end

  defp receive_rtp(state, packet) do
    with {:ok, plain, rx} <- Srtp.unprotect(state.rx, packet),
         {:ok, rtp} <- Rtp.decode(plain) do
      state = count(%{state | rx: rx}, :rtp_in)

      cond do
        Control.control_packet?(rtp) -> receive_control(state, rtp.payload)
        audio?(state, rtp) -> receive_audio(state, rtp)
        true -> state
      end
    else
      _ -> count(state, :auth_failed)
    end
  end

  defp audio?(state, %Rtp{payload_type: pt, ssrc: ssrc}),
    do: pt == CallMedia.opus_payload_type() and ssrc == CallMedia.peer_audio_ssrc(state.role)

  defp receive_audio(%{accepted: false} = state, _rtp), do: count(state, :dropped_in)

  defp receive_audio(state, rtp) do
    now = now_ms()
    stats = Rtcp.record(state.recv_stats, rtp.sequence_number, rtp.timestamp, now)

    jitter =
      JitterBuffer.push(state.jitter, rtp.sequence_number, rtp.timestamp, rtp.payload, now)

    count(%{state | recv_stats: stats, jitter: jitter}, :audio_in)
  end

  defp receive_control(state, payload) do
    case Control.receive_payload(state.control_rx, payload) do
      {:ok, events, control_rx} ->
        Enum.reduce(events, %{state | control_rx: control_rx}, &control_event(&2, &1))

      {:error, _reason} ->
        state
    end
  end

  # Accepted and hangup repeat once per second (CRS-13 section 9.7): each
  # takes effect at most once, and nothing does after the connection closes.
  defp control_event(%{closing: true} = state, _event), do: state

  defp control_event(%{role: :caller, accepted: false} = state, {:accepted, call_id}) do
    if call_id == state.call_id and state.ice_state in [:connected, :completed] do
      notify(state, :accepted)
      start_sending(%{state | accepted: true})
    else
      state
    end
  end

  # Only the callee sends "accepted" (CRS-13 section 9.3).
  defp control_event(%{role: :callee} = state, {:accepted, _call_id}) do
    notify(state, {:protocol_error, :accepted_from_caller})
    stop_now(state)
  end

  defp control_event(state, {:hangup, call_id, type, device_id} = hangup) do
    if call_id == state.call_id and not ignored_hangup?(state, hangup) do
      notify(state, {:remote_hangup, type, device_id})
      stop_now(state)
    else
      state
    end
  end

  defp control_event(state, {kind, status}) when kind in [:sender_status, :receiver_status] do
    if status[:call_id] in [nil, state.call_id], do: notify(state, {:remote_status, status})
    state
  end

  defp control_event(state, _event), do: state

  defp ignored_hangup?(%{role: :caller}, {:hangup, _id, type, _device}), do: type in 1..3
  defp ignored_hangup?(%{role: :callee}, {:hangup, _id, 4, _device}), do: true

  defp ignored_hangup?(%{role: :callee} = state, {:hangup, _id, type, device}),
    do: type in 1..3 and device != nil and device == state.local_device_id

  defp stop_now(state) do
    send(self(), :linger_done)
    %{state | closing: true}
  end

  # -- Playout -----------------------------------------------------------------

  defp playout(state) do
    {items, jitter} = JitterBuffer.pop(state.jitter, now_ms())

    items
    |> Enum.reduce(%{state | jitter: jitter}, &play_item(&2, &1))
    |> deliver_playout()
  end

  defp play_item(state, {:packet, payload, _ts}) do
    case Opus.decode(state.decoder, payload) do
      {:ok, pcm} ->
        state = queue_input(state, pcm)
        %{state | last_played_samples: div(byte_size(pcm), 2)}

      {:error, _reason} ->
        state
    end
  end

  defp play_item(state, {:lost, missing, next, gap_ticks}) do
    case conceal_samples(state, gap_ticks) do
      0 ->
        state

      samples ->
        source = if missing == 1, do: next, else: nil

        case Opus.conceal(state.decoder, source, samples) do
          {:ok, pcm} -> queue_input(state, pcm)
          {:error, _reason} -> state
        end
    end
  end

  # Lost audio between the last played packet and the next one, at the codec
  # rate, rounded down to 2.5 ms and capped.
  defp conceal_samples(%{last_played_samples: nil}, _gap), do: 0
  defp conceal_samples(_state, nil), do: 0

  defp conceal_samples(state, gap_ticks) do
    samples =
      div(gap_ticks * Opus.rate(), CallMedia.opus_clock_rate()) - state.last_played_samples

    step = div(Opus.rate(), 400)
    cap = div(Opus.rate() * state.timers.max_conceal_ms, 1000)
    samples |> min(cap) |> max(0) |> div(step) |> Kernel.*(step)
  end

  defp queue_input(%{call: call} = state, pcm) when is_pid(call) do
    buffered = state.input_pcm <> pcm
    keep = min(byte_size(buffered), @max_input_pcm_bytes)
    pcm = binary_part(buffered, byte_size(buffered) - keep, keep)
    %{state | input_pcm: pcm}
  end

  defp queue_input(state, _pcm), do: state

  defp deliver_playout(%{accepted: true, closing: false, call: call} = state)
       when is_pid(call) do
    bytes = div(Opus.rate() * state.timers.playout_tick_ms, 1000) * 2
    take = min(byte_size(state.input_pcm), bytes)
    <<audio::binary-size(^take), rest::binary>> = state.input_pcm
    pcm = audio <> :binary.copy(<<0>>, bytes - take)
    send(call, {:voice_carrier, :audio, pcm})
    %{state | input_pcm: rest}
  end

  defp deliver_playout(state), do: state

  # -- Send --------------------------------------------------------------------

  defp start_sending(%{next_send_ms: nil} = state) do
    send(self(), :send_tick)
    %{state | next_send_ms: now_ms()}
  end

  defp start_sending(state), do: state

  defp send_tick(%{closing: true} = state), do: state

  defp send_tick(state) do
    frame = Opus.frame_bytes()
    state = %{state | next_send_ms: state.next_send_ms + Opus.frame_ms()}
    Process.send_after(self(), :send_tick, max(state.next_send_ms - now_ms(), 0))

    state =
      case state.held do
        <<>> ->
          %{state | talking: false}

        held ->
          {pcm, rest} =
            if byte_size(held) >= frame,
              do: :erlang.split_binary(held, frame),
              else: {held <> <<0::size((frame - byte_size(held)) * 8)>>, <<>>}

          consumed = byte_size(held) - byte_size(rest)
          state = %{state | held: rest, held_consumed: state.held_consumed + consumed}
          state |> send_frame(pcm) |> flush_marks()
      end

    %{state | audio_ts: state.audio_ts + Opus.rtp_ticks(div(frame, 2))}
  end

  defp send_frame(state, pcm) do
    case Opus.encode(state.encoder, pcm) do
      # A DTX frame of 2 bytes or less need not be sent (RFC 6716).
      {:ok, packet} when byte_size(packet) <= 2 ->
        %{state | talking: false}

      {:ok, packet} ->
        rtp =
          Rtp.encode(%Rtp{
            marker: not state.talking,
            payload_type: CallMedia.opus_payload_type(),
            sequence_number: state.audio_seq,
            timestamp: state.audio_ts,
            ssrc: CallMedia.audio_ssrc(state.role),
            payload: packet
          })

        state = send_rtp(state, rtp)

        count(
          %{
            state
            | audio_seq: Bitwise.band(state.audio_seq + 1, 0xFFFF),
              talking: true,
              sent_packets: state.sent_packets + 1,
              sent_octets: state.sent_octets + byte_size(packet),
              sent_since_report: true
          },
          :audio_out
        )

      {:error, _reason} ->
        state
    end
  end

  defp hold_audio(state, pcm) do
    state = %{state | held: state.held <> pcm}
    max_bytes = div(Opus.rate() * 2 * state.timers.max_held_ms, 1000)

    if byte_size(state.held) > max_bytes do
      drop = byte_size(state.held) - max_bytes
      <<_::binary-size(^drop), rest::binary>> = state.held
      flush_marks(%{state | held: rest, held_consumed: state.held_consumed + drop})
    else
      state
    end
  end

  defp clear_audio(state) do
    state = %{state | held_consumed: state.held_consumed + byte_size(state.held), held: <<>>}
    flush_marks(state)
  end

  defp flush_marks(state) do
    {played, pending} =
      Enum.split_while(state.marks, fn {pos, _} -> pos <= state.held_consumed end)

    if state.call,
      do:
        Enum.each(played, fn {_, name} ->
          send(state.call, {:voice_carrier, :mark_played, name})
        end)

    %{state | marks: pending}
  end

  defp held_ms(state), do: div(byte_size(state.held) * 1000, Opus.rate() * 2)

  defp repeat_control(state) do
    case Control.repeat(state.control_tx) do
      {nil, _} -> state
      {packet, control_tx} -> send_rtp(%{state | control_tx: control_tx}, packet)
    end
  end

  defp local_hangup(%{closing: true} = state, _type, _device_id), do: state

  defp local_hangup(state, type, device_id) do
    event = {:hangup, state.call_id, type, device_id}
    {packet, control_tx} = Control.send_event(state.control_tx, event)
    state = send_rtp(%{state | control_tx: control_tx}, packet)
    Process.send_after(self(), :linger_done, state.timers.hangup_linger_ms)
    %{state | closing: true}
  end

  defp send_report(%{tx: nil} = state), do: state

  defp send_report(state) do
    sender =
      if state.sent_since_report do
        %{
          ntp_ms: System.system_time(:millisecond),
          rtp_timestamp: state.audio_ts,
          packets: state.sent_packets,
          octets: state.sent_octets
        }
      end

    stats = if state.recv_stats.base_seq, do: state.recv_stats

    {report, stats} =
      Rtcp.report(CallMedia.audio_ssrc(state.role), sender, stats, now_ms())

    state = %{state | sent_since_report: false, recv_stats: stats || state.recv_stats}

    case Srtp.protect_rtcp(state.tx, report) do
      {:ok, protected, tx} -> ice_send(%{state | tx: tx}, protected)
      {:error, _reason} -> state
    end
  end

  # Protects and sends one RTP packet. Before the remote parameters are known
  # there are no keys and nothing is sent.
  defp send_rtp(%{tx: nil} = state, _packet), do: state

  defp send_rtp(state, packet) do
    case Srtp.protect(state.tx, packet) do
      {:ok, protected, tx} -> ice_send(%{state | tx: tx}, protected)
      {:error, _reason} -> state
    end
  end

  defp ice_send(%{ice_state: ice_state} = state, packet)
       when ice_state in [:connected, :completed] do
    ExICE.ICEAgent.send_data(state.ice, packet)
    state
  end

  defp ice_send(state, _packet), do: state

  # -- Helpers -----------------------------------------------------------------

  defp notify(%{owner: owner}, event) when is_pid(owner),
    do: send(owner, {:signal_call_media, self(), event})

  defp notify(_state, _event), do: :ok

  defp count(state, key), do: %{state | counters: Map.update!(state.counters, key, &(&1 + 1))}

  defp schedule(message, ms), do: Process.send_after(self(), message, ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
