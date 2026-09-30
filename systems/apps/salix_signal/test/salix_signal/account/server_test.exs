defmodule SalixSignal.Account.ServerTest do
  # The account owner process end to end: envelopes pushed on a real chat
  # socket (fake chat service, CRS-01) are committed to the Postgres store,
  # acknowledged only after the commit (CRS-07 §5.3), and handed to the
  # product handler behind a durable cursor; a newer owner claim fences the
  # process; sends run in the owner process through SalixSignal.Account.
  use ExUnit.Case, async: false

  alias SalixSignal.{Account, Accounts, Storage}
  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Test.{FakeChat, MockService, SignalAccount}
  alias SalixSignalProto.CallSignaling, as: CallProto
  alias SalixSignalProto.GroupCall.Messages
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.Service.Frame

  @alice "00000000-0000-4000-8000-000000000061"
  @bob "00000000-0000-4000-8000-000000000062"

  # Upper bound for the owner's chat connect on a loaded machine (the chat
  # client's own connect timeout is 10 s).
  @connect_ms 30_000
  # Upper bound for any other wait.
  @wait_ms 30_000

  defmodule Handler do
    @moduledoc false
    # Forwards to the test process; refuses items while `:refuse` is set.
    @behaviour SalixSignal.Account.Handler

    def handle_inbound(account_id, seq, inbound) do
      send(
        :persistent_term.get({__MODULE__, :test}),
        {:handler_inbound, account_id, seq, inbound}
      )

      case :persistent_term.get({__MODULE__, :refuse}, 0) do
        0 ->
          :ok

        n ->
          :persistent_term.put({__MODULE__, :refuse}, n - 1)
          {:error, :busy}
      end
    end

    def incoming_call(_account_id, _info), do: :needs_permission
    def admit_call(_account_id, _info, _connection), do: {:error, :not_bound}

    def handle_event(account_id, event),
      do: send(:persistent_term.get({__MODULE__, :test}), {:handler_event, account_id, event})
  end

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    :persistent_term.put({Handler, :test}, self())
    :persistent_term.put({Handler, :refuse}, 0)
    :persistent_term.put({Handler, :clock}, nil)
    {:ok, upgrades} = Agent.start_link(fn -> [] end)
    server = start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)})
    {:ok, service} = MockService.start_link()

    alice = SignalAccount.new(service, @alice)
    bob = SignalAccount.new(service, @bob, store: :postgres)
    id = bob.account_id

    # The owner's clock: the system clock unless a test sets one.
    clock = fn ->
      :persistent_term.get({Handler, :clock}, nil) || System.system_time(:millisecond)
    end

    opts = [
      handler: Handler,
      chat: [
        host: "localhost",
        port: FakeChat.port(server),
        roots: [chain.root],
        backoff: [base_ms: 10, max_ms: 40]
      ],
      transport: %{
        identified: MockService.transport(service, {:identified, @bob, 1}),
        unidentified: MockService.transport(service, :unidentified)
      },
      pipeline: [
        trust_roots: [MockService.trust_root(service)],
        known_server_certificates: %{},
        clock: clock
      ],
      maintenance_interval_ms: 3_600_000,
      delivery_retry_ms: 50
    ]

    {:ok, pid} = Accounts.start_local(id, opts)

    on_exit(fn -> Accounts.stop_local(id) end)
    assert_receive {:fake_chat, :connected, socket}, @connect_ms

    %{id: id, pid: pid, opts: opts, socket: socket, service: service, alice: alice, bob: bob}
  end

  # A new owner process for the account, as after a node change: a new
  # claim and nothing carried over in memory.
  defp restart_owner(%{id: id, opts: opts}) do
    :ok = Accounts.stop_local(id)
    {:ok, pid} = Accounts.start_local(id, opts)
    assert_receive {:fake_chat, :connected, socket}, @connect_ms
    %{pid: pid, socket: socket}
  end

  defp push_queued(%{socket: socket, service: service}, first_id) do
    service
    |> MockService.queued(@bob, 1)
    |> Enum.with_index(first_id)
    |> Enum.map(fn {{guid, bytes}, id} ->
      request = %Frame.Request{
        verb: "PUT",
        path: "/api/v1/message",
        id: id,
        body: bytes,
        headers: [{"X-Signal-Timestamp", "1758790000500"}]
      }

      send(socket, {:send, Frame.encode_request(request)})
      {id, guid}
    end)
  end

  # The delivery cursor of the owner's delivery process once that process
  # has finished its current step.
  defp delivered(pid), do: :sys.get_state(:sys.get_state(pid).delivery).delivered

  defp body(%Inbound{content: content}) do
    {:ok, :data, wire} = Content.decode(content)
    wire.data_message.body
  end

  defp alice_sends(alice, text) do
    {{:ok, _info}, alice} = SignalAccount.run(alice, &Pipeline.send_text(&1, @bob, text))
    alice
  end

  test "a pushed envelope is committed, then acknowledged, then handed to the handler",
       %{id: id, pid: pid, socket: socket, alice: alice} = context do
    alice_sends(alice, "hello owner")
    [{request_id, guid}] = push_queued(context, 10)

    assert_receive {:fake_chat, :frame, ^socket, %Frame.Response{id: ^request_id, status: 200}},
                   @wait_ms

    assert Storage.admitted?(id, guid)
    assert_receive {:handler_inbound, ^id, seq, %Inbound{sender: @alice} = inbound}
    assert body(inbound) == "hello owner"
    assert_receive {:handler_event, ^id, {:profile_key_changed, @alice}}

    # The delivery process advances the cursor after the handler returns,
    # in the same step; waiting for that process orders the claim after it.
    # The cursor is durable: a new owner starts after this item.
    assert delivered(pid) == seq
    assert {:ok, %{delivered_seq: ^seq}} = Storage.claim(id, node())
  end

  @tag :signal_setup_regression
  test "a phone-number request gets a verifiable link from the account identity", ctx do
    :ok = Accounts.stop_local(ctx.id)
    pni = "00000000-0000-4000-8000-000000000063"
    bob = SignalAccount.new(ctx.service, @bob, store: :postgres, pni: pni)
    {:ok, pid} = Accounts.start_local(bob.account_id, ctx.opts)
    on_exit(fn -> Accounts.stop_local(bob.account_id) end)
    assert_receive {:fake_chat, :connected, socket}, @connect_ms

    {{:ok, _}, alice} =
      SignalAccount.run(ctx.alice, fn pipeline ->
        Pipeline.send_content(pipeline, "PNI:" <> pni, Content.text(1000, "pair"),
          timestamp: 1000,
          sealed: false
        )
      end)

    [{_guid, envelope}] = MockService.queued(ctx.service, "PNI:" <> pni, 1)

    send(
      socket,
      {:send,
       Frame.encode_request(%Frame.Request{
         verb: "PUT",
         path: "/api/v1/message",
         id: 71,
         body: envelope
       })}
    )

    id = bob.account_id
    assert_receive {:handler_inbound, ^id, _, %Inbound{sender: @alice}}, @wait_ms
    # The independent delivery process can read the commit before the
    # owner finishes its reply. Wait for the owner to finish this envelope.
    GenServer.call(pid, :epoch)
    {events, _alice} = SignalAccount.deliver(alice)

    signatures =
      for {:message, %Inbound{content: content}} <- events,
          {:ok, _, wire} = Content.decode(content),
          wire.pni_signature != nil,
          do: wire.pni_signature

    assert length(signatures) == 1, inspect(events, limit: 20)
    [%{pni: pni_bytes, signature: signature}] = signatures
    assert {:ok, ^pni_bytes} = SalixSignalProto.ServiceId.aci_from_string(pni)

    assert SalixSignalProto.Keys.verify_alternate_identity(
             bob.pipeline.account.identities.pni.public,
             bob.identity.public,
             signature
           )

    refute SalixSignalProto.Keys.verify_alternate_identity(
             bob.pipeline.account.identities.pni.public,
             alice.identity.public,
             signature
           )
  end

  @tag :signal_setup_regression
  test "an account call fetches authenticated relays and reuses them until expiry", ctx do
    test_pid = self()
    {:ok, ttl} = Agent.start_link(fn -> 0 end)
    original = ctx.opts[:transport].identified

    # Call startup requires a verified TLS relay, even before ICE allocation.
    {:ok, listener} =
      :ssl.listen(
        0,
        [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true] ++ ctx.chain.server
      )

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    relay_url = "turns:localhost:#{port}?transport=tcp"

    relay =
      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :ssl.transport_accept(listener, @wait_ms)
           {:ok, socket} = :ssl.handshake(socket, @wait_ms)
           send(test_pid, :relay_connected)

           receive do
             :stop -> :ssl.close(socket)
           end
         end}
      )

    transport = fn
      "GET", "/v2/calling/relays", _opts ->
        send(test_pid, :relays_requested)

        body =
          Jason.encode!(%{
            relays: [
              %{
                username: "test",
                password: "test",
                ttl: Agent.get(ttl, & &1),
                urls: [relay_url]
              }
            ]
          })

        {:ok, %SalixSignal.Service.Response{status: 200, body: body}}

      method, path, opts ->
        original.(method, path, opts)
    end

    opts =
      ctx.opts
      |> Keyword.put(:transport, %{ctx.opts[:transport] | identified: transport})
      |> Keyword.put(:call_signaling, media: [turn_tls: [cacerts: [ctx.chain.root]]])

    %{pid: pid} = restart_owner(%{ctx | opts: opts})
    assert {:ok, _} = Account.send_text(ctx.id, @alice, "establish identity")
    assert {:ok, _call, _call_id} = Account.call(ctx.id, @alice)
    assert_receive :relays_requested, @wait_ms
    assert_receive :relay_connected, @wait_ms
    assert {:offer, _} = call_reply!(ctx.alice)

    Agent.update(ttl, fn _ -> 3600 end)
    assert {:ok, [server]} = GenServer.call(pid, :call_ice_servers)
    assert_receive :relays_requested
    assert server.urls == [relay_url]
    assert {:ok, [^server]} = GenServer.call(pid, :call_ice_servers)
    refute_receive :relays_requested, 100
    send(relay, :stop)
  end

  test "the owner publishes its profile with the stored account key", ctx do
    await_chat(:sys.get_state(ctx.pid).chat)

    task =
      Task.async(fn -> Account.set_profile(ctx.id, %{given_name: "Comma", avatar: :keep}) end)

    socket = ctx.socket

    assert_receive {:fake_chat, :frame, ^socket,
                    %Frame.Request{verb: "PUT", path: "/v1/profile"} = request},
                   @wait_ms

    body = Jason.decode!(request.body)

    assert {:ok, {"Comma", nil}} =
             SalixSignalProto.Profile.decrypt_name(
               ctx.bob.profile_key,
               Base.decode64!(body["name"])
             )

    send(socket, {:send, Frame.encode_response(%Frame.Response{id: request.id, status: 200})})
    assert {:ok, %{version: version}} = Task.await(task)
    assert version == body["version"]
  end

  defp await_chat(chat, attempts \\ 1_000) do
    case SalixSignal.Service.Chat.phase(chat) do
      :open ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        await_chat(chat, attempts - 1)

      phase ->
        flunk("chat did not connect: #{inspect(phase)}")
    end
  end

  test "a refused item is handed over again and the cursor waits for it",
       %{id: id, pid: pid, socket: socket, alice: alice} = context do
    :persistent_term.put({Handler, :refuse}, 1)
    alice_sends(alice, "try again")
    [{request_id, _guid}] = push_queued(context, 20)

    assert_receive {:fake_chat, :frame, ^socket, %Frame.Response{id: ^request_id, status: 200}},
                   @wait_ms

    assert_receive {:handler_inbound, ^id, seq, _inbound}
    assert_receive {:handler_inbound, ^id, ^seq, inbound}
    assert body(inbound) == "try again"
    assert delivered(pid) == seq
    assert {:ok, %{delivered_seq: ^seq}} = Storage.claim(id, node())
  end

  test "a newer owner claim fences the process: nothing is committed or acknowledged",
       %{id: id, pid: pid, socket: socket, alice: alice} = context do
    ref = Process.monitor(pid)
    {:ok, _newer} = Storage.claim(id, node())
    alice_sends(alice, "for the next owner")
    [{request_id, guid}] = push_queued(context, 30)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :fenced}}, @wait_ms
    refute_received {:fake_chat, :frame, ^socket, %Frame.Response{id: ^request_id}}
    refute Storage.admitted?(id, guid)
  end

  test "sends run in the owner process and reach the peer", %{id: id, alice: alice} do
    assert {:ok, %{timestamp: timestamp, devices: [1]}} =
             Account.send_text(id, @alice, "from the owner")

    {events, _alice} = SignalAccount.deliver(alice)

    assert [%Inbound{timestamp: ^timestamp} = inbound] =
             for({:message, %Inbound{content_kind: :data} = i} <- events, do: i)

    assert body(inbound) == "from the owner"
    assert {:error, :unknown_group} = Account.send_group_text(id, :binary.copy(<<2>>, 32), "x")
    assert Account.groups(id) == []
  end

  test "status and crash reports of the owner and its chat socket show no secrets", %{
    pid: pid,
    bob: bob
  } do
    chat = :sys.get_state(pid).chat
    reports = :erlang.term_to_binary({:sys.get_status(pid), :sys.get_status(chat)})

    for secret <- [bob.identity.private, bob.profile_key, "device-password"] do
      assert :binary.match(reports, secret) == :nomatch
    end

    assert :binary.match(:erlang.term_to_binary(:sys.get_state(pid)), bob.identity.private) !=
             :nomatch
  end

  # Strictly increasing send timestamps (owner decision; CRS-07 §2 and
  # §5.4: a receiver drops a second message with the same author and
  # timestamp). The next owner may run on a node whose clock is behind.
  test "send timestamps keep increasing across a new owner whose clock is behind", context do
    %{id: id} = context
    ahead = System.system_time(:millisecond) + 60_000
    :persistent_term.put({Handler, :clock}, ahead)

    assert {:ok, %{timestamp: ^ahead}} = Account.send_text(id, @alice, "one")
    assert {:ok, %{timestamp: second}} = Account.send_text(id, @alice, "two")
    assert second == ahead + 1

    :persistent_term.put({Handler, :clock}, ahead - 5_000)
    restart_owner(context)

    assert {:ok, %{timestamp: third}} = Account.send_text(id, @alice, "three")
    assert third > second
  end

  # CRS-12 section 8: an offer that arrives while the device is in a group
  # call is answered busy. CRS-14 section 9.4: a media key for the group of
  # the active call goes to that call, with the sender from the decrypted
  # envelope; section 11: a ring reaches the product handler.
  test "while the account is in a group call, offers are busy and group-call keys reach the call",
       %{id: id, alice: alice} = context do
    group_id = :binary.copy(<<0x47>>, 32)

    # This test process stands in for the account's joined group-call
    # session (SalixSignal.GroupCall.Registry, key {aci, group_id}).
    {:ok, _} = Registry.register(SalixSignal.GroupCall.Registry, {@bob, group_id}, nil)

    call_id = CallProto.new_call_id()

    alice =
      alice_calls(
        alice,
        CallProto.encode({:offer, %{call_id: call_id, parameters: offer_parameters()}})
      )

    push_queued(context, 40)

    assert {:busy, ^call_id} = call_reply!(alice)

    alice = alice_calls(alice, Messages.media_key(group_id, 1, :binary.copy(<<9>>, 32), 0x20))
    push_queued(context, 50)

    assert_receive {:"$gen_cast",
                    {:signal, @alice,
                     %{group_id: ^group_id, media_key: %{counter: 1, demux_id: 0x20}}}},
                   @wait_ms

    _alice = alice_calls(alice, Messages.ring(group_id, :ring, 4242))
    push_queued(context, 60)

    assert_receive {:handler_event, ^id, {:group_call_ring, ^group_id, 4242, :ring, @alice}},
                   @wait_ms
  end

  defp alice_calls(alice, call_message) do
    {{:ok, _info}, alice} =
      SignalAccount.run(
        alice,
        &Pipeline.send_call_message(&1, @bob, call_message, %{urgent: true})
      )

    alice
  end

  defp offer_parameters do
    {public, _private} = SalixSignalProto.CallMedia.Keys.generate_keypair()

    CallProto.audio_only_parameters(
      %{public_key: public, ice_ufrag: "abcd", ice_pwd: "abcdefghijklmnopqrstuv"},
      300_000
    )
  end

  # The payload of the first call message that reaches Alice, polled for at
  # most 30 s.
  defp call_reply!(alice, tries \\ 300) do
    {events, alice} = SignalAccount.deliver(alice)

    replies =
      for {:message, %Inbound{content_kind: :call, content: content}} <- events do
        {:ok, :call, wire} = Content.decode(content)
        {:ok, message} = CallProto.decode(wire.call_message)
        message.payload
      end

    case replies do
      [payload | _] ->
        payload

      [] when tries > 0 ->
        Process.sleep(100)
        call_reply!(alice, tries - 1)

      [] ->
        flunk("no call message reached the caller")
    end
  end
end
