defmodule SalixIM.LarkSocketTest do
  @moduledoc """
  The long connection of a Lark app made by a scan, against a fake Lark:
  `POST /callback/ws/endpoint` answers the socket's address, and the socket
  forwards each frame the client sends to the test, which sends frames back.
  The handler of an envelope is the test's, so these tests check the
  connection alone; `SalixIM.LarkInbound` has its own.
  """
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixIM", "Elixir.ThousandIsland", "Elixir.Bandit"]

  require SystemsRuntime.Proc

  alias SalixIM.LarkSocket
  alias SalixIM.LarkSocket.Frame
  alias SalixIM.TestSupport.BanditServer

  defmodule FakeLark do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/callback/ws/endpoint"} = conn, %{test: test} = opts) do
      {:ok, raw, conn} = read_body(conn)
      SystemsRuntime.Proc.send(test, {:fake_lark, :endpoint, Jason.decode!(raw)})

      body =
        case Agent.get_and_update(opts.endpoints, fn
               [next | rest] -> {next, rest}
               [] -> {:accept, []}
             end) do
          :accept ->
            %{
              "code" => 0,
              "data" => %{
                "URL" => "ws://127.0.0.1:#{conn.port}/ws?device_id=d1&service_id=7",
                "ClientConfig" => %{"PingInterval" => 120}
              }
            }

          {:refuse, code} ->
            %{"code" => code, "msg" => "refused"}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end

    def call(%{request_path: "/ws"} = conn, %{test: test}) do
      conn
      |> WebSockAdapter.upgrade(SalixIM.LarkSocketTest.FakeSocket, %{test: test}, [])
      |> halt()
    end
  end

  defmodule FakeSocket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{test: test} = state) do
      SystemsRuntime.Proc.send(test, {:fake_lark, :socket, SystemsRuntime.Proc.self()})
      {:ok, state}
    end

    @impl true
    def handle_in({bytes, opcode: :binary}, %{test: test} = state) do
      {:ok, frame} = Frame.decode(bytes)
      SystemsRuntime.Proc.send(test, {:fake_lark, :frame, frame})
      {:ok, state}
    end

    def handle_in(_other, state), do: {:ok, state}

    @impl true
    def handle_info({:send, bytes}, state), do: {:push, {:binary, bytes}, state}
    def handle_info(:close, state), do: {:stop, :normal, 1000, state}
    def handle_info(_message, state), do: {:ok, state}
  end

  setup context do
    {:ok, endpoints} = Agent.start_link(fn -> Map.get(context, :endpoints, []) end)

    base =
      BanditServer.serve!(FakeLark, %{test: SystemsRuntime.Proc.self(), endpoints: endpoints})

    previous = SystemsRuntime.get_env(:salix_im, :lark_socket_base_url)
    SystemsRuntime.put_env(:salix_im, :lark_socket_base_url, base)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_im, :lark_socket_base_url, previous),
        else: SystemsRuntime.delete_env(:salix_im, :lark_socket_base_url)
    end)

    :ok
  end

  @connect %{
    "connect_id" => "cnx_socket",
    "provider" => "lark",
    "events" => "socket",
    "app_id" => "cli_scan",
    "app_secret" => "scan-secret"
  }

  defp start_socket(handler) do
    test = SystemsRuntime.Proc.self()

    handler =
      handler ||
        fn _connect, envelope ->
          SystemsRuntime.Proc.send(test, {:handled, envelope})
          {:ok, %{}}
        end

    start_supervised!(
      {LarkSocket,
       connect: @connect,
       task_supervisor: start_supervised!(SystemsRuntime.TaskSupervisor),
       handler: handler,
       catch_up: catch_up(test)}
    )

    settle_receive(
      {:fake_lark, :endpoint, %{"AppID" => "cli_scan", "AppSecret" => "scan-secret"}}
    )

    settle_receive({:fake_lark, :socket, socket})
    socket
  end

  defp catch_up(test),
    do: fn _connect, since, _handler -> SystemsRuntime.Proc.send(test, {:catch_up, since}) end

  defp push(socket, frame), do: SystemsRuntime.Proc.send(socket, {:send, Frame.encode(frame)})

  defp event(id, payload, headers \\ []),
    do:
      Frame.new(
        seq_id: 9,
        log_id: 4,
        service: 7,
        method: Frame.data(),
        headers: [{"type", "event"}, {"message_id", id}, {"trace_id", "t1"}] ++ headers,
        payload: payload
      )

  test "a frame is protobuf pbbp2.Frame as the Lark SDKs write it" do
    # A ping for service 7: SeqID 0, LogID 0, service 7, method 0, one header.
    bytes =
      <<0x08, 0x00, 0x10, 0x00, 0x18, 0x07, 0x20, 0x00, 0x2A, 0x0C, 0x0A, 0x04, "type", 0x12,
        0x04, "ping">>

    assert Frame.encode(Frame.ping(7)) == bytes
    assert {:ok, frame} = Frame.decode(bytes)
    assert frame.service == 7 and frame.method == Frame.control()
    assert Frame.header(frame, "type") == "ping"
    assert Frame.decode(<<0xFF, 0xFF>>) == :error
  end

  test "opens with the app's credentials, pings its service, and answers each handled event" do
    socket = start_socket(nil)

    settle_receive({:fake_lark, :frame, ping})
    assert Frame.header(ping, "type") == "ping"
    assert ping.service == 7

    envelope = %{"header" => %{"event_type" => "im.message.receive_v1", "event_id" => "ev1"}}
    push(socket, event("m1", Jason.encode!(envelope)))

    settle_receive({:handled, ^envelope})
    settle_receive({:fake_lark, :frame, answer})
    assert Frame.header(answer, "message_id") == "m1"
    assert Frame.header(answer, "biz_rt") == "0"
    assert answer.seq_id == 9 and answer.log_id == 4
    assert Jason.decode!(answer.payload) == %{"code" => 200}
  end

  test "puts an envelope sent in parts together before handling it" do
    socket = start_socket(nil)
    settle_receive({:fake_lark, :frame, _ping})

    json = Jason.encode!(%{"header" => %{"event_type" => "im.message.receive_v1"}, "pad" => "x"})
    {first, second} = String.split_at(json, 20)

    push(socket, event("big", second, [{"sum", "2"}, {"seq", "1"}]))
    settle_refute_receive({:handled, _envelope}, 200)
    push(socket, event("big", first, [{"sum", "2"}, {"seq", "0"}]))

    settle_receive({:handled, %{"pad" => "x"}})
  end

  test "a card's answer goes back as the card; a failed event is answered as failed, so Lark sends it again" do
    card = %{"card" => %{"type" => "raw", "data" => %{"elements" => []}}}

    handler = fn _connect, envelope ->
      case envelope["header"]["event_type"] do
        "card.action.trigger" -> {:ok, card}
        _other -> {:error, :delivery_failed}
      end
    end

    socket = start_socket(handler)
    settle_receive({:fake_lark, :frame, _ping})

    push(
      socket,
      event("failed", Jason.encode!(%{"header" => %{"event_type" => "im.message.receive_v1"}}))
    )

    push(
      socket,
      Frame.new(
        service: 7,
        method: Frame.data(),
        headers: [{"type", "card"}, {"message_id", "press"}],
        payload: Jason.encode!(%{"header" => %{"event_type" => "card.action.trigger"}})
      )
    )

    answers =
      for _ <- 1..2 do
        settle_receive({:fake_lark, :frame, answer})
        {Frame.header(answer, "message_id"), Jason.decode!(answer.payload)}
      end
      |> Map.new()

    # As the Lark SDKs answer a handler that failed.
    assert answers["failed"] == %{"code" => 500}
    assert %{"code" => 200, "data" => data} = answers["press"]
    assert Jason.decode!(Base.decode64!(data)) == card
    settle_refute_receive({:fake_lark, :frame, _other}, 200)
  end

  test "an envelope past the envelopes handled at a time waits for a free slot and is answered" do
    test = SystemsRuntime.Proc.self()

    # Each handler waits until the test lets it finish.
    handler = fn _connect, envelope ->
      SystemsRuntime.Proc.send(test, {:handling, envelope["n"], SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :finish -> {:ok, %{}}
      end
    end

    socket = start_socket(handler)
    settle_receive({:fake_lark, :frame, _ping})

    for n <- 1..17, do: push(socket, event("m#{n}", Jason.encode!(%{"n" => n})))

    handling =
      for _ <- 1..16 do
        settle_receive({:handling, n, pid})
        {n, pid}
      end

    assert Enum.map(handling, &elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..16)
    # The 17th is not dropped and not answered: it waits.
    settle_refute_receive({:handling, 17, _pid}, 200)
    settle_refute_receive({:fake_lark, :frame, _answer}, 0)

    {_n, first} = hd(handling)
    SystemsRuntime.Proc.send(first, :finish)
    settle_receive({:fake_lark, :frame, _answer})
    settle_receive({:handling, 17, last})

    for {_n, pid} <- tl(handling), do: SystemsRuntime.Proc.send(pid, :finish)
    SystemsRuntime.Proc.send(last, :finish)

    answered =
      for _ <- 1..16 do
        settle_receive({:fake_lark, :frame, answer})
        assert Jason.decode!(answer.payload) == %{"code" => 200}
        Frame.header(answer, "message_id")
      end

    assert "m17" in answered
  end

  @tag endpoints: [{:refuse, 1_000_040_345}]
  test "asks for a new address and opens again when Lark refuses or closes the socket, then reads back what was said since" do
    started = SystemsClock.system_time(:millisecond)

    start_supervised!(
      {LarkSocket,
       connect: @connect,
       task_supervisor: start_supervised!(SystemsRuntime.TaskSupervisor),
       handler: fn _connect, _envelope -> {:ok, %{}} end,
       catch_up: catch_up(SystemsRuntime.Proc.self())}
    )

    # Refused first, then accepted after the backoff.
    settle_receive({:fake_lark, :endpoint, _first})
    settle_receive({:fake_lark, :endpoint, _second})
    settle_receive({:fake_lark, :socket, socket})

    # A socket that just started reads back the ten minutes before it.
    settle_receive({:catch_up, since})
    assert since == started - 10 * 60_000

    SystemsRuntime.Proc.send(socket, :close)
    settle_receive({:fake_lark, :endpoint, _third})
    settle_receive({:fake_lark, :socket, _again})

    # Once open again: what was said since the socket was lost.
    settle_receive({:catch_up, lost})
    assert lost > started
    settle_refute_receive({:catch_up, _more}, 200)
  end

  test "a Feishu connect opens its socket on Feishu with the app's credentials" do
    base = SystemsRuntime.get_env(:salix_im, :lark_socket_base_url)
    previous = SystemsRuntime.get_env(:salix_im, :feishu_socket_base_url)
    SystemsRuntime.put_env(:salix_im, :feishu_socket_base_url, base)
    # Lark's host would refuse it.
    SystemsRuntime.put_env(:salix_im, :lark_socket_base_url, "http://127.0.0.1:1")
    on_exit(fn -> SystemsRuntime.put_env(:salix_im, :feishu_socket_base_url, previous) end)

    test = SystemsRuntime.Proc.self()
    connect = %{@connect | "connect_id" => "cnx_feishu", "provider" => "feishu"}

    start_supervised!(
      {LarkSocket,
       connect: connect,
       task_supervisor: start_supervised!(SystemsRuntime.TaskSupervisor),
       handler: fn _connect, envelope ->
         SystemsRuntime.Proc.send(test, {:handled, envelope})
         {:ok, %{}}
       end,
       catch_up: catch_up(test)}
    )

    settle_receive(
      {:fake_lark, :endpoint, %{"AppID" => "cli_scan", "AppSecret" => "scan-secret"}}
    )

    settle_receive({:fake_lark, :socket, socket})
    envelope = %{"header" => %{"event_type" => "im.message.receive_v1", "event_id" => "ev-fs"}}
    push(socket, event("m-fs", Jason.encode!(envelope)))
    settle_receive({:handled, ^envelope})
  end

  test "one socket per connect on a node" do
    _socket = start_socket(nil)
    assert {pid, credentials} = LarkSocket.whereis("cnx_socket")
    assert is_pid(pid)
    assert credentials == LarkSocket.credentials(@connect)

    assert :ignore ==
             LarkSocket.init(connect: @connect, handler: fn _c, _e -> {:ok, %{}} end)
  end
end
