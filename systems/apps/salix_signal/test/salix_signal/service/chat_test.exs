defmodule SalixSignal.Service.ChatTest do
  require SystemsRuntime.Proc

  # Behavior of the chat socket client against a fake chat service written
  # from CRS-01 sections 6 to 11 and CRS-15 section 9.
  use SystemsClock.Case, async: true

  alias SalixSignal.Service.{Chat, Credentials, Response}
  alias SalixSignal.Test.FakeChat
  alias SalixSignalProto.Service.Frame

  @aci "3f0f4b1c-5d2e-4a6b-8c7d-9e0f1a2b3c4d"

  # A loaded machine can take seconds for a TLS connect and upgrade. The
  # clients here wait up to @client_connect_ms before they give up and
  # retry, because some tests queue one server answer per upgrade attempt;
  # the tests wait longer than that.
  @client_connect_ms 30_000
  @connect_ms 45_000

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} = context do
    {:ok, upgrades} = Agent.start_link(fn -> Map.get(context, :upgrades, []) end)

    server =
      start_supervised!(
        {Bandit,
         FakeChat.bandit_options(SystemsRuntime.Proc.self(), chain, upgrades,
           auto_keepalive: Map.get(context, :auto_keepalive, true),
           upgrade_headers: [{"x-signal-alert", " idle-primary-device , "}]
         )}
      )

    %{port: FakeChat.port(server)}
  end

  defp start_chat(context, opts \\ []) do
    defaults = [
      owner: SystemsRuntime.Proc.self(),
      host: "localhost",
      port: context.port,
      roots: [context.chain.root],
      credentials: Credentials.device(@aci, 2, "device-password"),
      backoff: [base_ms: 10, max_ms: 40],
      connect_timeout_ms: @client_connect_ms,
      user_agent: "Salix-Signal-Test/1"
    ]

    start_supervised!(
      Supervisor.child_spec({Chat, Keyword.merge(defaults, opts)},
        id: SystemsRuntime.Proc.make_ref()
      )
    )
  end

  defp connected(chat) do
    assert_receive {:signal_chat, ^chat, {:connected, info}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms
    {socket, info}
  end

  defp flush_upgrades(count \\ 0) do
    SystemsRuntime.Proc.receive do
      {:fake_chat, :upgrade, _} -> flush_upgrades(count + 1)
    after
      0 -> count
    end
  end

  defp push(socket, request),
    do: SystemsRuntime.Proc.send(socket, {:send, Frame.encode_request(request)})

  test "the upgrade authenticates the device and pushed envelopes wait for the owner's ack",
       context do
    chat = start_chat(context)

    assert_receive {:fake_chat, :upgrade, headers}, @connect_ms
    expected_auth = "Basic " <> Base.encode64("#{@aci}.2:device-password")
    assert {"authorization", expected_auth} in headers
    assert {"user-agent", "Salix-Signal-Test/1"} in headers
    assert {"x-signal-receive-stories", "false"} in headers
    refute List.keymember?(headers, "x-signal-disable-messages", 0)

    {socket, info} = connected(chat)
    assert info == %{server_time_ms: 1_758_790_000_000, alerts: ["idle-primary-device"]}

    push(socket, %Frame.Request{
      verb: "PUT",
      path: "/api/v1/message",
      id: 77,
      body: <<8, 1>>,
      headers: [{"X-Signal-Timestamp", "1758790000123"}]
    })

    assert_receive {:signal_chat, ^chat, {:message, <<8, 1>>, 1_758_790_000_123, token}}
    # The server keeps the envelope until the owner has committed it.
    refute_receive {:fake_chat, :frame, _, %Frame.Response{id: 77}}, 100

    assert Chat.ack(chat, token) == :ok
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Response{id: 77, status: 200} = ack}
    assert ack.message == "OK"

    push(socket, %Frame.Request{verb: "PUT", path: "/api/v1/queue/empty", id: 78})
    assert_receive {:signal_chat, ^chat, :queue_empty}
  end

  test "a lost socket fails outstanding requests, fences old acks and reconnects", context do
    chat = start_chat(context)
    {socket, _info} = connected(chat)

    push(socket, %Frame.Request{verb: "PUT", path: "/api/v1/message", id: 5, body: "e"})
    assert_receive {:signal_chat, ^chat, {:message, "e", 0, old_token}}

    pending = SystemsRuntime.Task.async(fn -> Chat.request(chat, "GET", "/v1/slow") end)
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/slow"}}

    SystemsRuntime.Proc.send(socket, {:close, 1011})
    assert SystemsRuntime.Task.await(pending, :infinity) == {:error, :disconnected}
    assert_receive {:signal_chat, ^chat, {:disconnected, {:closed, 1011}}}

    {new_socket, _info} = connected(chat)
    assert new_socket != socket
    # The envelope is pushed again on the new socket; the old answer is void.
    assert Chat.ack(chat, old_token) == {:error, :stale}
  end

  @tag upgrades: [{:reject, 403, []}]
  test "an upgrade refused for credentials stops the client", context do
    chat = start_chat(context)
    assert_receive {:fake_chat, :upgrade, _}, @connect_ms
    assert_receive {:signal_chat, ^chat, {:stopped, :unauthorized}}, @connect_ms
    # A slow first attempt can have been retried before the refusal; only
    # an upgrade after the stop would be a reconnect.
    flush_upgrades()
    refute_receive {:fake_chat, :upgrade, _}, 100
    assert Chat.phase(chat) == {:stopped, :unauthorized}
  end

  test "a server that does not chain to the pinned roots is refused", context do
    other = FakeChat.chain()
    chat = start_chat(context, roots: [other.root])

    assert_receive {:signal_chat, ^chat, {:disconnected, {:connect_failed, error}}}, @connect_ms
    assert %Mint.TransportError{reason: {:tls_alert, _}} = error
    refute_received {:fake_chat, :upgrade, _}
  end
end
