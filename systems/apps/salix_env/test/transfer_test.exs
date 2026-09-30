defmodule SalixEnv.TransferTest do
  @moduledoc """
  Cross-node transfer covers one-time tokens, byte delivery
  to the owner, the completion envelope, and TTL expiry. Exercises the real
  Bandit listener started by the app.
  """
  use ExUnit.Case, async: false

  alias SalixEnv.Transfer
  alias SalixEnv.Transfer.StreamReceiver
  alias SalixEnv.Transfer.Tokens

  test "registered token streams bytes to the owner and returns a completion envelope" do
    {:ok, receiver} = StreamReceiver.start_link()
    {_token, url, stream} = StreamReceiver.register!(receiver)
    payload = :crypto.strong_rand_bytes(2048)
    consumer = Task.async(fn -> Enum.to_list(stream) end)

    assert {:ok, %{"ok" => true, "bytes" => 2048}} = Transfer.send_bytes(url, payload)
    assert IO.iodata_to_binary(Task.await(consumer)) == payload
  end

  test "a token is one-time: the second POST 404s" do
    {:ok, receiver} = StreamReceiver.start_link()
    {_token, url, stream} = StreamReceiver.register!(receiver)
    consumer = Task.async(fn -> Enum.to_list(stream) end)

    assert {:ok, %{"ok" => true}} = Transfer.send_bytes(url, "first")
    assert IO.iodata_to_binary(Task.await(consumer)) == "first"

    assert {:error, {404, _}} = Transfer.send_bytes(url, "second")
  end

  test "an unenumerated receiver retires and revokes its token at the idle deadline" do
    {:ok, receiver} =
      StreamReceiver.start_link(idle_timeout_ms: 30, absolute_timeout_ms: 1_000)

    {_token, url, _stream} = StreamReceiver.register!(receiver)
    monitor = Process.monitor(receiver)

    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 300
    assert {:error, {404, _}} = Transfer.send_bytes(url, "late")
  end

  test "the absolute deadline retires a receiver even while idle progress renews" do
    {:ok, receiver} =
      StreamReceiver.start_link(idle_timeout_ms: 1_000, absolute_timeout_ms: 30)

    {_token, _url, _stream} = StreamReceiver.register!(receiver)
    monitor = Process.monitor(receiver)

    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 300
  end

  test "an unconsumed terminal transfer does not retain its receiver" do
    {:ok, receiver} =
      StreamReceiver.start_link(idle_timeout_ms: 30, absolute_timeout_ms: 1_000)

    {token, _url, _stream} = StreamReceiver.register!(receiver)
    monitor = Process.monitor(receiver)
    send(receiver, {:transfer_eof, token, self()})

    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 300
    assert_receive {:transfer_ack, ^token}

    assert_receive {:transfer_complete, ^token, %{"ok" => false, "error" => error}}

    assert error =~ "remote_read_stream_idle_timeout"
  end

  test "owner death retires the receiver, attached worker, and token" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    worker = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, receiver} =
      StreamReceiver.start_link(
        owner: owner,
        idle_timeout_ms: 5_000,
        absolute_timeout_ms: 5_000
      )

    Process.unlink(receiver)
    :ok = StreamReceiver.attach_worker(receiver, worker)
    {_token, url, _stream} = StreamReceiver.register!(receiver)
    receiver_monitor = Process.monitor(receiver)
    worker_monitor = Process.monitor(worker)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, {:shutdown, :owner_down}}, 300
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 300
    assert {:error, {404, _}} = Transfer.send_bytes(url, "late")
  end

  test "unknown token 404s" do
    url = Transfer.advertise_url("bogus-token")
    assert {:error, {404, _}} = Transfer.send_bytes(url, "x")
  end

  test "expired token cannot be claimed" do
    token = Tokens.register(ttl_ms: 0)
    # already expired
    Process.sleep(5)
    assert :error = Tokens.claim(token)
  end

  test "advertise_url is well-formed" do
    url = Transfer.advertise_url("tok123")
    assert url =~ ~r{^http://[^/]+/stream/tok123$}
  end

  test "the advertised port defaults to the listener and supports local port forwarding" do
    previous = Application.get_env(:salix_env, :advertise_port)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:salix_env, :advertise_port)
      else
        Application.put_env(:salix_env, :advertise_port, previous)
      end
    end)

    Application.delete_env(:salix_env, :advertise_port)
    assert URI.parse(Transfer.advertise_url("default")).port == Transfer.port()

    Application.put_env(:salix_env, :advertise_port, 54_400)
    assert URI.parse(Transfer.advertise_url("mapped")).port == 54_400
    assert Transfer.port() != Transfer.advertise_port()
  end
end
