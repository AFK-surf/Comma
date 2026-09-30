defmodule SalixSignal.Messaging.ReceiveBudgetTest do
  # The receive work limits of the owner decision on availability: a
  # sender whose messages keep failing to decrypt is cooled down (its
  # envelopes are admitted as dropped and acknowledged without
  # decryption), and opening one envelope has a time budget. Both are
  # recorded as telemetry. Comma rules, not Signal facts.
  use ExUnit.Case, async: false

  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Test.{MemoryStore, MockService, SignalAccount}
  alias SalixSignalProto.Message.{Content, Envelope}

  @alice "00000000-0000-4000-8000-000000000051"
  @bob "00000000-0000-4000-8000-000000000052"

  defmodule SlowStore do
    @moduledoc false
    # A MemoryStore whose session reads take `delay` ms.
    @behaviour SalixSignal.Messaging.Store

    def session({store, delay}, address) do
      Process.sleep(delay)
      MemoryStore.session(store, address)
    end

    for {name, arity} <- [
          device_ids: 2,
          identity: 2,
          pre_keys: 2,
          admitted?: 2,
          message_seen?: 2,
          contact: 2,
          sent: 2,
          group: 2
        ] do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(name)({store, _delay}, unquote_splicing(args)),
        do: MemoryStore.unquote(name)(store, unquote_splicing(args))
    end

    def sender_key({store, _delay}, address, id), do: MemoryStore.sender_key(store, address, id)
    def commit({store, _delay}, epoch, ops), do: MemoryStore.commit(store, epoch, ops)
  end

  setup do
    test = self()

    :telemetry.attach(
      {__MODULE__, test},
      [:salix_signal, :receive, :guard],
      fn _event, _measurements, %{reason: reason}, _ -> send(test, {:guard, reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, test}) end)

    {:ok, clock} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    {:ok, service} = MockService.start_link()
    alice = SignalAccount.new(service, @alice)

    bob =
      SignalAccount.new(service, @bob,
        clock: fn -> Agent.get(clock, & &1) end,
        config: [failure_limit: 3, failure_window_ms: 60_000, cooling_ms: 60_000]
      )

    {alice, bob} = converse(alice, bob)
    %{alice: alice, bob: bob, clock: clock, service: service}
  end

  defp converse(alice, bob) do
    {{:ok, _}, alice} = SignalAccount.run(alice, &Pipeline.send_text(&1, @bob, "hello"))
    {_events, bob} = SignalAccount.deliver(bob)
    {{:ok, _}, bob} = SignalAccount.run(bob, &Pipeline.send_text(&1, @alice, "hi"))
    {_events, alice} = SignalAccount.deliver(alice)
    {_events, bob} = SignalAccount.deliver(bob)
    {alice, bob}
  end

  # An identified 1:1 message from Alice, so the envelope names her.
  defp identified(alice, body) do
    ts = System.system_time(:millisecond) + System.unique_integer([:positive])

    {{:ok, _}, alice} =
      SignalAccount.run(
        alice,
        &Pipeline.send_content(&1, @bob, Content.text(ts, body), timestamp: ts, sealed: false)
      )

    alice
  end

  # Takes Bob's queued envelope, breaks its MAC, and hands it to Bob.
  defp corrupted(bob) do
    [{guid, bytes}] = MockService.queued(bob.service, @bob, 1)
    MockService.ack(bob.service, @bob, 1, guid)
    {:ok, envelope} = Envelope.decode(bytes)
    size = byte_size(envelope.payload) - 1
    <<head::binary-size(^size), last>> = envelope.payload

    Envelope.encode(%{
      envelope
      | payload: head <> <<Bitwise.bxor(last, 1)>>,
        server_guid: :crypto.strong_rand_bytes(16)
    })
  end

  defp bodies(events) do
    for {:message, %Inbound{content_kind: :data, content: content}} <- events do
      {:ok, :data, wire} = Content.decode(content)
      wire.data_message.body
    end
  end

  test "a sender with repeated failures is cooled down, then heard again", %{
    alice: alice,
    bob: bob,
    clock: clock
  } do
    bob =
      Enum.reduce(1..3, {alice, bob}, fn i, {alice, bob} ->
        alice = identified(alice, "broken #{i}")

        {:ack, events, pipeline} = Pipeline.receive_envelope(bob.pipeline, corrupted(bob))
        assert Enum.any?(events, &match?({:decryption_failed, @alice, _}, &1))
        {alice, %{bob | pipeline: pipeline}}
      end)
      |> elem(1)

    assert_received {:guard, :cooling_started}

    # While cooling, even a valid message is dropped without decryption,
    # admitted, acknowledged and not answered with a retry request.
    alice = identified(alice, "during cooling")
    requests_before = length(MockService.requests(bob.service))
    {events, bob} = SignalAccount.deliver(bob)
    assert [{:dropped, :sender_cooling}] = events
    assert_received {:guard, :sender_cooling}
    assert MockService.queued(bob.service, @bob, 1) == []
    assert length(MockService.requests(bob.service)) == requests_before

    assert %Inbound{outcome: :drop, reason: :sender_cooling} =
             List.last(SignalAccount.inbound(bob))

    # After the cooling period the sender is heard again.
    Agent.update(clock, &(&1 + 61_000))
    _alice = identified(alice, "after cooling")
    {events, _bob} = SignalAccount.deliver(bob)
    assert bodies(events) == ["after cooling"]
  end

  test "opening an envelope past its time budget drops it; the next one decrypts", %{
    alice: alice,
    bob: bob
  } do
    fast = bob.pipeline

    slow = %{
      fast
      | store: {SlowStore, {bob.store, 300}},
        config: %{fast.config | decrypt_budget_ms: 50}
    }

    alice = identified(alice, "too slow")
    {events, bob} = SignalAccount.deliver(%{bob | pipeline: slow})
    assert [{:dropped, :decryption_budget_exceeded}] = events
    assert_received {:guard, :budget_exceeded}
    assert MockService.queued(bob.service, @bob, 1) == []

    # The dropped attempt changed no session: the next message decrypts.
    _alice = identified(alice, "in time")

    {events, _bob} =
      SignalAccount.deliver(%{
        bob
        | pipeline: %{bob.pipeline | store: fast.store, config: fast.config}
      })

    assert bodies(events) == ["in time"]
  end
end
