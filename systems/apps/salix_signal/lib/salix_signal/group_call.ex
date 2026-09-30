defmodule SalixSignal.GroupCall do
  @moduledoc """
  Signal group calls (CRS-14) for one account: joining, and the group-call
  material that arrives in call messages.

    * `join/1` starts a `SalixSignal.GroupCall.Session` on this node. An
      account has at most one session per group.
    * `handle_opaque/2` takes an opaque call payload from the call-signaling
      dispatcher (`SalixSignal.CallSignaling` option `opaque`) and routes
      it: media keys and leave notices to the session of their group (a
      key for a group without an active call is ignored, section 9.4), and
      rings to the `on_ring` handler.

  A group call counts as a call for the 1:1 collision rules (CRS-12
  section 8): the `incoming_call` function of `SalixSignal.CallSignaling`
  should answer `:busy` while `whereis/2` finds a session of the account.

  Comma has no linked devices, so ring responses (section 11), which travel
  only between devices of one account, are never expected and are
  discarded. The HTTP client is `SalixSignal.GroupCall.Sfu`.
  """

  alias SalixSignal.GroupCall.Session
  alias SalixSignalProto.GroupCall
  alias SalixSignalProto.GroupCall.Messages

  @registry SalixSignal.GroupCall.Registry

  @doc """
  Joins a group call: starts a session under
  `SalixSignal.GroupCall.Supervisor`. See `SalixSignal.GroupCall.Session`
  for the options.
  """
  @spec join(keyword() | map()) :: DynamicSupervisor.on_start_child()
  def join(opts),
    do: DynamicSupervisor.start_child(SalixSignal.GroupCall.Supervisor, {Session, opts})

  @doc "Leaves a group call."
  @spec leave(pid()) :: :ok
  def leave(session), do: Session.leave(session)

  @doc "The session of account `aci` in group `group_id` on this node, or nil."
  @spec whereis(String.t(), binary()) :: pid() | nil
  def whereis(aci, group_id) do
    case Registry.lookup(@registry, {aci, group_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "True when account `aci` is in any group call on this node."
  @spec active?(String.t()) :: boolean()
  def active?(aci),
    do: Registry.select(@registry, [{{{:"$1", :_}, :_, :_}, [{:==, :"$1", aci}], [true]}]) != []

  @doc """
  Routes one opaque call payload received by account `own_aci`.

  `inbound` is `%{sender_aci, data, age_s}`: the sender from the decrypted
  envelope (the only authentication of a media key's owner, section 9.4),
  the opaque data (CRS-12 section 3.7) and the message age (CRS-12 section
  6.1).

  Options: `on_ring`, `fun(%{group_id, ring_id, type, sender_aci}) -> any`
  for a ring or cancellation younger than 60 seconds (section 11).
  """
  @spec handle_opaque(String.t(), map(), keyword()) :: :ok
  def handle_opaque(own_aci, %{sender_aci: sender, data: data} = inbound, opts \\ []) do
    case Messages.decode_opaque(data) do
      {:ok, {:device, %{group_id: <<_::binary-32>> = group_id} = device}} ->
        if pid = whereis(own_aci, group_id), do: Session.receive_signal(pid, sender, device)

      {:ok, {:ring, ring}} ->
        on_ring = opts[:on_ring]

        if on_ring != nil and Map.get(inbound, :age_s, 0) <= GroupCall.max_ring_age_s() do
          on_ring.(Map.put(ring, :sender_aci, sender))
        end

      _ ->
        :ok
    end

    :ok
  end
end
