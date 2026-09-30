defmodule SalixSignal.Service.ChatTest do
  # Behavior of the chat socket client against a fake chat service written
  # from CRS-01 sections 6 to 11 and CRS-15 section 9.
  use ExUnit.Case, async: true

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
         FakeChat.bandit_options(self(), chain, upgrades,
           auto_keepalive: Map.get(context, :auto_keepalive, true),
           upgrade_headers: [{"x-signal-alert", " idle-primary-device , "}]
         )}
      )

    %{port: FakeChat.port(server)}
  end

  defp start_chat(context, opts \\ []) do
    defaults = [
      owner: self(),
      host: "localhost",
      port: context.port,
      roots: [context.chain.root],
      credentials: Credentials.device(@aci, 2, "device-password"),
      backoff: [base_ms: 10, max_ms: 40],
      connect_timeout_ms: @client_connect_ms,
      user_agent: "Salix-Signal-Test/1"
    ]

    start_supervised!(
      Supervisor.child_spec({Chat, Keyword.merge(defaults, opts)}, id: make_ref())
    )
  end

  defp connected(chat) do
    assert_receive {:signal_chat, ^chat, {:connected, info}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms
    {socket, info}
  end

  defp flush_upgrades(count \\ 0) do
    receive do
      {:fake_chat, :upgrade, _} -> flush_upgrades(count + 1)
    after
      0 -> count
    end
  end

  defp push(socket, request), do: send(socket, {:send, Frame.encode_request(request)})

  defp reply(socket, id, status, body \\ nil) do
    send(
      socket,
      {:send, Frame.encode_response(%Frame.Response{id: id, status: status, body: body})}
    )
  end

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

  # CRS-01 section 10.1 and Comma decision 3: only pushed envelopes are
  # answered. Queue-empty, unknown requests and pushes without a request id
  # get no answer, and a push without an id is not reported.
  test "the client answers only pushed envelopes", context do
    chat = start_chat(context)
    {socket, _info} = connected(chat)

    push(socket, %Frame.Request{verb: "PUT", path: "/api/v1/queue/empty", id: 78})
    push(socket, %Frame.Request{verb: "GET", path: "/v1/unknown", id: 79})
    push(socket, %Frame.Request{verb: "PUT", path: "/api/v1/message", id: nil, body: <<1>>})
    push(socket, %Frame.Request{verb: "PUT", path: "/api/v1/message", id: 80, body: <<2>>})

    assert_receive {:signal_chat, ^chat, :queue_empty}
    assert_receive {:signal_chat, ^chat, {:message, <<2>>, 0, token}}
    refute_received {:signal_chat, ^chat, {:message, <<1>>, _, _}}
    assert Chat.ack(chat, token) == :ok

    assert_receive {:fake_chat, :frame, ^socket, %Frame.Response{id: 80, status: 200}}
    refute_receive {:fake_chat, :frame, ^socket, %Frame.Response{}}, 200
  end

  # CRS-01 section 7.3.1: a response without a request id is dropped and the
  # request stays outstanding; a bad status or header line fails only the
  # matched request. The socket stays open.
  test "responses that break the client rules are dropped or fail their request", context do
    chat = start_chat(context)
    {socket, _info} = connected(chat)

    first = Task.async(fn -> Chat.request(chat, "GET", "/v1/first") end)
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/first", id: id1}}
    second = Task.async(fn -> Chat.request(chat, "GET", "/v1/second") end)
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/second", id: id2}}

    send_response = fn fields ->
      inner = struct(Frame.ResponseMessage, fields)
      frame = Frame.FrameMessage.encode(%Frame.FrameMessage{type: 2, response: inner})
      send(socket, {:send, frame})
    end

    send_response.(%{status: 200, message: "OK"})
    send_response.(%{id: id2, status: 200, message: "OK", headers: ["no-colon"]})
    assert Task.await(second) == {:error, :invalid_response}

    reply(socket, id1, 200, "first")
    assert {:ok, %Response{status: 200, body: "first"}} = Task.await(first)
    assert Chat.phase(chat) == :open
  end

  test "a request-only socket asks the server not to push messages", context do
    # Each client names itself, because a slow attempt of the first one can
    # be retried while the second one connects.
    start_chat(context, receive_messages: false, user_agent: "Salix-Signal-Test/requests")
    headers = upgrade_from("Salix-Signal-Test/requests")
    assert {"x-signal-disable-messages", "true"} in headers

    start_chat(context, credentials: nil, user_agent: "Salix-Signal-Test/anonymous")
    headers = upgrade_from("Salix-Signal-Test/anonymous")
    refute List.keymember?(headers, "authorization", 0)
  end

  # The headers of the next upgrade request from the client with `user_agent`.
  defp upgrade_from(user_agent) do
    receive do
      {:fake_chat, :upgrade, headers} ->
        if {"user-agent", user_agent} in headers, do: headers, else: upgrade_from(user_agent)
    after
      @connect_ms -> flunk("no upgrade request from #{user_agent}")
    end
  end

  test "concurrent requests are matched to their responses by request id", context do
    chat = start_chat(context)
    {socket, _info} = connected(chat)

    first = Task.async(fn -> Chat.request(chat, "GET", "/v1/first") end)
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/first", id: id1}}

    second =
      Task.async(fn -> Chat.request(chat, "PUT", "/v1/second", json: %{"a" => 1}) end)

    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/second"} = put}
    assert put.body == ~s({"a":1})
    assert {"content-type", "application/json"} in put.headers
    assert put.id != id1

    reply(socket, put.id, 204)
    reply(socket, id1, 200, "first")

    assert {:ok, %Response{status: 200, body: "first"}} = Task.await(first)
    assert {:ok, %Response{status: 204, body: ""}} = Task.await(second)
  end

  test "requests that the server cannot accept are refused locally", context do
    chat = start_chat(context, max_frame_bytes: 1_024)
    connected(chat)

    assert Chat.request(chat, "GET", "/v1/x", headers: [{"x-value", "a:b"}]) ==
             {:error, {:invalid_header, "x-value"}}

    assert Chat.request(chat, "PUT", "/v1/x", body: :binary.copy("a", 2_000)) ==
             {:error, :too_large}

    assert {:error, :timeout} = Chat.request(chat, "GET", "/v1/unanswered", timeout: 50)
  end

  test "a lost socket fails outstanding requests, fences old acks and reconnects", context do
    chat = start_chat(context)
    {socket, _info} = connected(chat)

    push(socket, %Frame.Request{verb: "PUT", path: "/api/v1/message", id: 5, body: "e"})
    assert_receive {:signal_chat, ^chat, {:message, "e", 0, old_token}}

    pending = Task.async(fn -> Chat.request(chat, "GET", "/v1/slow") end)
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/slow"}}

    send(socket, {:close, 1011})
    assert Task.await(pending) == {:error, :disconnected}
    assert_receive {:signal_chat, ^chat, {:disconnected, {:closed, 1011}}}

    {new_socket, _info} = connected(chat)
    assert new_socket != socket
    # The envelope is pushed again on the new socket; the old answer is void.
    assert Chat.ack(chat, old_token) == {:error, :stale}
  end

  for {code, reason} <- [{4401, :reauthentication_required}, {4409, :connected_elsewhere}] do
    @code code
    @reason reason
    test "close #{code} stops the client without reconnecting", context do
      chat = start_chat(context)
      {socket, _info} = connected(chat)

      # A slow first attempt can have been retried: drop every upgrade seen
      # so far, so that the check below sees only a reconnect.
      assert flush_upgrades() >= 1
      send(socket, {:close, @code})
      assert_receive {:signal_chat, ^chat, {:stopped, @reason}}
      refute_receive {:fake_chat, :upgrade, _}, 200
      assert Chat.request(chat, "GET", "/v1/x") == {:error, @reason}
      assert Chat.phase(chat) == {:stopped, @reason}
    end
  end

  @tag upgrades: [{:reject, 403, []}]
  test "an upgrade refused for credentials stops the client", context do
    chat = start_chat(context)
    assert_receive {:fake_chat, :upgrade, _}, @connect_ms
    assert_receive {:signal_chat, ^chat, {:stopped, :unauthorized}}, @connect_ms
    # A slow first attempt can have been retried before the refusal; only
    # an upgrade after the stop would be a reconnect.
    flush_upgrades()
    refute_receive {:fake_chat, :upgrade, _}, 200
    assert Chat.phase(chat) == {:stopped, :unauthorized}
  end

  @tag upgrades: [{:reject, 429, [{"retry-after", "0"}]}, {:reject, 503, []}]
  test "rate-limited and failed upgrades are retried with backoff", context do
    chat = start_chat(context)
    assert_receive {:signal_chat, ^chat, {:disconnected, {:upgrade_rejected, 429}}}, @connect_ms
    assert_receive {:signal_chat, ^chat, {:disconnected, {:upgrade_rejected, 503}}}, @connect_ms
    connected(chat)
  end

  # The idle checks read an injected clock that only the test moves, so a
  # slow scheduler cannot age the socket; the keepalive timers stay real.
  defp manual_clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {clock, fn -> Agent.get(clock, & &1) end}
  end

  test "keepalive requests keep an answered socket open", context do
    # Each answered keepalive moves the clock a tenth of the idle window;
    # twenty answers span twice the window.
    {clock, now} = manual_clock()
    idle_ms = 1_000

    chat =
      start_chat(context, keepalive_interval_ms: 50, idle_timeout_ms: idle_ms, clock: now)

    connected(chat)

    for _ <- 1..20 do
      assert_receive {:fake_chat, :keepalive, _}
      Agent.update(clock, &(&1 + div(idle_ms, 10)))
    end

    refute_received {:signal_chat, ^chat, {:disconnected, _}}
    assert Chat.phase(chat) == :open
  end

  @tag auto_keepalive: false
  test "a silent server is dropped and the client reconnects", context do
    {clock, now} = manual_clock()
    chat = start_chat(context, keepalive_interval_ms: 50, idle_timeout_ms: 1_000, clock: now)
    {socket, _info} = connected(chat)

    assert_receive {:fake_chat, :frame, ^socket,
                    %Frame.Request{verb: "GET", path: "/v1/keepalive"}}

    # Nothing arrives while the idle window passes.
    Agent.update(clock, &(&1 + 1_000))
    assert_receive {:signal_chat, ^chat, {:disconnected, :keepalive_timeout}}
    connected(chat)
  end

  test "a server that does not chain to the pinned roots is refused", context do
    other = FakeChat.chain()
    chat = start_chat(context, roots: [other.root])

    assert_receive {:signal_chat, ^chat, {:disconnected, {:connect_failed, error}}}, @connect_ms
    assert %Mint.TransportError{reason: {:tls_alert, _}} = error
    refute_received {:fake_chat, :upgrade, _}
  end
end
