defmodule SalixSignal.Messaging.PipelineTest do
  # Two Comma accounts exchange messages through a clean mock of the message
  # service (CRS-03 §9.5, CRS-05, CRS-06, CRS-07): first contact, sealed
  # sending, receipts, the message kinds of CRS-05, redelivery and crashes
  # around the receive commit, owner fencing, device-list correction, retry
  # requests and fallbacks.
  use SystemsClock.Case, async: true

  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Test.{MemoryStore, MockService, SignalAccount}
  alias SalixSignalProto.Address
  alias SalixSignalProto.Message.{Content, DecryptionError}

  @alice "00000000-0000-4000-8000-000000000001"
  @bob "00000000-0000-4000-8000-000000000002"
  setup do
    {:ok, service} = MockService.start_link()
    alice = SignalAccount.new(service, @alice)
    bob = SignalAccount.new(service, @bob)
    %{service: service, alice: alice, bob: bob}
  end

  defp messages(events), do: for({:message, %Inbound{} = inbound} <- events, do: inbound)

  defp data(%Inbound{content: content}) do
    {:ok, _kind, wire} = Content.decode(content)
    wire
  end

  defp send_text(account, to, body, opts \\ []) do
    {{:ok, info}, account} = SignalAccount.run(account, &Pipeline.send_text(&1, to, body, opts))
    {info, account}
  end

  # Alice writes first; Bob answers, so both sessions are established and
  # both queues are empty (the last delivery takes Alice's receipt).
  defp converse(alice, bob) do
    {_info, alice} = send_text(alice, @bob, "hello")
    {_events, bob} = SignalAccount.deliver(bob)
    {_info, bob} = send_text(bob, @alice, "hi")
    {_events, alice} = SignalAccount.deliver(alice)
    {_events, bob} = SignalAccount.deliver(bob)
    {alice, bob}
  end

  test "first contact is identified, later messages are sealed, receipts flow back", %{
    alice: alice,
    bob: bob
  } do
    # Alice has no profile key of Bob yet, so she cannot seal.
    {info, alice} = send_text(alice, @bob, "hello Bob")
    refute info.sealed?
    assert info.devices == [1]

    {events, bob} = SignalAccount.deliver(bob)
    assert [inbound] = messages(events)

    assert %Inbound{
             outcome: :message,
             content_kind: :data,
             sender: @alice,
             sender_device: 1,
             sealed?: false
           } = inbound

    assert data(inbound).data_message.body == "hello Bob"
    assert inbound.timestamp == info.timestamp
    assert {:profile_key_changed, @alice} in events

    # Bob learned Alice's profile key, so his delivery receipt is sealed.
    [{_as, "PUT", "/v1/messages/" <> @alice, receipt_request}] =
      for {as, "PUT", path, opts} = r <- MockService.requests(bob.service),
          as == :unidentified,
          path == "/v1/messages/" <> @alice,
          do: r

    assert [%{"type" => 6}] = receipt_request[:json]["messages"]
    refute receipt_request[:json]["urgent"]

    {info, bob} = send_text(bob, @alice, "hello Alice")
    assert info.sealed?

    {events, alice} = SignalAccount.deliver(alice)

    kinds = for %Inbound{} = i <- messages(events), do: i.content_kind
    assert :receipt in kinds
    assert :data in kinds
    # Alice's first message was identified, so Bob's acknowledgement made
    # the service send her a server delivery receipt (CRS-07 §7.1).
    assert Enum.any?(events, &match?({:server_receipt, @bob, 1, _}, &1))

    [reply] = for i <- messages(events), i.content_kind == :data, do: i
    assert reply.sealed?
    assert data(reply).data_message.body == "hello Alice"

    [receipt] = for i <- messages(events), i.content_kind == :receipt, do: i
    assert data(receipt).receipt_message.timestamps != []
  end

  test "reactions, edits, deletes, typing and the 1:1 timer arrive as their content kinds", %{
    alice: alice,
    bob: bob
  } do
    {alice, bob} = converse(alice, bob)
    {sent, alice} = send_text(alice, @bob, "original")

    {{:ok, _}, alice} =
      SignalAccount.run(alice, &Pipeline.send_reaction(&1, @bob, "👍", @alice, sent.timestamp))

    {{:ok, _}, alice} =
      SignalAccount.run(alice, &Pipeline.send_edit(&1, @bob, sent.timestamp, "edited"))

    {{:ok, _}, alice} =
      SignalAccount.run(alice, &Pipeline.send_remote_delete(&1, @bob, sent.timestamp))

    {{:ok, typing}, alice} = SignalAccount.run(alice, &Pipeline.send_typing(&1, @bob, :started))
    {{:ok, _}, alice} = SignalAccount.run(alice, &Pipeline.set_expire_timer(&1, @bob, 3600))

    request =
      List.last(
        for {_, "PUT", "/v1/messages/" <> @bob, o} <- MockService.requests(alice.service),
            do: o[:json]
      )

    assert request["urgent"] == true

    {events, bob} = SignalAccount.deliver(bob)
    received = messages(events)

    [original, reaction, edit, delete, typing_message, timer] = received
    assert data(original).data_message.body == "original"
    assert data(reaction).data_message.reaction.emoji == "👍"
    assert data(reaction).data_message.reaction.target_message_timestamp == sent.timestamp
    assert edit.content_kind == :edit
    assert data(edit).edit_message.original_message_timestamp == sent.timestamp
    assert data(delete).data_message.remote_delete.target_message_timestamp == sent.timestamp
    assert typing_message.content_kind == :typing
    assert data(typing_message).typing_message.timestamp == typing.timestamp
    assert Content.flag?(data(timer).data_message, :expire_timer_update)

    assert {:expire_timer_changed, @alice, %{seconds: 3600, version: 1}} in events
    assert MemoryStore.contact(bob.store, @alice).expire_timer == %{seconds: 3600, version: 1}

    # Bob's next message carries the new timer and its version (CRS-05 §5.2).
    {_info, _bob} = send_text(bob, @alice, "ok")
    {events, _alice} = SignalAccount.deliver(alice)
    [ok] = for i <- messages(events), i.content_kind == :data, do: data(i).data_message
    assert {ok.body, ok.expire_timer, ok.expire_timer_version} == {"ok", 3600, 1}
  end

  test "a crash before the commit replays the envelope; after it, the redelivery is only acknowledged",
       %{alice: alice, bob: bob} do
    {alice, bob} = converse(alice, bob)
    {_info, alice} = send_text(alice, @bob, "one")

    MemoryStore.crash_next_commit(bob.store)
    assert_raise RuntimeError, fn -> SignalAccount.deliver(bob) end
    assert [_still_queued] = MockService.queued(bob.service, @bob, 1)

    # The replay decrypts: the crash changed nothing.
    {events, bob} = SignalAccount.deliver(bob, ack: false)
    assert [%Inbound{} = first] = messages(events)
    assert data(first).data_message.body == "one"

    # The acknowledgement was lost; the service pushes the envelope again.
    {events, bob} = SignalAccount.deliver(bob)
    assert [{:redelivered, _guid}] = events
    assert MockService.queued(bob.service, @bob, 1) == []

    # One admission, and the ratchets are still in step.
    assert length(for i <- SignalAccount.inbound(bob), i.content_kind == :data, do: i) == 2
    {_info, _alice} = send_text(alice, @bob, "two")
    {events, _bob} = SignalAccount.deliver(bob)
    assert [second] = messages(events)
    assert data(second).data_message.body == "two"
  end

  test "a stale owner does not commit and does not acknowledge", %{alice: alice, bob: bob} do
    {_info, _alice} = send_text(alice, @bob, "fenced")
    MemoryStore.set_epoch(bob.store, 2)

    {events, bob} = SignalAccount.deliver(bob)
    assert events == [:fenced]
    assert [_queued] = MockService.queued(bob.service, @bob, 1)
    assert MemoryStore.dump(bob.store).sessions == %{}
  end

  test "the device list is corrected after 409 and 410 and the message is sent again", %{
    service: service,
    alice: alice,
    bob: bob
  } do
    {alice, bob} = converse(alice, bob)

    # Bob links a second device: 409 missing, a session from its bundle.
    bob2 =
      SignalAccount.new(service, @bob,
        device_id: 2,
        identity: bob.identity,
        profile_key: bob.profile_key
      )

    {info, alice} = send_text(alice, @bob, "to both")
    assert info.devices == [1, 2]

    assert Enum.any?(
             info.events,
             &match?({:devices_changed, @bob, %{missing: [2], extra: []}}, &1)
           )

    {events, _bob} = SignalAccount.deliver(bob)
    assert [%Inbound{}] = messages(events)
    {events, _bob2} = SignalAccount.deliver(bob2)
    assert [%Inbound{} = on_two] = messages(events)
    assert data(on_two).data_message.body == "to both"

    # The device goes away: 409 extra, its session is forgotten.
    MockService.remove_device(service, @bob, 2)
    {info, alice} = send_text(alice, @bob, "one device again")
    assert info.devices == [1]
    assert MemoryStore.session(alice.store, Address.new(@bob, 2)) == nil

    # Device 1 re-registers with a new registration ID: 410 stale.
    MockService.set_registration_id(service, @bob, 1, 16_001)
    {info, _alice} = send_text(alice, @bob, "after re-registration")
    assert Enum.any?(info.events, &match?({:devices_changed, @bob, %{stale: [1]}}, &1))

    assert MemoryStore.session(alice.store, Address.new(@bob, 1)).current.remote_registration_id ==
             16_001
  end

  test "a message without a session gets a retry request; the sender resets and resends", %{
    service: service,
    alice: alice,
    bob: bob
  } do
    {alice, bob} = converse(alice, bob)

    # Bob loses his session with Alice's device.
    Agent.update(bob.store, fn s ->
      %{s | sessions: Map.delete(s.sessions, Address.new(@alice, 1))}
    end)

    {sent, alice} = send_text(alice, @bob, "lost")

    {events, bob} = SignalAccount.deliver(bob)

    assert [%Inbound{outcome: :failed, reason: :no_session}] =
             for(i <- SignalAccount.inbound(bob), i.outcome == :failed, do: i)

    assert {:decryption_failed, @alice, :unless_resent} in events

    # Alice gets the retry request, resets the session and resends the
    # kept content with its original timestamp in a new session.
    {events, alice} = SignalAccount.deliver(alice)
    assert [%Inbound{content_kind: :decryption_error}] = messages(events)

    {events, _bob} = SignalAccount.deliver(bob)
    assert [%Inbound{} = resent] = messages(events)
    assert resent.timestamp == sent.timestamp
    assert data(resent).data_message.body == "lost"
    assert MemoryStore.session(alice.store, Address.new(@bob, 1)).current.pending != nil
  end

  test "call messages go to call signaling after the commit", %{service: service, alice: alice} do
    test = SystemsRuntime.Proc.self()

    bob =
      SignalAccount.new(service, "00000000-0000-4000-8000-000000000003",
        call_message: &send(test, {:call, &1})
      )

    {{:ok, _}, _alice} =
      SignalAccount.run(
        alice,
        &Pipeline.send_call_message(&1, bob.aci, <<0x0A, 1, 2>>, %{urgent: true})
      )

    {events, _bob} = SignalAccount.deliver(bob)
    assert [%Inbound{content_kind: :call}] = messages(events)

    assert_received {:call,
                     %{
                       sender_aci: @alice,
                       sender_device_id: 1,
                       call_message: <<0x0A, 1, 2>>,
                       delivery_timestamp_ms: 1
                     }}
  end
end
