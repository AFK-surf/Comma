defmodule SalixEnv.BridgeDispatchTest do
  @moduledoc """
  The connector RPC round trip without a real WebSocket: a fake socket-owner
  process registers in `SalixEnv.Bridges` and answers `:env_rpc` messages, so we
  can exercise `SalixEnv.Bridge.rpc/3` and `SalixEnv.Connector.Live` end to end
  (local node path, disconnected/missing/timeout, and the durable record gate).
  """
  use ExUnit.Case, async: false

  alias SalixEnv.{Bridge, Connector, Protocol, Registry}
  alias SalixStore.Ids

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_takeover_timeout = Application.get_env(:salix_env, :bridge_takeover_timeout_ms)
    prev_kill_timeout = Application.get_env(:salix_env, :bridge_kill_timeout_ms)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    # SalixEnv.Bridge.registry() is started by SalixEnv.Application.

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev)
      restore_env(:bridge_takeover_timeout_ms, prev_takeover_timeout)
      restore_env(:bridge_kill_timeout_ms, prev_kill_timeout)
    end)

    {:ok, env: "env-#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_env, key)
  defp restore_env(key, value), do: Application.put_env(:salix_env, key, value)

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
          "connector_id" => "connector-#{System.unique_integer([:positive])}",
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
    test = self()
    takeover = Keyword.get(opts, :takeover, :stop)

    pid =
      spawn_link(fn ->
        Bridge.register_owner(env_id)
        send(test, :owner_ready)
        fake_owner_loop(env_id, handler, test, takeover)
      end)

    receive do
      :owner_ready -> pid
    after
      7_000 -> flunk("owner did not register")
    end
  end

  defp fake_owner_loop(env_id, handler, test, takeover) do
    receive do
      {:env_rpc, ref, from, message} ->
        send(from, {:env_rpc_reply, ref, handler.(message)})
        fake_owner_loop(env_id, handler, test, takeover)

      {:env_owner_takeover, ^env_id, _new_owner} ->
        send(test, {:owner_takeover, self()})

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

  test "Bridge.rpc times out if the owner never replies", %{env: env} do
    start_fake_owner(env, fn _ ->
      Process.sleep(5000)
      {:ok, %{}}
    end)

    assert {:error, :timeout} = Bridge.rpc(env, Protocol.request("read", %{}), 100)
  end

  test "Bridge.read_stream timeout explicitly cancels the exact owner request", %{env: env} do
    test = self()

    owner =
      spawn_link(fn ->
        Bridge.register_owner(env)
        send(test, :read_owner_ready)

        receive do
          {:env_read_stream, ref, from, message} ->
            send(test, {:read_stream_started, ref, from, message["id"]})

            receive do
              {:env_read_stream_cancel, cancel_ref, cancel_from} ->
                send(test, {:read_stream_cancelled, cancel_ref, cancel_from})
            end
        end
      end)

    assert_receive :read_owner_ready
    message = Protocol.request("read_stream", %{"path" => "/never-starts"})

    assert {:error, :timeout} = Bridge.read_stream(env, message, 30)
    assert_receive {:read_stream_started, ref, caller, id}
    assert id == message["id"]
    assert caller == self()
    assert_receive {:read_stream_cancelled, ^ref, ^caller}, 100
    refute Process.alive?(owner)
  end

  test "remote read dispatch rejects before routing when supervised admission is full", %{
    env: env
  } do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :connector, :read_stream],
        &__MODULE__.handle_remote_read_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    supervisor = start_supervised!({Task.Supervisor, max_children: 1})
    token_count = :ets.info(SalixEnv.Transfer.Tokens, :size)

    {:ok, blocker} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :release_remote_read_slot -> :ok
        end
      end)

    message = Protocol.request("read_stream", %{"path" => "/not-routed"})

    assert {:error, :connector_remote_read_stream_capacity_exhausted} =
             Connector.Live.start_remote_read_stream(node(), env, message, 100,
               supervisor: supervisor,
               absolute_timeout_ms: 100
             )

    assert_receive {:remote_read_telemetry, [:salix, :connector, :read_stream], %{},
                    %{outcome: :saturated, transport: :other}}

    assert :ets.info(SalixEnv.Transfer.Tokens, :size) == token_count
    send(blocker, :release_remote_read_slot)
  end

  test "remote read dispatch cleans up when its supervisor is unavailable", %{env: env} do
    token_count = :ets.info(SalixEnv.Transfer.Tokens, :size)

    supervisor = :missing_remote_read_supervisor_for_test

    assert {:error, :connector_remote_read_stream_unavailable} =
             Connector.Live.start_remote_read_stream(
               node(),
               env,
               Protocol.request("read_stream", %{"path" => "/not-routed"}),
               100,
               supervisor: supervisor,
               absolute_timeout_ms: 100
             )

    assert :ets.info(SalixEnv.Transfer.Tokens, :size) == token_count
  end

  test "remote read dispatch runs in the bounded supervisor and streams through transfer", %{
    env: env
  } do
    test = self()
    supervisor = start_supervised!({Task.Supervisor, max_children: 1})

    owner =
      spawn_link(fn ->
        Bridge.register_owner(env)
        send(test, :remote_read_owner_ready)

        receive do
          {:env_read_stream, ref, from, _message} ->
            {:ok, receiver} = SalixEnv.FrameStream.start_link()

            send(
              from,
              {:env_read_stream_reply, ref, {:ok, SalixEnv.FrameStream.stream(receiver), nil}}
            )

            :ok = SalixEnv.FrameStream.chunk(receiver, "remote-bytes", 100)
            :ok = SalixEnv.FrameStream.eof(receiver, 100)
        end
      end)

    assert_receive :remote_read_owner_ready

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
    assert eventually(fn -> Task.Supervisor.children(supervisor) == [] end)
    refute Process.alive?(owner)
  end

  test "remote read absolute deadline releases a worker when transfer never completes", %{
    env: env
  } do
    test = self()
    supervisor = start_supervised!({Task.Supervisor, max_children: 1})

    owner =
      spawn_link(fn ->
        Bridge.register_owner(env)
        send(test, :stalled_remote_read_owner_ready)

        receive do
          {:env_read_stream, ref, from, _message} ->
            {:ok, receiver} = SalixEnv.FrameStream.start_link()
            send(test, {:stalled_remote_read_receiver, receiver})

            send(
              from,
              {:env_read_stream_reply, ref, {:ok, SalixEnv.FrameStream.stream(receiver), nil}}
            )
        end

        receive do
          :stop_stalled_remote_read_owner -> :ok
        end
      end)

    assert_receive :stalled_remote_read_owner_ready

    assert {:ok, stream, nil} =
             Connector.Live.start_remote_read_stream(
               node(),
               env,
               Protocol.request("read_stream", %{"path" => "/stalled-remote"}),
               100,
               supervisor: supervisor,
               absolute_timeout_ms: 1_200
             )

    assert_receive {:stalled_remote_read_receiver, source}

    assert_raise RuntimeError, "transfer stream failed: :timeout", fn ->
      Enum.to_list(stream)
    end

    assert eventually(fn -> Task.Supervisor.children(supervisor) == [] end)
    GenServer.cast(source, :close)
    assert eventually(fn -> not Process.alive?(source) end)
    send(owner, :stop_stalled_remote_read_owner)
  end

  test "register_owner lets a reconnecting owner take over the local env id", %{env: env} do
    Process.flag(:trap_exit, true)

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

    assert_receive {:owner_takeover, ^old}, 1_000
    refute Process.alive?(old)
    Process.exit(new, :kill)
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  def handle_remote_read_telemetry(event, measurements, metadata, pid) do
    send(pid, {:remote_read_telemetry, event, measurements, metadata})
  end

  test "register_owner kills a stale owner that ignores takeover", %{env: env} do
    Process.flag(:trap_exit, true)
    Application.put_env(:salix_env, :bridge_takeover_timeout_ms, 50)
    Application.put_env(:salix_env, :bridge_kill_timeout_ms, 500)

    old =
      start_fake_owner(
        env,
        fn _message -> {:ok, %{"owner" => "old"}} end,
        takeover: :ignore
      )

    new =
      start_fake_owner(env, fn _message ->
        {:ok, %{"owner" => "new"}}
      end)

    assert_receive {:owner_takeover, ^old}, 1_000

    assert {:ok, %{"owner" => "new"}} =
             Bridge.rpc(env, Protocol.request("read", %{"path" => "/x"}), 1000)

    refute Process.alive?(old)
    Process.exit(new, :kill)
  end

  test "owner retirement includes the same transport moving to another node", %{env: env} do
    previous = %{"transport_id" => env, "node" => "salix@old-node"}

    assert Registry.owner_location_changed?(previous, %{
             "transport_id" => env,
             "node" => "salix@new-node"
           })

    assert Registry.owner_location_changed?(previous, %{
             "transport_id" => "replacement-transport",
             "node" => "salix@old-node"
           })

    refute Registry.owner_location_changed?(previous, %{
             "transport_id" => env,
             "node" => "salix@old-node"
           })
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

  test "Connector.Live reports disconnected when the record says disconnected", %{env: env} do
    {:ok, ^env, record} = connect_record(env, to_string(node()))
    connector_run_id = record["connector_run_id"]
    {:ok, _} = Registry.mark_disconnected(connector_run_id)

    assert {:error, :disconnected} =
             Connector.Live.request(connector_run_id, "read", %{"path" => "/x"})
  end

  test "an archive repair connection admits only runtime quiet control", %{env: env} do
    {:ok, ^env, record} = connect_record(env, to_string(node()), %{"archive_repair" => true})
    run_id = record["connector_run_id"]
    start_fake_owner(env, fn message -> {:ok, %{"method" => message["method"]}} end)

    assert {:error, :vm_archiving} =
             Connector.Live.request(run_id, "exec", %{"command" => "true"})

    assert {:error, :vm_archiving} =
             Connector.Live.read_stream(run_id, %{"method" => "read_stream"}, 500)

    assert {:ok, %{"method" => "cloud_runtime_quiesce"}} =
             Connector.Live.request(run_id, "cloud_runtime_quiesce", %{"token" => "archive"})
  end

  test "Connector.Live reports disconnected for an unknown env" do
    assert {:error, :disconnected} = Connector.Live.request("nope", "read", %{"path" => "/x"})
  end

  @tag :fin_status_contract
  test "Connector.Live treats an unreachable owning node as disconnected", %{env: env} do
    # Record names a node that is not a connected BEAM peer → routed as gone.
    {:ok, ^env, record} = connect_record(env, "salix@ghost-node")

    assert {:error, :disconnected} =
             Connector.Live.request(record["connector_run_id"], "read", %{"path" => "/x"})
  end
end
