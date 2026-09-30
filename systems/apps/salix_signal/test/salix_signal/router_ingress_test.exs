defmodule SalixSignal.RouterIngressTest do
  # A Signal message end to end (docs/messaging-voice.md): a peer's
  # encrypted envelopes reach a running account owner, the product handler
  # binds the peer with a claim code, and the peer's next message reaches
  # the bound Group's Router Conversation. The account stores the envelope
  # GUID as raw UUID bytes, so only the real pipeline exercises it.
  use ExUnit.Case, async: false

  alias SalixSignal.{Accounts, IMHandler}
  alias SalixSignal.Messaging.Pipeline
  alias SalixSignal.Test.{FakeChat, MockService, SignalAccount}
  alias SalixSignalProto.Service.Frame
  alias SalixStore.{CasRecord, Ids, Keys}

  @alice "00000000-0000-4000-8000-000000000081"
  @comma "00000000-0000-4000-8000-000000000082"

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    SalixAgent.TestSupport.configure_control_fixtures!()
    {:ok, upgrades} = Agent.start_link(fn -> [] end)
    server = start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)})
    {:ok, service} = MockService.start_link()
    alice = SignalAccount.new(service, @alice)
    comma = SignalAccount.new(service, @comma, store: :postgres)

    opts = [
      handler: IMHandler,
      chat: [
        host: "localhost",
        port: FakeChat.port(server),
        roots: [chain.root],
        backoff: [base_ms: 10, max_ms: 40]
      ],
      transport: %{
        identified: MockService.transport(service, {:identified, @comma, 1}),
        unidentified: MockService.transport(service, :unidentified)
      },
      pipeline: [trust_roots: [MockService.trust_root(service)], known_server_certificates: %{}],
      maintenance_interval_ms: 3_600_000,
      delivery_retry_ms: 50
    ]

    {:ok, pid} = Accounts.start_local(comma.account_id, opts)

    on_exit(fn ->
      Accounts.stop_local(comma.account_id)
      SalixAgent.TestSupport.stop_all_agents()
    end)

    assert_receive {:fake_chat, :connected, socket}, 30_000

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group_id), %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_group(group_id),
        &Map.put(&1, "router_agent_id", router["agent_id"])
      )

    %{
      id: comma.account_id,
      pid: pid,
      socket: socket,
      service: service,
      alice: alice,
      tenant: tenant,
      group_id: group_id
    }
  end

  test "a bound peer's message after its claim reaches the Router Conversation", ctx do
    {:ok, claim} =
      SalixIM.SignalConnects.start_claim(ctx.tenant, ctx.group_id, ctx.id, "comma_user:u1")

    alice = send_text(ctx, ctx.alice, claim["command"], 10)

    eventually(fn ->
      match?({:ok, _}, SalixIM.SignalConnects.find_signal_connect(ctx.id, @alice))
    end)

    # The confirmation carries the account's profile key, so the next
    # message is sealed, as a Signal app sends it.
    {_events, alice} = SignalAccount.deliver(alice)
    _alice = send_text(ctx, alice, "What is on my calendar?", 20)

    [input] =
      eventually(fn ->
        router_inputs(ctx.group_id)
        |> Enum.filter(&(&1["source_text"] == "What is on my calendar?"))
        |> case do
          [] -> nil
          found -> found
        end
      end)

    assert input["provider"] == "signal"
    assert input["provider_context"]["from_user_id"] == @alice

    assert input["provider_context"]["event_id"] =~
             ~r/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/

    # Nothing waits for a retry: later messages are not held behind it.
    delivery = :sys.get_state(:sys.get_state(ctx.pid).delivery)
    assert delivery.timer == nil
  end

  defp send_text(ctx, account, text, first_request_id) do
    {{:ok, _info}, account} = SignalAccount.run(account, &Pipeline.send_text(&1, @comma, text))

    ctx.service
    |> MockService.queued(@comma, 1)
    |> Enum.with_index(first_request_id)
    |> Enum.each(fn {{guid, bytes}, request_id} ->
      request = %Frame.Request{verb: "PUT", path: "/api/v1/message", id: request_id, body: bytes}
      send(ctx.socket, {:send, Frame.encode_request(request)})
      MockService.ack(ctx.service, @comma, 1, guid)
    end)

    account
  end

  defp router_inputs(group_id) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        group_id,
        conversation["conversation_id"],
        limit: 50
      )

    for message <- messages,
        origin = get_in(message, ["agent_input", "trusted_origin"]),
        is_map(origin),
        do: origin
  end

  defp eventually(fun, tries \\ 400) do
    case fun.() do
      result when result in [nil, false] and tries > 0 ->
        Process.sleep(25)
        eventually(fun, tries - 1)

      result when result in [nil, false] ->
        flunk("condition not met")

      result ->
        result
    end
  end
end
