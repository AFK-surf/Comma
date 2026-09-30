defmodule SalixEnv.Bridge do
  @moduledoc """
  The connector bridge — the Salix port of willow's `internal/environ/bridge.go`,
  minus NATS. A connector's WebSocket lives on exactly one node (the node that
  accepted the upgrade). That node's socket-owning process registers itself in
  the local `SalixEnv.Bridges` `Registry` under the `env_id`; this module is the
  RPC seam that drives a request/response round trip through it.

  ## Single-node round trip

  `rpc/3` looks up the socket owner in `SalixEnv.Bridges`, hands it the request
  envelope (with a fresh monitor ref), and blocks on the reply. The owner pushes
  the frame to the connector, correlates the connector's response by envelope
  `id`, and sends the reply back here. A dead socket owner is surfaced as
  `{:error, :disconnected}` (its `DOWN` ends the wait), never a hang.

  ## Multi-node forwarding (replaces `env.<env_id>.req`)

  When the agent runs on a different node than the connector's socket,
  `SalixEnv.Connector.Live` calls `rpc/3` on the owning node via `:erpc`. The
  owning node runs the exact same local round trip. Large `read_stream` and
  `write_stream` bodies use `SalixEnv.Transfer` between Salix nodes, but the
  connector-visible protocol remains the frame stream protocol on the owner
  node. `rpc/3` is therefore the public, `:erpc`-safe entry point for ordinary
  request/response envelopes.

  The contract with the socket owner: it must register as
  `Registry.register(SalixEnv.Bridges, env_id, :connector)` and handle
  `{:env_rpc, ref, from_pid, message}` by pushing `message` to the connector and
  eventually replying `send(from_pid, {:env_rpc_reply, ref, {:ok, result} |
  {:error, reason}})`.

  Read-stream caller/cancel ownership is modeled in
  `tla/salix/ConnectorReadStream.tla`.
  """

  @registry SalixEnv.Bridges
  @replace_attempts 5
  @default_takeover_timeout_ms 15_000
  @default_kill_timeout_ms 15_000

  @doc "The `Registry` name socket owners register under (one entry per env_id)."
  def registry, do: @registry

  @doc """
  Register the calling process as the socket owner for `env_id`. Called from a
  connector socket handler on this node. Replaces any prior local registration
  for the same env_id (a reconnect on the same node).
  """
  @spec register_owner(String.t(), map() | :unmanaged | nil) :: :ok | {:error, term()}
  def register_owner(env_id, scope \\ nil) do
    with :ok <- do_register_owner(env_id, @replace_attempts),
         do: register_owner_scope(env_id, scope)
  end

  defp do_register_owner(env_id, attempts) do
    case Registry.register(@registry, env_id, :connector) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        :ok

      {:error, {:already_registered, pid}} when attempts > 0 ->
        with :ok <- replace_owner(pid, env_id) do
          do_register_owner(env_id, attempts - 1)
        end

      {:error, {:already_registered, pid}} ->
        {:error, {:owner_not_replaced, pid}}
    end
  end

  defp register_owner_scope(_env_id, nil), do: :ok
  defp register_owner_scope(env_id, :unmanaged), do: put_owner_scope(env_id, :unmanaged)

  defp register_owner_scope(env_id, %{tenant_id: tenant, group_id: group, device_id: device})
       when is_binary(tenant) and is_binary(group) and is_binary(device) do
    put_owner_scope(env_id, {tenant, group, device})
  end

  defp register_owner_scope(_, _), do: {:error, :invalid_owner_scope}

  defp put_owner_scope(env_id, scope) do
    case Registry.register(@registry, {:owner_scope, env_id}, scope) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        Registry.update_value(@registry, {:owner_scope, env_id}, fn _ -> scope end)

        :ok

      {:error, _} ->
        {:error, :owner_scope_conflict}
    end
  end

  defp replace_owner(pid, env_id) do
    ref = Process.monitor(pid)
    send(pid, {:env_owner_takeover, env_id, self()})

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      takeover_timeout_ms() ->
        Process.exit(pid, :kill)
        wait_owner_down(pid, ref)
    end
  end

  defp wait_owner_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      kill_timeout_ms() ->
        Process.demonitor(ref, [:flush])
        {:error, {:owner_not_replaced, pid}}
    end
  end

  @doc "Stop a superseded socket owner on its current Salix node and confirm the outcome."
  @spec stop_owner_on(String.t() | atom(), String.t()) :: :ok | {:error, term()}
  def stop_owner_on(owner_node, transport_id) do
    owner =
      [node() | Node.list()]
      |> Enum.find(&(to_string(&1) == to_string(owner_node)))

    cond do
      owner == node() ->
        stop_local_owner(transport_id)

      owner in Node.list() ->
        try do
          :erpc.call(owner, __MODULE__, :stop_local_owner, [transport_id], 20_000)
        catch
          kind, reason -> {:error, {:remote_owner_stop_failed, kind, reason}}
        end

      true ->
        {:error, :owner_node_unavailable}
    end
  end

  @doc false
  def stop_local_owner(transport_id) do
    case Registry.lookup(@registry, transport_id) do
      [{pid, _} | _] when pid == self() -> :ok
      [{pid, _} | _] -> replace_owner(pid, transport_id)
      [] -> :ok
    end
  end

  defp takeover_timeout_ms do
    Application.get_env(:salix_env, :bridge_takeover_timeout_ms, @default_takeover_timeout_ms)
  end

  defp kill_timeout_ms do
    Application.get_env(:salix_env, :bridge_kill_timeout_ms, @default_kill_timeout_ms)
  end

  @doc "True if a connector socket for `env_id` is bridged on THIS node."
  @spec local?(String.t()) :: boolean()
  def local?(env_id), do: Registry.lookup(@registry, env_id) != []

  @doc """
  True if a socket owner for `env_id` is verifiably registered on
  `owner_node` (this node: local registry; a connected peer: `:erpc`).
  False for unreachable owners and on any check failure — used to detect
  durable records left `connected` by a crash that skipped the socket
  owner's terminate (e.g. a node restart), which node-liveness alone cannot
  catch when the restarted node reuses the same name.
  """
  @spec live_on?(String.t() | atom(), String.t()) :: boolean()
  def live_on?(owner_node, env_id) do
    owner = SalixEnv.ClusterNodes.find(owner_node)

    cond do
      owner == node() ->
        local?(env_id)

      owner in Node.list() ->
        try do
          :erpc.call(owner, __MODULE__, :local?, [env_id], 5_000) == true
        catch
          _, _ -> false
        end

      true ->
        false
    end
  end

  @doc """
  Run one RPC round trip against the connector bridged on THIS node. Safe to
  invoke via `:erpc` from another node. `message` is a `SalixEnv.Protocol`
  request envelope; returns `{:ok, result_map}` | `{:error, reason}`.

  `{:error, :disconnected}` when no live socket owner is registered locally
  (e.g. the connector dropped between the registry read and this call).
  """
  @spec rpc(String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def rpc(env_id, message, timeout \\ 30_000) do
    case Registry.lookup(@registry, env_id) do
      [{owner, _} | _] ->
        with :ok <- provider_cutover_admission(env_id, owner, message["method"]),
             do: call_owner(owner, message, timeout)

      [] ->
        {:error, :disconnected}
    end
  end

  @doc "Begin a frame-based connector `read_stream` on THIS node."
  @spec read_stream(String.t(), map(), timeout()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}
  def read_stream(env_id, message, timeout \\ 30_000) do
    case Registry.lookup(@registry, env_id) do
      [{owner, _} | _] -> call_owner_read_stream(owner, message, timeout)
      [] -> {:error, :disconnected}
    end
  end

  @doc """
  Stream connector `read_stream` bytes from THIS node to another Salix node's
  internal transfer URL. The connector still sees only frame-based `read_stream`;
  h2c is an inter-node implementation detail.
  """
  @spec read_stream_to_url(String.t(), map(), String.t(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def read_stream_to_url(env_id, message, url, timeout \\ 30_000) do
    with {:ok, stream, _size} <- read_stream(env_id, message, timeout),
         {:ok, result} <- SalixEnv.Transfer.send_stream(url, stream) do
      case result do
        %{"ok" => false, "error" => reason} -> {:error, reason}
        _ -> {:ok, result}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Begin a connector `write_stream` on THIS node.

  The connector-visible protocol is the pre-pipe frame protocol: first send a
  plain `write_stream` request, then stream `type: "stream"` data frames, then
  wait for the connector's `channel: "done"` frame.
  """
  @spec begin_write_stream(String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def begin_write_stream(env_id, message, timeout \\ 30_000) do
    case Registry.lookup(@registry, env_id) do
      [{owner, _} | _] ->
        with :ok <- provider_cutover_admission(env_id, owner, "write_stream"),
             do: call_owner_write(owner, :begin, [message], timeout)

      [] ->
        {:error, :disconnected}
    end
  end

  @doc """
  Prepare an internal transfer URL for connector `write_stream` bytes on THIS
  node. A remote Salix caller POSTs bytes to the URL; this node forwards them
  to the connector as frame chunks and completes the HTTP response after the
  connector reports final write status.
  """
  @spec prepare_remote_write_stream(String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def prepare_remote_write_stream(env_id, message, timeout \\ 30_000) do
    prepare_remote_write_stream(env_id, message, timeout, self())
  end

  @doc false
  @spec prepare_remote_write_stream(String.t(), map(), timeout(), pid()) ::
          {:ok, map()} | {:error, term()}
  def prepare_remote_write_stream(env_id, message, timeout, caller) when is_pid(caller) do
    with [{owner, _} | _] <- Registry.lookup(@registry, env_id),
         :ok <- provider_cutover_admission(env_id, owner, "write_stream"),
         {:ok, %{"id" => id}} <- call_owner_write(owner, :begin, [message], timeout) do
      case SalixEnv.WriteFrameSink.start(owner, id, timeout, caller: caller) do
        {:ok, sink} ->
          {:ok, %{"url" => SalixEnv.WriteFrameSink.url(sink)}}

        {:error, reason} ->
          send(owner, {:env_write_stream_abort, id, {:remote_write_stream_sink_start, reason}})
          {:error, reason}
      end
    else
      [] -> {:error, :disconnected}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec write_stream_chunk(String.t(), String.t(), binary(), timeout()) :: :ok | {:error, term()}
  def write_stream_chunk(env_id, id, chunk, timeout \\ 30_000) when is_binary(chunk) do
    case Registry.lookup(@registry, env_id) do
      [{owner, _} | _] ->
        call_owner_write(owner, :chunk, [id, chunk], timeout)

      [] ->
        {:error, :disconnected}
    end
  end

  @spec finish_write_stream(String.t(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def finish_write_stream(env_id, id, timeout \\ 30_000) do
    case Registry.lookup(@registry, env_id) do
      [{owner, _} | _] -> call_owner_write(owner, :eof, [id], timeout)
      [] -> {:error, :disconnected}
    end
  end

  @spec abort_write_stream(String.t(), String.t(), term()) :: :ok
  def abort_write_stream(env_id, id, reason) do
    case Registry.lookup(@registry, env_id) do
      [{owner, _} | _] -> send(owner, {:env_write_stream_abort, id, reason})
      [] -> :ok
    end

    :ok
  end

  # The socket's authenticated Group/Device scope is registered beside its
  # owner. Check only commands capable of creating new post-cutover facts.
  # The indexed Workload read runs in the caller, never in the socket loop.
  @cutover_read_methods ~w(read read_ref stat list glob grep process_list process_tail runtime_probe runtime_auth_read runtime_auth_status external_runtime_events cloud_runtime_quiesce agent_runtime_stop process_stop)

  defp provider_cutover_admission(_env_id, _owner, method)
       when method in @cutover_read_methods,
       do: :ok

  defp provider_cutover_admission(env_id, owner, _method) do
    case Registry.lookup(@registry, {:owner_scope, env_id}) do
      [{^owner, {tenant, group, device}}] ->
        SalixStore.Compute.group_provider_mutation_admission(tenant, group, device)

      [{^owner, :unmanaged}] ->
        :ok

      _ when is_binary(env_id) and byte_size(env_id) >= 8 ->
        if String.starts_with?(env_id, "cloudvm-"),
          do: {:error, :group_workload_unavailable},
          else: :ok

      _ ->
        :ok
    end
  end

  defp call_owner(owner, message, timeout) do
    ref = Process.monitor(owner)
    send(owner, {:env_rpc, ref, self(), message})

    receive do
      {:env_rpc_reply, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        {:error, :disconnected}
    after
      timeout ->
        # ConnectorSocket monitors the caller as the primary ownership fence.
        # An explicit timeout cancellation closes the shorter caller budget
        # without waiting for the socket's absolute pending-entry deadline.
        send(owner, {:env_rpc_cancel, ref, self()})
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp call_owner_write(owner, op, args, timeout) do
    ref = Process.monitor(owner)
    send(owner, List.to_tuple([:env_write_stream, op, ref, self() | args]))

    receive do
      {:env_write_stream_reply, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        {:error, :disconnected}
    after
      timeout ->
        send(owner, {:env_write_stream_cancel, ref, self()})
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp call_owner_read_stream(owner, message, timeout) do
    ref = Process.monitor(owner)
    send(owner, {:env_read_stream, ref, self(), message})

    receive do
      {:env_read_stream_reply, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        {:error, :disconnected}
    after
      timeout ->
        send(owner, {:env_read_stream_cancel, ref, self()})
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end
end
