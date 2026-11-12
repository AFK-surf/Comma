defmodule SalixAgent.LanTcpSendTest do
  require SystemsRuntime.Proc

  @moduledoc """
  `device.lan_tcp_send`: raw bytes to a host and port on the gateway's network
  through its `lan_tcp_dial` tunnel (`SalixAgent.SSH.DeviceRelay`).

  The connector side of the tunnel is played by the test with a T-Circle's
  limits (8 KiB frames, 16 KiB window) in front of a local listener that
  stands in for the device (a printer's raw port).
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.AgentWorkspace
  alias SalixAgent.Tools.LanGateway
  alias SalixStore.S3

  defmodule Dispatch do
    def get_device(_agent_id, _device_id),
      do: SystemsRuntime.PersistentTerm.get({__MODULE__, :device})

    def open_tunnel(_agent_id, _target, id, params, relay) do
      test = SystemsRuntime.PersistentTerm.get({__MODULE__, :test})
      SystemsRuntime.Proc.send(test, {:open_tunnel, params})

      case SystemsRuntime.PersistentTerm.get({__MODULE__, :tunnel}) do
        {:refuse, reason} ->
          {:error, reason}

        {:device, port, lose_after} ->
          owner = SalixAgent.LanTcpSendTest.TunnelOwner.start(port, id, relay, lose_after, test)

          {:ok,
           %{
             owner: owner,
             result: %{"status" => "connected", "window" => 16_384, "max_frame" => 8_192}
           }}
      end
    end
  end

  # The gateway's end of the tunnel: frames to and from the relay, at most one
  # window unacknowledged each way. With `lose_after`, the connector goes away
  # once it has that many bytes, before acknowledging them; with `:silent` it
  # stays but never acknowledges.
  defmodule TunnelOwner do
    @max_frame 8_192
    @window 16_384

    def start(port, id, relay, lose_after, test) do
      SystemsRuntime.Proc.spawn(fn ->
        {:ok, device} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])

        loop(%{
          device: device,
          id: id,
          relay: relay,
          test: test,
          lose_after: lose_after,
          pending: "",
          sent: 0,
          acked: 0,
          received: 0
        })
      end)
    end

    defp loop(state) do
      SystemsRuntime.Proc.receive do
        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "bytes" => _bytes}}
        when state.lose_after == :silent ->
          loop(state)

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "eof" => true}}
        when state.lose_after == :silent ->
          SystemsRuntime.Proc.send(state.test, :tunnel_ended)
          :gen_tcp.close(state.device)

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "bytes" => bytes}}
        when is_integer(state.lose_after) and
               state.received + byte_size(bytes) >= state.lose_after ->
          :gen_tcp.close(state.device)

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "bytes" => bytes}} ->
          :gen_tcp.send(state.device, bytes)
          received = state.received + byte_size(bytes)

          SystemsRuntime.Proc.send(
            state.relay,
            {:env_tunnel_frame, state.id, %{"channel" => "tcp_ack", "seq" => received}}
          )

          loop(%{state | received: received})

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp_ack", "seq" => seq}} ->
          loop(flush(%{state | acked: seq}))

        {:env_tunnel_send, _relay, _id, %{"channel" => "tcp", "eof" => true}} ->
          :gen_tcp.close(state.device)

        {:tcp, _device, data} ->
          loop(flush(%{state | pending: state.pending <> data}))

        {:tcp_closed, _device} ->
          SystemsRuntime.Proc.send(
            state.relay,
            {:env_tunnel_frame, state.id, %{"channel" => "tcp", "eof" => true}}
          )
      end
    end

    defp flush(%{pending: pending} = state) when pending != "" do
      case min(min(@max_frame, @window - (state.sent - state.acked)), byte_size(pending)) do
        size when size > 0 ->
          <<chunk::binary-size(^size), rest::binary>> = pending
          frame = %{"channel" => "tcp", "bytes" => chunk}
          SystemsRuntime.Proc.send(state.relay, {:env_tunnel_frame, state.id, frame})
          flush(%{state | pending: rest, sent: state.sent + size})

        _full ->
          state
      end
    end

    defp flush(state), do: state
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      dispatch: SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)
    SystemsRuntime.PersistentTerm.put({Dispatch, :test}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      for key <- [:test, :device, :tunnel],
          do: SystemsRuntime.PersistentTerm.erase({Dispatch, key})

      for {app, key, value} <- [
            {:salix_store, :s3_backend, previous.s3},
            {:salix_agent, :env_dispatch, previous.dispatch}
          ] do
        if value,
          do: SystemsRuntime.put_env(app, key, value),
          else: SystemsRuntime.delete_env(app, key)
      end
    end)

    gateway(["http_request", "lan_tcp_dial"])
    {:ok, ctx: %{agent_id: SalixAgent.TestSupport.new_agent_id()}}
  end

  defp gateway(methods) do
    capabilities = %{"lan_gateway" => %{"methods" => methods}}

    SystemsRuntime.PersistentTerm.put(
      {Dispatch, :device},
      {:ok,
       %{
         "device_id" => "dev-gw",
         "environment_id" => "env-gw",
         "status" => "connected",
         "capabilities" => capabilities,
         "environments" => [
           %{
             "environment_id" => "env-gw",
             "environment_provider" => "connector",
             "status" => "connected",
             "capabilities" => capabilities
           }
         ]
       }}
    )
  end

  # A device on the gateway's network: it reads until the sender closes and
  # reports the bytes, or, given a reply, answers after `expect` bytes and
  # closes.
  defp device(opts \\ []) do
    test = SystemsRuntime.Proc.self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listen)

    SystemsRuntime.Proc.spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)

      case Keyword.fetch(opts, :reply) do
        {:ok, reply} ->
          {:ok, request} = :gen_tcp.recv(socket, Keyword.fetch!(opts, :expect))
          :ok = :gen_tcp.send(socket, reply)
          # A printer answers a status query and keeps the job open.
          if Keyword.get(opts, :keep_open),
            do: SystemsRuntime.Proc.send(test, {:device_got, request <> read_all(socket, "")}),
            else: SystemsRuntime.Proc.send(test, {:device_got, request})

          :gen_tcp.close(socket)

        :error ->
          SystemsRuntime.Proc.send(test, {:device_got, read_all(socket, "")})
      end
    end)

    SystemsRuntime.PersistentTerm.put(
      {Dispatch, :tunnel},
      {:device, port, Keyword.get(opts, :lose_after)}
    )

    port
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  # The device finishes reading when the gateway's end closes, which may come
  # after the tool returned.
  defp device_got do
    SystemsRuntime.Proc.receive do
      {:device_got, bytes} -> bytes
    end
  end

  # The silent gateway got the relay's eof: the tunnel did not stay open.
  defp tunnel_ended do
    SystemsRuntime.Proc.receive do
      :tunnel_ended -> true
    end
  end

  defp send_tcp(ctx, args),
    do:
      LanGateway.lan_tcp_send(
        Map.merge(%{"device_id" => "dev-gw", "host" => "192.168.150.19", "port" => 9100}, args),
        ctx
      )

  test "a print job larger than the gateway's window reaches the device whole", %{ctx: ctx} do
    device()
    job = :binary.copy("\eE hello printer\r\n", 3_000)

    assert %{"sent_bytes" => sent} =
             ctx |> send_tcp(%{"data_b64" => Base.encode64(job)}) |> Jason.decode!()

    assert sent == byte_size(job)
    assert_received {:open_tunnel, %{"host" => "192.168.150.19", "port" => 9100}}
    assert device_got() == job
  end

  test "a workspace file is sent as is", %{ctx: ctx} do
    device()
    job = :binary.copy(<<0, 27, 255, ?%>>, 20_000)
    {:ok, write} = AgentWorkspace.prepare_write(ctx.agent_id, "/print/job.pcl", job)
    {:ok, :seeded} = AgentWorkspace.seed_operation(ctx.agent_id, "seed", :seeded, [write])

    assert %{"sent_bytes" => 80_000} =
             ctx |> send_tcp(%{"path" => "/print/job.pcl"}) |> Jason.decode!()

    assert device_got() == job
  end

  test "read_reply returns what the device answers before it closes", %{ctx: ctx} do
    device(expect: 6, reply: "READY\r\n")

    result =
      ctx
      |> send_tcp(%{"data_b64" => Base.encode64("\e%-123"), "read_reply" => true})
      |> Jason.decode!()

    assert result == %{
             "sent_bytes" => 6,
             "reply_b64" => Base.encode64("READY\r\n"),
             "reply_text" => "READY\r\n",
             "reply_bytes" => 7,
             "closed" => true,
             "truncated" => false,
             "timed_out" => false
           }

    assert device_got() == "\e%-123"
  end

  test "a reply that comes early is returned after the rest of the bytes are confirmed",
       %{ctx: ctx} do
    job = "@PJL INFO STATUS\r\n" <> :binary.copy("x", 40_000)
    device(expect: 18, reply: "CODE=10001\r\n", keep_open: true)

    assert %{"reply_text" => "CODE=10001\r\n", "timed_out" => true, "sent_bytes" => 40_018} =
             ctx
             |> send_tcp(%{
               "data_b64" => Base.encode64(job),
               "read_reply" => true,
               "timeout_ms" => 200
             })
             |> Jason.decode!()

    assert device_got() == job
  end

  test "a connector lost before it acknowledged the last bytes is not reported as sent",
       %{ctx: ctx} do
    device(lose_after: 30_000)

    assert {:tool_failure, _, "connection_closed", "user_reportable", _, []} =
             send_tcp(ctx, %{"data_b64" => Base.encode64(:binary.copy("x", 40_000))})

    device(lose_after: 5)

    assert {:tool_failure, _, "connection_closed", "user_reportable", _, []} =
             send_tcp(ctx, %{"data_b64" => Base.encode64("hello printer")})
  end

  test "a gateway that never acknowledges fails the call, with or without a reply, and the tunnel ends",
       %{ctx: ctx} do
    device(lose_after: :silent)

    assert {:tool_failure, _, "gateway_timeout", "user_reportable", _, []} =
             send_tcp(ctx, %{"data_b64" => Base.encode64("ping"), "timeout_ms" => 200})

    assert tunnel_ended()

    device(lose_after: :silent)

    assert {:tool_failure, _, "gateway_timeout", "user_reportable", _, []} =
             send_tcp(ctx, %{
               "data_b64" => Base.encode64(:binary.copy("x", 50_000)),
               "read_reply" => true,
               "timeout_ms" => 200
             })

    assert tunnel_ended()
  end

  test "a gateway without lan_tcp_dial or a refused connection fails before or at the dial",
       %{ctx: ctx} do
    gateway(["http_request"])

    assert {:tool_failure, _, "not_a_lan_gateway", "user_reportable", _, []} =
             send_tcp(ctx, %{"data_b64" => Base.encode64("x")})

    refute_received {:open_tunnel, _}

    gateway(["lan_tcp_dial"])
    SystemsRuntime.PersistentTerm.put({Dispatch, :tunnel}, {:refuse, "connection refused"})

    assert {:tool_failure, content, "gateway_refused", "user_reportable", _, []} =
             send_tcp(ctx, %{"data_b64" => Base.encode64("x")})

    assert content =~ "connection refused"
  end

  test "rejects missing or doubled data and oversized base64", %{ctx: ctx} do
    assert_raise RuntimeError, ~r/data_b64 or path/, fn -> send_tcp(ctx, %{}) end

    assert_raise RuntimeError, ~r/not both/, fn ->
      send_tcp(ctx, %{"data_b64" => "eA==", "path" => "/a"})
    end

    assert_raise RuntimeError, ~r/1 to 65536 bytes/, fn ->
      send_tcp(ctx, %{"data_b64" => Base.encode64(:binary.copy("x", 65_537))})
    end
  end
end
