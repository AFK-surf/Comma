defmodule SalixSignal.CallSignaling do
  @moduledoc """
  1:1 call signaling for one Signal account device (CRS-12).

  One process per account device receives the account's call messages,
  classifies offers against the calls it already has (CRS-12 section 8) and
  routes the other payloads to the call they name. Each call runs in its own
  `SalixSignal.CallSignaling.Call` process on this node, which owns the
  call's `SalixSignal.CallMedia.Connection`.

  The messaging layer calls `receive_message/2` for every decrypted content
  message whose field 3 (the call message) is set, and delivers the call
  messages that this layer sends through the `send` function. Call messages
  need no durable state: a lost call message only loses a call attempt.

  ## Options

    * `aci`, `device_id`: this account's ACI string and device ID
    * `identity_key`: this account's ACI identity public key, 32 bytes, or
      33 bytes with its `0x05` type byte (CRS-12 section 6.2)
    * `peer_identity_key`: `fun(aci) -> {:ok, key} | :error`, the stored
      identity key of a peer ACI; a call message from a peer without one is
      dropped (CRS-12 section 6.2)
    * `send`: `fun(recipient_aci, call_message, %{urgent: boolean}) -> :ok |
      {:error, reason}` sends one encoded call message to all devices of the
      recipient (CRS-12 section 6); it runs in a separate process and
      counts as failed after `send_deadline_ms`
    * `incoming_call`: `fun(info) -> :ring | :busy | :needs_permission |
      :ignore` decides an offer that has no collision; `info` is
      `%{peer_aci, peer_device_id, call_id, media_type}`. `:needs_permission`
      answers hangup type 4, for a caller that is not allowed to call
      (CRS-12 section 8)
    * `admit`: `fun(info, connection) -> :ok | {:ok, term} | {:error,
      reason}` attaches the media connection to a voice call when the call
      can start: for the callee when ICE connects (before it accepts), for
      the caller when the callee accepts. `SalixSignal.Carrier.admit/2` is
      the production implementation. An error declines or ends the call.
    * `opaque` (optional): `fun(%{sender_aci, sender_device_id, data,
      urgency, age_s}) -> any` receives opaque payloads, the group-call
      material of CRS-14; `SalixSignal.GroupCall.handle_opaque/3` routes
      them. It runs in this process and must return quickly. Without it
      opaque payloads are dropped.
    * `ice_servers`: a list, or a function returning a list, `{:ok, list}`, or
      `{:error, reason}`. Lists come from
      `SalixSignal.CallMedia.Relays.ice_servers/1`
    * `max_calls`: concurrent calls with different peers before offers are
      answered busy (default 16)
    * `max_bitrate_bps`: the bitrate this side asks the peer to send at
      most, in the connection parameters (default 300,000: audio needs about
      32,000 and this side never decodes video)
    * `media`: extra options for each `SalixSignal.CallMedia.Connection`
    * `setup_timeout_ms`, `send_deadline_ms`: CRS-12 section 10 timers
      (defaults 60 s and 15 s)
  """

  use GenServer

  require Logger

  alias SalixSignal.CallSignaling.Call
  alias SalixSignalProto.CallSignaling, as: Proto

  @defaults %{
    max_calls: 16,
    max_bitrate_bps: 300_000,
    media: [],
    ice_servers: [],
    setup_timeout_ms: Proto.setup_timeout_ms(),
    send_deadline_ms: Proto.send_deadline_ms()
  }

  # ICE updates that arrive before their offer (CRS-12 section 7.2 step 4)
  # wait at most as long as an offer stays valid, for a bounded number of
  # calls and candidates.
  @early_ice_max_calls 32
  @early_ice_max_candidates 64

  @type inbound :: %{
          required(:sender_aci) => String.t(),
          required(:sender_device_id) => pos_integer(),
          required(:call_message) => binary(),
          optional(:server_timestamp_ms) => integer() | nil,
          optional(:delivery_timestamp_ms) => integer() | nil
        }

  # -- API ---------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), if(name, do: [name: name], else: []))
  end

  @doc """
  Hands over one received call message: the sender's ACI and device ID,
  the encoded call message (content field 3), the envelope server timestamp
  and the `X-Signal-Timestamp` of the delivering request (CRS-12 section
  6.1).
  """
  @spec receive_message(GenServer.server(), inbound()) :: :ok
  def receive_message(server, inbound), do: GenServer.cast(server, {:receive, inbound})

  @doc """
  Starts an outgoing audio call to `peer_aci` (CRS-12 section 7.1). Returns
  the call process and the call ID, or `{:error, :busy}` when a call with
  that peer exists or `max_calls` is reached, or
  `{:error, :unknown_identity}`.
  """
  @spec call(GenServer.server(), String.t()) ::
          {:ok, pid(), Proto.call_id()} | {:error, term()}
  def call(server, peer_aci), do: GenServer.call(server, {:call, peer_aci})

  @doc "Ends a call locally with hangup type 0 (CRS-12 section 7.3)."
  @spec hangup(pid()) :: :ok
  def hangup(call), do: Call.hangup(call)

  @doc "The live calls: `%{pid, peer_aci, call_id, role, connected_device, connected_and_accepted}`."
  @spec calls(GenServer.server()) :: [map()]
  def calls(server), do: GenServer.call(server, :calls)

  # -- Server ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    config = Map.merge(@defaults, opts)

    required = [
      :aci,
      :device_id,
      :identity_key,
      :peer_identity_key,
      :send,
      :incoming_call,
      :admit
    ]

    case Enum.reject(required, &Map.has_key?(config, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "missing options: #{inspect(missing)}"
    end

    {:ok, %{config: config, calls: %{}, early_ice: %{}}}
  end

  @impl GenServer
  def handle_cast({:receive, inbound}, state) do
    {:noreply, receive_inbound(state, inbound)}
  end

  @impl GenServer
  def handle_call({:call, peer_aci}, _from, state) do
    with :ok <- free_for(state, peer_aci),
         {:ok, peer_ik} <- peer_identity(state, peer_aci) do
      call_id = Proto.new_call_id()
      args = call_args(state, :caller, peer_aci, nil, call_id, peer_ik, %{})

      case start_call(state, args) do
        {:ok, pid, state} -> {:reply, {:ok, pid, call_id}, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      :error -> {:reply, {:error, :unknown_identity}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:calls, _from, state) do
    calls =
      Enum.map(state.calls, fn {pid, call} ->
        call
        |> Map.take([:peer_aci, :call_id, :role])
        |> Map.merge(call.status)
        |> Map.put(:pid, pid)
      end)

    {:reply, calls, state}
  end

  @impl GenServer
  def handle_info({:call_status, pid, status}, state) do
    case state.calls do
      %{^pid => call} ->
        {:noreply, put_in(state.calls[pid], %{call | status: Map.merge(call.status, status)})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | calls: Map.delete(state.calls, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  # -- Receive -----------------------------------------------------------------

  defp receive_inbound(state, %{sender_aci: aci, sender_device_id: device} = inbound) do
    case Proto.decode(inbound.call_message) do
      {:ok, message} ->
        if Proto.for_device?(message, state.config.device_id),
          do: route(state, aci, device, message.payload, inbound),
          else: state

      {:error, {:invalid_answer, call_id}} ->
        forward(state, aci, call_id, {:invalid_answer, device})

      {:error, reason} ->
        Logger.debug("signal call message dropped: #{inspect(reason)}")
        state
    end
  end

  defp route(state, aci, device, {:offer, offer}, inbound) do
    age = Proto.message_age(inbound[:delivery_timestamp_ms], inbound[:server_timestamp_ms])

    if Proto.offer_expired?(age), do: state, else: offer(state, aci, device, offer)
  end

  defp route(state, aci, device, {:ice, call_id, _} = payload, _inbound) do
    case find_call(state, aci, call_id) do
      nil -> buffer_ice(state, aci, device, payload)
      pid -> forward_to(state, pid, {:signal, payload, device})
    end
  end

  defp route(state, aci, device, {:hangup, call_id, _, _} = payload, _inbound),
    do: forward(state, aci, call_id, {:signal, payload, device})

  defp route(state, aci, device, {:busy, call_id} = payload, _inbound),
    do: forward(state, aci, call_id, {:signal, payload, device})

  defp route(state, aci, device, {:answer, %{call_id: call_id}} = payload, _inbound),
    do: forward(state, aci, call_id, {:signal, payload, device})

  # Opaque payloads carry group-call material (CRS-12 section 5.4, CRS-14).
  # The receiver must know the sender's ACI (CRS-12 section 3.7), which the
  # decrypted envelope gives.
  defp route(state, aci, device, {:opaque, data, urgency}, inbound) do
    case state.config[:opaque] do
      nil ->
        state

      handler ->
        age = Proto.message_age(inbound[:delivery_timestamp_ms], inbound[:server_timestamp_ms])

        handler.(%{
          sender_aci: aci,
          sender_device_id: device,
          data: data,
          urgency: urgency,
          age_s: age
        })

        state
    end
  end

  defp forward(state, aci, call_id, message) do
    case find_call(state, aci, call_id) do
      nil -> state
      pid -> forward_to(state, pid, message)
    end
  end

  defp forward_to(state, pid, message) do
    send(pid, message)
    state
  end

  # -- Offers (CRS-12 sections 7.2 and 8) --------------------------------------

  defp offer(state, aci, device, %{call_id: call_id} = offer) do
    with {:ok, peer_ik} <- peer_identity(state, aci) do
      existing = peer_call(state, aci)

      decision =
        cond do
          # A second copy of the offer that started an incoming call is not
          # a new call attempt.
          match?({_pid, %{role: :callee, call_id: ^call_id}}, existing) ->
            :ignore

          existing != nil ->
            {_pid, call} = existing
            Proto.classify_offer(Map.put(call.status, :call_id, call.call_id), call_id, device)

          length(live_calls(state)) >= state.config.max_calls ->
            :busy

          true ->
            :ring
        end

      apply_decision(state, decision, existing, aci, device, offer, peer_ik)
    else
      :error -> state
    end
  end

  defp apply_decision(state, :ring, _existing, aci, device, offer, peer_ik),
    do: ring(state, aci, device, offer, peer_ik)

  defp apply_decision(state, :busy, _existing, aci, _device, offer, _peer_ik),
    do: send_busy(state, aci, offer.call_id)

  defp apply_decision(state, :ignore, _existing, _aci, _device, _offer, _peer_ik), do: state

  defp apply_decision(state, :recall, {pid, _}, aci, device, offer, peer_ik) do
    Call.finish(pid, :silent)
    ring(forget(state, pid), aci, device, offer, peer_ik)
  end

  defp apply_decision(state, :replace, {pid, _}, aci, device, offer, peer_ik) do
    Call.hangup(pid)
    ring(forget(state, pid), aci, device, offer, peer_ik)
  end

  defp apply_decision(state, :both_lose, {pid, _}, aci, _device, offer, _peer_ik) do
    Call.hangup(pid)
    send_busy(forget(state, pid), aci, offer.call_id)
  end

  # A call that is ending no longer counts for collisions; its process
  # stays monitored until it has sent its last message.
  defp forget(state, pid), do: put_in(state.calls[pid].status[:ending], true)

  defp ring(state, aci, device, offer, peer_ik) do
    early = take_early_ice(state, aci, offer.call_id, device)
    state = %{state | early_ice: Map.delete(state.early_ice, {aci, offer.call_id})}

    extra = %{
      media_type: offer.media_type,
      remote: offer.parameters,
      early_candidates: early
    }

    args = call_args(state, :callee, aci, device, offer.call_id, peer_ik, extra)

    case start_call(state, args) do
      {:ok, _pid, state} -> state
      {:error, _reason} -> state
    end
  end

  defp send_busy(state, aci, call_id) do
    send_fun = state.config.send
    message = Proto.encode({:busy, call_id})
    deadline = state.config.send_deadline_ms

    # Busy is always a broadcast (CRS-12 section 8). Nothing depends on the
    # result.
    Task.start(fn ->
      task = Task.async(fn -> send_fun.(aci, message, %{urgent: false}) end)
      Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill)
    end)

    state
  end

  # -- Calls -------------------------------------------------------------------

  defp call_args(state, role, aci, device, call_id, peer_ik, extra) do
    own_ik = raw_key(state.config.identity_key)

    {caller_ik, callee_ik} = if role == :caller, do: {own_ik, peer_ik}, else: {peer_ik, own_ik}

    Map.merge(
      %{
        signaling: self(),
        role: role,
        peer_aci: aci,
        peer_device_id: device,
        call_id: call_id,
        media_type: :audio,
        caller_identity_key: caller_ik,
        callee_identity_key: callee_ik,
        config: state.config
      },
      extra
    )
  end

  defp start_call(state, args) do
    case DynamicSupervisor.start_child(SalixSignal.CallSignaling.Supervisor, {Call, args}) do
      {:ok, pid} ->
        Process.monitor(pid)

        call = %{
          peer_aci: args.peer_aci,
          call_id: args.call_id,
          role: args.role,
          status: %{connected_device: nil, connected_and_accepted: false}
        }

        {:ok, pid, put_in(state.calls[pid], call)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp free_for(state, peer_aci) do
    if peer_call(state, peer_aci) != nil or length(live_calls(state)) >= state.config.max_calls,
      do: {:error, :busy},
      else: :ok
  end

  defp live_calls(state),
    do: Enum.reject(state.calls, fn {_pid, call} -> call.status[:ending] end)

  defp peer_call(state, aci),
    do: state |> live_calls() |> Enum.find(fn {_pid, call} -> call.peer_aci == aci end)

  defp find_call(state, aci, call_id) do
    Enum.find_value(state.calls, fn {pid, call} ->
      if call.peer_aci == aci and call.call_id == call_id, do: pid
    end)
  end

  defp peer_identity(state, aci) do
    case state.config.peer_identity_key.(aci) do
      {:ok, key} when byte_size(key) in [32, 33] -> {:ok, raw_key(key)}
      _ -> :error
    end
  end

  # Identity keys enter the media key derivation without the type byte
  # (CRS-12 section 6.2, CRS-13 section 4.1).
  defp raw_key(<<0x05, key::binary-32>>), do: key
  defp raw_key(<<key::binary-32>>), do: key

  # -- Early ICE updates -------------------------------------------------------

  defp buffer_ice(state, aci, device, {:ice, call_id, candidates}) do
    now = System.monotonic_time(:millisecond)
    max_age_ms = Proto.max_offer_age_s() * 1000

    early =
      state.early_ice
      |> Map.reject(fn {_key, {at, _}} -> now - at > max_age_ms end)

    key = {aci, call_id}
    {at, held} = Map.get(early, key, {now, []})
    held = Enum.take(held ++ Enum.map(candidates, &{device, &1}), @early_ice_max_candidates)
    early = Map.put(early, key, {at, held})

    early =
      if map_size(early) > @early_ice_max_calls do
        {oldest, _} = Enum.min_by(early, fn {_key, {at, _}} -> at end)
        Map.delete(early, oldest)
      else
        early
      end

    %{state | early_ice: early}
  end

  defp take_early_ice(state, aci, call_id, device) do
    case state.early_ice do
      %{{^aci, ^call_id} => {_at, held}} ->
        for {^device, candidate} <- held, do: candidate

      _ ->
        []
    end
  end
end
