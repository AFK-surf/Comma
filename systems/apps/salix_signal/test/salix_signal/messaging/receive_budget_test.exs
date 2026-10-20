defmodule SalixSignal.Messaging.ReceiveBudgetTest do
  # The receive work limits of the owner decision on availability: a
  # sender whose messages keep failing to decrypt is cooled down (its
  # envelopes are admitted as dropped and acknowledged without
  # decryption), and opening one envelope has a time budget. Both are
  # recorded as telemetry. Comma rules, not Signal facts.
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SalixSignal"]
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
      SystemsClock.sleep(delay)
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
    test = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      {__MODULE__, test},
      [:salix_signal, :receive, :guard],
      fn _event, _measurements, %{reason: reason}, _ ->
        SystemsRuntime.Proc.send(test, {:guard, reason})
      end,
      nil
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach({__MODULE__, test}) end)

    {:ok, clock} = Agent.start_link(fn -> SystemsClock.system_time(:millisecond) end)
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
    ts = SystemsClock.system_time(:millisecond) + SystemsRuntime.Proc.unique_integer([:positive])

    {{:ok, _}, alice} =
      SignalAccount.run(
        alice,
        &Pipeline.send_content(&1, @bob, Content.text(ts, body), timestamp: ts, sealed: false)
      )

    alice
  end
end
