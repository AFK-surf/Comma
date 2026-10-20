defmodule SalixSignal.GroupsTest do
  # Groups v2 over the network (CRS-09b sections 2, 3, 5 and 7): group auth
  # credentials over the chat socket, then the storage service over HTTPS.
  # The fake storage service (test/support/fake_storage.ex) verifies every
  # auth presentation and profile key presentation with the server side of
  # CRS-09a, fills accepted changes and signs them.
  use SystemsClock.Case, async: true

  alias SalixSignal.Groups
  alias SalixSignal.Service.{Chat, Credentials}
  alias SalixSignal.Test.{FakeChat, FakeStorage}

  alias SalixSignalProto.Group.{
    AuthCredential,
    Change,
    InviteLink,
    Params,
    ProfileKey,
    ProfileKeyCredential,
    ServerParams,
    State,
    Uid,
    Wire
  }

  alias SalixSignalProto.Service.Frame

  @now 1_758_758_400 + 7_200
  @aci <<0x00000000000040008000000000000021::128>>
  @pni <<0x00000000000040008000000000000022::128>>
  @profile_key :binary.copy(<<0x5C>>, 32)

  setup_all do
    secret = ServerParams.generate(:binary.copy(<<0x77>>, 32))
    {:ok, server} = ServerParams.decode_public(ServerParams.public_from_secret(secret))
    %{chain: FakeChat.chain(), secret: secret, server: server}
  end

  setup %{chain: chain, secret: secret} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)

    chat_server =
      start_supervised!(
        {Bandit, FakeChat.bandit_options(SystemsRuntime.Proc.self(), chain, upgrades)},
        id: :chat
      )

    chat =
      start_supervised!(
        {Chat,
         owner: SystemsRuntime.Proc.self(),
         host: "localhost",
         port: FakeChat.port(chat_server),
         roots: [chain.root],
         credentials: Credentials.device("00000000-0000-4000-8000-000000000021", 1, "pw")}
      )

    assert_receive {:signal_chat, ^chat, {:connected, _}}
    assert_receive {:fake_chat, :connected, socket}

    storage = start_supervised!({FakeStorage, {SystemsRuntime.Proc.self(), secret, @now}})

    storage_server =
      start_supervised!({Bandit, FakeStorage.bandit_options(storage, chain)}, id: :storage)

    %{
      chat: chat,
      socket: socket,
      storage: storage,
      opts: [
        storage_url: "https://localhost:#{FakeChat.port(storage_server)}",
        http: [roots: [chain.root]],
        now: fn -> @now end
      ]
    }
  end

  # The chat service's answer to GET /v1/certificate/auth/group: one
  # credential per day of the requested range.
  defp answer_credentials(%{socket: socket, secret: secret}) do
    assert_receive {:fake_chat, :frame, ^socket,
                    %Frame.Request{verb: "GET", path: path} = request}

    %URI{path: "/v1/certificate/auth/group", query: query} = URI.parse(path)
    query = URI.decode_query(query)
    assert query["v101"] == "true"
    first = String.to_integer(query["redemptionStartSeconds"])
    last = String.to_integer(query["redemptionEndSeconds"])
    assert {first, last} == {@now - rem(@now, 86_400), @now - rem(@now, 86_400) + 7 * 86_400}

    credentials =
      for day <- first..last//86_400 do
        response =
          AuthCredential.issue(secret, @aci, @pni, day, SystemsRuntime.Proc.random_bytes(32))

        %{"credential" => Base.encode64(response), "redemptionTime" => day}
      end

    body =
      Jason.encode!(%{
        "credentials" => credentials,
        "callLinkAuthCredentials" => [],
        "pni" => "00000000-0000-4000-8000-000000000022"
      })

    SystemsRuntime.Proc.send(
      socket,
      {:send, Frame.encode_response(%Frame.Response{id: request.id, status: 200, body: body})}
    )
  end

  defp client(ctx) do
    task =
      SystemsRuntime.Task.async(fn ->
        Groups.fetch_credentials(ctx.chat, ctx.server, @aci, ctx.opts)
      end)

    answer_credentials(ctx)
    {:ok, credentials} = SystemsRuntime.Task.await(task, :infinity)
    assert map_size(credentials) == 8
    Groups.client(ctx.server, credentials, ctx.opts)
  end

  # This account's expiring profile key credential presentation for a group.
  defp presentation_fun(%{secret: secret, server: server}) do
    {context, request} = ProfileKeyCredential.request(@aci, @profile_key)
    commitment = ProfileKey.commitment(@profile_key, @aci)
    expiration = @now - rem(@now, 86_400) + 7 * 86_400

    {:ok, response} =
      ProfileKeyCredential.issue(secret, request, @aci, commitment, expiration, <<1::256>>)

    {:ok, credential, _} = ProfileKeyCredential.receive(server, context, response, @now)

    fn params ->
      {:ok, {presentation, _, _}} = ProfileKeyCredential.present(server, params, credential)
      presentation
    end
  end

  defp new_group(ctx, access, opts \\ []) do
    params = Params.from_master_key(SystemsRuntime.Proc.random_bytes(32))
    admin = <<0x00000000000040008000000000000023::128>>
    password = SystemsRuntime.Proc.random_bytes(16)

    members =
      [
        %Wire.Member{
          user_id: Uid.encrypt(params, {:aci, admin}),
          role: 2,
          profile_key: ProfileKey.encrypt(params, :binary.copy(<<1>>, 32), admin)
        }
      ] ++
        Keyword.get(opts, :members, [])

    FakeStorage.put_group(ctx.storage, params, %Wire.Group{
      title: State.encrypt_attribute(params, :title, "Signal friends"),
      revision: 5,
      access_control: %Wire.AccessControl{join_by_link: access},
      members: Enum.map(members, fn m -> if is_function(m), do: m.(params), else: m end),
      invite_link_password: password
    })

    {params, InviteLink.build(params.master_key, password)}
  end

  test "joining by a direct link: join info, a verified self-add, then the full state", ctx do
    client = client(ctx)
    {params, url} = new_group(ctx, 1)

    {:ok, {:joined, joined_params, state, signed}} =
      Groups.join_by_link(client, url, presentation_fun(ctx))

    assert joined_params == params
    assert state.revision == 6
    assert state.title == "Signal friends"

    assert %{role: 1, profile_key: @profile_key, joined_at_revision: 6} =
             State.find_member(state, params, {:aci, @aci})

    # The update message that members receive carries this signed change.
    {:ok, change} = Change.verify_signed(ctx.server, params, signed)
    assert Change.editor(params, change.actions) == {:aci, @aci}

    assert_received {:fake_storage, "GET", "/v2/groups/join/" <> _}
    assert_received {:fake_storage, "PATCH", "/v2/groups/"}
    assert_received {:fake_storage, "GET", "/v2/groups/"}
  end

  test "an approval link sends a join request; the requester cannot read the group", ctx do
    client = client(ctx)
    {params, url} = new_group(ctx, 3)

    assert {:ok, {:requested, ^params, _signed}} =
             Groups.join_by_link(client, url, presentation_fun(ctx))

    assert [%Wire.RequestingMember{user_id: uid}] =
             FakeStorage.group(ctx.storage, params).requesting_members

    assert uid == Uid.encrypt(params, {:aci, @aci})
    assert Groups.get_group(client, params) == {:error, {:forbidden, nil}}
  end
end
