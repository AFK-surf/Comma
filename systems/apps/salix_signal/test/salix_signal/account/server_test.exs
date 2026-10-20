defmodule SalixSignal.Account.ServerTest do
  require SystemsRuntime.Proc

  # The account owner process end to end: envelopes pushed on a real chat
  # socket (fake chat service, CRS-01) are committed to the Postgres store,
  # acknowledged only after the commit (CRS-07 §5.3), and handed to the
  # product handler behind a durable cursor; a newer owner claim fences the
  # process; sends run in the owner process through SalixSignal.Account.
  use SystemsClock.Case, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.SalixSignal", "Elixir.ThousandIsland", "Elixir.Bandit"]

  alias SalixSignal.{Account, Accounts, Storage}
  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Test.{FakeChat, MockService, SignalAccount}
  alias SalixSignalProto.CallSignaling, as: CallProto
  alias SalixSignalProto.GroupCall.Messages
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.Service.Frame

  @alice "00000000-0000-4000-8000-000000000061"
  @bob "00000000-0000-4000-8000-000000000062"
  defmodule Handler do
    @moduledoc false
    # Forwards to the test process; refuses items while `:refuse` is set.
    @behaviour SalixSignal.Account.Handler

    def handle_inbound(account_id, seq, inbound) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :test}),
        {:handler_inbound, account_id, seq, inbound}
      )

      case SystemsRuntime.PersistentTerm.get({__MODULE__, :refuse}, 0) do
        0 ->
          :ok

        n ->
          SystemsRuntime.PersistentTerm.put({__MODULE__, :refuse}, n - 1)
          {:error, :busy}
      end
    end

    def incoming_call(_account_id, _info), do: :needs_permission
    def admit_call(_account_id, _info, _connection), do: {:error, :not_bound}

    def handle_event(account_id, event),
      do:
        SystemsRuntime.Proc.send(
          SystemsRuntime.PersistentTerm.get({__MODULE__, :test}),
          {:handler_event, account_id, event}
        )
  end

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    SystemsRuntime.PersistentTerm.put({Handler, :test}, SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put({Handler, :refuse}, 0)
    SystemsRuntime.PersistentTerm.put({Handler, :clock}, nil)
    {:ok, upgrades} = Agent.start_link(fn -> [] end)

    server =
      start_supervised!(
        {Bandit, FakeChat.bandit_options(SystemsRuntime.Proc.self(), chain, upgrades)}
      )

    {:ok, service} = MockService.start_link()

    alice = SignalAccount.new(service, @alice)
    bob = SignalAccount.new(service, @bob, store: :postgres)
    id = bob.account_id

    # The owner's clock: the system clock unless a test sets one.
    clock = fn ->
      SystemsRuntime.PersistentTerm.get({Handler, :clock}, nil) ||
        SystemsClock.system_time(:millisecond)
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
    settle_receive({:fake_chat, :connected, socket})
    %{id: id, pid: pid, opts: opts, socket: socket, service: service, alice: alice, bob: bob}
  end

  # A new owner process for the account, as after a node change: a new
  # claim and nothing carried over in memory.
  defp restart_owner(%{id: id, opts: opts}) do
    :ok = Accounts.stop_local(id)
    {:ok, pid} = Accounts.start_local(id, opts)
    settle_receive({:fake_chat, :connected, socket})
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

      SystemsRuntime.Proc.send(socket, {:send, Frame.encode_request(request)})
      {id, guid}
    end)
  end

  # The delivery cursor of the owner's delivery process once that process
  # has finished its current step.
  defp delivered(pid), do: :sys.get_state(:sys.get_state(pid).delivery, :infinity).delivered

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

    settle_receive({:fake_chat, :frame, ^socket, %Frame.Response{id: ^request_id, status: 200}})
    assert Storage.admitted?(id, guid)
    settle_receive({:handler_inbound, ^id, seq, %Inbound{sender: @alice} = inbound})
    assert body(inbound) == "hello owner"
    settle_receive({:handler_event, ^id, {:profile_key_changed, @alice}})
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
    settle_receive({:fake_chat, :connected, socket})

    {{:ok, _}, alice} =
      SignalAccount.run(ctx.alice, fn pipeline ->
        Pipeline.send_content(pipeline, "PNI:" <> pni, Content.text(1000, "pair"),
          timestamp: 1000,
          sealed: false
        )
      end)

    [{_guid, envelope}] = MockService.queued(ctx.service, "PNI:" <> pni, 1)

    SystemsRuntime.Proc.send(
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
    settle_receive({:handler_inbound, ^id, _, %Inbound{sender: @alice}})
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

  test "a refused item is handed over again and the cursor waits for it",
       %{id: id, pid: pid, socket: socket, alice: alice} = context do
    SystemsRuntime.PersistentTerm.put({Handler, :refuse}, 1)
    alice_sends(alice, "try again")
    [{request_id, _guid}] = push_queued(context, 20)

    settle_receive({:fake_chat, :frame, ^socket, %Frame.Response{id: ^request_id, status: 200}})
    settle_receive({:handler_inbound, ^id, seq, _inbound})
    settle_receive({:handler_inbound, ^id, ^seq, inbound})
    assert body(inbound) == "try again"
    assert delivered(pid) == seq
    assert {:ok, %{delivered_seq: ^seq}} = Storage.claim(id, node())
  end

  test "a newer owner claim fences the process: nothing is committed or acknowledged",
       %{id: id, pid: pid, socket: socket, alice: alice} = context do
    ref = SystemsRuntime.Proc.monitor(pid)
    {:ok, _newer} = Storage.claim(id, node())
    alice_sends(alice, "for the next owner")
    [{request_id, guid}] = push_queued(context, 30)

    settle_receive({:DOWN, ^ref, :process, ^pid, {:shutdown, :fenced}})
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
    chat = :sys.get_state(pid, :infinity).chat
    reports = :erlang.term_to_binary({:sys.get_status(pid), :sys.get_status(chat)})

    for secret <- [bob.identity.private, bob.profile_key, "device-password"] do
      assert :binary.match(reports, secret) == :nomatch
    end

    assert :binary.match(
             :erlang.term_to_binary(:sys.get_state(pid, :infinity)),
             bob.identity.private
           ) !=
             :nomatch
  end

  # Strictly increasing send timestamps (owner decision; CRS-07 §2 and
  # §5.4: a receiver drops a second message with the same author and
  # timestamp). The next owner may run on a node whose clock is behind.
  test "send timestamps keep increasing across a new owner whose clock is behind", context do
    %{id: id} = context
    ahead = SystemsClock.system_time(:millisecond) + 60_000
    SystemsRuntime.PersistentTerm.put({Handler, :clock}, ahead)

    assert {:ok, %{timestamp: ^ahead}} = Account.send_text(id, @alice, "one")
    assert {:ok, %{timestamp: second}} = Account.send_text(id, @alice, "two")
    assert second == ahead + 1

    SystemsRuntime.PersistentTerm.put({Handler, :clock}, ahead - 5_000)
    restart_owner(context)

    assert {:ok, %{timestamp: third}} = Account.send_text(id, @alice, "three")
    assert third > second
  end
end
