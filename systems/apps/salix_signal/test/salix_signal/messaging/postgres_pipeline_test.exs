defmodule SalixSignal.Messaging.PostgresPipelineTest do
  # The receive and send pipelines over the Postgres store
  # (SalixSignal.Storage) with a clean mock of the message service
  # (CRS-05, CRS-07): a process killed inside the receive commit changes
  # nothing and the envelope replays; a lost acknowledgement only
  # acknowledges; an owner rebuilt from the tables alone keeps the ratchets
  # in step; a fenced owner neither commits nor acknowledges.
  use ExUnit.Case, async: false

  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Storage
  alias SalixSignal.Test.{MockService, SignalAccount}
  alias SalixSignalProto.Message.Content
  alias SalixStore.Repo

  @alice "00000000-0000-4000-8000-000000000081"
  @bob "00000000-0000-4000-8000-000000000082"

  setup do
    {:ok, service} = MockService.start_link()
    alice = SignalAccount.new(service, @alice, store: :postgres)
    bob = SignalAccount.new(service, @bob, store: :postgres)
    %{service: service, alice: alice, bob: bob}
  end

  defp messages(events), do: for({:message, %Inbound{} = inbound} <- events, do: inbound)

  defp body(%Inbound{content: content}) do
    {:ok, _kind, wire} = Content.decode(content)
    wire.data_message.body
  end

  defp send_text(account, to, body) do
    {{:ok, info}, account} = SignalAccount.run(account, &Pipeline.send_text(&1, to, body))
    {info, account}
  end

  defp converse(alice, bob) do
    {_info, alice} = send_text(alice, @bob, "hello")
    {_events, bob} = SignalAccount.deliver(bob)
    {_info, bob} = send_text(bob, @alice, "hi")
    {_events, alice} = SignalAccount.deliver(alice)
    {_events, bob} = SignalAccount.deliver(bob)
    {alice, bob}
  end

  defp data_count(account) do
    {:ok, items} = Storage.inbound_after(account.account_id, 0, 500)
    length(for {_seq, %Inbound{content_kind: :data}} <- items, do: :ok)
  end

  test "a process killed inside the receive commit changes nothing; the envelope replays",
       %{alice: alice, bob: bob} do
    {alice, bob} = converse(alice, bob)
    {_info, alice} = send_text(alice, @bob, "one")
    [{guid, _bytes}] = MockService.queued(bob.service, @bob, 1)
    test = self()

    # Another transaction holds the admission row of this envelope, so the
    # receive commit writes the session advance and then waits on it.
    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "INSERT INTO signal_inbound (account_id, kind, key, admitted_at) VALUES ($1, 1, $2, now())",
            [Ecto.UUID.dump!(bob.account_id), guid]
          )

          send(test, :holding)
          receive do: (:release -> Repo.rollback(:released))
        end)
      end)

    assert_receive :holding
    worker = spawn(fn -> SignalAccount.deliver(bob) end)
    wait_until_blocked(bob.account_id)
    Process.exit(worker, :kill)
    send(blocker.pid, :release)
    assert {:error, :released} = Task.await(blocker)

    assert [_still_queued] = MockService.queued(bob.service, @bob, 1)
    refute Storage.admitted?(bob.account_id, guid)

    # The replay decrypts: the killed commit left the ratchet where it was.
    {events, bob} = SignalAccount.deliver(bob, ack: false)
    assert [first] = messages(events)
    assert body(first) == "one"

    # The acknowledgement was lost; the redelivery is only acknowledged.
    {events, bob} = SignalAccount.deliver(bob)
    assert [{:redelivered, ^guid}] = events
    assert MockService.queued(bob.service, @bob, 1) == []
    assert data_count(bob) == 2

    {_info, _alice} = send_text(alice, @bob, "two")
    {events, _bob} = SignalAccount.deliver(bob)
    assert ["two"] = Enum.map(messages(events), &body/1)
  end

  test "an owner rebuilt from the tables alone continues both ratchets", %{alice: alice, bob: bob} do
    {alice, bob} = converse(alice, bob)
    alice = SignalAccount.restart(alice)
    bob = SignalAccount.restart(bob)

    {info, alice} = send_text(alice, @bob, "after restart")
    assert info.sealed?
    {events, bob} = SignalAccount.deliver(bob)
    assert ["after restart"] = Enum.map(messages(events), &body/1)

    {_info, _bob} = send_text(bob, @alice, "and back")
    {events, _alice} = SignalAccount.deliver(alice)

    assert "and back" in Enum.map(
             for(%Inbound{content_kind: :data} = i <- messages(events), do: i),
             &body/1
           )
  end

  test "a fenced owner does not commit or acknowledge; the new owner processes the envelope",
       %{alice: alice, bob: bob} do
    {alice, bob} = converse(alice, bob)
    {_info, _alice} = send_text(alice, @bob, "for the new owner")

    stale = bob
    bob = SignalAccount.restart(bob)

    assert {[:fenced], _} = SignalAccount.deliver(stale)
    assert [_still_queued] = MockService.queued(bob.service, @bob, 1)

    {events, _bob} = SignalAccount.deliver(bob)
    assert ["for the new owner"] = Enum.map(messages(events), &body/1)
    assert MockService.queued(bob.service, @bob, 1) == []
  end

  # Waits until the receive commit waits on the held row lock.
  defp wait_until_blocked(account_id, tries \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%signal_inbound%'"
      )

    cond do
      waiting > 0 -> :ok
      tries == 0 -> flunk("the receive commit of #{account_id} never waited")
      true -> Process.sleep(20) && wait_until_blocked(account_id, tries - 1)
    end
  end
end
