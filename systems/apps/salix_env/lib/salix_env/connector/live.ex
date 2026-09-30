defmodule SalixEnv.Connector.Live do
  @moduledoc """
  The production `SalixEnv.Connector`: routes a request envelope to the node
  that holds the target connector's WebSocket and runs the round trip there.

  Resolution:

    1. `SalixEnv.Registry.get_by_connector_run_id(connector_run_id)` resolves the
       current connector run to its stable device and live transport.
    2. status must be `"connected"`; otherwise `{:error, :disconnected}`.
    3. owning node == `node()` → `SalixEnv.Bridge.rpc/3` directly.
    4. owning node is a connected peer → `:erpc.call(node, SalixEnv.Bridge,
       :rpc, …)` — the peer runs the same local round trip. A non-connected /
       unreachable owner surfaces as `{:error, :disconnected}` (the durable
       record is stale; the recovery sweep will flip it).

  Streaming copies use the same owner resolution. Connectors still receive only
  the JSON frame protocol; cross-node bulk bytes are bridged with
  `SalixEnv.Transfer` between Salix nodes.

  `request/4` is the convenience front door (method + params, timeout derived
  from `SalixEnv.Protocol`); `dispatch/2` satisfies the `SalixEnv.Connector`
  behaviour with a pre-built envelope.

  Supervised remote read ownership is modeled in
  `tla/salix/ConnectorReadStream.tla`.
  """

  @behaviour SalixEnv.Connector

  alias SalixEnv.{Bridge, Protocol, Registry}
  alias SalixEnv.Transfer.StreamReceiver

  @doc "Issue `method`/`params` to `connector_run_id`, returning `{:ok, result}` | error."
  @spec request(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(connector_run_id, method, params, opts \\ []) do
    timeout = opts[:timeout] || Protocol.timeout(method, params)
    dispatch(connector_run_id, Protocol.request(method, params), timeout)
  end

  @spec read_stream(String.t(), map(), timeout()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}
  def read_stream(connector_run_id, message, timeout \\ Protocol.timeout("read_stream", %{})) do
    route_read_stream(connector_run_id, message, timeout)
  end

  @spec begin_write_stream(String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def begin_write_stream(
        connector_run_id,
        message,
        timeout \\ Protocol.timeout("write_stream", %{})
      ) do
    route_write(connector_run_id, :begin_write_stream, [message, timeout])
  end

  @spec write_stream(String.t(), map(), Enumerable.t(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def write_stream(
        connector_run_id,
        message,
        stream,
        timeout \\ Protocol.timeout("write_stream", %{})
      ) do
    route_write_stream(connector_run_id, message, stream, timeout)
  end

  @spec write_stream_chunk(String.t(), String.t(), binary(), timeout()) :: :ok | {:error, term()}
  def write_stream_chunk(
        connector_run_id,
        id,
        chunk,
        timeout \\ Protocol.timeout("write_stream", %{})
      ) do
    route_write(connector_run_id, :write_stream_chunk, [id, chunk, timeout])
  end

  @spec finish_write_stream(String.t(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def finish_write_stream(connector_run_id, id, timeout \\ Protocol.timeout("write_stream", %{})) do
    route_write(connector_run_id, :finish_write_stream, [id, timeout])
  end

  @spec abort_write_stream(String.t(), String.t(), term()) :: :ok
  def abort_write_stream(connector_run_id, id, reason) do
    _ = route_write(connector_run_id, :abort_write_stream, [id, reason])
    :ok
  end

  @impl true
  def dispatch(connector_run_id, message),
    do: dispatch(connector_run_id, message, default_timeout(message))

  # A `connected` record younger than this may belong to a socket that is
  # still registering its owner (record write precedes owner registration);
  # never heal-flip inside the window.
  @heal_grace_ms 30_000

  @doc "Dispatch a pre-built envelope with an explicit timeout."
  @spec dispatch(String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def dispatch(connector_run_id, message, timeout) do
    case Registry.get_by_connector_run_id(connector_run_id) do
      {:ok, env_id, %{"status" => "connected", "node" => node_str} = record} ->
        case if(
               archive_repair?(record) and
                 message["method"] not in ~w(cloud_runtime_quiesce cloud_runtime_resume cloud_runtime_release),
               do: {:error, :vm_archiving},
               else: route(env_id, node_str, message, timeout)
             ) do
          {:error, :disconnected} = err ->
            # The durable record said connected but no socket owner answered:
            # a crash skipped the owner's terminate (e.g. node restart under
            # the same name). Heal the record so resolvers and the sprite
            # carrier revive stop trusting it.
            heal_stale_record(env_id, record)
            err

          other ->
            other
        end

      {:ok, _env_id, _disconnected} ->
        {:error, :disconnected}

      {:error, :not_found} ->
        {:error, :disconnected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp archive_repair?(record), do: get_in(record, ["meta", "archive_repair"]) == true

  defp heal_stale_record(_transport_id, record) do
    updated_at = record["updated_at"] || record["registered_at"] || 0

    if System.system_time(:millisecond) - updated_at > @heal_grace_ms do
      _ =
        Registry.mark_disconnected(record["connector_run_id"],
          connection_generation: record["connection_generation"],
          owner_node: record["node"]
        )
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp route(env_id, node_str, message, timeout) do
    owner = SalixEnv.ClusterNodes.find(node_str)

    cond do
      owner == node() ->
        Bridge.rpc(env_id, message, timeout)

      owner in Node.list() ->
        erpc(owner, env_id, message, timeout)

      true ->
        # The record names a node that is not a connected peer: the socket is
        # gone (or partitioned). Treat as disconnected — the recovery sweep
        # makes the durable record agree.
        {:error, :disconnected}
    end
  end

  defp route_write(connector_run_id, fun, args) do
    case Registry.get_by_connector_run_id(connector_run_id) do
      {:ok, _env_id, %{"status" => "connected", "meta" => %{"archive_repair" => true}}} ->
        {:error, :vm_archiving}

      {:ok, env_id, %{"status" => "connected", "node" => node_str} = record} ->
        owner = SalixEnv.ClusterNodes.find(node_str)

        result =
          cond do
            owner == node() ->
              apply(Bridge, fun, [env_id | args])

            owner in Node.list() ->
              erpc_call(owner, Bridge, fun, [env_id | args], write_erpc_timeout(args))

            true ->
              {:error, :disconnected}
          end

        maybe_heal_disconnected(env_id, record, result)

      {:ok, _env_id, _disconnected} ->
        {:error, :disconnected}

      {:error, :not_found} ->
        {:error, :disconnected}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp route_write_stream(connector_run_id, message, stream, timeout) do
    case Registry.get_by_connector_run_id(connector_run_id) do
      {:ok, _env_id, %{"status" => "connected", "meta" => %{"archive_repair" => true}}} ->
        {:error, :vm_archiving}

      {:ok, env_id, %{"status" => "connected", "node" => node_str} = record} ->
        owner = SalixEnv.ClusterNodes.find(node_str)

        result =
          cond do
            owner == node() ->
              local_write_stream(env_id, message, stream, timeout)

            owner in Node.list() ->
              remote_write_stream(owner, env_id, message, stream, timeout)

            true ->
              {:error, :disconnected}
          end

        maybe_heal_disconnected(env_id, record, result)

      {:ok, _env_id, _disconnected} ->
        {:error, :disconnected}

      {:error, :not_found} ->
        {:error, :disconnected}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp local_write_stream(env_id, message, stream, timeout) do
    with {:ok, %{"id" => id}} <- Bridge.begin_write_stream(env_id, message, timeout),
         :ok <- send_write_stream_chunks(env_id, id, stream, timeout) do
      Bridge.finish_write_stream(env_id, id, timeout)
    else
      {:error, {_id, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_write_stream(owner, env_id, message, stream, timeout) do
    with {:ok, %{"url" => url}} <-
           erpc_call(
             owner,
             Bridge,
             :prepare_remote_write_stream,
             [env_id, Map.delete(message, "transfer"), timeout, self()],
             timeout + 5_000
           ),
         {:ok, result} <- SalixEnv.Transfer.send_stream(url, stream) do
      case result do
        %{"ok" => false, "error" => reason} -> {:error, reason}
        _ -> {:ok, result}
      end
    end
  end

  defp route_read_stream(connector_run_id, message, timeout) do
    case Registry.get_by_connector_run_id(connector_run_id) do
      {:ok, _env_id, %{"status" => "connected", "meta" => %{"archive_repair" => true}}} ->
        {:error, :vm_archiving}

      {:ok, env_id, %{"status" => "connected", "node" => node_str} = record} ->
        owner = SalixEnv.ClusterNodes.find(node_str)

        result =
          cond do
            owner == node() ->
              Bridge.read_stream(env_id, message, timeout)

            owner in Node.list() ->
              remote_read_stream(owner, env_id, message, timeout)

            true ->
              {:error, :disconnected}
          end

        maybe_heal_disconnected(env_id, record, result)

      {:ok, _env_id, _disconnected} ->
        {:error, :disconnected}

      {:error, :not_found} ->
        {:error, :disconnected}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp remote_read_stream(owner, env_id, message, timeout) do
    opts =
      if message["method"] == "read_ref",
        do: [absolute_timeout_ms: normalize_timeout(timeout)],
        else: []

    start_remote_read_stream(owner, env_id, message, timeout, opts)
  catch
    :error, {:erpc, :noconnection} -> {:error, :disconnected}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def start_remote_read_stream(owner, env_id, message, timeout, opts \\ []) do
    supervisor =
      Keyword.get(opts, :supervisor, SalixEnv.ConnectorRemoteReadTaskSupervisor)

    absolute_timeout = remote_read_stream_timeout_ms(opts)
    idle_timeout = remote_read_stream_idle_timeout_ms(opts)
    bridge_timeout = min(normalize_timeout(timeout), max(absolute_timeout - 1_000, 1))

    with {:ok, receiver} <-
           StreamReceiver.start_link(
             owner: self(),
             idle_timeout_ms: idle_timeout,
             absolute_timeout_ms: absolute_timeout
           ) do
      {_token, url, stream} = StreamReceiver.register!(receiver)

      task = fn ->
        reply =
          remote_read_stream_call(
            owner,
            env_id,
            message,
            url,
            bridge_timeout,
            absolute_timeout
          )

        case reply do
          {:ok, _} -> :ok
          {:error, reason} -> StreamReceiver.fail(receiver, reason)
        end
      end

      case start_remote_read_task(supervisor, task) do
        {:ok, worker} ->
          :ok = StreamReceiver.attach_worker(receiver, worker)
          {:ok, stream, nil}

        {:error, :max_children} ->
          GenServer.stop(receiver, :normal)
          emit_remote_read_stream_saturated()
          {:error, :connector_remote_read_stream_capacity_exhausted}

        {:error, :supervisor_unavailable} ->
          GenServer.stop(receiver, :normal)
          {:error, :connector_remote_read_stream_unavailable}

        {:error, {:supervisor_exit, reason}} ->
          GenServer.stop(receiver, :normal)
          {:error, {:remote_read_stream_start_failed, reason}}

        {:error, reason} ->
          GenServer.stop(receiver, :normal)
          {:error, {:remote_read_stream_start_failed, reason}}
      end
    end
  catch
    :exit, {:noproc, _} -> {:error, :connector_remote_read_stream_unavailable}
    :exit, reason -> {:error, {:remote_read_stream_start_failed, reason}}
  end

  defp remote_read_stream_call(
         owner,
         env_id,
         message,
         url,
         bridge_timeout,
         absolute_timeout
       ) do
    :erpc.call(
      owner,
      Bridge,
      :read_stream_to_url,
      [env_id, message, url, bridge_timeout],
      absolute_timeout
    )
  catch
    :error, {:erpc, :noconnection} -> {:error, :disconnected}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_remote_read_task(supervisor, task) do
    Task.Supervisor.start_child(supervisor, task)
  catch
    :exit, {:noproc, _} -> {:error, :supervisor_unavailable}
    :exit, reason -> {:error, {:supervisor_exit, reason}}
  end

  defp emit_remote_read_stream_saturated do
    :telemetry.execute(
      [:salix, :connector, :read_stream],
      %{},
      %{outcome: :saturated, transport: :other}
    )
  end

  defp remote_read_stream_timeout_ms(opts) do
    configured =
      Keyword.get(
        opts,
        :absolute_timeout_ms,
        Application.get_env(:salix_env, :connector_remote_read_stream_timeout_ms, 305_000)
      )

    case configured do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 305_000
    end
  end

  defp remote_read_stream_idle_timeout_ms(opts) do
    configured =
      Keyword.get(
        opts,
        :idle_timeout_ms,
        Application.get_env(:salix_env, :connector_remote_read_stream_idle_timeout_ms, 30_000)
      )

    case configured do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 30_000
    end
  end

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: 30_000

  # The :erpc carries the full RPC timeout plus a small slop so the remote
  # round trip can complete and return before the call itself gives up.
  defp erpc(owner, env_id, message, timeout) do
    :erpc.call(owner, Bridge, :rpc, [env_id, message, timeout], timeout + 5_000)
  catch
    :error, {:erpc, :noconnection} -> {:error, :disconnected}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp erpc_call(owner, module, fun, args, timeout) do
    :erpc.call(owner, module, fun, args, timeout)
  catch
    :error, {:erpc, :noconnection} -> {:error, :disconnected}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    kind, reason -> {:error, {kind, reason}}
  end

  defp maybe_heal_disconnected(env_id, record, {:error, :disconnected} = err) do
    heal_stale_record(env_id, record)
    err
  end

  defp maybe_heal_disconnected(_env_id, _record, result), do: result

  defp default_timeout(%{"method" => m, "params" => p}), do: Protocol.timeout(m, p || %{})
  defp default_timeout(%{"method" => m}), do: Protocol.timeout(m, %{})
  defp default_timeout(_), do: 30_000

  defp write_erpc_timeout(args) do
    args
    |> List.last()
    |> case do
      timeout when is_integer(timeout) -> timeout + 5_000
      _ -> 35_000
    end
  end

  defp send_write_stream_chunks(env_id, id, stream, timeout) do
    stream
    |> chunked_binary_stream(64 * 1024)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Bridge.write_stream_chunk(env_id, id, chunk, timeout) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Bridge.abort_write_stream(env_id, id, reason)
          {:halt, {:error, {id, reason}}}
      end
    end)
  rescue
    e ->
      reason = Exception.message(e)
      Bridge.abort_write_stream(env_id, id, reason)
      {:error, {id, reason}}
  end

  defp chunked_binary_stream(stream, size) do
    Stream.resource(
      fn -> suspend_next(stream |> Stream.map(&IO.iodata_to_binary/1)) end,
      &next_binary_chunk(&1, size),
      fn
        %{cont: cont} when is_function(cont, 1) -> cont.({:halt, nil})
        _state -> :ok
      end
    )
  end

  defp next_binary_chunk(%{rest: rest} = state, size) when byte_size(rest) >= size do
    <<chunk::binary-size(^size), tail::binary>> = rest
    {[chunk], %{state | rest: tail}}
  end

  defp next_binary_chunk(%{done: true, rest: ""} = state, _size), do: {:halt, state}

  defp next_binary_chunk(%{done: true, rest: rest} = state, _size) do
    {[rest], %{state | rest: ""}}
  end

  defp next_binary_chunk(%{rest: rest} = state, _size) when byte_size(rest) > 0 do
    {[rest], %{state | rest: ""}}
  end

  defp next_binary_chunk(%{cont: cont, rest: rest} = state, size) do
    case cont.({:cont, nil}) do
      {:suspended, "", cont} ->
        next_binary_chunk(%{state | cont: cont}, size)

      {:suspended, bin, cont} ->
        next_binary_chunk(%{state | cont: cont, rest: rest <> bin}, size)

      {:done, _} ->
        next_binary_chunk(%{state | cont: nil, done: true}, size)

      {:halted, _} ->
        {:halt, state}
    end
  end

  defp suspend_next(stream) do
    case Enumerable.reduce(stream, {:cont, nil}, fn item, _acc -> {:suspend, item} end) do
      {:suspended, item, cont} -> %{cont: cont, rest: item, done: false}
      {:done, _} -> %{cont: nil, rest: "", done: true}
      {:halted, _} -> %{cont: nil, rest: "", done: true}
    end
  end
end
