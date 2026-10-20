defmodule SalixEnv.BridgeDispatchTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The connector RPC round trip without a real WebSocket: a fake socket-owner
  process registers in `SalixEnv.Bridges` and answers `:env_rpc` messages, so we
  can exercise `SalixEnv.Bridge.rpc/3` and `SalixEnv.Connector.Live` end to end
  (local node path, disconnected/missing/timeout, and the durable record gate).
  """
  use SystemsClock.Case, async: false
  require SystemsClock

  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SalixEnv"]
  alias SalixEnv.{Bridge, Connector, Protocol, Registry}
  alias SalixStore.Ids

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_takeover_timeout = SystemsRuntime.get_env(:salix_env, :bridge_takeover_timeout_ms)
    prev_kill_timeout = SystemsRuntime.get_env(:salix_env, :bridge_kill_timeout_ms)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    # SalixEnv.Bridge.registry() is started by SalixEnv.Application.

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      restore_env(:bridge_takeover_timeout_ms, prev_takeover_timeout)
      restore_env(:bridge_kill_timeout_ms, prev_kill_timeout)
    end)

    {:ok, env: "env-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_env, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_env, key, value)

  defp connect_record(transport_id, owner_node, extra_meta \\ %{}) do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    Registry.connect(
      owner_node,
      Map.merge(
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => Ids.new_device_id(),
          "connector_id" => "connector-#{SystemsRuntime.Proc.unique_integer([:positive])}",
          "alias" => "laptop"
        },
        extra_meta
      ),
      transport_id: transport_id
    )
  end

  # A stand-in for SalixWeb.ConnectorSocket: registers as the env's owner and
  # replies to :env_rpc by running `handler.(message)`.
  defp start_fake_owner(env_id, handler, opts \\ []) do
    test = SystemsRuntime.Proc.self()
    takeover = Keyword.get(opts, :takeover, :stop)

    pid =
      SystemsRuntime.Proc.spawn_link(fn ->
        Bridge.register_owner(env_id)
        SystemsRuntime.Proc.send(test, :owner_ready)
        fake_owner_loop(env_id, handler, test, takeover)
      end)

    SystemsClock.vreceive do
      :owner_ready -> pid
    after
      7_000 -> flunk("owner did not register")
    end
  end

  defp fake_owner_loop(env_id, handler, test, takeover) do
    SystemsRuntime.Proc.receive do
      {:env_rpc, ref, from, message} ->
        SystemsRuntime.Proc.send(from, {:env_rpc_reply, ref, handler.(message)})
        fake_owner_loop(env_id, handler, test, takeover)

      {:env_owner_takeover, ^env_id, _new_owner} ->
        SystemsRuntime.Proc.send(test, {:owner_takeover, SystemsRuntime.Proc.self()})

        case takeover do
          :ignore -> fake_owner_loop(env_id, handler, test, takeover)
          :stop -> :ok
        end

      :stop ->
        :ok
    end
  end

  test "Bridge.rpc round trips through the registered owner", %{env: env} do
    start_fake_owner(env, fn message ->
      assert message["method"] == "exec"

      Protocol.outcome(%{
        "type" => "response",
        "result" => %{"echo" => message["params"]["command"]}
      })
    end)

    assert {:ok, %{"echo" => "ls -la"}} =
             Bridge.rpc(env, Protocol.request("exec", %{"command" => "ls -la"}), 1000)
  end

  test "Bridge.rpc returns :disconnected when no owner is registered", %{env: env} do
    assert {:error, :disconnected} = Bridge.rpc(env, Protocol.request("read", %{}), 500)
  end

  test "remote read dispatch runs in the bounded supervisor and streams through transfer", %{
    env: env
  } do
    test = SystemsRuntime.Proc.self()
    supervisor = start_supervised!({SystemsRuntime.TaskSupervisor, max_children: 1})

    owner =
      SystemsRuntime.Proc.spawn_link(fn ->
        Bridge.register_owner(env)
        SystemsRuntime.Proc.send(test, :remote_read_owner_ready)

        SystemsRuntime.Proc.receive do
          {:env_read_stream, ref, from, _message} ->
            {:ok, receiver} = SalixEnv.FrameStream.start_link()

            SystemsRuntime.Proc.send(
              from,
              {:env_read_stream_reply, ref, {:ok, SalixEnv.FrameStream.stream(receiver), nil}}
            )

            :ok = SalixEnv.FrameStream.chunk(receiver, "remote-bytes", 100)
            :ok = SalixEnv.FrameStream.eof(receiver, 100)
        end
      end)

    settle_receive(:remote_read_owner_ready)

    assert {:ok, stream, nil} =
             Connector.Live.start_remote_read_stream(
               node(),
               env,
               Protocol.request("read_stream", %{"path" => "/remote"}),
               500,
               supervisor: supervisor,
               absolute_timeout_ms: 2_000
             )

    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == "remote-bytes"
    assert eventually(fn -> SystemsRuntime.TaskSupervisor.children(supervisor) == [] end)
    refute SystemsRuntime.Proc.alive?(owner)
  end

  test "register_owner lets a reconnecting owner take over the local env id", %{env: env} do
    SystemsRuntime.Proc.trap_exit(true)

    old =
      start_fake_owner(env, fn _message ->
        {:ok, %{"owner" => "old"}}
      end)

    new =
      start_fake_owner(env, fn _message ->
        {:ok, %{"owner" => "new"}}
      end)

    assert {:ok, %{"owner" => "new"}} =
             Bridge.rpc(env, Protocol.request("read", %{"path" => "/x"}), 1000)

    settle_receive({:owner_takeover, ^old})
    refute SystemsRuntime.Proc.alive?(old)
    SystemsRuntime.Proc.exit(new, :kill)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  def handle_remote_read_telemetry(event, measurements, metadata, pid) do
    SystemsRuntime.Proc.send(pid, {:remote_read_telemetry, event, measurements, metadata})
  end

  test "Connector.Live routes to the local owner for a connected record", %{env: env} do
    {:ok, ^env, record} = connect_record(env, to_string(node()))
    connector_run_id = record["connector_run_id"]

    start_fake_owner(env, fn _message ->
      {:ok, %{"exit_code" => 0, "stdout" => "ok"}}
    end)

    assert {:ok, %{"stdout" => "ok"}} =
             Connector.Live.request(connector_run_id, "exec", %{"command" => "true"})
  end
end
