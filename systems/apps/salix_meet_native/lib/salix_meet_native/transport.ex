defmodule SalixMeetNative.Transport do
  @moduledoc false
  use GenServer

  require Logger

  alias ExICE.ICEAgent
  alias SalixMeetNative.MediaSession
  alias SalixMeetNative.MediaSession.{Answer, Channel}

  @dcep_ppi 50
  @binary_ppi 53
  @empty_binary_ppi 57
  @string_ppi 51
  @empty_string_ppi 56
  @max_buffered_per_stream 256

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))

  @spec local_params(pid()) :: %{fingerprint: String.t(), ufrag: String.t(), pwd: String.t()}
  def local_params(pid), do: SystemsClock.call(pid, :local_params, 5_000)

  # The owner learns about a crashed transport from its `:EXIT` message, which
  # can still be queued behind a timer that calls in here; those calls report
  # the transport as down instead of exiting the owner.
  @spec connect(pid(), %Answer{}) :: :ok | {:error, term()}
  def connect(pid, %Answer{} = answer), do: call(pid, {:connect, answer})

  @spec open_channel(pid(), String.t()) :: :ok | {:error, :transport_down}
  def open_channel(pid, label), do: call(pid, {:open_channel, label})

  @spec send_data(pid(), String.t(), binary()) :: :ok | {:error, term()}
  def send_data(pid, label, data), do: call(pid, {:send, label, data})

  @spec channel_open?(pid(), String.t()) :: boolean()
  def channel_open?(pid, label), do: call(pid, {:channel_open?, label}) == true

  defp call(pid, request) do
    SystemsClock.call(pid, request, 5_000)
  catch
    :exit, _ -> {:error, :transport_down}
  end

  def close(pid), do: SystemsClock.call(pid, :close, 5_000)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    {:ok, ice} =
      ICEAgent.start_link(
        role: :controlling,
        ip_filter: Keyword.get(opts, :ip_filter, fn _ -> true end)
      )

    :ok = ICEAgent.gather_candidates(ice)
    {:ok, ufrag, pwd} = ICEAgent.get_local_credentials(ice)
    {pkey, cert} = ExDTLS.generate_key_cert()

    {:ok,
     %{
       owner: owner,
       rtp_sink: Keyword.get(opts, :rtp_sink),
       ice: ice,
       ice_connected?: false,
       ufrag: ufrag,
       pwd: pwd,
       pkey: pkey,
       cert: cert,
       fingerprint: cert |> ExDTLS.get_cert_fingerprint() |> colon_hex(),
       peer_fingerprint: nil,
       dtls: nil,
       dtls_state: :new,
       dtls_timer: nil,
       pending_local: nil,
       in_srtp: nil,
       sctp: nil,
       sctp_state: :new,
       sctp_timer: nil,
       channels: %{},
       pending_open: [],
       buffered: %{}
     }}
  end

  @impl true
  def handle_call(:local_params, _from, state),
    do: {:reply, %{fingerprint: state.fingerprint, ufrag: state.ufrag, pwd: state.pwd}, state}

  def handle_call({:connect, %Answer{} = answer}, _from, %{dtls: nil} = state) do
    :ok = ICEAgent.set_remote_credentials(state.ice, answer.ice_ufrag, answer.ice_pwd)

    for %{transport: :udp} = c <- answer.candidates do
      "candidate:" <> attr = MediaSession.candidate_line(c)
      ICEAgent.add_remote_candidate(state.ice, attr)
    end

    :ok = ICEAgent.end_of_candidates(state.ice)

    channels =
      Map.new(answer.channels, fn %Channel{} = ch ->
        {ch.id,
         %{
           label: ch.label,
           ordered: ch.ordered,
           max_packet_life_time: ch.max_packet_life_time,
           negotiated?: true,
           open?: false
         }}
      end)

    dtls =
      ExDTLS.init(
        mode: :client,
        dtls_srtp: true,
        pkey: state.pkey,
        cert: state.cert,
        verify_peer: true
      )

    {:reply, :ok,
     %{
       state
       | dtls: dtls,
         peer_fingerprint: normalize_fingerprint(answer.fingerprint),
         channels: channels,
         sctp: ExSCTP.new()
     }}
  end

  def handle_call({:connect, _answer}, _from, state),
    do: {:reply, {:error, :already_connected}, state}

  def handle_call({:open_channel, label}, _from, state) do
    cond do
      Enum.any?(state.channels, fn {_id, ch} -> ch.label == label end) -> {:reply, :ok, state}
      label in state.pending_open -> {:reply, :ok, state}
      state.sctp_state == :connected -> {:reply, :ok, state |> open_local(label) |> drain_sctp()}
      true -> {:reply, :ok, %{state | pending_open: state.pending_open ++ [label]}}
    end
  end

  def handle_call({:send, label, data}, _from, state) do
    case find_open(state, label) do
      {:ok, id} ->
        {ppi, payload} = if data == "", do: {@empty_binary_ppi, <<0>>}, else: {@binary_ppi, data}

        case ExSCTP.send(state.sctp, id, ppi, payload) do
          :ok -> {:reply, :ok, drain_sctp(state)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, {:channel_not_open, label}}, state}
    end
  end

  def handle_call({:channel_open?, label}, _from, state),
    do: {:reply, match?({:ok, _}, find_open(state, label)), state}

  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, shutdown(state)}

  @impl true
  def handle_info({:ex_ice, _pid, {:connection_state_change, ice_state}}, state) do
    notify(state, {:ice, ice_state})

    case ice_state do
      :connected -> {:noreply, ice_connected(state)}
      :completed -> {:noreply, ice_connected(state)}
      :failed -> {:noreply, fail(state, :ice_failed)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:ex_ice, _pid, {:data, data}}, state), do: {:noreply, ice_data(state, data)}
  def handle_info({:ex_ice, _pid, _other}, state), do: {:noreply, state}

  def handle_info(:dtls_timeout, %{dtls: nil} = state), do: {:noreply, state}

  def handle_info(:dtls_timeout, state) do
    state = %{state | dtls_timer: nil}

    case ExDTLS.handle_timeout(state.dtls) do
      {:retransmit, packets, timeout} ->
        if state.ice_connected?, do: ice_send(state, packets)
        {:noreply, arm_dtls(state, timeout)}

      :ok ->
        {:noreply, state}
    end
  end

  def handle_info(:sctp_timeout, %{sctp: nil} = state), do: {:noreply, state}

  def handle_info(:sctp_timeout, state) do
    ExSCTP.handle_timeout(state.sctp)
    {:noreply, drain_sctp(%{state | sctp_timer: nil})}
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, shutdown(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp ice_connected(%{ice_connected?: true} = state), do: state

  defp ice_connected(%{dtls: nil} = state), do: %{state | ice_connected?: true}

  defp ice_connected(state) do
    state = %{state | ice_connected?: true}

    case state.dtls_state do
      :new ->
        {:ok, packets, timeout} = ExDTLS.do_handshake(state.dtls)
        ice_send(state, packets)
        %{arm_dtls(state, timeout) | dtls_state: :connecting}

      _ ->
        if state.pending_local, do: ice_send(state, state.pending_local)
        %{state | pending_local: nil}
    end
  end

  defp ice_data(%{dtls: nil} = state, _data), do: state

  defp ice_data(state, <<first, _::binary>> = data) when first in 20..63 do
    case ExDTLS.handle_data(state.dtls, data) do
      {:handshake_packets, packets, timeout} ->
        state =
          if state.ice_connected? do
            ice_send(state, packets)
            state
          else
            %{state | pending_local: packets}
          end

        %{arm_dtls(state, timeout) | dtls_state: :connecting}

      {:handshake_finished, lkm, rkm, profile, packets} ->
        handshake_finished(state, lkm, rkm, profile, packets)

      {:handshake_finished, lkm, rkm, profile} ->
        handshake_finished(state, lkm, rkm, profile, [])

      :handshake_want_read ->
        state

      {:ok, sctp_data} when state.sctp != nil ->
        :ok = ExSCTP.handle_data(state.sctp, sctp_data)
        drain_sctp(state)

      {:ok, _data} ->
        state

      {:error, :peer_closed_for_writing} ->
        fail(state, :dtls_closed)

      {:error, reason} ->
        fail(state, {:dtls, reason})
    end
  end

  defp ice_data(
         %{dtls_state: :connected, in_srtp: srtp} = state,
         <<first, second, _::binary>> = data
       )
       when first in 128..191 do
    if second in 192..223 do
      state
    else
      case ExLibSRTP.unprotect(srtp, data) do
        {:ok, packet} when is_tuple(state.rtp_sink) ->
          send(elem(state.rtp_sink, 0), {:rtp, elem(state.rtp_sink, 1), packet})

        _ ->
          :ok
      end

      state
    end
  end

  defp ice_data(state, _data), do: state

  defp handshake_finished(state, _lkm, rkm, profile, packets) do
    actual = state.dtls |> ExDTLS.get_peer_cert() |> ExDTLS.get_cert_fingerprint() |> colon_hex()

    if actual == state.peer_fingerprint do
      {:ok, crypto} = ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(profile)
      in_srtp = ExLibSRTP.new()

      :ok =
        ExLibSRTP.add_stream(in_srtp, %ExLibSRTP.Policy{
          ssrc: :any_inbound,
          key: rkm,
          rtp: crypto,
          rtcp: crypto
        })

      ice_send(state, packets)
      notify(state, :dtls_connected)
      :ok = ExSCTP.connect(state.sctp)
      drain_sctp(%{state | dtls_state: :connected, in_srtp: in_srtp})
    else
      fail(state, :dtls_fingerprint_mismatch)
    end
  end

  defp drain_sctp(%{sctp: nil} = state), do: state

  defp drain_sctp(state) do
    case ExSCTP.poll(state.sctp) do
      :none -> state
      event -> state |> sctp_event(event) |> drain_sctp()
    end
  end

  defp sctp_event(state, {:transmit, packets}) do
    for packet <- packets do
      case ExDTLS.write_data(state.dtls, packet) do
        {:ok, out} ->
          ice_send(state, out)

        {:error, reason} ->
          Logger.warning("meet transport: DTLS write failed: #{inspect(reason)}")
      end
    end

    state
  end

  defp sctp_event(state, :connected) do
    notify(state, :sctp_connected)
    state = %{state | sctp_state: :connected}

    state =
      Enum.reduce(state.channels, state, fn
        {id, %{negotiated?: true} = ch}, acc ->
          _ = ExSCTP.open_stream(acc.sctp, id)
          configure(acc, id, ch)
          notify(acc, {:channel_open, ch.label})
          put_in(acc.channels[id].open?, true)

        _other, acc ->
          acc
      end)

    Enum.reduce(state.pending_open, %{state | pending_open: []}, &open_local(&2, &1))
  end

  defp sctp_event(state, :disconnected), do: fail(state, :sctp_disconnected)

  defp sctp_event(state, {:timeout, ms}) do
    if state.sctp_timer, do: SystemsClock.cancel_timer(state.sctp_timer)
    %{state | sctp_timer: ms && SystemsClock.send_after(self(), :sctp_timeout, ms)}
  end

  defp sctp_event(state, {:data, id, @dcep_ppi, data}), do: dcep(state, id, data)

  defp sctp_event(state, {:data, id, ppi, data}) do
    payload =
      cond do
        ppi in [@binary_ppi, @string_ppi] -> data
        ppi in [@empty_binary_ppi, @empty_string_ppi] -> ""
        true -> nil
      end

    cond do
      payload == nil ->
        state

      match?(%{open?: true}, state.channels[id]) ->
        notify(state, {:data, state.channels[id].label, payload})
        state

      true ->
        update_in(state.buffered, fn buffered ->
          Map.update(buffered, id, [payload], fn list ->
            Enum.take([payload | list], @max_buffered_per_stream)
          end)
        end)
    end
  end

  defp sctp_event(state, {:stream_closed, id}) do
    case Map.pop(state.channels, id) do
      {nil, _} ->
        state

      {ch, channels} ->
        notify(state, {:channel_closed, ch.label})
        %{state | channels: channels}
    end
  end

  defp sctp_event(state, _event), do: state

  defp dcep(
         state,
         id,
         <<0x03, ch_type, _priority::16, param::32, label_len::16, proto_len::16, rest::binary>>
       ) do
    with <<label::binary-size(^label_len), _protocol::binary-size(^proto_len)>> <- rest,
         nil <- state.channels[id] do
      :ok = ExSCTP.send(state.sctp, id, @dcep_ppi, <<0x02>>)
      {reliability, ordered} = channel_type(ch_type)

      ch = %{
        label: label,
        ordered: ordered,
        max_packet_life_time: if(reliability == :timed, do: param, else: 0),
        negotiated?: false,
        open?: true
      }

      _ =
        ExSCTP.configure_stream(
          state.sctp,
          id,
          ordered,
          reliability,
          if(reliability == :reliable, do: 0, else: param)
        )

      notify(state, {:channel_open, label})
      {buffered, buffers} = Map.pop(state.buffered, id, [])
      for payload <- Enum.reverse(buffered), do: notify(state, {:data, label, payload})
      %{state | channels: Map.put(state.channels, id, ch), buffered: buffers}
    else
      _ -> state
    end
  end

  defp dcep(state, id, <<0x02, _::binary>>) do
    case state.channels[id] do
      %{open?: false} = ch ->
        configure(state, id, ch)
        notify(state, {:channel_open, ch.label})
        put_in(state.channels[id].open?, true)

      _ ->
        state
    end
  end

  defp dcep(state, _id, _data), do: state

  defp open_local(state, label) do
    id = next_local_id(state)
    _ = ExSCTP.open_stream(state.sctp, id)
    open = <<0x03, 0x00, 0::16, 0::32, byte_size(label)::16, 0::16, label::binary>>
    :ok = ExSCTP.send(state.sctp, id, @dcep_ppi, open)
    ch = %{label: label, ordered: true, max_packet_life_time: 0, negotiated?: false, open?: false}
    %{state | channels: Map.put(state.channels, id, ch)}
  end

  defp next_local_id(state) do
    used = Map.keys(state.channels)
    Enum.find(0..65_534//2, &(&1 not in used))
  end

  defp configure(state, id, %{ordered: ordered, max_packet_life_time: mplt}) do
    {reliability, param} = if mplt > 0, do: {:timed, mplt}, else: {:reliable, 0}
    _ = ExSCTP.configure_stream(state.sctp, id, ordered, reliability, param)
    :ok
  end

  defp channel_type(type) do
    ordered = Bitwise.band(type, 0x80) == 0

    reliability =
      case Bitwise.band(type, 0x03) do
        0x01 -> :rexmit
        0x02 -> :timed
        _ -> :reliable
      end

    {reliability, ordered}
  end

  defp find_open(state, label) do
    Enum.find_value(state.channels, :error, fn
      {id, %{label: ^label, open?: true}} -> {:ok, id}
      _ -> nil
    end)
  end

  defp ice_send(state, packets) when is_list(packets),
    do: Enum.each(packets, &ice_send(state, &1))

  defp ice_send(state, packet) when is_binary(packet), do: ICEAgent.send_data(state.ice, packet)

  defp arm_dtls(state, timeout) do
    if state.dtls_timer, do: SystemsClock.cancel_timer(state.dtls_timer)
    %{state | dtls_timer: SystemsClock.send_after(self(), :dtls_timeout, timeout)}
  end

  defp fail(state, reason) do
    notify(state, {:failed, reason})
    state
  end

  defp shutdown(state) do
    if state.dtls != nil and state.dtls_state == :connected do
      case ExDTLS.close(state.dtls) do
        {:ok, packets} -> ice_send(state, packets)
        _ -> :ok
      end
    end

    if Process.alive?(state.ice), do: ICEAgent.stop(state.ice)
    %{state | dtls: nil, sctp: nil}
  end

  defp notify(state, msg), do: send(state.owner, {:meet_transport, self(), msg})

  defp colon_hex(bin),
    do:
      bin
      |> Base.encode16()
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)

  defp normalize_fingerprint(nil), do: nil
  defp normalize_fingerprint(fp), do: fp |> String.trim() |> String.upcase()
end
