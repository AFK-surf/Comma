defmodule SalixSignal.Account.OperationsTest do
  # The account operations the product layer uses (C12c), end to end
  # through the owner process: chat requests on a real socket to the fake
  # chat service (CRS-01), messages through the mock message service
  # (CRS-07), uploads to the fake CDN (CRS-10), groups on the fake storage
  # service (CRS-09b) and a group call on the fake calling server (CRS-14).
  use ExUnit.Case, async: false

  alias SalixSignal.{Account, Accounts, Attachments}
  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Test.{FakeCdn, FakeChat, FakeSfu, FakeStorage, MockService, SignalAccount}
  alias SalixSignalProto.Attachment.Pointer
  alias SalixSignalProto.GroupCall, as: GroupCallProto
  alias SalixSignalProto.GroupCall.Messages
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.{CallSignaling, Profile, ServiceId}

  alias SalixSignalProto.Group.{
    AuthCredential,
    Params,
    ProfileKey,
    ProfileKeyCredential,
    ServerParams,
    State,
    Uid,
    Wire
  }

  alias SalixSignalProto.Service.Frame

  @alice "00000000-0000-4000-8000-0000000000c1"
  @bob "00000000-0000-4000-8000-0000000000c2"
  @pni "00000000-0000-4000-8000-0000000000cf"
  @alice_demux 0x20

  # Upper bounds on a loaded machine; each wait ends when its message arrives.
  @connect_ms 30_000
  @wait_ms 30_000

  defmodule Handler do
    @moduledoc false
    # Forwards to the test process. Mode `:block` waits for `:release`;
    # mode `:reply` answers the sender through the same account.
    @behaviour SalixSignal.Account.Handler

    def handle_inbound(account_id, seq, inbound) do
      test = :persistent_term.get({__MODULE__, :test})
      send(test, {:handler_inbound, account_id, seq, inbound})

      case :persistent_term.get({__MODULE__, :mode}, :normal) do
        :block ->
          send(test, {:handler_blocked, self()})

          receive do
            :release -> :ok
          after
            20_000 -> {:error, :not_released}
          end

        :reply when inbound.content_kind == :data ->
          reply = SalixSignal.Account.send_text(account_id, inbound.sender, "echo")
          send(test, {:handler_replied, reply})
          :ok

        _mode ->
          :ok
      end
    end

    def incoming_call(_account_id, _info), do: :needs_permission
    def admit_call(_account_id, _info, _connection), do: {:error, :not_bound}

    def handle_event(account_id, event),
      do: send(:persistent_term.get({__MODULE__, :test}), {:handler_event, account_id, event})
  end

  setup_all do
    secret = ServerParams.generate(:binary.copy(<<0x3C>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    %{chain: FakeChat.chain(), secret: secret, server: server}
  end

  setup %{chain: chain, secret: secret, server: server} do
    :persistent_term.put({Handler, :test}, self())
    :persistent_term.put({Handler, :mode}, :normal)
    {:ok, upgrades} = Agent.start_link(fn -> [] end)

    chat_server =
      start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)}, id: :chat)

    cdn = start_supervised!({FakeCdn, self()})
    cdn_server = start_supervised!({Bandit, FakeCdn.bandit_options(cdn, chain)}, id: :cdn)
    now = System.system_time(:second)
    storage = start_supervised!({FakeStorage, {self(), secret, now}})

    storage_server =
      start_supervised!({Bandit, FakeStorage.bandit_options(storage, chain)}, id: :storage)

    {:ok, service} = MockService.start_link()
    alice = SignalAccount.new(service, @alice)
    bob = SignalAccount.new(service, @bob, store: :postgres)
    id = bob.account_id
    cdn_url = "https://localhost:#{FakeChat.port(cdn_server)}"

    opts = [
      handler: Handler,
      chat: [
        host: "localhost",
        port: FakeChat.port(chat_server),
        roots: [chain.root],
        backoff: [base_ms: 10, max_ms: 40]
      ],
      transport: %{
        identified: MockService.transport(service, {:identified, @bob, 1}),
        unidentified: MockService.transport(service, :unidentified)
      },
      pipeline: [trust_roots: [MockService.trust_root(service)], known_server_certificates: %{}],
      attachments: [http: [trust: :signal, roots: [chain.root]]],
      server_params: server,
      groups: [
        storage_url: "https://localhost:#{FakeChat.port(storage_server)}",
        http: [roots: [chain.root]]
      ],
      maintenance_interval_ms: 3_600_000,
      delivery_retry_ms: 50
    ]

    %{
      id: id,
      opts: opts,
      service: service,
      alice: alice,
      bob: bob,
      cdn: cdn,
      cdn_url: cdn_url,
      storage: storage,
      now: now,
      secret: secret,
      server: server,
      chain: chain
    }
  end

  defp start_owner(%{id: id, opts: opts} = ctx, extra \\ []) do
    {:ok, pid} = Accounts.start_local(id, opts ++ extra)
    on_exit(fn -> Accounts.stop_local(id) end)
    assert_receive {:fake_chat, :connected, socket}, @connect_ms
    # The owner has seen its chat socket connect (chat requests need it).
    assert eventually(fn -> if :sys.get_state(pid).maintained?, do: true end)
    Map.merge(ctx, %{pid: pid, socket: socket})
  end

  defp push_queued(%{socket: socket, service: service}, first_id) do
    service
    |> MockService.queued(@bob, 1)
    |> Enum.with_index(first_id)
    |> Enum.each(fn {{_guid, bytes}, id} ->
      request = %Frame.Request{
        verb: "PUT",
        path: "/api/v1/message",
        id: id,
        body: bytes,
        headers: [{"X-Signal-Timestamp", "1758790000500"}]
      }

      send(socket, {:send, Frame.encode_request(request)})
    end)
  end

  defp alice_sends(alice, text) do
    {{:ok, _info}, alice} = SignalAccount.run(alice, &Pipeline.send_text(&1, @bob, text))
    alice
  end

  defp received(alice, kind) do
    {events, _alice} = SignalAccount.deliver(alice)

    for {:message, %Inbound{content_kind: ^kind, content: content}} <- events do
      {:ok, ^kind, wire} = Content.decode(content)
      wire
    end
  end

  # A chat request of the owner, answered with `status` and a JSON body.
  defp answer_request(socket, prefix, status, body) do
    request = receive_request(socket, prefix)
    respond(socket, request, status, body)
    request
  end

  # The next chat request of the owner whose path starts with `prefix`.
  defp receive_request(socket, prefix) do
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: path} = request}
                   when binary_part(path, 0, min(byte_size(path), byte_size(prefix))) == prefix,
                   @wait_ms

    request
  end

  # CRS-10 section 3: a TUS upload form on the fake CDN.
  defp form(ctx, key) do
    %{
      "cdn" => 3,
      "key" => key,
      "headers" => %{"Upload-Metadata" => "filename " <> Base.encode64(key)},
      "signedUploadLocation" => ctx.cdn_url <> "/tus/attachments"
    }
  end

  defp answer_form(ctx, key),
    do: answer_request(ctx.socket, "/v4/attachments/form/upload", 200, form(ctx, key))

  defp respond(socket, request, status, body) do
    response = %Frame.Response{id: request.id, status: status, body: Jason.encode!(body)}
    send(socket, {:send, Frame.encode_response(response)})
  end

  defp download(ctx, pointer) do
    Attachments.download(pointer,
      http: [trust: :signal, roots: [ctx.chain.root]],
      base_urls: %{3 => ctx.cdn_url}
    )
  end

  test "handler delivery runs outside the owner: sends go on while it blocks, and it may send",
       ctx do
    ctx = start_owner(ctx)
    :persistent_term.put({Handler, :mode}, :block)
    alice = alice_sends(ctx.alice, "slow")
    push_queued(ctx, 10)

    assert_receive {:handler_inbound, _id, slow, %Inbound{content_kind: :data}}, @wait_ms
    assert_receive {:handler_blocked, delivery}, @wait_ms
    assert {:ok, %{timestamp: _}} = Account.send_text(ctx.id, @alice, "meanwhile")
    assert [%{data_message: %{body: "meanwhile"}}] = received(alice, :data)

    # The cursor moves past the item once the handler accepts it.
    :persistent_term.put({Handler, :mode}, :reply)
    send(delivery, :release)
    assert :sys.get_state(delivery).delivered >= slow

    # A handler that sends on its own account does not wait for itself.
    alice = alice_sends(alice, "ping")
    push_queued(ctx, 20)
    assert_receive {:handler_replied, {:ok, %{timestamp: _}}}, @wait_ms
    assert [%{data_message: %{body: "echo"}}] = received(alice, :data)
  end

  test "an attachment uploads in the caller over the owner's chat and sends as a pointer", ctx do
    ctx = start_owner(ctx)
    data = :crypto.strong_rand_bytes(3_000)

    upload =
      Task.async(fn ->
        Account.upload_attachment(ctx.id, data, content_type: "image/png", file_name: "a.png")
      end)

    # While the upload waits for its form, the owner answers other requests.
    assert_receive {:fake_chat, :frame, socket,
                    %Frame.Request{path: "/v4/attachments/" <> _} = request},
                   @wait_ms

    assert {:ok, _} = Account.send_text(ctx.id, @alice, "while uploading")
    respond(socket, request, 200, form(ctx, "upload-key-1"))

    assert {:ok, %Pointer{content_type: "image/png", file_name: "a.png"} = pointer} =
             Task.await(upload, @wait_ms)

    assert {:ok, _} = Account.send_text(ctx.id, @alice, "a file", attachments: [pointer])

    assert [_while, %{data_message: %{body: "a file", attachments: [received]}}] =
             received(ctx.alice, :data)

    assert download(ctx, received) == {:ok, data}
  end

  # CRS-05 section 5: a body holds at most 2,048 bytes; longer text is a
  # `text/x-signal-plain` attachment with a truncated body.
  test "long text goes as a long-text attachment with a truncated body", ctx do
    ctx = start_owner(ctx)
    long = String.duplicate("ä", 1_500) <> String.duplicate("x", 3_000)

    sent = Task.async(fn -> Account.send_text(ctx.id, @alice, long) end)
    answer_form(ctx, "long-text-1")
    assert {:ok, %{timestamp: _}} = Task.await(sent, @wait_ms)

    assert [%{data_message: %{body: body, attachments: [pointer]}}] = received(ctx.alice, :data)
    assert byte_size(body) == 2_048
    assert String.starts_with?(long, body)
    assert pointer.content_type == "text/x-signal-plain"
    assert download(ctx, pointer) == {:ok, long}

    # A text at the limit is sent inline.
    inline = String.duplicate("y", 2_048)
    assert {:ok, _} = Account.send_text(ctx.id, @alice, inline)
    assert [%{data_message: %{body: ^inline, attachments: []}}] = received(ctx.alice, :data)
  end

  test "a reaction to a malformed author is refused and the owner keeps running", ctx do
    ctx = start_owner(ctx)

    assert Account.send_reaction(ctx.id, @alice, "👍", "not-an-aci", 1) ==
             {:error, :invalid_author}

    assert Account.send_group_reaction(ctx.id, :binary.copy(<<4>>, 32), "👍", "nope", 1) ==
             {:error, :invalid_author}

    assert Process.alive?(ctx.pid)
    assert {:ok, _} = Account.send_reaction(ctx.id, @alice, "👍", @alice, 1)
  end

  # CRS-08: the profile of a sender whose profile key is new is read off
  # the owner process; the name is stored with the contact.
  test "a new profile key makes the owner read the profile name; profile_name reads it", ctx do
    ctx = start_owner(ctx)
    assert Account.profile_name(ctx.id, @alice) == {:ok, nil}

    _alice = alice_sends(ctx.alice, "hello")
    push_queued(ctx, 30)
    assert_receive {:handler_event, _id, {:profile_key_changed, @alice}}, @wait_ms

    {:ok, uuid} = ServiceId.aci_from_string(@alice)
    version = Profile.version(ctx.alice.profile_key, uuid)
    {:ok, name} = Profile.encrypt_name(ctx.alice.profile_key, "Alice", "Liddell")

    # The fetch is pending; the owner still answers.
    assert {:ok, _} = Account.send_text(ctx.id, @alice, "hi")

    answer_request(ctx.socket, "/v1/profile/#{@alice}/#{version}", 200, %{
      "name" => Base.encode64(name)
    })

    assert eventually(fn -> Account.profile_name(ctx.id, @alice) end) == {:ok, "Alice Liddell"}
  end

  # CRS-09b section 7, CRS-08: the new member's expiring profile key
  # credential is read with its stored profile key (in the caller's process,
  # not the owner), presented to the storage service, and the members get
  # the group update; an account without a stored profile key is invited.
  test "adding members: a credential presentation for a known profile key, else an invitation",
       ctx do
    params = Params.from_master_key(:crypto.strong_rand_bytes(32))
    {:ok, bob_uuid} = ServiceId.aci_from_string(@bob)
    {:ok, alice_uuid} = ServiceId.aci_from_string(@alice)
    bob_uid = Uid.encrypt(params, {:aci, bob_uuid})

    FakeStorage.put_group(ctx.storage, params, %Wire.Group{
      revision: 4,
      access_control: %Wire.AccessControl{membership: 3, join_by_link: 4},
      members: [
        %Wire.Member{
          user_id: bob_uid,
          role: 2,
          profile_key: ProfileKey.encrypt(params, ctx.bob.profile_key, bob_uuid)
        }
      ]
    })

    bob_member = %{
      uid: bob_uid,
      service_id: {:aci, bob_uuid},
      role: 2,
      profile_key: ctx.bob.profile_key,
      joined_at_revision: 0,
      label_emoji: nil,
      label_text: nil
    }

    group = %{
      master_key: params.master_key,
      revision: 4,
      state: %State{revision: 4, members: [bob_member]},
      endorsements: nil,
      sending: nil
    }

    :ok = Pipeline.write(ctx.bob.pipeline, [{:put_group, params.group_id, group}])
    ctx = start_owner(ctx)

    # Alice's message gives the account her profile key.
    alice = alice_sends(ctx.alice, "add me")
    push_queued(ctx, 40)
    assert_receive {:handler_event, _id, {:profile_key_changed, @alice}}, @wait_ms

    dave = "00000000-0000-4000-8000-0000000000c4"

    adding =
      Task.async(fn -> Account.add_group_members(ctx.id, params.group_id, [@alice, dave]) end)

    # CRS-08 section 7: the versioned profile with a credential request.
    version = Profile.version(ctx.alice.profile_key, alice_uuid)
    request = receive_request(ctx.socket, "/v1/profile/#{@alice}/#{version}/")
    %URI{path: "/v1/profile/" <> path} = URI.parse(request.path)
    [_aci, _version, hex] = String.split(path, "/")
    {:ok, credential_request} = Base.decode16(hex, case: :lower)

    {:ok, response} =
      ProfileKeyCredential.issue(
        ctx.secret,
        credential_request,
        alice_uuid,
        ProfileKey.commitment(ctx.alice.profile_key, alice_uuid),
        ctx.now - rem(ctx.now, 86_400) + 7 * 86_400,
        :crypto.strong_rand_bytes(32)
      )

    respond(ctx.socket, request, 200, %{"credential" => Base.encode64(response)})
    answer_credentials(ctx)
    assert {:ok, 5} = Task.await(adding, @wait_ms)

    stored = FakeStorage.group(ctx.storage, params)
    alice_uid = Uid.encrypt(params, {:aci, alice_uuid})
    assert Enum.any?(stored.members, &(&1.user_id == alice_uid and &1.role == 1))
    assert [%Wire.InvitedMember{added_by: ^bob_uid}] = stored.invited_members

    assert [%{group_id: group_id, members: members}] = Account.groups(ctx.id)
    assert group_id == params.group_id
    assert Enum.sort(members) == [@alice, @bob]

    assert [%{data_message: %{group_v2: %{revision: 5, group_change: change}}}] =
             received(alice, :data)

    assert is_binary(change)
    assert Account.add_group_members(ctx.id, params.group_id, ["x"]) == {:error, :invalid_member}
  end

  # CRS-14: the account joins with its own membership token (group
  # credentials over the chat socket, token from the storage service),
  # announces the era to the group, sends its media key to the account in
  # the call, and calls `admit` with the era; a refused admission leaves.
  test "joining a group call wires the account's token, sends and admission", ctx do
    params = Params.from_master_key(:crypto.strong_rand_bytes(32))
    {:ok, alice_uuid} = ServiceId.aci_from_string(@alice)
    {:ok, bob_uuid} = ServiceId.aci_from_string(@bob)
    alice_uid = Uid.encrypt(params, {:aci, alice_uuid})
    bob_uid = Uid.encrypt(params, {:aci, bob_uuid})

    FakeStorage.put_group(ctx.storage, params, %Wire.Group{
      revision: 2,
      members: [
        %Wire.Member{
          user_id: bob_uid,
          role: 2,
          profile_key: ProfileKey.encrypt(params, ctx.bob.profile_key, bob_uuid)
        },
        %Wire.Member{
          user_id: alice_uid,
          role: 1,
          profile_key: ProfileKey.encrypt(params, ctx.alice.profile_key, alice_uuid)
        }
      ]
    })

    member = fn uid, id ->
      %{
        uid: uid,
        service_id: {:aci, id},
        role: 1,
        profile_key: nil,
        joined_at_revision: 0,
        label_emoji: nil,
        label_text: nil
      }
    end

    group = %{
      master_key: params.master_key,
      revision: 2,
      state: %State{
        revision: 2,
        members: [member.(bob_uid, bob_uuid), member.(alice_uid, alice_uuid)]
      },
      endorsements: nil,
      sending: nil
    }

    :ok = Pipeline.write(ctx.bob.pipeline, [{:put_group, params.group_id, group}])

    # The storage service's token names the caller's UID ciphertext.
    token = "fake:" <> Base.encode16(:crypto.hash(:sha256, bob_uid), case: :lower)
    sfu = start_supervised!({FakeSfu, {self(), token, []}})
    sfu_server = start_supervised!({Bandit, FakeSfu.bandit_options(sfu, ctx.chain)}, id: :sfu)
    FakeSfu.put_devices(sfu, [{@alice_demux, GroupCallProto.opaque_user_id(alice_uid)}])

    ctx =
      start_owner(ctx,
        group_call: [
          sfu_url: "https://localhost:#{FakeChat.port(sfu_server)}",
          http: [roots: [ctx.chain.root]],
          ice_opts: [ip_filter: fn ip -> match?({_, _, _, _}, ip) end]
        ]
      )

    test = self()

    admit = fn session, info ->
      send(test, {:admit, self(), session, info})

      receive do
        {:admit_result, result} -> result
      after
        @wait_ms -> {:error, :timeout}
      end
    end

    assert {:ok, session} = Account.join_group_call(ctx.id, params.group_id, admit: admit)
    ref = Process.monitor(session)
    answer_credentials(ctx)

    assert_receive {:admit, admit_task, ^session, %{era_id: era}}, @wait_ms
    assert is_binary(era)
    assert Account.join_group_call(ctx.id, params.group_id) == {:error, :already_in_call}
    assert SalixSignal.GroupCall.active?(@bob)

    # The era reached the group, and the media key reached the one account
    # in the call as a 1:1 call message.
    assert eventually(fn -> call_arrivals(ctx.alice, params.group_id) end) == {true, true}

    send(admit_task, {:admit_result, {:error, :declined}})
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, @wait_ms
    assert Account.join_group_call(ctx.id, :binary.copy(<<8>>, 32)) == {:error, :unknown_group}
  end

  test "joining by link initializes a missing profile and receives a group credential", ctx do
    params = Params.from_master_key(:crypto.strong_rand_bytes(32))
    password = :crypto.strong_rand_bytes(16)

    FakeStorage.put_group(ctx.storage, params, %Wire.Group{
      revision: 0,
      access_control: %Wire.AccessControl{join_by_link: 1},
      invite_link_password: password
    })

    ctx = start_owner(ctx)
    url = SalixSignalProto.Group.InviteLink.build(params.master_key, password)
    joining = Task.async(fn -> Account.join_group(ctx.id, url) end)
    answer_credentials(ctx)
    request = receive_request(ctx.socket, "/v1/profile/#{@bob}/")
    respond(ctx.socket, request, 200, %{})
    publish = receive_request(ctx.socket, "/v1/profile")
    assert publish.verb == "PUT"
    body = Jason.decode!(publish.body)
    {:ok, bob_uuid} = ServiceId.aci_from_string(@bob)

    assert Base.decode64!(body["commitment"]) ==
             ProfileKey.commitment(ctx.bob.profile_key, bob_uuid)

    assert {:ok, {"Comma", nil}} =
             Profile.decrypt_name(ctx.bob.profile_key, Base.decode64!(body["name"]))

    respond(ctx.socket, publish, 200, %{})
    answer_own_profile_credential(ctx)
    assert {:ok, {:joined, group_id}} = Task.await(joining, @wait_ms)
    assert group_id == params.group_id
    assert [%{group_id: ^group_id}] = Account.groups(ctx.id)
  end

  test "a missing credential does not overwrite an existing account profile", ctx do
    ctx = start_owner(ctx)

    url =
      SalixSignalProto.Group.InviteLink.build(
        :crypto.strong_rand_bytes(32),
        :crypto.strong_rand_bytes(16)
      )

    joining = Task.async(fn -> Account.join_group(ctx.id, url) end)
    answer_credentials(ctx)
    request = receive_request(ctx.socket, "/v1/profile/#{@bob}/")
    {:ok, name} = Profile.encrypt_name(ctx.bob.profile_key, "Existing bot", nil)
    respond(ctx.socket, request, 200, %{"name" => Base.encode64(name)})
    assert {:error, :no_profile_credential} = Task.await(joining, @wait_ms)
    refute_receive {:fake_chat, :frame, _, %Frame.Request{verb: "PUT", path: "/v1/profile"}}
  end

  test "an incoming direct invitation makes the owner accept and persist membership", ctx do
    params = Params.from_master_key(:crypto.strong_rand_bytes(32))
    {:ok, bob_uuid} = ServiceId.aci_from_string(@bob)
    bob_uid = Uid.encrypt(params, {:aci, bob_uuid})

    FakeStorage.put_group(ctx.storage, params, %Wire.Group{
      revision: 0,
      invited_members: [%Wire.InvitedMember{member: %Wire.Member{user_id: bob_uid, role: 1}}]
    })

    ctx = start_owner(ctx)

    timestamp = System.system_time(:millisecond)

    content =
      %SalixSignalProto.Message.Wire.Content{
        data_message: %SalixSignalProto.Message.Wire.DataMessage{
          timestamp: timestamp,
          group_v2: %SalixSignalProto.Message.Wire.GroupContext{
            master_key: params.master_key,
            revision: 0
          }
        }
      }
      |> Protobuf.encode()

    {{:ok, _}, alice} =
      SignalAccount.run(
        ctx.alice,
        &Pipeline.send_content(&1, @bob, content, timestamp: timestamp)
      )

    push_queued(ctx, 70)
    answer_credentials(ctx)
    request = receive_request(ctx.socket, "/v1/profile/#{@bob}/")
    respond(ctx.socket, request, 503, %{})
    GenServer.call(ctx.pid, :epoch)
    assert Account.groups(ctx.id) == []

    # A new message at the same group revision retries a failed acceptance.
    {:ok, :data, wire} = Content.decode(content)

    retry_content =
      Protobuf.encode(%{
        wire
        | data_message: %{wire.data_message | timestamp: wire.data_message.timestamp + 1}
      })

    {{:ok, _}, _alice} =
      SignalAccount.run(
        alice,
        &Pipeline.send_content(&1, @bob, retry_content, timestamp: timestamp + 1)
      )

    push_queued(ctx, 80)
    answer_own_profile_credential(ctx)
    group_id = params.group_id
    assert_receive {:handler_event, _, {:group_updated, ^group_id, 1}}, @wait_ms
    assert [%{group_id: ^group_id}] = Account.groups(ctx.id)
    assert [%Wire.Member{user_id: ^bob_uid}] = FakeStorage.group(ctx.storage, params).members
    assert FakeStorage.group(ctx.storage, params).invited_members == []
  end

  defp answer_own_profile_credential(ctx) do
    {:ok, bob_uuid} = ServiceId.aci_from_string(@bob)
    request = receive_request(ctx.socket, "/v1/profile/#{@bob}/")
    %URI{path: path} = URI.parse(request.path)
    hex = path |> String.split("/") |> List.last()

    {:ok, response} =
      ProfileKeyCredential.issue(
        ctx.secret,
        Base.decode16!(hex, case: :lower),
        bob_uuid,
        ProfileKey.commitment(ctx.bob.profile_key, bob_uuid),
        ctx.now - rem(ctx.now, 86_400) + 7 * 86_400,
        :crypto.strong_rand_bytes(32)
      )

    respond(ctx.socket, request, 200, %{"credential" => Base.encode64(response)})
  end

  defp answer_credentials(ctx) do
    assert_receive {:fake_chat, :frame, socket,
                    %Frame.Request{verb: "GET", path: "/v1/certificate/auth/group?" <> query} =
                      request},
                   @wait_ms

    query = URI.decode_query(query)
    first = String.to_integer(query["redemptionStartSeconds"])
    last = String.to_integer(query["redemptionEndSeconds"])
    {:ok, aci} = ServiceId.aci_from_string(@bob)
    {:ok, pni} = ServiceId.aci_from_string(@pni)

    credentials =
      for day <- first..last//86_400 do
        response = AuthCredential.issue(ctx.secret, aci, pni, day, :crypto.strong_rand_bytes(32))
        %{"credential" => Base.encode64(response), "redemptionTime" => day}
      end

    body =
      Jason.encode!(%{
        "credentials" => credentials,
        "callLinkAuthCredentials" => [],
        "pni" => @pni
      })

    send(
      socket,
      {:send, Frame.encode_response(%Frame.Response{id: request.id, status: 200, body: body})}
    )
  end

  # Whether Alice has received the group-call update and a media key.
  defp call_arrivals(alice, group_id) do
    {events, _alice} = SignalAccount.deliver(alice)
    Process.put(:arrivals, Process.get(:arrivals, []) ++ events)
    events = Process.get(:arrivals)

    update? =
      Enum.any?(events, fn
        {:message, %Inbound{content_kind: :data, content: content}} ->
          {:ok, :data, wire} = Content.decode(content)
          wire.data_message.group_call_update != nil

        _ ->
          false
      end)

    key? =
      Enum.any?(events, fn
        {:message, %Inbound{content_kind: :call, content: content}} ->
          {:ok, :call, wire} = Content.decode(content)
          {:ok, %{payload: {:opaque, data, _}}} = CallSignaling.decode(wire.call_message)

          match?(
            {:ok, {:device, %{group_id: ^group_id, media_key: %{}}}},
            Messages.decode_opaque(data)
          )

        _ ->
          false
      end)

    if update? and key?, do: {true, true}, else: nil
  end

  defp eventually(fun, tries \\ 300) do
    case fun.() do
      result when result in [nil, {:ok, nil}] and tries > 0 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end
end
