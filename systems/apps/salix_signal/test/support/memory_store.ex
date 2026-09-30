defmodule SalixSignal.Test.MemoryStore do
  @moduledoc false
  # An in-memory SalixSignal.Messaging.Store for pipeline tests. One Agent
  # holds the state of one account. A commit applies all of its operations
  # or none, and only while its epoch is the current owner epoch.
  #
  # Test controls: set_epoch/2 makes earlier owners stale, and
  # crash_next_commit/1 makes the next commit raise before it applies
  # anything, like a node that stops in the middle of processing.

  @behaviour SalixSignal.Messaging.Store

  alias SalixSignalProto.PreKeys

  def start(pre_keys, epoch \\ 1) do
    Agent.start_link(fn ->
      %{
        epoch: epoch,
        crash_next_commit: false,
        sessions: %{},
        identities: %{},
        pre_keys: pre_keys,
        admitted: %{},
        admitted_order: [],
        messages: MapSet.new(),
        contacts: %{},
        sent: %{},
        sender_keys: %{},
        groups: %{},
        last_send_timestamp: 0,
        commits: 0
      }
    end)
  end

  def set_epoch(store, epoch), do: Agent.update(store, &%{&1 | epoch: epoch})
  def crash_next_commit(store), do: Agent.update(store, &%{&1 | crash_next_commit: true})
  def dump(store), do: Agent.get(store, & &1)

  def inbound(store),
    do: Agent.get(store, fn s -> Enum.map(Enum.reverse(s.admitted_order), &s.admitted[&1]) end)

  def put_contact(store, name, contact),
    do: Agent.update(store, &put_in(&1, [:contacts, name], contact))

  @impl true
  def session(store, address), do: Agent.get(store, &Map.get(&1.sessions, address))

  @impl true
  def device_ids(store, name) do
    Agent.get(store, fn s ->
      for {%{name: ^name, device_id: device}, _record} <- s.sessions, do: device
    end)
    |> Enum.sort()
  end

  @impl true
  def identity(store, name), do: Agent.get(store, &Map.get(&1.identities, name))

  @impl true
  def pre_keys(store, kind),
    do: Agent.get(store, &PreKeys.Store.pre_key_lookup(Map.fetch!(&1.pre_keys, kind)))

  @impl true
  def admitted?(store, guid), do: Agent.get(store, &Map.has_key?(&1.admitted, guid))

  @impl true
  def message_seen?(store, key), do: Agent.get(store, &MapSet.member?(&1.messages, key))

  @impl true
  def contact(store, name), do: Agent.get(store, &Map.get(&1.contacts, name))

  @impl true
  def sent(store, key), do: Agent.get(store, &Map.get(&1.sent, key))

  @impl true
  def sender_key(store, address, distribution),
    do: Agent.get(store, &Map.get(&1.sender_keys, {address, distribution}))

  @impl true
  def group(store, group_id), do: Agent.get(store, &Map.get(&1.groups, group_id))

  @impl true
  def commit(store, epoch, ops) do
    result =
      Agent.get_and_update(store, fn
        %{crash_next_commit: true} = s ->
          {:crash, %{s | crash_next_commit: false}}

        %{epoch: ^epoch} = s ->
          {:ok, Enum.reduce(ops, %{s | commits: s.commits + 1}, &apply_op/2)}

        s ->
          {{:error, :fenced}, s}
      end)

    if result == :crash, do: raise("simulated crash before commit"), else: result
  end

  defp apply_op({:put_session, address, record}, s), do: put_in(s, [:sessions, address], record)

  defp apply_op({:delete_session, address}, s),
    do: %{s | sessions: Map.delete(s.sessions, address)}

  defp apply_op({:put_identity, name, key}, s), do: put_in(s, [:identities, name], key)

  defp apply_op({:pre_key_effects, kind, effects}, s),
    do: update_in(s, [:pre_keys, kind], &PreKeys.Store.apply_effects(&1, effects))

  defp apply_op({:admit, guid, inbound}, s),
    do: %{
      s
      | admitted: Map.put(s.admitted, guid, inbound),
        admitted_order: [guid | s.admitted_order]
    }

  defp apply_op({:record_message, key}, s), do: %{s | messages: MapSet.put(s.messages, key)}
  defp apply_op({:put_contact, name, contact}, s), do: put_in(s, [:contacts, name], contact)
  defp apply_op({:put_sent, key, sent}, s), do: put_in(s, [:sent, key], sent)

  defp apply_op({:sender_key, {address, distribution, record}}, s),
    do: put_in(s, [:sender_keys, {address, distribution}], record)

  defp apply_op({:put_group, group_id, group}, s), do: put_in(s, [:groups, group_id], group)
  defp apply_op({:put_pre_keys, kind, store}, s), do: put_in(s, [:pre_keys, kind], store)

  defp apply_op({:put_send_timestamp, ms}, s),
    do: %{s | last_send_timestamp: max(s.last_send_timestamp, ms)}
end
