defmodule SalixStore.AgentVMM.Worker do
  require SystemsClock

  @moduledoc """
  The node's Agent VMM worker (`priv/salix_vmm_worker`, built from
  `systems/gateway/salix-vmm-worker`): one Rust process per Salix node that
  holds the node's Agent VMM Host connections.

  This server owns the process as a port. It starts it in a fresh `0700`
  directory and sends the configuration as the first frame: the node's
  instance id, the public TLS listener and its certificate, the private Unix
  socket path and a random token. The worker exits when the port closes, so
  it never outlives the node. If it exits, this server starts a new one after
  a short wait; the Hosts it held reconnect, to this node or another.

  Three things cross between Salix and the worker:

    * The worker asks Salix for every control decision over the port. Each
      request is answered by `SalixStore.AgentVMMGatewayControl`, in a task,
      under the node's instance id. The worker keeps transport state only.
    * Salix runs typed runtime operations in a Host session through
      `session_call/5`. The caller connects to the worker's socket itself: no
      operation passes through this server.
    * `open_iroh_tunnel/3` hands the caller a socket that carries one outbound
      iroh service tunnel.

  A Host is connected to one node, and a session is usable only there. Every
  worker joins the `:pg` group of its instance id, and `session_call/5` runs
  the operation on the node that holds the session: here, or there through
  `:erpc`. `SalixStore.AgentVMM` records that instance id with each connection
  and session; this module keeps no such record.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixStore.{AgentVMM, AgentVMMGatewayControl}

  @pg_scope :salix_agent_vmm_pg
  @frame_limit 33_554_432
  @start_timeout_ms 10_000
  @endpoint_timeout_ms 5_000
  @restart_min_ms 1_000
  @restart_max_ms 30_000
  @erpc_margin_ms 5_000
  # Control requests answered at once. A Host connection has at most a claim, a
  # settlement and a registry call in flight.
  @max_control_tasks 2_048
  @instance_id_pattern ~r/\A[a-z0-9](?:[-a-z0-9]*[a-z0-9])?\z/

  @type session_key :: %{
          registration_id: String.t(),
          allocation_id: String.t(),
          allocation_generation: pos_integer(),
          connection_epoch: String.t()
        }

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      # terminate/2 tells Salix which connections end with the worker.
      shutdown: 15_000
    }
  end

  @doc "The `:pg` scope the workers of every node join (`SalixStore.Application` starts it)."
  def pg_scope, do: @pg_scope

  @doc "Whether this node is configured to run a worker."
  def enabled?, do: is_list(SystemsRuntime.get_env(:salix_store, :agent_vmm_worker))

  @doc "Whether a running worker with this instance id is known to this node."
  @spec online?(term()) :: boolean()
  def online?(instance_id), do: members(instance_id) != []

  @doc """
  Run one typed runtime operation in the Host session `session_key` names, on
  the node whose worker has `instance_id`. `payload` is the operation's
  arguments, or for `compute.image.import` its header fields.

  Returns `{:ok, status, body}` with the worker's answer, or
  `{:error, :gateway_unavailable}` when no worker with that instance id runs
  or it gave no answer in `timeout_ms`.
  """
  @spec session_call(String.t(), session_key(), String.t(), map(), pos_integer()) ::
          {:ok, pos_integer(), term()} | {:error, :gateway_unavailable}
  def session_call(instance_id, session_key, operation, payload, timeout_ms)
      when is_binary(instance_id) and is_map(session_key) and is_binary(operation) and
             is_map(payload) and is_integer(timeout_ms) and timeout_ms > 0 do
    case local_members(instance_id) ++ members(instance_id) do
      [] ->
        {:error, :gateway_unavailable}

      [pid | _] when node(pid) == node() ->
        call_worker(pid, session_key, operation, payload, timeout_ms)

      [pid | _] ->
        args = [instance_id, session_key, operation, payload, timeout_ms]

        try do
          :erpc.call(
            node(pid),
            __MODULE__,
            :local_session_call,
            args,
            timeout_ms + @erpc_margin_ms
          )
        catch
          _kind, _reason -> {:error, :gateway_unavailable}
        else
          {:ok, status, body} when is_integer(status) -> {:ok, status, body}
          _ -> {:error, :gateway_unavailable}
        end
    end
  end

  @doc false
  # The `:erpc` entry on the node that holds the session.
  def local_session_call(instance_id, session_key, operation, payload, timeout_ms) do
    case local_members(instance_id) do
      [pid | _] -> call_worker(pid, session_key, operation, payload, timeout_ms)
      [] -> {:error, :gateway_unavailable}
    end
  end

  @doc """
  Dial the iroh endpoint `endpoint_addr` (its `EndpointAddr` as a JSON map)
  through this node's worker.

  Returns a connected, passive, binary-mode raw socket owned by the caller.
  It carries the one `agent-vmm/service-tunnel/1` stream of the tunnel, for at
  most an hour.
  """
  @spec open_iroh_tunnel(map(), pos_integer(), GenServer.server()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def open_iroh_tunnel(endpoint_addr, timeout_ms, server \\ __MODULE__)
      when is_map(endpoint_addr) and is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, path, token} <- endpoint(server),
         {:ok, socket} <- connect(path) do
      request = Jason.encode!(%{token: token, op: "iroh_tunnel", endpoint_addr: endpoint_addr})

      with :ok <- :gen_tcp.send(socket, request),
           {:ok, reply} <- :gen_tcp.recv(socket, 0, timeout_ms),
           {:ok, %{"type" => "ready"}} <- Jason.decode(reply),
           :ok <- :inet.setopts(socket, packet: :raw) do
        {:ok, socket}
      else
        other ->
          :gen_tcp.close(socket)
          {:error, tunnel_error(other)}
      end
    end
  end

  defp tunnel_error({:ok, %{"body" => %{"error" => reason}}}) when is_binary(reason),
    do: {:tunnel_refused, reason}

  defp tunnel_error(_other), do: :gateway_unavailable

  defp members(instance_id) do
    :pg.get_members(@pg_scope, {:agent_vmm_worker, instance_id})
  rescue
    # The scope is not started on a node that runs no Salix store.
    ArgumentError -> []
  end

  defp local_members(instance_id) do
    :pg.get_local_members(@pg_scope, {:agent_vmm_worker, instance_id})
  rescue
    ArgumentError -> []
  end

  defp call_worker(pid, session_key, operation, payload, timeout_ms) do
    with {:ok, path, token} <- endpoint(pid),
         {:ok, socket} <- connect(path) do
      field = if operation == "compute.image.import", do: :headers, else: :args

      request =
        Jason.encode!(%{
          :token => token,
          :op => "session_call",
          :operation => operation,
          :session => session_key,
          field => payload
        })

      try do
        with :ok <- :gen_tcp.send(socket, request),
             {:ok, reply} <- :gen_tcp.recv(socket, 0, timeout_ms),
             {:ok, %{"status" => status} = answer} when is_integer(status) <- Jason.decode(reply) do
          {:ok, status, answer["body"]}
        else
          _ -> {:error, :gateway_unavailable}
        end
      after
        # Closing withdraws an operation the worker has not answered.
        :gen_tcp.close(socket)
      end
    end
  end

  defp endpoint(server) do
    SystemsClock.call(server, :endpoint, @endpoint_timeout_ms)
  catch
    :exit, _reason -> {:error, :gateway_unavailable}
  end

  defp connect(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 4], 2_000) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:error, :gateway_unavailable}
    end
  end

  # ---- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.trap_exit(true)
    {:ok, tasks} = SystemsRuntime.TaskSupervisor.start_link(max_children: @max_control_tasks)

    state = %{
      opts: opts,
      tasks: tasks,
      instance_id: nil,
      port: nil,
      dir: nil,
      path: nil,
      token: nil,
      remote_addr: nil,
      # registration id => connection epoch, as the worker reported them.
      connections: %{},
      restart_ms: @restart_min_ms
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start_or_retry(state)}

  @impl true
  def handle_call(:endpoint, _from, %{port: port} = state) when is_port(port),
    do: {:reply, {:ok, state.path, state.token}, state}

  def handle_call(:endpoint, _from, state), do: {:reply, {:error, :gateway_unavailable}, state}

  def handle_call(:remote_addr, _from, state), do: {:reply, state.remote_addr, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state)
      when byte_size(data) <= @frame_limit do
    case Jason.decode(data) do
      {:ok, %{"type" => "call", "id" => id, "op" => op} = frame} ->
        answer_control(state, id, op, frame["body"])
        {:noreply, state}

      {:ok, %{"type" => "event"} = event} ->
        {:noreply, observe_event(state, event)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("agent vmm worker exited with status #{status}")
    {:noreply, state |> stopped() |> schedule_start()}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: {:noreply, state |> stopped() |> schedule_start()}

  def handle_info(:start, %{port: nil} = state), do: {:noreply, start_or_retry(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stopped(state)

  defp start_or_retry(state) do
    case start_worker(state) do
      {:ok, state} ->
        :ok = :pg.join(@pg_scope, {:agent_vmm_worker, state.instance_id}, self())
        emit_event("worker_start")
        Logger.info("agent vmm worker #{state.instance_id} listens on #{state.remote_addr}")
        %{state | restart_ms: @restart_min_ms}

      {:error, reason, state} ->
        Logger.warning("agent vmm worker did not start: #{inspect(reason)}")
        schedule_start(state)
    end
  end

  defp schedule_start(state) do
    SystemsClock.send_after(self(), :start, state.restart_ms)
    %{state | restart_ms: min(state.restart_ms * 2, @restart_max_ms)}
  end

  defp start_worker(state) do
    instance_id = option(state, :instance_id, nil)
    dir = Path.join(System.tmp_dir!(), "salix-vmm-worker-" <> random(8))
    path = Path.join(dir, "worker.sock")
    token = random(32)
    exe = option(state, :command, Path.join(:code.priv_dir(:salix_store), "salix_vmm_worker"))

    with :ok <- valid_instance_id(instance_id),
         :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, port} <- open_port(exe) do
      config =
        Jason.encode!(%{
          instance_id: instance_id,
          remote_listen: option(state, :remote_listen, "0.0.0.0:7443"),
          tls_cert_file: option(state, :tls_cert_file, ""),
          tls_key_file: option(state, :tls_key_file, ""),
          socket: path,
          token: token,
          iroh_preset: option(state, :iroh_preset, nil)
        })

      state = %{state | port: port, dir: dir, path: path, token: token, instance_id: instance_id}
      true = Port.command(port, config)

      SystemsClock.vreceive do
        {^port, {:data, data}} when byte_size(data) <= @frame_limit ->
          case Jason.decode(data) do
            {:ok, %{"type" => "ready", "remote_addr" => remote_addr}} ->
              {:ok, %{state | remote_addr: remote_addr}}

            _ ->
              {:error, :bad_ready, stopped(state)}
          end

        {^port, {:exit_status, status}} ->
          {:error, {:exit_status, status}, stopped(%{state | port: nil})}
      after
        @start_timeout_ms -> {:error, :start_timeout, stopped(state)}
      end
    else
      {:error, reason} -> {:error, reason, stopped(%{state | dir: dir})}
    end
  end

  defp valid_instance_id(instance_id) do
    if is_binary(instance_id) and byte_size(instance_id) <= 128 and
         Regex.match?(@instance_id_pattern, instance_id),
       do: :ok,
       else: {:error, :invalid_instance_id}
  end

  defp open_port(exe) do
    if File.exists?(exe) do
      {:ok, Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:packet, 4}])}
    else
      {:error, {:missing_executable, exe}}
    end
  rescue
    error -> {:error, error}
  end

  # The worker is gone, or about to be: its connections ended with it. Salix is
  # told for each one, as the worker itself tells it for a connection it loses.
  defp stopped(state) do
    if is_port(state.port) do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end

      emit_event("worker_exit")
    end

    if state.instance_id do
      :pg.leave(@pg_scope, {:agent_vmm_worker, state.instance_id}, self())

      Enum.each(state.connections, fn {registration_id, epoch} ->
        try do
          AgentVMM.mark_connection_lost(registration_id, state.instance_id, epoch)
        rescue
          _ -> :ok
        catch
          _kind, _reason -> :ok
        end
      end)
    end

    if state.dir, do: File.rm_rf(state.dir)
    emit_sample(0, 0)
    %{state | port: nil, dir: nil, path: nil, token: nil, remote_addr: nil, connections: %{}}
  end

  # ---- control requests ----------------------------------------------------------

  # Answered in a task: a slow store call never holds the port's other frames.
  defp answer_control(state, id, op, body) do
    %{port: port, instance_id: instance_id} = state

    started =
      SystemsRuntime.TaskSupervisor.start_child(state.tasks, fn ->
        {status, answer} = control(instance_id, op, body)
        reply(port, id, status, answer)
      end)

    case started do
      {:ok, _pid} -> :ok
      _ -> reply(port, id, 503, %{error: "control_unavailable"})
    end
  end

  defp control(instance_id, op, body) do
    with {:ok, operation} <- AgentVMMGatewayControl.operation(op),
         true <- is_map(body) do
      AgentVMMGatewayControl.call(instance_id, operation, body)
    else
      _ -> {404, %{error: "unknown_control_operation"}}
    end
  rescue
    _ -> {503, %{error: "control_unavailable"}}
  catch
    _kind, _reason -> {503, %{error: "control_unavailable"}}
  end

  defp reply(port, id, status, body) do
    Port.command(port, Jason.encode!(%{type: "reply", id: id, status: status, body: body}))
  rescue
    # The worker left before its answer.
    ArgumentError -> false
  end

  # ---- worker facts --------------------------------------------------------------

  defp observe_event(
         state,
         %{
           "event" => "connected",
           "registration_id" => registration_id,
           "connection_epoch" => epoch
         }
       )
       when is_binary(registration_id) and is_binary(epoch) do
    emit_event("host_connected")
    %{state | connections: Map.put(state.connections, registration_id, epoch)}
  end

  defp observe_event(
         state,
         %{
           "event" => "disconnected",
           "registration_id" => registration_id,
           "connection_epoch" => epoch
         }
       ) do
    # Salix has been told (the worker reports this after its control call).
    emit_event("host_disconnected")

    case state.connections do
      # A replacement connection has put its own epoch here already.
      %{^registration_id => ^epoch} ->
        %{state | connections: Map.delete(state.connections, registration_id)}

      _ ->
        state
    end
  end

  defp observe_event(state, %{"event" => "stats"} = event) do
    emit_sample(count(event["connections"]), count(event["sessions"]))
    state
  end

  defp observe_event(state, %{"event" => "count", "name" => name}) when is_binary(name) do
    emit_event(name)
    state
  end

  defp observe_event(state, %{"event" => "image_import"} = event) do
    SystemsRuntime.Telemetry.execute(
      [:salix, :agent_vmm, :image_import, :stop],
      %{duration: count(event["duration_ms"]), bytes: count(event["bytes"])},
      %{outcome: event["outcome"]}
    )

    state
  end

  defp observe_event(state, _event), do: state

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

  defp emit_sample(connections, sessions) do
    SystemsRuntime.Telemetry.execute(
      [:salix, :agent_vmm, :worker, :sample],
      %{connections: connections, sessions: sessions},
      %{}
    )
  end

  defp emit_event(name),
    do:
      SystemsRuntime.Telemetry.execute([:salix, :agent_vmm, :worker, :event], %{count: 1}, %{
        event: name
      })

  # Configuration: start options first (tests), then the application env.
  defp option(state, key, default) do
    Keyword.get_lazy(state.opts, key, fn ->
      :salix_store |> SystemsRuntime.get_env(:agent_vmm_worker, []) |> Keyword.get(key, default)
    end)
  end

  defp random(bytes),
    do: bytes |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false)
end
