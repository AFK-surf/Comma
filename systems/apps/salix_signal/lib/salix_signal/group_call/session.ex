defmodule SalixSignal.GroupCall.Session do
  @moduledoc """
  One joined Signal group call (CRS-14), audio only.

  The process owns the ICE agent toward the calling server (SFU), the
  AEAD_AES_128_GCM SRTP contexts of both directions, this device's frame
  encryption state and media send key, the keys received from the other
  devices, one jitter buffer and Opus decoder per speaker, and the mixer
  that turns all speakers into the one stream a `SalixVoice.CallActor`
  hears. It runs on the node that holds that voice call (PLAN "Design
  rules": call media is node-local).

  ## Joining (CRS-14 section 12)

  At start the session requests a membership token, joins with a fresh
  X25519 key and ICE credentials, derives the SRTP keys, runs ICE as the
  controlling agent toward the SFU's UDP addresses, peeks, announces the
  era to the group, and distributes its media send key. It then sends a
  heartbeat every second and a video request for no video, re-peeks on
  device-joined-or-left notifications, and rotates or advances its key
  (section 9.3). Received reliable SFU messages are acknowledged at once.

  ## Options

    * `group_id`: the 32-byte Groups v2 group identifier
    * `aci`: this account's ACI string
    * `token`: `fun() -> {:ok, token} | {:error, reason}`, the membership
      token (`SalixSignal.GroupCall.Sfu.fetch_token/2`); called at join and
      every 24 hours
    * `members`: `fun() -> {:ok, [%{aci: String.t(), member_id: binary()}]}`,
      the group's full members with their 65-byte UID ciphertexts (group
      state); called at join and when a device or key of an unknown member
      appears (section 9.4)
    * `send`: `fun(acis, call_message, %{urgent: boolean}) -> :ok | {:error,
      reason}` sends one encoded call message to all devices of each account
      (section 9.2). It must send the own account a separate 1:1 message. It
      runs in a separate process and counts as failed after
      `send_deadline_ms`.
    * `announce`: `fun(era_id) -> :ok | {:error, reason}` sends the
      group-call-update data message (section 3) to the group, urgent
    * `owner` (optional): a pid that receives `{:signal_group_call, pid,
      event}`: `{:joined, %{era_id, demux_id}}`, `{:devices, [demux_id]}`,
      `{:ice, state}`, `{:left, reason}` and `{:call_ended, reason}`; the
      session leaves when the owner exits
    * `sfu_url` (default production), `http` (options for
      `SalixSignal.GroupCall.Sfu`), `ice_opts`, `keypair` and timer
      overrides

  ## Voice call

  After `attach_call/2` the session is the carrier socket of a voice call
  (see `SalixVoice`): the mixed speakers go to the call as
  `{:voice_carrier, :audio, pcm16_24k}`, and the call's agent audio is sent
  as one 60 ms Opus frame every 60 ms, frame-encrypted, with the audio-level
  header extension. At most `max_held_ms` of agent audio waits here.

  ## Leaving (section 10.3)

  `leave/1`, the end of the voice call, an ICE failure, removal by the SFU
  or the owner's exit: a leaving message through the SFU, a leaving message
  over signaling to every account in the call, the device-to-SFU leave
  twice, and the group-call-update message. The process then stops.
  """

  use GenServer, restart: :temporary

  require Logger

  alias SalixSignal.CallMedia.{JitterBuffer, Opus}
  alias SalixSignal.GroupCall.{Mixer, Sfu}
  alias SalixSignalProto.CallMedia.{Rtcp, Rtp, Srtp}
  alias SalixSignalProto.Crypto.X25519
  alias SalixSignalProto.GroupCall
  alias SalixSignalProto.GroupCall.{Messages, Reliable}
  alias SalixSignalProto.GroupCall.Frame.{Receiver, Sender}
  alias SalixSignalProto.GroupCall.Sfu, as: Body

  @registry SalixSignal.GroupCall.Registry
  @tasks SalixSignal.GroupCall.TaskSupervisor

  @defaults %{
    heartbeat_ms: GroupCall.heartbeat_interval_ms(),
    rotation_delay_ms: GroupCall.rotation_delay_ms(),
    token_refresh_ms: GroupCall.token_refresh_ms(),
    playout_tick_ms: 20,
    rtcp_interval_ms: 5_000,
    jitter_delay_ms: 60,
    max_held_ms: 120_000,
    max_conceal_ms: 120,
    linger_ms: 200,
    send_deadline_ms: 15_000,
    repeek_retry_ms: 2_000
  }

  # Keys for devices that are not in the call yet (section 9.4), bounded.
  @max_held_keys 32
  # ICE agents started until their credentials use only letters and digits,
  # as deployed clients' do (section 5.4). Comma decision D1 in CRS-14: this
  # stays until a live join shows that the SFU accepts other characters.
  @max_ice_attempts 32

  # -- API ---------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc "Makes this session the carrier socket of the voice call `call_id`."
  def attach_call(pid, call_id), do: GenServer.call(pid, {:attach_call, call_id}, 10_000)

  @doc """
  Hands over a device-to-device message received over signaling from
  `sender_aci` (the decoded `{:device, map}` of
  `SalixSignalProto.GroupCall.Messages.decode_opaque/1`).
  """
  def receive_signal(pid, sender_aci, device),
    do: GenServer.cast(pid, {:signal, sender_aci, device})

  @doc "Leaves the call (section 10.3) and stops."
  def leave(pid), do: GenServer.cast(pid, {:leave, :local})

  @doc "Queues agent audio (PCM16 mono 24 kHz) for sending."
  def send_audio(pid, pcm), do: send(pid, {:voice_call, :audio, pcm})

  @doc "The joined call: `%{era_id, demux_id, devices, ice_state, key}` and counters."
  def info(pid), do: GenServer.call(pid, :info)

  # -- Init --------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    required = [:group_id, :aci, :token, :members, :send, :announce]

    case Enum.reject(required, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "missing options: #{inspect(missing)}"
    end

    <<_::binary-32>> = opts.group_id
    Process.flag(:trap_exit, true)

    case Registry.register(@registry, {opts.aci, opts.group_id}, nil) do
      {:ok, _} -> {:ok, new_state(opts), {:continue, :join}}
      {:error, {:already_registered, _pid}} -> {:stop, {:shutdown, :already_in_call}}
    end
  end

  defp new_state(opts) do
    {public, private} = opts[:keypair] || X25519.keypair()
    {:ok, encoder} = Opus.encoder()
    owner = opts[:owner]

    %{
      config: opts,
      timers: Map.merge(@defaults, Map.take(opts, Map.keys(@defaults))),
      group_id: opts.group_id,
      aci: opts.aci,
      owner: owner,
      owner_ref: if(is_pid(owner), do: Process.monitor(owner)),
      public: public,
      private: private,
      token: nil,
      own_demux: nil,
      era_id: nil,
      ice: nil,
      ice_state: :new,
      tx: nil,
      rx: nil,
      sender: Sender.new(),
      pending_key: nil,
      rotate_again: false,
      receivers: %{},
      held_keys: [],
      devices: %{},
      members: %{},
      reliable: Reliable.new(),
      sfu_counter: 1,
      data_counter: 1,
      peek_task: nil,
      repeek: false,
      peeked: false,
      encoder: encoder,
      streams: %{},
      mixer: Mixer.new(rate: Opus.rate(), tick_ms: Map.get(opts, :playout_tick_ms, 20)),
      audio_seq: :rand.uniform(0x7FFF),
      audio_ts: :rand.uniform(0x7FFFFFFF),
      talking: false,
      sent_packets: 0,
      sent_octets: 0,
      sent_since_report: false,
      held: <<>>,
      held_consumed: 0,
      marks: [],
      next_send_ms: nil,
      call: nil,
      call_ref: nil,
      leaving: false,
      counters: %{audio_in: 0, audio_out: 0, undecryptable: 0, auth_failed: 0, heartbeats: 0}
    }
  end

  @impl GenServer
  def handle_continue(:join, state) do
    config = state.config

    with {:ok, ice, ufrag, pwd} <- start_ice(config),
         state = %{state | ice: ice},
         {:ok, token} <- config.token.(),
         {:ok, join} <-
           Sfu.join(
             sfu_url(state),
             token,
             %{ice_ufrag: ufrag, ice_pwd: pwd, public_key: state.public},
             http: config[:http] || []
           ),
         :active <- join.status,
         {:ok, keys} <- GroupCall.srtp_keys(state.private, join.public_key) do
      :ok = ExICE.ICEAgent.set_remote_credentials(ice, join.ice_ufrag, join.ice_pwd)

      for "candidate:" <> candidate <- Body.udp_candidates(join),
          do: ExICE.ICEAgent.add_remote_candidate(ice, candidate)

      :ok = ExICE.ICEAgent.gather_candidates(ice)

      state = %{
        state
        | token: token,
          private: nil,
          own_demux: join.demux_id,
          era_id: join.era_id,
          tx: Srtp.new(keys.send.key, keys.send.salt),
          rx: Srtp.new(keys.receive.key, keys.receive.salt)
      }

      notify(state, {:joined, %{era_id: join.era_id, demux_id: join.demux_id}})
      announce(state)

      for {message, ms} <- [
            heartbeat: state.timers.heartbeat_ms,
            playout: state.timers.playout_tick_ms,
            rtcp: state.timers.rtcp_interval_ms,
            refresh_token: state.timers.token_refresh_ms
          ],
          do: schedule(message, ms)

      {:noreply, state |> refresh_members() |> start_peek()}
    else
      status when status in [:pending, :blocked] -> fail(state, {:not_admitted, status})
      {:error, reason} -> fail(state, reason)
      other -> fail(state, {:unexpected, other})
    end
  end

  defp fail(state, reason) do
    notify(state, {:left, {:join_failed, reason}})
    {:stop, {:shutdown, {:join_failed, reason}}, state}
  end

  defp sfu_url(state), do: state.config[:sfu_url] || GroupCall.sfu_url(:production)

  defp start_ice(config, attempt \\ 1)

  defp start_ice(_config, attempt) when attempt > @max_ice_attempts,
    do: {:error, :ice_credentials}

  defp start_ice(config, attempt) do
    opts =
      [
        role: :controlling,
        on_new_candidate: self(),
        on_connection_state_change: self(),
        on_gathering_state_change: self(),
        on_data: self()
      ] ++ (config[:ice_opts] || [])

    {:ok, ice} = ExICE.ICEAgent.start_link(opts)
    {:ok, ufrag, pwd} = ExICE.ICEAgent.get_local_credentials(ice)

    if alphanumeric?(ufrag) and alphanumeric?(pwd) do
      {:ok, ice, ufrag, pwd}
    else
      ExICE.ICEAgent.stop(ice)
      start_ice(config, attempt + 1)
    end
  end

  defp alphanumeric?(string), do: String.match?(string, ~r/\A[A-Za-z0-9]+\z/)

  # -- Calls and casts ---------------------------------------------------------

  @impl GenServer
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

  def handle_call(:info, _from, state) do
    info =
      Map.merge(state.counters, %{
        era_id: state.era_id,
        demux_id: state.own_demux,
        devices: Map.keys(state.devices),
        ice_state: state.ice_state,
        key: Sender.key(state.sender),
        pending_key: state.pending_key
      })

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:signal, sender_aci, device}, state),
    do: {:noreply, receive_signal_message(state, sender_aci, device)}

  def handle_cast({:leave, reason}, state), do: {:noreply, local_leave(state, reason)}

  # -- ICE ---------------------------------------------------------------------

  @impl GenServer
  def handle_info({:ex_ice, ice, {:data, packet}}, %{ice: ice} = state),
    do: {:noreply, receive_packet(state, packet)}

  def handle_info({:ex_ice, ice, {:connection_state_change, ice_state}}, %{ice: ice} = state) do
    notify(state, {:ice, ice_state})
    state = %{state | ice_state: ice_state}

    case ice_state do
      :connected ->
        state = state |> send_video_request() |> send_heartbeat()
        {:noreply, start_sending(state)}

      :failed ->
        {:noreply, local_leave(state, :ice_failed)}

      :closed ->
        {:stop, {:shutdown, :ice_closed}, state}

      _ ->
        {:noreply, state}
    end
  end

  # Client candidates are not sent to the SFU (section 6.1).
  def handle_info({:ex_ice, _ice, _event}, state), do: {:noreply, state}

  # -- Timers ------------------------------------------------------------------

  def handle_info(:heartbeat, state) do
    schedule(:heartbeat, state.timers.heartbeat_ms)
    {:noreply, send_heartbeat(state)}
  end

  def handle_info(:playout, state) do
    schedule(:playout, state.timers.playout_tick_ms)
    {:noreply, playout(state)}
  end

  def handle_info(:rtcp, state) do
    schedule(:rtcp, state.timers.rtcp_interval_ms)
    {:noreply, send_report(state)}
  end

  def handle_info(:send_tick, state), do: {:noreply, send_tick(state)}

  def handle_info(:switch_key, state), do: {:noreply, switch_key(state)}

  def handle_info(:repeek, state), do: {:noreply, start_peek(state)}

  def handle_info(:refresh_token, state) do
    schedule(:refresh_token, state.timers.token_refresh_ms)
    token_fun = state.config.token
    Task.Supervisor.async_nolink(@tasks, fn -> {:token, token_fun.()} end)
    {:noreply, state}
  end

  def handle_info(:stop, state), do: {:stop, :normal, state}

  # -- Task results ------------------------------------------------------------

  def handle_info({ref, {:peek, result}}, %{peek_task: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | peek_task: nil}

    state =
      case result do
        {:ok, peek} ->
          apply_peek(state, peek)

        {:error, reason} ->
          Logger.debug("signal group call peek failed: #{inspect(reason)}")
          schedule(:repeek, state.timers.repeek_retry_ms)
          state
      end

    if state.repeek, do: {:noreply, start_peek(%{state | repeek: false})}, else: {:noreply, state}
  end

  def handle_info({ref, {:token, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, token} -> {:noreply, %{state | token: token}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{peek_task: ref} = state) do
    schedule(:repeek, state.timers.repeek_retry_ms)
    {:noreply, %{state | peek_task: nil}}
  end

  # -- Voice call (carrier socket) ---------------------------------------------

  def handle_info({:voice_call, :audio, pcm}, state) when is_binary(pcm),
    do: {:noreply, hold_audio(state, pcm)}

  def handle_info({:voice_call, :clear}, state) do
    state = %{state | held_consumed: state.held_consumed + byte_size(state.held), held: <<>>}
    {:noreply, flush_marks(state)}
  end

  def handle_info({:voice_call, :mark, name}, state) do
    position = state.held_consumed + byte_size(state.held)
    {:noreply, flush_marks(%{state | marks: state.marks ++ [{position, name}]})}
  end

  def handle_info({:voice_call, :end, reason}, state) do
    if state.call_ref, do: Process.demonitor(state.call_ref, [:flush])
    notify(state, {:call_ended, reason})
    {:noreply, local_leave(%{state | call: nil, call_ref: nil}, :call_ended)}
  end

  def handle_info({:voice_call, _kind, _a, _b, _c}, state), do: {:noreply, state}
  def handle_info({:voice_call, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{call_ref: ref} = state) do
    notify(state, {:call_ended, reason})
    {:noreply, local_leave(%{state | call: nil, call_ref: nil}, :call_ended)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:noreply, local_leave(%{state | owner: nil}, :owner_down)}

  def handle_info({:EXIT, ice, reason}, %{ice: ice} = state) when ice != nil,
    do: {:stop, {:shutdown, {:ice_exit, reason}}, %{state | ice: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
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

  # -- Membership and peeks (sections 5.3, 9.3, 9.4) ---------------------------

  defp refresh_members(state) do
    case state.config.members.() do
      {:ok, members} ->
        map =
          for %{aci: aci, member_id: member_id} <- members,
              into: %{},
              do: {GroupCall.opaque_user_id(member_id), aci}

        %{state | members: map}

      _ ->
        state
    end
  end

  defp start_peek(%{token: nil} = state), do: state
  defp start_peek(%{peek_task: ref} = state) when ref != nil, do: %{state | repeek: true}
  defp start_peek(%{leaving: true} = state), do: state

  defp start_peek(state) do
    {url, token, http} = {sfu_url(state), state.token, state.config[:http] || []}

    task =
      Task.Supervisor.async_nolink(@tasks, fn -> {:peek, Sfu.peek(url, token, http: http)} end)

    %{state | peek_task: task.ref}
  end

  defp apply_peek(%{leaving: true} = state, _peek), do: state

  defp apply_peek(state, peek) do
    devices =
      for %{demux_id: demux, opaque_user_id: user} <- peek.devices,
          demux != state.own_demux,
          into: %{},
          do: {demux, user}

    state =
      if Enum.any?(devices, fn {_demux, user} -> not Map.has_key?(state.members, user) end),
        do: refresh_members(state),
        else: state

    previous = state.devices
    added = Map.drop(devices, Map.keys(previous))
    removed = Map.drop(previous, Map.keys(devices))
    left_accounts = MapSet.difference(accounts(state, previous), accounts(state, devices))

    state =
      Enum.reduce(Map.keys(removed), %{state | devices: devices}, fn demux, state ->
        %{
          state
          | receivers: Map.delete(state.receivers, demux),
            streams: Map.delete(state.streams, demux),
            mixer: Mixer.drop(state.mixer, demux)
        }
      end)

    state =
      state
      |> devices_appeared(added)
      |> accounts_left(left_accounts)
      |> release_held_keys()

    first_peek? = not state.peeked
    state = %{state | peeked: true}

    if added != %{} or removed != %{}, do: notify(state, {:devices, Map.keys(devices)})

    if first_peek? or added != %{} or removed != %{},
      do: send_video_request(state),
      else: state
  end

  defp accounts(state, devices) do
    for {_demux, user} <- devices,
        aci = state.members[user],
        aci != nil,
        into: MapSet.new(),
        do: aci
  end

  defp owner_aci(state, demux) do
    case state.devices do
      %{^demux => user} -> {:known, state.members[user]}
      _ -> :unknown
    end
  end

  # Section 9.3: advance the send key one step and send it to every account
  # with an added device, with the pending rotated key if there is one.
  defp devices_appeared(state, added) when added == %{}, do: state

  defp devices_appeared(state, added) do
    sender = Sender.advance(state.sender)
    state = %{state | sender: sender}
    recipients = state |> accounts(added) |> MapSet.to_list()
    state = send_key(state, recipients, Sender.key(sender))

    case state.pending_key do
      nil -> state
      pending -> send_key(state, recipients, {0, pending})
    end
  end

  # Section 9.3: an account left. A new random key goes to every account
  # still in the call; this device switches to it after the rotation delay.
  defp accounts_left(state, left) do
    cond do
      MapSet.size(left) == 0 -> state
      state.pending_key != nil -> %{state | rotate_again: true}
      true -> rotate(state)
    end
  end

  defp rotate(state) do
    secret = :crypto.strong_rand_bytes(32)
    recipients = state |> accounts(state.devices) |> MapSet.to_list()
    schedule(:switch_key, state.timers.rotation_delay_ms)
    send_key(%{state | pending_key: secret}, recipients, {0, secret})
  end

  defp switch_key(%{pending_key: nil} = state), do: state

  defp switch_key(state) do
    state = %{
      state
      | sender: Sender.use_key(state.sender, 0, state.pending_key),
        pending_key: nil
    }

    if state.rotate_again, do: rotate(%{state | rotate_again: false}), else: state
  end

  defp send_key(state, [], _key), do: state

  defp send_key(state, recipients, {counter, secret}) do
    message = Messages.media_key(state.group_id, counter, secret, state.own_demux)
    dispatch(state, recipients, message, false)
  end

  # -- Keys and notices over signaling (sections 9.4, 10.3) -------------------

  defp receive_signal_message(%{group_id: own} = state, _sender_aci, %{group_id: gid})
       when gid != own,
       do: state

  defp receive_signal_message(state, sender_aci, %{media_key: %{} = key} = device) do
    state = receive_key(state, sender_aci, key)
    if device.leaving, do: start_peek(state), else: state
  end

  defp receive_signal_message(state, _sender_aci, %{leaving: demux}) when is_integer(demux),
    do: start_peek(state)

  defp receive_signal_message(state, _sender_aci, _device), do: state

  defp receive_key(state, sender_aci, %{demux_id: demux} = key) do
    case owner_aci(state, demux) do
      {:known, ^sender_aci} ->
        add_key(state, demux, key)

      {:known, nil} ->
        # The device is in the call but its member is not known yet.
        state |> hold_key(sender_aci, key) |> refresh_members() |> release_held_keys()

      {:known, _other} ->
        state

      :unknown ->
        state |> hold_key(sender_aci, key) |> refresh_members() |> start_peek()
    end
  end

  defp add_key(state, demux, %{counter: counter, secret: secret}) do
    receiver = Map.get(state.receivers, demux, Receiver.new())

    %{
      state
      | receivers: Map.put(state.receivers, demux, Receiver.add_key(receiver, {counter, secret}))
    }
  end

  defp hold_key(state, sender_aci, key),
    do: %{state | held_keys: Enum.take([{sender_aci, key} | state.held_keys], @max_held_keys)}

  defp release_held_keys(%{held_keys: []} = state), do: state

  defp release_held_keys(state) do
    {ready, waiting} =
      Enum.split_with(state.held_keys, fn {_aci, key} ->
        match?({:known, aci} when aci != nil, owner_aci(state, key.demux_id))
      end)

    state = %{state | held_keys: waiting}

    ready
    |> Enum.reverse()
    |> Enum.reduce(state, fn {aci, key}, state ->
      if owner_aci(state, key.demux_id) == {:known, aci},
        do: add_key(state, key.demux_id, key),
        else: state
    end)
  end

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
    case Srtp.unprotect_rtcp(state.rx, packet) do
      {:ok, _plain, rx} -> %{state | rx: rx}
      {:error, _} -> count(state, :auth_failed)
    end
  end

  defp receive_rtp(state, packet) do
    with {:ok, plain, rx} <- Srtp.unprotect(state.rx, packet),
         {:ok, rtp} <- Rtp.decode(plain) do
      state = %{state | rx: rx}

      case GroupCall.classify(rtp.ssrc, rtp.payload_type) do
        :sfu -> receive_sfu(state, rtp.payload)
        {:audio, demux} when demux != state.own_demux -> receive_audio(state, demux, rtp)
        {:data, demux} when demux != state.own_demux -> receive_data(state, demux, rtp.payload)
        _ -> state
      end
    else
      _ -> count(state, :auth_failed)
    end
  end

  defp receive_sfu(state, payload) do
    case Messages.decode_sfu(payload) do
      {:ok, message} ->
        {messages, ack, reliable} = Reliable.receive(state.reliable, message)
        state = %{state | reliable: reliable}
        state = if ack, do: send_sfu(state, Messages.ack(ack)), else: state
        Enum.reduce(messages, state, &sfu_message(&2, &1))

      {:error, _} ->
        state
    end
  end

  defp sfu_message(state, %{removed: %{}}), do: local_leave(state, :removed)

  defp sfu_message(state, %{device_joined_or_left: %{}} = message) do
    case Messages.peek_info(message) do
      {:ok, peek} -> apply_peek(state, peek)
      :repeek -> start_peek(state)
    end
  end

  defp sfu_message(state, _message), do: state

  defp receive_audio(state, demux, rtp) do
    with %Receiver{} = receiver <- state.receivers[demux],
         {:ok, opus, receiver} <- Receiver.decrypt(receiver, rtp.payload) do
      stream = Map.get_lazy(state.streams, demux, fn -> new_stream(state) end)
      now = now_ms()

      stream = %{
        stream
        | jitter: JitterBuffer.push(stream.jitter, rtp.sequence_number, rtp.timestamp, opus, now)
      }

      state = %{state | receivers: Map.put(state.receivers, demux, receiver)}
      count(%{state | streams: Map.put(state.streams, demux, stream)}, :audio_in)
    else
      _ -> count(state, :undecryptable)
    end
  end

  defp receive_data(state, demux, payload) do
    with %Receiver{} = receiver <- state.receivers[demux],
         {:ok, plaintext, receiver} <- Receiver.decrypt(receiver, payload) do
      state = %{state | receivers: Map.put(state.receivers, demux, receiver)}

      case Messages.decode_device_data(plaintext) do
        {:ok, {:heartbeat, _}} -> count(state, :heartbeats)
        {:ok, :leaving} -> start_peek(state)
        _ -> state
      end
    else
      _ -> count(state, :undecryptable)
    end
  end

  defp new_stream(state) do
    {:ok, decoder} = Opus.decoder()

    %{
      jitter: JitterBuffer.new(delay_ms: state.timers.jitter_delay_ms),
      decoder: decoder,
      last_samples: nil
    }
  end

  # -- Playout and mixing ------------------------------------------------------

  defp playout(state) do
    now = now_ms()

    {streams, mixer} =
      Enum.reduce(state.streams, {%{}, state.mixer}, fn {demux, stream}, {streams, mixer} ->
        {items, jitter} = JitterBuffer.pop(stream.jitter, now)

        {stream, mixer} =
          Enum.reduce(items, {%{stream | jitter: jitter}, mixer}, &play(&1, &2, demux, state))

        {Map.put(streams, demux, stream), mixer}
      end)

    {mixed, mixer} = Mixer.pop(mixer)
    if mixed != nil and is_pid(state.call), do: send(state.call, {:voice_carrier, :audio, mixed})
    %{state | streams: streams, mixer: mixer}
  end

  defp play({:packet, payload, _ts}, {stream, mixer}, demux, _state) do
    case Opus.decode(stream.decoder, payload) do
      {:ok, pcm} ->
        {%{stream | last_samples: div(byte_size(pcm), 2)}, Mixer.push(mixer, demux, pcm)}

      {:error, _} ->
        {stream, mixer}
    end
  end

  defp play({:lost, missing, next, gap_ticks}, {stream, mixer}, demux, state) do
    case conceal_samples(stream, gap_ticks, state.timers.max_conceal_ms) do
      0 ->
        {stream, mixer}

      samples ->
        source = if missing == 1, do: next, else: nil

        case Opus.conceal(stream.decoder, source, samples) do
          {:ok, pcm} -> {stream, Mixer.push(mixer, demux, pcm)}
          {:error, _} -> {stream, mixer}
        end
    end
  end

  # Lost audio between the last played packet and the next one, at the codec
  # rate, rounded down to 2.5 ms and capped.
  defp conceal_samples(%{last_samples: nil}, _gap, _cap_ms), do: 0
  defp conceal_samples(_stream, nil, _cap_ms), do: 0

  defp conceal_samples(stream, gap_ticks, cap_ms) do
    samples = div(gap_ticks * Opus.rate(), 48_000) - stream.last_samples
    step = div(Opus.rate(), 400)
    cap = div(Opus.rate() * cap_ms, 1000)
    samples |> min(cap) |> max(0) |> div(step) |> Kernel.*(step)
  end

  # -- Send --------------------------------------------------------------------

  defp start_sending(%{next_send_ms: nil} = state) do
    send(self(), :send_tick)
    %{state | next_send_ms: now_ms()}
  end

  defp start_sending(state), do: state

  defp send_tick(%{leaving: true} = state), do: state

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
    with {:ok, packet} when byte_size(packet) > 2 <- Opus.encode(state.encoder, pcm),
         {:ok, encrypted, sender} <- Sender.encrypt(state.sender, packet) do
      rtp =
        Rtp.encode(%Rtp{
          marker: not state.talking,
          payload_type: GroupCall.audio_payload_type(),
          sequence_number: state.audio_seq,
          timestamp: state.audio_ts,
          ssrc: GroupCall.audio_ssrc(state.own_demux),
          extension: GroupCall.audio_level_extension(GroupCall.audio_level(pcm)),
          payload: encrypted
        })

      state = send_rtp(%{state | sender: sender}, rtp)

      count(
        %{
          state
          | audio_seq: Bitwise.band(state.audio_seq + 1, 0xFFFF),
            talking: true,
            sent_packets: state.sent_packets + 1,
            sent_octets: state.sent_octets + byte_size(encrypted),
            sent_since_report: true
        },
        :audio_out
      )
    else
      # A DTX frame of 2 bytes or less need not be sent (RFC 6716).
      _ -> %{state | talking: false}
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

  # A device-to-device message through the SFU: frame-encrypted, RTP data
  # on SSRC demux + 13, sequence number and timestamp from its own counter
  # (section 10.4).
  defp send_device_data(state, plaintext) do
    case Sender.encrypt(state.sender, plaintext) do
      {:ok, encrypted, sender} ->
        rtp =
          Rtp.encode(%Rtp{
            payload_type: GroupCall.data_payload_type(),
            sequence_number: Bitwise.band(state.data_counter, 0xFFFF),
            timestamp: Bitwise.band(state.data_counter, 0xFFFFFFFF),
            ssrc: GroupCall.data_ssrc(state.own_demux),
            payload: encrypted
          })

        send_rtp(%{state | sender: sender, data_counter: state.data_counter + 1}, rtp)

      {:error, :exhausted} ->
        state
    end
  end

  # A device-to-SFU message: plain RTP data on SSRC 1 (section 10.4).
  defp send_sfu(state, payload) do
    rtp =
      Rtp.encode(%Rtp{
        payload_type: GroupCall.data_payload_type(),
        sequence_number: Bitwise.band(state.sfu_counter, 0xFFFF),
        timestamp: Bitwise.band(state.sfu_counter, 0xFFFFFFFF),
        ssrc: GroupCall.sfu_ssrc(),
        payload: payload
      })

    send_rtp(%{state | sfu_counter: state.sfu_counter + 1}, rtp)
  end

  defp send_heartbeat(%{own_demux: nil} = state), do: state
  defp send_heartbeat(%{leaving: true} = state), do: state
  defp send_heartbeat(state), do: send_device_data(state, Messages.heartbeat())

  # The video request names every remote demux ID (section 10.5), so it
  # waits for the first peek; it also needs a connected transport. ICE and
  # the first peek complete in either order.
  defp send_video_request(%{own_demux: nil} = state), do: state
  defp send_video_request(%{peeked: false} = state), do: state

  defp send_video_request(%{ice_state: ice_state} = state)
       when ice_state not in [:connected, :completed],
       do: state

  defp send_video_request(state),
    do: send_sfu(state, Messages.video_request(Map.keys(state.devices)))

  defp send_report(%{tx: nil} = state), do: state
  defp send_report(%{sent_since_report: false} = state), do: state

  defp send_report(state) do
    sender = %{
      ntp_ms: System.system_time(:millisecond),
      rtp_timestamp: state.audio_ts,
      packets: state.sent_packets,
      octets: state.sent_octets
    }

    # RTCP CNAME: the decimal demux ID (section 7.1).
    {report, _} =
      Rtcp.report(state.own_demux, sender, nil, now_ms(), Integer.to_string(state.own_demux))

    state = %{state | sent_since_report: false}

    case Srtp.protect_rtcp(state.tx, report) do
      {:ok, protected, tx} -> ice_send(%{state | tx: tx}, protected)
      {:error, _} -> state
    end
  end

  defp send_rtp(%{tx: nil} = state, _packet), do: state

  defp send_rtp(state, packet) do
    case Srtp.protect(state.tx, packet) do
      {:ok, protected, tx} -> ice_send(%{state | tx: tx}, protected)
      {:error, _} -> state
    end
  end

  defp ice_send(%{ice_state: ice_state} = state, packet)
       when ice_state in [:connected, :completed] do
    ExICE.ICEAgent.send_data(state.ice, packet)
    state
  end

  defp ice_send(state, _packet), do: state

  # -- Leave (section 10.3) ----------------------------------------------------

  defp local_leave(%{leaving: true} = state, _reason), do: state

  defp local_leave(state, reason) do
    state =
      if state.own_demux do
        recipients = state |> accounts(state.devices) |> MapSet.to_list()

        state
        |> send_device_data(Messages.leaving_via_sfu())
        |> dispatch(recipients, Messages.leaving(state.group_id, state.own_demux), false)
        |> send_sfu(Messages.leave_sfu())
        |> send_sfu(Messages.leave_sfu())
        |> tap(&announce/1)
      else
        state
      end

    notify(state, {:left, reason})
    Process.send_after(self(), :stop, state.timers.linger_ms)
    %{state | leaving: true}
  end

  # -- Helpers -----------------------------------------------------------------

  defp dispatch(state, [], _message, _urgent), do: state

  defp dispatch(state, recipients, message, urgent) do
    send_fun = state.config.send
    deadline = state.timers.send_deadline_ms

    Task.Supervisor.start_child(@tasks, fn ->
      task = Task.async(fn -> send_fun.(recipients, message, %{urgent: urgent}) end)
      Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill)
    end)

    state
  end

  defp announce(%{era_id: nil}), do: :ok

  defp announce(state) do
    announce_fun = state.config.announce
    era_id = state.era_id
    Task.Supervisor.start_child(@tasks, fn -> announce_fun.(era_id) end)
    :ok
  end

  defp notify(%{owner: owner}, event) when is_pid(owner),
    do: send(owner, {:signal_group_call, self(), event})

  defp notify(_state, _event), do: :ok

  defp count(state, key), do: %{state | counters: Map.update!(state.counters, key, &(&1 + 1))}

  defp schedule(message, ms), do: Process.send_after(self(), message, ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
