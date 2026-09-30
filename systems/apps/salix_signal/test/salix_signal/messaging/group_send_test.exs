defmodule SalixSignal.Messaging.GroupSendTest do
  # Group sends and sender-key receiving over the Postgres store with a
  # clean mock of the message service (CRS-09c sections 5 to 7, CRS-06
  # §10.2, CRS-07 §3.3 and §4, CRS-09a section 15): the distribution
  # message goes 1:1 once per device, the content once for every device
  # with a group send token for exactly the recipients, receivers decrypt
  # with the stored sender key, and a new device of a member gets the
  # distribution message after the 409 correction.
  use ExUnit.Case, async: false

  alias SalixSignal.Account.{GroupCalls, GroupSync}
  alias SalixSignal.Messaging.{GroupSend, Inbound, Pipeline}
  alias SalixSignal.Storage
  alias SalixSignal.Test.{MockService, SignalAccount}
  alias SalixSignalProto.PreKeys
  alias SalixSignalProto.Group.{Change, Endorsements, Notary, Params, ServerParams, State, Uid}
  alias SalixSignalProto.Message.Content

  @alice "00000000-0000-4000-8000-000000000091"
  @bob "00000000-0000-4000-8000-000000000092"
  @carol "00000000-0000-4000-8000-000000000093"
  @master_key :binary.copy(<<0x91>>, 32)

  setup_all do
    secret = ServerParams.generate(:binary.copy(<<0x19>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    %{secret: secret, server: server}
  end

  setup %{secret: secret, server: server} do
    now_s = System.system_time(:second)

    {:ok, service} =
      MockService.start_link(
        group_send_verifier: fn token, ids ->
          Endorsements.verify_full_token(token, ids, secret, now_s)
        end
      )

    accounts =
      for aci <- [@alice, @bob, @carol],
          into: %{},
          do: {aci, SignalAccount.new(service, aci, store: :postgres)}

    params = Params.from_master_key(@master_key)
    members = for aci <- [@alice, @bob, @carol], do: service_id(aci)
    endorsements = endorsements(secret, server, params, members, now_s)

    state = %State{
      revision: 3,
      title: "Team",
      members:
        for id <- members do
          %{
            uid: Uid.encrypt(params, id),
            service_id: id,
            role: 1,
            profile_key: nil,
            joined_at_revision: 0,
            label_emoji: nil,
            label_text: nil
          }
        end
    }

    group = %{
      master_key: @master_key,
      revision: 3,
      state: state,
      endorsements: endorsements,
      sending: nil
    }

    for {_aci, account} <- accounts do
      :ok = Pipeline.write(account.pipeline, [{:put_group, params.group_id, group}])
    end

    %{service: service, accounts: accounts, group_id: params.group_id}
  end

  defp service_id(aci) do
    {:ok, uuid} = SalixSignalProto.ServiceId.aci_from_string(aci)
    {:aci, uuid}
  end

  # The server issues endorsements for the members (CRS-09a section 15.3)
  # and every member receives them (section 15.4).
  defp endorsements(secret, server, params, members, now_s) do
    expiration = div(now_s, 86_400) * 86_400 + 2 * 86_400
    ciphertexts = Enum.map(members, &Uid.encrypt(params, &1))

    response =
      Endorsements.issue(
        ciphertexts,
        Endorsements.key_pair(secret, expiration),
        :crypto.strong_rand_bytes(32)
      )

    {:ok, %{endorsements: list, expiration: ^expiration}} =
      Endorsements.receive(server, params, response, members, hd(members), now_s)

    %{expiration: expiration, by_member: Map.new(Enum.zip(members, list))}
  end

  defp group_text(alice, group_id, body) do
    {{:ok, info}, alice} =
      SignalAccount.run(alice, &GroupSend.send_text(&1, group_id, body))

    {info, alice}
  end

  defp messages(events), do: for({:message, %Inbound{} = inbound} <- events, do: inbound)

  defp data(%Inbound{content: content}) do
    {:ok, _kind, wire} = Content.decode(content)
    wire.data_message
  end

  test "the distribution message goes once per device; the content once, sealed with the sender key",
       %{service: service, accounts: accounts, group_id: group_id} do
    alice = accounts[@alice]
    {info, alice} = group_text(alice, group_id, "hello team")

    assert Enum.sort(info.sender_key) == [@bob, @carol]
    assert Enum.sort(info.recipients) == [@bob, @carol]
    assert info.failed == [] and info.unregistered == []

    multi =
      for {:unidentified, "PUT", "/v1/messages/multi_recipient?" <> _, _} = r <-
            MockService.requests(service),
          do: r

    assert [{_, _, path, opts}] = multi
    assert path =~ "ts=#{info.timestamp}&online=false&urgent=true&story=false"
    assert {"content-type", "application/vnd.signal-messenger.mrm"} in opts[:headers]

    for aci <- [@bob, @carol] do
      {events, _account} = SignalAccount.deliver(accounts[aci])

      assert Enum.any?(events, &match?({:sender_key_received, @alice, 1, _}, &1))
      [distribution, group_message] = messages(events)
      assert distribution.content_kind == nil

      assert %Inbound{sender: @alice, sealed?: true, content_kind: :data, group_id: ^group_id} =
               group_message

      assert data(group_message).body == "hello team"
      assert data(group_message).group_v2.master_key == @master_key
      assert data(group_message).group_v2.revision == 3
      # The stored group is at this revision already: no refresh needed.
      refute Enum.any?(events, &match?({:group_seen, _, _, _}, &1))
    end

    # The second message needs no distribution: one envelope per member.
    {_info, _alice} = group_text(alice, group_id, "second")

    for aci <- [@bob, @carol] do
      assert [{_guid, _bytes}] = MockService.queued(service, aci, 1)
      {events, _account} = SignalAccount.deliver(accounts[aci])
      assert ["second"] = for(m <- messages(events), do: data(m).body)
    end
  end

  test "a replayed sender-key message is dropped as a duplicate", %{
    service: service,
    accounts: accounts,
    group_id: group_id
  } do
    {_info, _alice} = group_text(accounts[@alice], group_id, "once")
    bob = accounts[@bob]
    queued = MockService.queued(service, @bob, 1)
    {events, bob} = SignalAccount.deliver(bob, ack: false)
    assert ["once"] = for(m <- messages(events), m.content_kind == :data, do: data(m).body)

    # Same envelopes again: the GUIDs were admitted.
    {events, _bob} = SignalAccount.deliver(bob)
    assert length(for {:redelivered, _} <- events, do: :ok) == length(queued)
  end

  test "a new device of a member gets the distribution message after the 409 correction", %{
    service: service,
    accounts: accounts,
    group_id: group_id
  } do
    alice = accounts[@alice]
    {_info, alice} = group_text(alice, group_id, "before")

    # Carol links a second device.
    carol = accounts[@carol]
    now = System.system_time(:millisecond)
    pre_keys = PreKeys.Store.new(carol.identity, now)

    body =
      PreKeys.upload_body(
        signed_pre_key: PreKeys.Store.current_signed(pre_keys),
        last_resort_pre_key: PreKeys.Store.current_last_resort(pre_keys),
        pre_keys: [PreKeys.one_time_pre_key(1, now)]
      )

    MockService.register(service, @carol, 2, 4242, carol.identity.public, body)

    {info, _alice} = group_text(alice, group_id, "after")
    assert Enum.sort(info.sender_key) == [@bob, @carol]

    # Device 2 got the distribution message and the group message. A 1:1
    # send lists every device of an account (CRS-07 §4), so device 1 got
    # the distribution message again; the same chain changes nothing there.
    assert [_distribution, _group_message] = MockService.queued(service, @carol, 2)
    assert length(MockService.queued(service, @carol, 1)) == 4

    {events, _carol} = SignalAccount.deliver(carol)

    assert ["before", "after"] =
             for(m <- messages(events), m.content_kind == :data, do: data(m).body)
  end

  # CRS-07 §4: after 410 (and 409) every affected device is treated as not
  # holding this sender's sender key. The correction here happens in a 1:1
  # send, so the group's own state still lists the old device as served.
  test "a device that a 1:1 send finds re-registered gets the distribution message again", %{
    service: service,
    accounts: accounts,
    group_id: group_id
  } do
    alice = accounts[@alice]
    {_info, alice} = group_text(alice, group_id, "before")
    {_events, carol} = SignalAccount.deliver(accounts[@carol])

    # Carol reinstalls device 1: a new registration ID, new pre-keys and
    # no stored sender keys.
    carol =
      SignalAccount.new(service, @carol,
        store: :postgres,
        identity: carol.identity,
        profile_key: carol.profile_key,
        registration_id: carol.registration_id + 1
      )

    # A 1:1 send meets 410 for device 1 and builds a new session.
    {{:ok, _info}, alice} = SignalAccount.run(alice, &Pipeline.send_text(&1, @carol, "direct"))
    {info, _alice} = group_text(alice, group_id, "after")
    assert @carol in info.sender_key

    {events, _carol} = SignalAccount.deliver(carol)

    assert ["direct", "after"] =
             for(m <- messages(events), m.content_kind == :data, do: data(m).body)
  end

  test "an unknown group is refused; a newer revision in a message asks for a refresh", %{
    accounts: accounts,
    group_id: group_id
  } do
    alice = accounts[@alice]

    assert {{:error, :unknown_group}, alice} =
             SignalAccount.run(alice, &GroupSend.send_text(&1, :binary.copy(<<1>>, 32), "x"))

    # Bob's stored group is older than the revision in Alice's message.
    bob = accounts[@bob]
    group = Pipeline.read(bob.pipeline, :group, [group_id])
    :ok = Pipeline.write(bob.pipeline, [{:put_group, group_id, %{group | revision: 2}}])

    {_info, _alice} = group_text(alice, group_id, "newer")
    {events, _bob} = SignalAccount.deliver(bob)
    assert {:group_seen, @master_key, 3, nil} in events

    # The own sender key is durable: another owner continues the chain.
    assert %{sending: %{record: _}} = Storage.group(alice.account_id, group_id)
  end

  test "a change carried in a group message is applied only as the next revision", %{
    accounts: accounts,
    group_id: group_id,
    secret: secret,
    server: server
  } do
    bob = accounts[@bob]
    params = Params.from_master_key(@master_key)

    signed = fn revision, gid, sign? ->
      actions =
        Change.build(revision, [
          {:change_title, State.encrypt_attribute(params, :title, "Renamed")}
        ])

      {:ok, decoded} = State.decode(SalixSignalProto.Group.Wire.Actions, actions)
      bytes = Protobuf.encode(%{decoded | group_id: gid})
      signature = if sign?, do: Notary.sign(secret, bytes), else: :binary.copy(<<0>>, 64)

      Protobuf.encode(%SalixSignalProto.Group.Wire.SignedChange{
        actions: bytes,
        server_signature: signature
      })
    end

    apply = fn revision, change ->
      GroupSync.apply_change(bob.pipeline, server, @master_key, revision, change)
    end

    # The stored revision is 3. A gap, a context revision that differs
    # from the change, another group, a bad signature and a missing change
    # all mean a full fetch instead.
    assert :not_applicable = apply.(5, signed.(5, group_id, true))
    assert :not_applicable = apply.(4, signed.(5, group_id, true))
    assert :not_applicable = apply.(4, signed.(4, :binary.copy(<<9>>, 32), true))
    assert :not_applicable = apply.(4, signed.(4, group_id, false))
    assert :not_applicable = apply.(4, nil)
    assert %{revision: 3} = Storage.group(bob.account_id, group_id)

    assert {:ok, %{revision: 4, state: %State{title: "Renamed"}}, _pipeline} =
             apply.(4, signed.(4, group_id, true))

    assert %{revision: 4, state: %State{title: "Renamed"}} =
             Storage.group(bob.account_id, group_id)
  end

  defp decoded(%Inbound{content: content}) do
    {:ok, kind, wire} = Content.decode(content)
    {kind, wire}
  end

  defp multi_requests(service) do
    for {:unidentified, "PUT", "/v1/messages/multi_recipient?" <> query, _} <-
          MockService.requests(service),
        do: URI.decode_query(query)
  end

  # CRS-05 sections 5.5, 5.8 and 6.2; CRS-07 §8; CRS-09b section 9: every
  # message this account sends to a group names the group, and typing is
  # online and not urgent.
  test "group reactions, edits, deletes and typing reach every member with the group", %{
    service: service,
    accounts: accounts,
    group_id: group_id
  } do
    alice = accounts[@alice]
    {:ok, bob_uuid} = SalixSignalProto.ServiceId.aci_from_string(@bob)
    {text, alice} = group_text(alice, group_id, "original")
    run = fn account, fun -> SignalAccount.run(account, fun) end

    {{:ok, _}, alice} = run.(alice, &GroupSend.send_reaction(&1, group_id, "👍", @bob, 1234))
    {{:ok, _}, alice} = run.(alice, &GroupSend.send_edit(&1, group_id, text.timestamp, "edited"))
    {{:ok, _}, alice} = run.(alice, &GroupSend.send_remote_delete(&1, group_id, text.timestamp))
    {{:ok, typing}, alice} = run.(alice, &GroupSend.send_typing(&1, group_id, :started))

    # A malformed target author is refused before anything is sent.
    requests = length(MockService.requests(service))

    assert {{:error, :invalid_author}, _alice} =
             run.(alice, &GroupSend.send_reaction(&1, group_id, "x", "not-an-aci", 1))

    assert length(MockService.requests(service)) == requests

    assert %{"online" => "true", "urgent" => "false"} =
             Enum.find(multi_requests(service), &(&1["ts"] == "#{typing.timestamp}"))

    for aci <- [@bob, @carol] do
      {events, _account} = SignalAccount.deliver(accounts[aci])

      assert [
               {:data, %{data_message: original}},
               {:data, %{data_message: reaction}},
               {:edit, %{edit_message: edit}},
               {:data, %{data_message: delete}},
               {:typing, %{typing_message: typing_message}}
             ] =
               for(m <- messages(events), m.content_kind != nil, do: decoded(m))

      for data <- [original, reaction, edit.data_message, delete],
          do: assert(data.group_v2.master_key == @master_key)

      assert %{emoji: "👍", target_author_aci: ^bob_uuid, target_message_timestamp: 1234} =
               reaction.reaction

      assert edit.original_message_timestamp == text.timestamp
      assert edit.data_message.body == "edited"
      assert delete.remote_delete.target_message_timestamp == text.timestamp
      assert %{group_id: ^group_id, action: 0} = typing_message
    end
  end

  test "a group this account has left takes no member messages", %{
    accounts: accounts,
    group_id: group_id
  } do
    alice = accounts[@alice]
    group = Pipeline.read(alice.pipeline, :group, [group_id])
    {:ok, alice_uuid} = SalixSignalProto.ServiceId.aci_from_string(@alice)
    members = Enum.reject(group.state.members, &(&1.service_id == {:aci, alice_uuid}))

    :ok =
      Pipeline.write(alice.pipeline, [
        {:put_group, group_id, %{group | state: %{group.state | members: members}}}
      ])

    assert {{:error, :not_a_member}, _alice} =
             SignalAccount.run(alice, &GroupSend.send_text(&1, group_id, "still here?"))
  end

  # CRS-14 section 9.2: a media key for more than one other account goes as
  # one group message to exactly those members; for one account it goes
  # 1:1. The own account is sent to only when it has other devices (CRS-07
  # §3.1 and §3.2: its list leaves out this device, and an empty list is
  # refused).
  test "group-call messages: one group message for several accounts, 1:1 for one", %{
    service: service,
    accounts: accounts,
    group_id: group_id
  } do
    alice = accounts[@alice]
    call_message = <<0x0A, 0x03, "key">>

    {{:ok, info}, alice} =
      SignalAccount.run(
        alice,
        &GroupCalls.send_call_message(&1, group_id, [@alice, @bob, @carol], call_message, false)
      )

    assert Enum.sort(info.recipients) == [@bob, @carol]
    assert info.own_devices == []
    [multi] = multi_requests(service)
    assert multi["urgent"] == "false"

    {{:ok, info}, _alice} =
      SignalAccount.run(
        alice,
        &GroupCalls.send_call_message(&1, group_id, [@carol], call_message, false)
      )

    assert info.recipients == [@carol]
    assert length(multi_requests(service)) == 1

    refute Enum.any?(MockService.requests(service), fn {_as, method, path, _opts} ->
             method == "PUT" and path == "/v1/messages/" <> @alice
           end)

    {events, _bob} = SignalAccount.deliver(accounts[@bob])

    assert [{:call, %{call_message: ^call_message}}] =
             for(m <- messages(events), m.content_kind == :call, do: decoded(m))

    {events, _carol} = SignalAccount.deliver(accounts[@carol])

    assert [{:call, _}, {:call, _}] =
             for(m <- messages(events), m.content_kind == :call, do: decoded(m))

    assert {:ok, members} = GroupCalls.members(alice.account_id, group_id)
    assert Enum.sort(Enum.map(members, & &1.aci)) == [@alice, @bob, @carol]
    assert Enum.all?(members, &(byte_size(&1.member_id) == 65))
  end

  test "the group-call update names the era in an urgent group message", %{
    service: service,
    accounts: accounts,
    group_id: group_id
  } do
    {{:ok, info}, _alice} =
      SignalAccount.run(accounts[@alice], &GroupSend.send_call_update(&1, group_id, "era-1"))

    assert %{"urgent" => "true"} =
             Enum.find(multi_requests(service), &(&1["ts"] == "#{info.timestamp}"))

    {events, _bob} = SignalAccount.deliver(accounts[@bob])

    assert [{:data, %{data_message: data}}] =
             for(m <- messages(events), m.content_kind == :data, do: decoded(m))

    assert data.group_call_update.era_id == "era-1"
    assert data.group_v2.master_key == @master_key
  end
end
