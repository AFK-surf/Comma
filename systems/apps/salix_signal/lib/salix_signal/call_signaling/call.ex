defmodule SalixSignal.CallSignaling.Call do
  @moduledoc """
  One 1:1 call attempt (CRS-12 section 7), started by
  `SalixSignal.CallSignaling`.

  The process owns the call's `SalixSignal.CallMedia.Connection`, sends the
  call's signaling messages one at a time (the next only after the previous
  one completed or failed, CRS-12 section 7.1), batches its local ICE
  candidates into ICE updates while a send is in flight, and ends the call
  on a hangup, a busy, a media failure or the setup timeout (CRS-12
  section 10).

  ## Callee

  The process asks the `incoming_call` policy. On `:ring` it starts the
  media connection with the offer's parameters, sends one answer and its ICE
  updates targeted to the offering device, and applies the offering
  device's ICE updates, including those that arrived before the offer. When
  ICE connects it calls `admit`; on success it accepts in-band (CRS-13
  section 9), on failure it declines with hangup type 0. On `:busy` or
  `:needs_permission` it sends busy or hangup type 4 and ends.

  ## Caller

  The process sends one broadcast offer and broadcast ICE updates. The first
  answering device binds the media connection; its ICE updates are applied
  and those of other devices are dropped. The media connection's ICE
  credentials come from its own ICE agent, so this side cannot fork one
  offer to several answering devices (CRS-12 section 7.1 step 4): an answer
  from a second device is ignored, and that device stops ringing at the
  broadcast hangup type 1 that follows acceptance, or at the end of the call.
  When the bound device accepts in-band, the process calls `admit` and
  broadcasts hangup type 1 naming the accepting device.
  """

  use GenServer, restart: :temporary

  alias SalixSignal.CallMedia
  alias SalixSignal.CallMedia.Connection
  alias SalixSignalProto.CallSignaling, as: Proto

  # Bounds on ICE state held for devices that did not bind the call, and on
  # the candidates of one ICE update.
  @max_held_candidates 64
  @max_candidates_per_update 32

  # -- API ---------------------------------------------------------------------

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Ends the call locally: in-band and broadcast hangup type 0 (CRS-12 section 7.3)."
  def hangup(pid) do
    send(pid, :local_hangup)
    :ok
  end

  @doc """
  Ends the call. `:silent` sends nothing (a re-call, CRS-12 section 8);
  `:hangup` is `hangup/1`.
  """
  def finish(pid, :silent) do
    send(pid, :finish_silent)
    :ok
  end

  def finish(pid, :hangup), do: hangup(pid)

  # -- Init --------------------------------------------------------------------

  @impl GenServer
  def init(args) do
    config = args.config

    state = %{
      signaling: args.signaling,
      config: config,
      role: args.role,
      call_id: args.call_id,
      peer_aci: args.peer_aci,
      # Callee: the offering device. Caller: the answering device that bound
      # the media connection.
      peer_device_id: args.peer_device_id,
      media_type: args.media_type,
      caller_identity_key: args.caller_identity_key,
      callee_identity_key: args.callee_identity_key,
      remote: args[:remote],
      early_candidates: args[:early_candidates] || [],
      held_candidates: %{},
      connection: nil,
      connection_ref: nil,
      ice_connected: false,
      accepted: false,
      queue: :queue.new(),
      local_candidates: [],
      in_flight: nil,
      ending: false,
      setup_timer: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %{role: :callee} = state) do
    case state.config.incoming_call.(info(state)) do
      :ring -> {:noreply, start_callee(state)}
      :busy -> {:noreply, state |> enqueue({:busy, state.call_id}) |> finish()}
      :needs_permission -> {:noreply, state |> enqueue_hangup(:needs_permission, nil) |> finish()}
      _ignore -> {:stop, :normal, state}
    end
  end

  def handle_continue(:start, %{role: :caller} = state) do
    case start_connection(state, nil) do
      {:ok, state} ->
        params = offer_parameters(state)

        offer = %{call_id: state.call_id, media_type: :audio, parameters: params}
        {:noreply, state |> enqueue({:offer, offer}) |> start_setup_timer()}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, state}
    end
  end

  defp start_callee(state) do
    case start_connection(state, state.remote) do
      {:ok, state} ->
        Enum.each(state.early_candidates, &apply_candidate(state, &1))
        params = offer_parameters(state)

        state
        |> Map.merge(%{remote: nil, early_candidates: []})
        |> enqueue({:answer, %{call_id: state.call_id, parameters: params}})
        |> start_setup_timer()

      {:error, _reason} ->
        # An incoming-call failure before the local accept sends nothing
        # (CRS-12 section 7.3).
        finish(state)
    end
  end

  defp start_connection(state, remote) do
    with {:ok, servers} <- ice_servers(state.config.ice_servers) do
      opts =
        state.config.media
        |> Map.new()
        |> Map.merge(%{
          role: state.role,
          call_id: state.call_id,
          owner: self(),
          caller_identity_key: state.caller_identity_key,
          callee_identity_key: state.callee_identity_key,
          local_device_id: state.config.device_id,
          ice_servers: servers
        })

      opts = if remote, do: Map.put(opts, :remote, remote), else: opts

      case CallMedia.start_connection(opts) do
        {:ok, pid} ->
          {:ok, %{state | connection: pid, connection_ref: Process.monitor(pid)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ice_servers(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, servers} when is_list(servers) -> {:ok, servers}
      {:error, _} = error -> error
      servers when is_list(servers) -> {:ok, servers}
    end
  catch
    :exit, _ -> {:error, :call_relays_unavailable}
  end

  defp ice_servers(list) when is_list(list), do: {:ok, list}

  defp offer_parameters(state) do
    state.connection
    |> Connection.local_parameters()
    |> Proto.audio_only_parameters(state.config.max_bitrate_bps)
  end

  defp start_setup_timer(state),
    do: %{
      state
      | setup_timer: Process.send_after(self(), :setup_timeout, state.config.setup_timeout_ms)
    }

  # -- Signaling from the peer -------------------------------------------------

  @impl GenServer
  def handle_info({:signal, _payload, _device}, %{ending: true} = state), do: {:noreply, state}

  def handle_info({:signal, payload, device}, state),
    do: {:noreply, signal(state, payload, device)}

  def handle_info({:invalid_answer, _device}, %{role: :caller, ending: false} = state),
    do: {:noreply, failure(state)}

  def handle_info({:invalid_answer, _device}, state), do: {:noreply, state}

  # -- Media events ------------------------------------------------------------

  def handle_info({:signal_call_media, pid, event}, %{connection: pid} = state),
    do: {:noreply, media(state, event)}

  def handle_info({:signal_call_media, _pid, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connection_ref: ref} = state) do
    state = %{state | connection: nil, connection_ref: nil}
    {:noreply, if(state.ending, do: maybe_stop(state), else: failure(state))}
  end

  # -- Local events ------------------------------------------------------------

  def handle_info(:local_hangup, %{ending: false} = state), do: {:noreply, local_hangup(state)}
  def handle_info(:local_hangup, state), do: {:noreply, state}

  def handle_info(:finish_silent, %{ending: false} = state),
    do: {:noreply, state |> stop_connection() |> finish()}

  def handle_info(:finish_silent, state), do: {:noreply, state}

  def handle_info(:setup_timeout, %{ending: false, accepted: false} = state),
    do: {:noreply, local_hangup(state)}

  def handle_info(:setup_timeout, state), do: {:noreply, state}

  # -- Sends -------------------------------------------------------------------

  def handle_info({:sent, tag, _result}, %{in_flight: {tag, _pid, ref, timer}} = state) do
    Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    {:noreply, send_done(state)}
  end

  def handle_info({:send_deadline, tag}, %{in_flight: {tag, pid, ref, _timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, send_done(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{in_flight: {_tag, _pid2, ref, timer}} = state
      ) do
    Process.cancel_timer(timer)
    {:noreply, send_done(state)}
  end

  def handle_info(:stop, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # -- Signaling ---------------------------------------------------------------

  defp signal(%{role: :callee} = state, {:ice, _id, candidates}, device) do
    if device == state.peer_device_id, do: Enum.each(candidates, &apply_candidate(state, &1))
    state
  end

  defp signal(%{role: :callee} = state, {:hangup, _id, type, about}, _device) do
    case Proto.callee_reaction(type, about, state.config.device_id) do
      :end -> state |> stop_connection() |> finish()
      :ignore -> state
    end
  end

  defp signal(
         %{role: :caller, peer_device_id: nil} = state,
         {:answer, %{parameters: params}},
         device
       ) do
    case Connection.set_remote(state.connection, params) do
      :ok ->
        {held, others} = Map.pop(state.held_candidates, device, [])
        state = %{state | peer_device_id: device, held_candidates: others}
        held |> Enum.reverse() |> Enum.each(&apply_candidate(state, &1))
        %{state | held_candidates: %{}}

      {:error, _reason} ->
        # A low-order key in the answer rejects the call (CRS-13 section 4.2).
        failure(state)
    end
  end

  defp signal(%{role: :caller} = state, {:ice, _id, candidates}, device) do
    cond do
      device == state.peer_device_id ->
        Enum.each(candidates, &apply_candidate(state, &1))
        state

      state.peer_device_id == nil ->
        hold_candidates(state, device, candidates)

      true ->
        state
    end
  end

  defp signal(%{role: :caller} = state, {:hangup, _id, type, about}, device),
    do: caller_reaction(state, {:hangup, type, about}, device)

  defp signal(%{role: :caller} = state, {:busy, _id}, device),
    do: caller_reaction(state, :busy, device)

  defp signal(state, _payload, _device), do: state

  defp caller_reaction(state, event, device) do
    call = %{accepted: state.accepted, connected_device: connected_device(state)}

    case Proto.caller_reaction(call, event, device) do
      :ignore ->
        state

      :end ->
        state |> stop_connection() |> finish()

      {:end, {:hangup, type, about}} ->
        # In-band to the other devices: the media connection is to another
        # device unless the sender is the bound one.
        state =
          if state.connection && state.peer_device_id != device do
            Connection.hangup(state.connection, Proto.hangup_type_number(type), about)
            state
          else
            stop_connection(state)
          end

        state |> enqueue_hangup(type, about) |> finish()
    end
  end

  defp hold_candidates(state, device, candidates) do
    held = Map.get(state.held_candidates, device, [])
    total = state.held_candidates |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    room = max(@max_held_candidates - total, 0)
    held = Enum.reverse(Enum.take(candidates, room)) ++ held
    %{state | held_candidates: Map.put(state.held_candidates, device, held)}
  end

  defp apply_candidate(%{connection: nil}, _candidate), do: :ok

  defp apply_candidate(state, {:added, candidate}),
    do: Connection.add_remote_candidate(state.connection, candidate)

  defp apply_candidate(state, {:removed, address}),
    do: Connection.remove_remote_candidate(state.connection, address)

  # -- Media -------------------------------------------------------------------

  defp media(%{ending: true} = state, _event), do: state

  defp media(state, {:local_candidate, candidate}) do
    %{state | local_candidates: [candidate | state.local_candidates]} |> pump()
  end

  defp media(state, {:ice, ice}) when ice in [:connected, :completed] do
    state = %{state | ice_connected: true}
    report(state)
    if state.role == :callee and not state.accepted, do: callee_accept(state), else: state
  end

  defp media(%{role: :caller} = state, :accepted) do
    state = %{state | accepted: true}
    cancel_setup_timer(state)

    case admit(state) do
      :ok ->
        report(state)
        enqueue_hangup(state, :accepted_elsewhere, state.peer_device_id)

      :error ->
        local_hangup(state)
    end
  end

  defp media(%{role: :caller} = state, {:remote_hangup, type, _about}) do
    # An in-band hangup from the bound device; the connection is stopping.
    number = if is_atom(type), do: Proto.hangup_type_number(type), else: type

    type =
      case number do
        0 -> :normal
        4 -> :needs_permission
        other -> other
      end

    caller_reaction(%{state | connection: nil}, {:hangup, type, nil}, state.peer_device_id)
  end

  defp media(state, {:remote_hangup, _type, _about}),
    do: finish(%{state | connection: nil})

  defp media(state, {:call_ended, _reason}) do
    # The voice call ended; the connection sends the in-band hangup.
    state |> enqueue_hangup(:normal, nil) |> finish()
  end

  defp media(state, _event), do: state

  defp callee_accept(state) do
    with :ok <- admit(state),
         :ok <- accept(state.connection) do
      cancel_setup_timer(state)
      state = %{state | accepted: true}
      report(state)
      state
    else
      _error ->
        # The call cannot start: decline (CRS-12 section 7.3).
        local_hangup(state)
    end
  end

  defp accept(connection) do
    Connection.accept(connection)
  catch
    :exit, _ -> {:error, :connection_down}
  end

  defp admit(state) do
    case state.config.admit.(info(state), state.connection) do
      :ok -> :ok
      {:ok, _} -> :ok
      _error -> :error
    end
  catch
    _kind, _reason -> :error
  end

  # -- Ending ------------------------------------------------------------------

  # A failure of the call itself (CRS-12 section 7.3): the callee sends
  # nothing before it accepted and hangup type 0 after; the caller always
  # sends hangup type 0.
  defp failure(%{role: :callee, accepted: false} = state),
    do: state |> stop_connection() |> finish()

  defp failure(state), do: local_hangup(state)

  defp local_hangup(state) do
    if state.connection, do: Connection.hangup(state.connection, 0, nil)
    state |> enqueue_hangup(:normal, nil) |> finish()
  end

  defp stop_connection(%{connection: nil} = state), do: state

  defp stop_connection(state) do
    Process.demonitor(state.connection_ref, [:flush])

    try do
      GenServer.stop(state.connection, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end

    %{state | connection: nil, connection_ref: nil}
  end

  defp finish(state) do
    cancel_setup_timer(state)
    state = %{state | ending: true, local_candidates: []}
    send(state.signaling, {:call_status, self(), %{ending: true}})
    state |> pump() |> maybe_stop()
  end

  defp maybe_stop(%{ending: true, in_flight: nil, connection: nil} = state) do
    if :queue.is_empty(state.queue), do: send(self(), :stop), else: :ok
    state
  end

  defp maybe_stop(state), do: state

  defp cancel_setup_timer(%{setup_timer: nil}), do: :ok
  defp cancel_setup_timer(%{setup_timer: timer}), do: Process.cancel_timer(timer)

  # -- Send queue --------------------------------------------------------------

  defp enqueue_hangup(state, type, about),
    do: enqueue(state, {:hangup, state.call_id, type, about})

  defp enqueue(state, payload), do: %{state | queue: :queue.in(payload, state.queue)} |> pump()

  defp pump(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, payload}, queue} ->
        start_send(%{state | queue: queue}, payload)

      {:empty, _} when state.local_candidates != [] ->
        {batch, rest} =
          state.local_candidates |> Enum.reverse() |> Enum.split(@max_candidates_per_update)

        payload = {:ice, state.call_id, Enum.map(batch, &{:added, &1})}
        start_send(%{state | local_candidates: Enum.reverse(rest)}, payload)

      {:empty, _} ->
        state
    end
  end

  defp pump(state), do: state

  # Targets (CRS-12 sections 7 and 8): the caller broadcasts everything; the
  # callee targets its answer and ICE updates at the offering device and
  # broadcasts busy and hangups. A send that has not completed after
  # `send_deadline_ms` counts as failed (CRS-12 section 10). A failed send
  # is not repeated: the peer's timers end a call that lost a message.
  defp start_send(state, payload) do
    destination =
      case {state.role, payload} do
        {:callee, {:answer, _}} -> state.peer_device_id
        {:callee, {:ice, _, _}} -> state.peer_device_id
        _ -> nil
      end

    message = Proto.encode(payload, destination_device_id: destination)
    send_fun = state.config.send
    peer = state.peer_aci
    urgent = Proto.urgent?(payload)
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            send_fun.(peer, message, %{urgent: urgent})
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:sent, tag, result})
      end)

    timer = Process.send_after(self(), {:send_deadline, tag}, state.config.send_deadline_ms)
    %{state | in_flight: {tag, pid, ref, timer}}
  end

  defp send_done(state), do: %{state | in_flight: nil} |> pump() |> maybe_stop()

  # -- Reports -----------------------------------------------------------------

  defp connected_device(%{ice_connected: true, peer_device_id: device}), do: device
  defp connected_device(_state), do: nil

  defp report(state) do
    send(state.signaling, {
      :call_status,
      self(),
      %{
        connected_device: connected_device(state),
        connected_and_accepted: state.ice_connected and state.accepted
      }
    })
  end

  defp info(state) do
    %{
      role: state.role,
      peer_aci: state.peer_aci,
      peer_device_id: state.peer_device_id,
      call_id: state.call_id,
      media_type: state.media_type
    }
  end
end
