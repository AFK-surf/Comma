defmodule SalixSignal.CallMedia.TLSRelayTest do
  use ExUnit.Case, async: true

  alias SalixSignal.CallMedia.TLSRelay
  alias SalixSignal.Test.FakeChat
  alias ExSTUN.Message
  alias ExSTUN.Message.Type
  alias ExSTUN.Message.Attribute.{ErrorCode, Nonce, Realm, XORMappedAddress}
  alias ExTURN.Attribute.{Lifetime, XORRelayedAddress}

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, listener} =
      :ssl.listen(
        0,
        [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true] ++ chain.server
      )

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    %{listener: listener, port: port}
  end

  defp accept(listener) do
    {:ok, socket} = :ssl.transport_accept(listener, 5_000)
    {:ok, socket} = :ssl.handshake(socket, 5_000)
    socket
  end

  defp request(socket) do
    {:ok, <<_type::16, length::16, _::binary-size(16)>> = header} = :ssl.recv(socket, 20, 5_000)
    payload = if length == 0, do: <<>>, else: elem(:ssl.recv(socket, length, 5_000), 1)
    {:ok, message} = Message.decode(header <> payload)
    message
  end

  test "mixed Signal relay URLs use only TLS and refresh the allocation", ctx do
    test_pid = self()
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, udp_port}} = :inet.sockname(udp)
    on_exit(fn -> :gen_udp.close(udp) end)

    server =
      Task.async(fn ->
        socket = accept(ctx.listener)
        req = request(socket)
        assert req.type == %Type{class: :request, method: :allocate}

        challenge =
          Message.new(req.transaction_id, %Type{class: :error_response, method: :allocate}, [
            %ErrorCode{code: 401},
            %Nonce{value: "test-nonce"},
            %Realm{value: "test-realm"}
          ])
          |> Message.with_fingerprint()
          |> Message.encode()

        :ok = :ssl.send(socket, challenge)
        req = request(socket)
        key = Message.lt_key("user", "password", "test-realm")
        assert :ok = Message.authenticate(req, key)

        response =
          Message.new(req.transaction_id, %Type{class: :success_response, method: :allocate}, [
            %XORRelayedAddress{address: {192, 0, 2, 42}, port: 45000},
            %XORMappedAddress{address: {192, 0, 2, 43}, port: 46000},
            %Lifetime{value: 2}
          ])
          |> Message.with_integrity(key)
          |> Message.with_fingerprint()
          |> Message.encode()

        # TLS records are not TURN packet boundaries.
        <<first::binary-size(7), rest::binary>> = response
        :ok = :ssl.send(socket, first)
        :ok = :ssl.send(socket, rest)
        send(test_pid, :allocated)
        refresh = request(socket)
        assert refresh.type == %Type{class: :request, method: :refresh}
        assert :ok = Message.authenticate(refresh, key)

        refreshed =
          Message.new(refresh.transaction_id, %Type{class: :success_response, method: :refresh}, [
            %Lifetime{value: 600}
          ])
          |> Message.with_integrity(key)
          |> Message.with_fingerprint()
          |> Message.encode()

        :ok = :ssl.send(socket, refreshed)
        send(test_pid, :refreshed)
        assert {:error, :closed} = :ssl.recv(socket, 0, 10_000)
      end)

    {:ok, connection} =
      SalixSignal.CallMedia.start_connection(%{
        role: :caller,
        call_id: 123,
        owner: self(),
        caller_identity_key: :crypto.strong_rand_bytes(32),
        callee_identity_key: :crypto.strong_rand_bytes(32),
        ice_servers: [
          %{
            urls: ["turn:127.0.0.1:#{udp_port}?transport=udp", "turns:localhost:#{ctx.port}"],
            username: "user",
            credential: "password"
          }
        ],
        turn_tls: [cacerts: [ctx.chain.root]],
        ice_opts: [ip_filter: fn ip -> tuple_size(ip) == 4 end]
      })

    assert_receive :allocated, 5_000
    assert_receive {:signal_call_media, ^connection, {:local_candidate, candidate}}, 5_000
    assert candidate =~ "192.0.2.42 45000 typ relay"
    assert {:error, :timeout} = :gen_udp.recv(udp, 0, 200)
    assert_receive :refreshed, 5_000
    refute_receive {:signal_call_media, ^connection, {:local_candidate, _}}, 200
    relay = :sys.get_state(connection).tls_relay
    monitor = Process.monitor(relay)
    GenServer.stop(connection)
    assert_receive {:DOWN, ^monitor, :process, ^relay, :normal}
    Task.await(server)
  end

  test "call startup fails when no TLS relay is advertised" do
    assert {:error, :turn_tls_unavailable} =
             SalixSignal.CallMedia.start_connection(%{
               ice_servers: [%{urls: ["turn:127.0.0.1:3478?transport=udp"]}]
             })

    assert {:error, :turn_tls_unavailable} = SalixSignal.CallMedia.start_connection(%{})
  end

  test "ChannelData padding and coalesced TLS frames preserve datagram boundaries", ctx do
    channel = <<0x4000::16, 5::16, "hello">>
    padded = channel <> <<0, 0, 0>>
    stun = Message.new(%Type{class: :indication, method: :binding}) |> Message.encode()

    server =
      Task.async(fn ->
        socket = accept(ctx.listener)
        assert {:ok, ^padded} = :ssl.recv(socket, byte_size(padded), 5_000)
        :ok = :ssl.send(socket, padded <> stun <> padded)
        assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
      end)

    {:ok, relay} =
      TLSRelay.start(
        owner: self(),
        host: "localhost",
        port: ctx.port,
        cacerts: [ctx.chain.root]
      )

    {:ok, uri} = ExSTUN.URI.parse(GenServer.call(relay, :url))
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    :ok = :gen_udp.send(udp, {127, 0, 0, 1}, uri.port, channel)
    assert {:ok, {_, _, ^channel}} = :gen_udp.recv(udp, 0, 5_000)
    assert {:ok, {_, _, ^stun}} = :gen_udp.recv(udp, 0, 5_000)
    assert {:ok, {_, _, ^channel}} = :gen_udp.recv(udp, 0, 5_000)
    TLSRelay.stop(relay)
    :gen_udp.close(udp)
    Task.await(server)
  end

  test "an untrusted certificate is refused before any TURN credentials are sent", ctx do
    server =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(ctx.listener, 5_000)
        assert {:error, _} = :ssl.handshake(socket, 5_000)
      end)

    other = FakeChat.chain()

    assert {:error, :turn_tls_connection_failed} =
             SalixSignal.CallMedia.start_connection(%{
               ice_servers: [
                 %{
                   urls: ["turn:127.0.0.1:3478?transport=udp", "turns:localhost:#{ctx.port}"],
                   username: "user",
                   credential: "password"
                 }
               ],
               turn_tls: [cacerts: [other.root]]
             })

    Task.await(server)
  end

  test "owner loss closes the TLS connection", ctx do
    server =
      Task.async(fn ->
        socket = accept(ctx.listener)
        assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
      end)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, relay} =
      TLSRelay.start(
        owner: owner,
        host: "localhost",
        port: ctx.port,
        cacerts: [ctx.chain.root]
      )

    monitor = Process.monitor(relay)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^relay, :normal}
    Task.await(server)
  end
end
