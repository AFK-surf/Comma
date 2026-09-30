defmodule SalixSignal.Account.GroupMembersTest do
  # Membership changes the Router asks for (CRS-09b sections 5.2, 7 and 9):
  # add a member with its profile key credential presentation or invite it,
  # remove members, and leave. The fake storage service
  # (test/support/fake_storage.ex) verifies presentations, enforces the
  # administrator rules, fills and signs accepted changes; the account
  # stores the resulting state and members receive the group update
  # message with the signed change through the mock message service.
  use ExUnit.Case, async: false

  alias SalixSignal.Account.GroupSync
  alias SalixSignal.Groups
  alias SalixSignal.Messaging.{GroupSend, Inbound, Pipeline}
  alias SalixSignal.Test.{FakeChat, FakeStorage, MockService, SignalAccount}
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.ServiceId

  alias SalixSignalProto.Group.{
    AuthCredential,
    Change,
    Params,
    ProfileKey,
    ProfileKeyCredential,
    ServerParams,
    State,
    Storage,
    Uid,
    Wire
  }

  @alice "00000000-0000-4000-8000-0000000000b1"
  @bob "00000000-0000-4000-8000-0000000000b2"
  @carol "00000000-0000-4000-8000-0000000000b3"
  @dave "00000000-0000-4000-8000-0000000000b4"
  @pni "00000000-0000-4000-8000-0000000000bf"

  setup_all do
    secret = ServerParams.generate(:binary.copy(<<0x2B>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    %{chain: FakeChat.chain(), secret: secret, server: server}
  end

  setup %{chain: chain, secret: secret, server: server} do
    now = System.system_time(:second)
    storage = start_supervised!({FakeStorage, {self(), secret, now}})
    storage_server = start_supervised!({Bandit, FakeStorage.bandit_options(storage, chain)})
    {:ok, service} = MockService.start_link()

    accounts =
      for aci <- [@alice, @bob, @carol],
          into: %{},
          do: {aci, SignalAccount.new(service, aci, store: :postgres)}

    # Alice is the group's administrator, Bob a member; Carol is not in it.
    params = Params.from_master_key(:crypto.strong_rand_bytes(32))

    FakeStorage.put_group(storage, params, %Wire.Group{
      title: State.encrypt_attribute(params, :title, "Crew"),
      revision: 5,
      access_control: %Wire.AccessControl{membership: 3, join_by_link: 4},
      members: [wire_member(params, @alice, 2, 0), wire_member(params, @bob, 1, 3)]
    })

    ctx = %{
      secret: secret,
      server: server,
      now: now,
      storage: storage,
      service: service,
      accounts: accounts,
      params: params,
      opts: [
        storage_url: "https://localhost:#{FakeChat.port(storage_server)}",
        http: [roots: [chain.root]]
      ]
    }

    # Each account stores the group as fetched from the storage service.
    accounts =
      Map.new(accounts, fn {aci, account} ->
        if aci == @carol do
          {aci, account}
        else
          {:ok, _group, pipeline} =
            GroupSync.refresh(account.pipeline, client(ctx, aci), server, params.master_key)

          {aci, %{account | pipeline: pipeline}}
        end
      end)

    Map.put(ctx, :accounts, accounts)
  end

  defp uuid(aci) do
    {:ok, uuid} = ServiceId.aci_from_string(aci)
    uuid
  end

  defp wire_member(params, aci, role, joined_at) do
    %Wire.Member{
      user_id: Uid.encrypt(params, {:aci, uuid(aci)}),
      role: role,
      profile_key: ProfileKey.encrypt(params, :binary.copy(<<role>>, 32), uuid(aci)),
      joined_at_revision: joined_at
    }
  end

  # Group auth credentials for today to today + 7 days (CRS-09b section 2),
  # as the chat service issues them.
  defp client(ctx, aci) do
    {first, last} = Storage.credential_range(ctx.now)

    entries =
      for day <- first..last//86_400 do
        response =
          AuthCredential.issue(
            ctx.secret,
            uuid(aci),
            uuid(@pni),
            day,
            :crypto.strong_rand_bytes(32)
          )

        %{"credential" => Base.encode64(response), "redemptionTime" => day}
      end

    {:ok, credentials} =
      Storage.receive_credentials(
        ctx.server,
        uuid(aci),
        %{"credentials" => entries, "pni" => @pni},
        nil
      )

    Groups.client(ctx.server, credentials, ctx.opts)
  end

  # The expiring profile key credential presentation of `aci` for the group
  # (CRS-09a section 14), as the adder builds it from that member's profile.
  defp presentation(ctx, aci) do
    key = :crypto.strong_rand_bytes(32)
    {context, request} = ProfileKeyCredential.request(uuid(aci), key)
    expiration = ctx.now - rem(ctx.now, 86_400) + 7 * 86_400

    {:ok, response} =
      ProfileKeyCredential.issue(
        ctx.secret,
        request,
        uuid(aci),
        ProfileKey.commitment(key, uuid(aci)),
        expiration,
        :crypto.strong_rand_bytes(32)
      )

    {:ok, credential, _} = ProfileKeyCredential.receive(ctx.server, context, response, ctx.now)
    {:ok, {presentation, _, _}} = ProfileKeyCredential.present(ctx.server, ctx.params, credential)
    presentation
  end

  for {kind, invited_id, operation} <- [
        {:aci, @carol, :accept_invitation},
        {:pni, @pni, :accept_pni_invitation}
      ] do
    test "accepts a pending #{kind} invitation and sends the membership update", ctx do
      account = ctx.accounts[@carol]

      pipeline = %{
        account.pipeline
        | account: Map.put(account.pipeline.account, :pni_uuid, uuid(@pni))
      }

      service_id = {unquote(kind), uuid(unquote(invited_id))}

      invite = %Wire.InvitedMember{
        member: %Wire.Member{user_id: Uid.encrypt(ctx.params, service_id), role: 1}
      }

      FakeStorage.put_group(ctx.storage, ctx.params, %Wire.Group{
        revision: 6,
        members: [wire_member(ctx.params, @alice, 2, 0)],
        invited_members: [invite]
      })

      {:ok, group, pipeline} =
        GroupSync.refresh(pipeline, client(ctx, @carol), ctx.server, ctx.params.master_key)

      assert GroupSync.invitation(pipeline, group.state) ==
               unquote(operation)

      assert {:error, :not_a_member} = GroupSend.member_group(pipeline, ctx.params.group_id)

      assert {:ok, accepted, pipeline} =
               GroupSync.accept_invitation(
                 pipeline,
                 client(ctx, @carol),
                 ctx.server,
                 group,
                 fn _ -> presentation(ctx, @carol) end
               )

      assert accepted.revision == 7
      assert accepted.state.invited == []
      assert {:aci, uuid(@carol)} in State.member_service_ids(accepted.state)
      assert {:ok, _} = GroupSend.member_group(pipeline, ctx.params.group_id)
      assert GroupSync.invitation(pipeline, accepted.state) == nil
      assert {:ok, %{state: remote}} = Groups.get_group(client(ctx, @carol), ctx.params)
      assert {:aci, uuid(@carol)} in State.member_service_ids(remote)
      assert updates(ctx, @alice) == [7]
    end
  end

  defp change(ctx, aci, change) do
    account = ctx.accounts[aci]

    GroupSync.change_members(
      account.pipeline,
      client(ctx, aci),
      ctx.server,
      ctx.params.group_id,
      change
    )
  end

  defp stored(ctx, aci),
    do: Pipeline.read(ctx.accounts[aci].pipeline, :group, [ctx.params.group_id])

  defp service_ids(%State{members: members}), do: Enum.map(members, & &1.service_id)

  # The group update messages an account received: the revision and the
  # signed change, which verifies with the notary key.
  defp updates(ctx, aci) do
    {events, _account} = SignalAccount.deliver(ctx.accounts[aci])

    for {:message, %Inbound{content_kind: :data, content: content}} <- events,
        {:ok, :data, wire} = Content.decode(content),
        %{group_v2: %{group_change: signed} = context} = wire.data_message,
        is_binary(signed) do
      assert {:ok, _change} = Change.verify_signed(ctx.server, ctx.params, signed)
      context.revision
    end
  end

  test "an administrator adds a member with a presentation and invites one without", ctx do
    assert {:ok, 6, _pipeline} =
             change(ctx, @alice, {:add, [{@carol, presentation(ctx, @carol)}, {@bob, nil}]})

    group = stored(ctx, @alice)
    assert group.revision == 6
    assert {:aci, uuid(@carol)} in service_ids(group.state)

    assert %{role: 1, joined_at_revision: 6} =
             State.find_member(group.state, ctx.params, {:aci, uuid(@carol)})

    # Bob is already a member: no invitation for him. Bob and Carol get the
    # update with the signed change.
    assert group.state.invited == []
    assert updates(ctx, @bob) == [6]
    assert updates(ctx, @carol) == [6]

    # Dave has no profile key here: he is invited, added by Alice.
    assert {:ok, 7, _pipeline} = change(ctx, @alice, {:add, [{@dave, nil}]})
    group = stored(ctx, @alice)
    alice_uid = Uid.encrypt(ctx.params, {:aci, uuid(@alice)})

    assert [%{service_id: {:aci, dave}, role: 1, added_by: ^alice_uid}] = group.state.invited
    assert dave == uuid(@dave)
    assert length(FakeStorage.group(ctx.storage, ctx.params).invited_members) == 1
  end

  test "a change that is already done sends no request", ctx do
    assert {:ok, 5, _pipeline} = change(ctx, @alice, {:add, [{@bob, presentation(ctx, @bob)}]})
    assert {:ok, 5, _pipeline} = change(ctx, @alice, {:remove, [@carol]})
    refute_received {:fake_storage, "PATCH", _}
  end

  test "an administrator removes a member; a member who is not one is refused", ctx do
    assert {:error, :forbidden, _pipeline} = change(ctx, @bob, {:remove, [@alice]})
    assert FakeStorage.group(ctx.storage, ctx.params).revision == 5
    assert stored(ctx, @bob).revision == 5

    assert {:ok, 6, _pipeline} = change(ctx, @alice, {:remove, [@bob]})
    refute {:aci, uuid(@bob)} in service_ids(stored(ctx, @alice).state)
    assert length(FakeStorage.group(ctx.storage, ctx.params).members) == 1
  end

  # CRS-09b section 7: the last administrator promotes others in the same
  # change before it removes itself.
  test "leaving as the last administrator promotes the earliest member first", ctx do
    assert {:ok, 6, pipeline} = change(ctx, @alice, :leave)

    assert [%Wire.Member{role: 2} = bob] = FakeStorage.group(ctx.storage, ctx.params).members
    assert bob.user_id == Uid.encrypt(ctx.params, {:aci, uuid(@bob)})

    # The account keeps the group but is no longer a member of it.
    refute {:aci, uuid(@alice)} in service_ids(stored(ctx, @alice).state)
    assert GroupSend.member_group(pipeline, ctx.params.group_id) == {:error, :not_a_member}

    assert {:error, :not_a_member, _pipeline} = change(ctx, @alice, {:remove, [@bob]})
    assert updates(ctx, @bob) == [6]
  end
end
