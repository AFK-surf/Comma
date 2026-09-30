defmodule SalixSignalProto.Group.StateTest do
  # Group state, changes, invite links and storage requests (CRS-09b). The
  # "server" here is a test server built from CRS-09a: it issues
  # credentials, fills ciphertexts into accepted changes and signs them with
  # its notary key, as CRS-09b sections 4.6 and 5.2 describe.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Group.{
    Change,
    InviteLink,
    Notary,
    Params,
    ProfileKey,
    ProfileKeyCredential,
    ServerParams,
    State,
    Storage,
    Uid,
    Wire
  }

  alias SalixSignalProto.Group.Wire.Actions, as: A

  @now 1_728_000_000
  @expiration @now + 3 * 86_400

  setup_all do
    secret = ServerParams.generate(:binary.copy(<<0x5A>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    group = Params.from_master_key(:binary.copy(<<0x11>>, 32))
    {:ok, secret: secret, server: server, group: group}
  end

  defp person(n), do: %{aci: <<n::128>>, profile_key: :crypto.hash(:sha256, <<n>>)}

  # An expiring profile key credential presentation for `person`, as the
  # chat server would issue it (CRS-09a section 14).
  defp presentation(%{secret: secret, server: server, group: group}, person) do
    {context, request} = ProfileKeyCredential.request(person.aci, person.profile_key)
    commitment = ProfileKey.commitment(person.profile_key, person.aci)

    {:ok, response} =
      ProfileKeyCredential.issue(secret, request, person.aci, commitment, @expiration, <<7::256>>)

    {:ok, credential, _} = ProfileKeyCredential.receive(server, context, response, @now)
    {:ok, {presentation, _, _}} = ProfileKeyCredential.present(server, group, credential)
    presentation
  end

  defp server_member(group, person, role, joined_at) do
    %Wire.Member{
      user_id: Uid.encrypt(group, {:aci, person.aci}),
      role: role,
      profile_key: ProfileKey.encrypt(group, person.profile_key, person.aci),
      joined_at_revision: joined_at
    }
  end

  # The server's side of an accepted change: it sets the editor and group
  # identifier and signs the action bytes.
  defp sign_change(%{secret: secret, group: group}, actions_bytes, editor) do
    {:ok, actions} = State.decode(A, actions_bytes)

    actions = %{
      actions
      | editor: Uid.encrypt(group, {:aci, editor.aci}),
        group_id: group.group_id
    }

    bytes = Protobuf.encode(actions)

    Protobuf.encode(%Wire.SignedChange{
      actions: bytes,
      server_signature: Notary.sign(secret, bytes),
      change_epoch: 0
    })
  end

  test "a server group state decrypts: attributes, access, members and profile keys", ctx do
    %{group: group} = ctx
    admin = person(1)
    member = person(2)
    invitee = person(3)

    wire = %Wire.Group{
      public_key: Params.public_params(group),
      title: State.encrypt_attribute(group, :title, "  Comma team \n"),
      description: State.encrypt_attribute(group, :description, "notes"),
      disappearing_timer: State.encrypt_attribute(group, :disappearing_timer, 3600),
      access_control: %Wire.AccessControl{attributes: 3, join_by_link: 1},
      revision: 4,
      members: [
        server_member(group, admin, 2, 0),
        # A member record in request form: only the presentation.
        %Wire.Member{role: 1, presentation: presentation(ctx, member), joined_at_revision: 3}
      ],
      invited_members: [
        %Wire.InvitedMember{
          member: %Wire.Member{user_id: Uid.encrypt(group, {:pni, invitee.aci}), role: 1},
          added_by: Uid.encrypt(group, {:aci, admin.aci}),
          timestamp: 99
        }
      ],
      invite_link_password: <<1::128>>
    }

    {:ok, state} = State.decrypt(group, Protobuf.encode(wire))

    assert state.revision == 4
    assert state.title == "Comma team"
    assert state.description == "notes"
    assert state.disappearing_timer == 3600
    assert state.access == %{attributes: 3, membership: 2, join_by_link: 1, member_labels: 2}
    assert State.member_service_ids(state) == [{:aci, admin.aci}, {:aci, member.aci}]
    assert Enum.map(state.members, & &1.profile_key) == [admin.profile_key, member.profile_key]
    assert Enum.map(state.members, & &1.role) == [2, 1]
    assert [%{service_id: {:pni, _}, role: 1, added_by_service_id: {:aci, _}}] = state.invited
    assert state.invite_link_password == <<1::128>>

    # Another group's state does not decrypt under these keys.
    other = Params.from_master_key(:binary.copy(<<0x22>>, 32))
    assert State.decrypt(other, wire) == {:error, :invalid}
  end

  test "blobs that do not decrypt read as unset", %{group: group} do
    other = Params.from_master_key(:binary.copy(<<0x33>>, 32))

    {:ok, state} =
      State.decrypt(group, %Wire.Group{
        title: State.encrypt_attribute(other, :title, "x"),
        revision: 1
      })

    assert state.title == nil
    assert state.access.join_by_link == 4
  end

  test "an admin's add-member change is signed by the server and applied by members", ctx do
    %{group: group, server: server} = ctx
    admin = person(1)
    newcomer = person(5)

    base = %Wire.Group{
      public_key: Params.public_params(group),
      revision: 7,
      members: [server_member(group, admin, 2, 0)]
    }

    {:ok, state} = State.decrypt(group, base)

    request = Change.build(8, [{:add_member, presentation(ctx, newcomer), 1}])
    signed = sign_change(ctx, request, admin)

    # What a member receives in the group context of the update message.
    context = Storage.encode_context(group, 8, signed)
    {:ok, %{master_key: key, revision: 8, change: ^signed}} = Storage.decode_context(context)
    assert key == group.master_key

    {:ok, change} = Change.verify_signed(server, group, signed)
    assert Change.editor(group, change.actions) == {:aci, admin.aci}
    {:ok, updated} = Change.apply_actions(state, group, change.actions, change.epoch)

    assert updated.revision == 8

    assert %{role: 1, profile_key: key, joined_at_revision: 8} =
             State.find_member(updated, group, {:aci, newcomer.aci})

    assert key == newcomer.profile_key

    # A change for another group, or altered action bytes, is not applied.
    other = Params.from_master_key(:binary.copy(<<0x44>>, 32))
    assert Change.verify_signed(server, other, signed) == {:error, :invalid}
    {:ok, %Wire.SignedChange{} = decoded} = State.decode(Wire.SignedChange, signed)
    tampered = Protobuf.encode(%{decoded | actions: decoded.actions <> <<0x10, 0x09>>})
    assert Change.verify_signed(server, group, tampered) == {:error, :invalid}
  end

  test "invitations, join requests, roles, bans and epochs follow CRS-09b section 6", ctx do
    %{group: group} = ctx
    admin = person(1)
    invitee = person(6)
    requester = person(7)
    uid = fn p -> Uid.encrypt(group, {:aci, p.aci}) end

    {:ok, state} =
      State.decrypt(group, %Wire.Group{revision: 1, members: [server_member(group, admin, 2, 0)]})

    apply! = fn state, operations, revision ->
      {:ok, actions} = State.decode(A, Change.build(revision, operations))
      {:ok, state} = Change.apply_actions(state, group, actions)
      state
    end

    # An admin invites with role 2; the invitee accepts with a presentation.
    state = apply!.(state, [{:add_invited_member, uid.(invitee), 2, uid.(admin)}], 2)
    assert [%{service_id: {:aci, _}, role: 2}] = state.invited
    state = apply!.(state, [{:accept_invitation, presentation(ctx, invitee)}], 3)
    assert state.invited == []

    assert %{role: 2, joined_at_revision: 3} =
             State.find_member(state, group, {:aci, invitee.aci})

    # A join request is approved as an ordinary member.
    state = apply!.(state, [{:add_requesting_member, presentation(ctx, requester)}], 4)
    assert [%{service_id: {:aci, _}}] = state.requesting
    state = apply!.(state, [{:approve_requesting_member, uid.(requester), 1}], 5)
    assert %{role: 1, profile_key: key} = State.find_member(state, group, {:aci, requester.aci})
    assert key == requester.profile_key

    # Removal, ban, title and link changes in one change.
    title = State.encrypt_attribute(group, :title, "Renamed")

    state =
      apply!.(
        state,
        [
          {:remove_member, uid.(requester)},
          {:ban, uid.(requester)},
          {:change_title, title},
          {:change_join_by_link_access, 3},
          {:change_link_password, <<9::128>>}
        ],
        6
      )

    refute State.find_member(state, group, {:aci, requester.aci})
    assert [%{service_id: {:aci, _}}] = state.banned
    assert state.title == "Renamed"
    assert state.access.join_by_link == 3
    assert state.invite_link_password == <<9::128>>

    # An empty title blob unsets the title.
    state = apply!.(state, [{:change_title, ""}], 7)
    assert state.title == nil

    # Changing the role of a non-member is an inconsistency: refetch the state.
    {:ok, actions} = State.decode(A, Change.build(8, [{:change_role, uid.(requester), 2}]))
    assert Change.apply_actions(state, group, actions) == {:error, :unknown_member}

    # A change epoch above 7 only advances the revision.
    {:ok, actions} = State.decode(A, Change.build(8, [{:remove_member, uid.(admin)}]))
    {:ok, skipped} = Change.apply_actions(state, group, actions, 8)
    assert skipped.revision == 8
    assert skipped.members == state.members
  end

  test "an approval of a requester this state does not list still adds the member", ctx do
    # CRS-09b section 6: approve requesting members adds a full member with
    # the given role. A state that missed the join request (for example a
    # full-state fetch between the request and the approval) must still
    # list the approved member.
    %{group: group} = ctx
    admin = person(1)
    requester = person(8)

    {:ok, state} =
      State.decrypt(group, %Wire.Group{revision: 3, members: [server_member(group, admin, 2, 0)]})

    assert state.requesting == []
    uid = Uid.encrypt(group, {:aci, requester.aci})
    {:ok, actions} = State.decode(A, Change.build(4, [{:approve_requesting_member, uid, 1}]))
    {:ok, state} = Change.apply_actions(state, group, actions)

    assert %{role: 1, joined_at_revision: 4, service_id: {:aci, aci}} =
             State.find_member(state, group, {:aci, requester.aci})

    assert aci == requester.aci
  end

  test "a member record with a presentation takes its ciphertexts from the presentation", ctx do
    # CRS-09b section 4.3: if field 4 is present, the UID and profile key
    # ciphertexts come from the presentation; fields 1 and 3 are used only
    # without it.
    %{group: group} = ctx
    member = person(9)
    other = person(10)
    stale = server_member(group, other, 1, 2)

    record = %Wire.Member{stale | presentation: presentation(ctx, member)}
    {:ok, state} = State.decrypt(group, %Wire.Group{revision: 2, members: [record]})

    assert State.member_service_ids(state) == [{:aci, member.aci}]
    assert [%{profile_key: key}] = state.members
    assert key == member.profile_key

    # The same rule holds for a join request in state and in changes.
    requesting = %Wire.RequestingMember{
      user_id: stale.user_id,
      profile_key: stale.profile_key,
      presentation: presentation(ctx, member)
    }

    {:ok, state} =
      State.decrypt(group, %Wire.Group{revision: 2, requesting_members: [requesting]})

    assert [%{service_id: {:aci, aci}}] = state.requesting
    assert aci == member.aci
  end

  test "a group context without a revision is invalid (CRS-05 section 5.7)", %{group: group} do
    without_revision = Protobuf.encode(%Wire.Context{master_key: group.master_key})
    assert Storage.decode_context(without_revision) == {:error, :invalid}

    with_zero = Storage.encode_context(group, 0)
    assert {:ok, %{revision: 0, change: nil}} = Storage.decode_context(with_zero)
  end

  describe "invite links (CRS-09b section 8)" do
    @example "https://signal.group/#CjQKIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fEhCgoaKjpKWmp6ipqqusra6v"

    test "the worked example builds and parses" do
      master_key = for i <- 0..31, into: <<>>, do: <<i>>
      password = for i <- 0xA0..0xAF, into: <<>>, do: <<i>>

      assert InviteLink.build(master_key, password) == @example
      assert InviteLink.parse(@example) == {:ok, {master_key, password}}
    end

    test "scheme, host case, path and base64 variants are accepted" do
      "https://signal.group/#" <> fragment = @example
      {:ok, expected} = InviteLink.parse(@example)
      standard = fragment |> Base.url_decode64!(padding: false) |> Base.encode64()

      for url <- [
            "sgnl://signal.group/#" <> fragment,
            "https://SIGNAL.GROUP/#" <> fragment,
            "https://signal.group#" <> fragment,
            "https://signal.group/#" <> standard
          ] do
        assert InviteLink.parse(url) == {:ok, expected}, url
      end
    end

    test "other hosts, paths and link versions are rejected" do
      "https://signal.group/#" <> fragment = @example
      assert InviteLink.parse("https://example.com/#" <> fragment) == {:error, :invalid}
      assert InviteLink.parse("https://signal.group/join#" <> fragment) == {:error, :invalid}
      assert InviteLink.parse("http://signal.group/#" <> fragment) == {:error, :invalid}
      unknown = Base.url_encode64(<<0x12, 0x02, 0x0A, 0x00>>, padding: false)
      assert InviteLink.parse("https://signal.group/#" <> unknown) == {:error, :unknown_version}
    end
  end

  test "storage authorization carries the public params and a fresh auth presentation", ctx do
    %{group: group, server: server, secret: secret} = ctx
    aci = <<1::128>>
    pni = <<2::128>>
    {today, last} = Storage.credential_range(@now + 500)
    assert {today, last} == {@now, @now + 7 * 86_400}

    body = %{
      "credentials" => [
        %{
          "credential" =>
            Base.encode64(
              SalixSignalProto.Group.AuthCredential.issue(secret, aci, pni, today, <<3::256>>)
            ),
          "redemptionTime" => today
        },
        # A credential for another account is dropped.
        %{
          "credential" =>
            Base.encode64(
              SalixSignalProto.Group.AuthCredential.issue(secret, pni, aci, last, <<4::256>>)
            ),
          "redemptionTime" => last
        }
      ],
      "pni" => "00000000-0000-0000-0000-000000000002"
    }

    {:ok, credentials} = Storage.receive_credentials(server, aci, body, nil)
    assert Map.keys(credentials) == [today]

    {:ok, "Basic " <> encoded} = Storage.authorize(server, group, credentials, @now + 500)
    [public_hex, presentation_hex] = encoded |> Base.decode64!() |> String.split(":")
    assert Base.decode16!(public_hex, case: :lower) == Params.public_params(group)
    presentation = Base.decode16!(presentation_hex, case: :lower)

    assert SalixSignalProto.Group.AuthCredential.verify(
             secret,
             Params.public_params(group),
             presentation,
             @now
           )

    assert Storage.authorize(server, group, credentials, @now + 86_400) ==
             {:error, :no_credential}
  end

  test "change log ranges parse" do
    assert Storage.content_range("versions 3-9/12") == {:ok, {3, 9, 12}}
    assert Storage.content_range("bytes 3-9/12") == :error
    assert Storage.content_range(nil) == :error
  end
end
