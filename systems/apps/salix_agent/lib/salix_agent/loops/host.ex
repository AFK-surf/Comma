defmodule SalixAgent.Loops.Host do
  @moduledoc """
  The spinfoam child process of this node, driven over stdio JSON-RPC
  (docs/salix/tasks-background-execution.md, "Background loops").

  One `Host` per BEAM node owns one spinfoam process. It speaks protocol v1:
  one JSON object per line each way, string request ids, named parameters,
  no batches. Control requests go out with an id and a deadline; responses
  are routed by id. The child's reverse requests (`host.call`) are executed
  through `SalixAgent.DependencyJob` with this process as owner, so a
  capability that hangs is cancelled at its deadline and never blocks the
  reader, and a late result is discarded by token.

  ## What the Host owns

    * the Port, the initialize handshake and the compiler fact it reports;
    * the outstanding-request table, bounded by spinfoam's 48 slots (surplus
      requests queue here instead of being refused with `BUSY`). Compile
      requests take a slot here too, although spinfoam does not count them:
      neither side serializes builds;
    * the `object_id -> ref` table: which Loop, at which incarnation, each
      loaded object is, or which script run (`kind: :script`) owns it. A
      `host.call` for an unknown object is refused;
    * script objects (`SalixAgent.ScriptRun`): one-shot programs owned by
      the calling process. Their `host.call` requests are forwarded to that
      owner, which executes them inline under its own tool admission and
      answers through `host_reply/2`; the owner is monitored and its object
      unloaded when it exits; an exited or faulted script object is reported
      to the owner, never to the Reconciler. At most `script_max_objects/0`
      script objects are resident per node;
    * the restart budget: a child that exits is respawned with backoff, at
      most `@max_restarts_per_hour` times per hour, then the Host stays
      `unavailable` and alerts. There is no unbounded retry.

  ## What it does not own

  Which Loops should run here, and when, is `SalixAgent.Loops.Reconciler`'s
  decision: after every successful (re)initialize the Host tells the
  Reconciler, which adopts the Agents this node holds. Durable Loop state is
  `SalixAgent.Loops`'s. Nothing in the child survives its exit, by design.
  """

  use GenServer
  require Logger

  alias SalixAgent.DependencyJob
  alias SalixAgent.Loops.Capabilities

  @protocol_version 1
  @max_line 262_144
  @max_outstanding 40
  @default_request_timeout_ms 10_000
  @load_request_timeout_ms 20_000
  # spinfoam's compile deadline (15 s) plus load and transfer slack.
  @compile_request_timeout_ms 20_000
  @initialize_timeout_ms 15_000
  @max_restarts_per_hour 5
  @restart_window_ms :timer.hours(1)
  @restart_backoff_ms [1_000, 2_000, 4_000, 8_000, 16_000]
  @sweep_ms 30_000
  @min_host_call_ms 100
  @max_host_call_ms 60_000
  @default_script_max_objects 64

  @type loop_ref :: Capabilities.loop_ref()

  @typedoc "A script run's registration: the owner process answers its host calls."
  @type script_ref :: %{
          required(:kind) => :script,
          required(:owner) => pid(),
          required(:agent_id) => String.t(),
          optional(:session_id) => String.t() | nil,
          optional(:tenant_id) => String.t() | nil,
          optional(:group_id) => String.t() | nil
        }

  @doc "Resident script objects allowed per node (`:salix_agent, :script_max_objects`)."
  @spec script_max_objects() :: pos_integer()
  def script_max_objects,
    do: Application.get_env(:salix_agent, :script_max_objects, @default_script_max_objects)

  # ---- public API -----------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Availability, session, compiler and counters."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__),
    do: safe_call(server, :status, 5_000, %{available: false, reason: :host_not_running})

  @doc """
  Compile a source bundle in the child (`sf.build.compile`). The reply is
  the terminal build: `state` `succeeded` with `result.elf`, or `failed`
  with the compiler's error. The request waits up to the compiler's
  15-second deadline; the child serves other requests meanwhile, and
  compile requests do not take one of its 48 request slots.
  """
  @spec build_compile(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def build_compile(files, entry) when is_map(files) and is_binary(entry) do
    request(
      "sf.build.compile",
      %{"sdk_version" => 1, "entry" => entry, "files" => files},
      @compile_request_timeout_ms
    )
  end

  @doc """
  Load `elf` for `ref` and register the object without starting it. A loop
  ref carries the incarnation the caller is about to record; a script ref
  (`kind: :script`) is refused with `{:error, :script_capacity}` once
  `script_max_objects/0` script objects are resident.
  """
  @spec object_load(loop_ref() | script_ref(), binary(), term(), [map()]) ::
          {:ok, String.t()} | {:error, term()}
  def object_load(ref, elf, config, capabilities) when is_binary(elf) do
    params = %{
      "elf" => Base.encode64(elf),
      "config" => config,
      "capabilities" => capabilities
    }

    safe_call(
      __MODULE__,
      {:load, ref, params},
      @load_request_timeout_ms + 1_000,
      {:error, :host_not_running}
    )
  end

  @doc """
  Answer a `host.call` that was forwarded to a script owner. `reply` is the
  JSON result or an error message; a reply for an unknown or already
  answered request is dropped.
  """
  @spec host_reply(String.t(), {:ok, term()} | {:error, String.t()}) :: :ok
  def host_reply(rpc_id, reply) when is_binary(rpc_id),
    do: GenServer.cast(__MODULE__, {:host_reply, rpc_id, reply})

  @doc "Bind an already loaded object to a (new) incarnation of its Loop."
  @spec object_bind(String.t(), loop_ref()) :: :ok | {:error, term()}
  def object_bind(object_id, loop),
    do: safe_call(__MODULE__, {:bind, object_id, loop}, 5_000, {:error, :host_not_running})

  @spec object_start(String.t()) :: :ok | {:error, term()}
  def object_start(object_id) do
    with {:ok, _} <- request("sf.object.start", %{"object_id" => object_id}), do: :ok
  end

  @spec object_stop(String.t()) :: {:ok, map()} | {:error, term()}
  def object_stop(object_id),
    do: request("sf.object.stop", %{"object_id" => object_id}, @load_request_timeout_ms)

  @doc "Stop if needed and release the object; forgets the registration."
  @spec object_unload(String.t()) :: :ok | {:error, term()}
  def object_unload(object_id) do
    result = request("sf.object.unload", %{"object_id" => object_id}, @load_request_timeout_ms)
    _ = safe_call(__MODULE__, {:forget, object_id}, 5_000, :ok)

    case result do
      {:ok, _} -> :ok
      {:error, %{"kind" => "OBJECT_NOT_FOUND"}} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec object_get(String.t()) :: {:ok, map()} | {:error, term()}
  def object_get(object_id), do: request("sf.object.get", %{"object_id" => object_id})

  @spec object_list(String.t() | nil, pos_integer()) :: {:ok, map()} | {:error, term()}
  def object_list(after_id \\ nil, limit \\ 100) do
    params =
      %{"limit" => limit} |> then(&if(after_id, do: Map.put(&1, "after", after_id), else: &1))

    request("sf.object.list", params)
  end

  @spec event_deliver(String.t(), String.t(), String.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def event_deliver(object_id, event_id, topic, payload) do
    case request("sf.event.deliver", %{
           "object_id" => object_id,
           "event_id" => event_id,
           "topic" => topic,
           "payload" => payload
         }) do
      {:ok, %{"accepted" => true} = reply} -> {:ok, reply}
      {:ok, reply} -> {:error, {:not_accepted, reply}}
      {:error, %{"kind" => "MAILBOX_FULL"}} -> {:error, :mailbox_full}
      {:error, %{"kind" => "OBJECT_NOT_FOUND"}} -> {:error, :not_found}
      {:error, %{"kind" => "INVALID_OBJECT"}} -> {:error, :not_active}
      {:error, _} = error -> error
    end
  end

  @doc """
  Deliver an event to the object currently running `loop_id` on this node.
  Called on the owner node by `SalixAgent.Loops` (locally or over `:erpc`).
  """
  @spec deliver_loop_event(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def deliver_loop_event(loop_id, %{
        "event_id" => event_id,
        "topic" => topic,
        "payload" => payload
      }) do
    case object_for_loop(loop_id) do
      nil -> {:error, :not_resident}
      object_id -> event_deliver(object_id, event_id, topic, payload)
    end
  end

  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats, do: request("sf.stats", %{})

  @doc "The refs of every object registered on this node, Loops and scripts alike."
  @spec objects(GenServer.server()) :: %{String.t() => loop_ref() | script_ref()}
  def objects(server \\ __MODULE__), do: safe_call(server, :objects, 5_000, %{})

  @doc "The loop refs of every Loop object registered on this node."
  @spec loop_objects(GenServer.server()) :: %{String.t() => loop_ref()}
  def loop_objects(server \\ __MODULE__) do
    server |> objects() |> Map.reject(fn {_id, ref} -> script_ref?(ref) end)
  end

  @spec object_for_loop(String.t()) :: String.t() | nil
  def object_for_loop(loop_id) do
    loop_objects()
    |> Enum.find_value(fn {object_id, ref} -> if ref.loop_id == loop_id, do: object_id end)
  end

  defp script_ref?(%{kind: :script}), do: true
  defp script_ref?(_ref), do: false

  defp script_count(state), do: Enum.count(state.objects, fn {_id, r} -> script_ref?(r) end)

  defp reserve_script_load(state, delta),
    do: %{state | script_loads: max(state.script_loads + delta, 0)}

  @doc "A raw control request. Returns the JSON-RPC result or the error object."
  @spec request(String.t(), map(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def request(method, params, timeout_ms \\ @default_request_timeout_ms) do
    safe_call(
      __MODULE__,
      {:request, method, params, timeout_ms},
      timeout_ms + 1_000,
      {:error, :host_not_running}
    )
  end

  defp safe_call(server, message, timeout, fallback) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:noproc, _} -> fallback
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {reason, _} -> if(is_map(fallback), do: fallback, else: {:error, reason})
  end

  # ---- GenServer ------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct port: nil,
              available: false,
              reason: :starting,
              session_id: nil,
              compiler: %{},
              limits: %{},
              buf: "",
              next_id: 1,
              # request id => %{from, method, timer}
              requests: %{},
              # queued {method, params, timeout, from} beyond the slot cap
              queue: :queue.new(),
              # object_id => loop ref
              objects: %{},
              # dependency token => %{rpc_id, job, object_id}
              host_calls: %{},
              rpc_tokens: %{},
              # forwarded script host.call: rpc_id => object_id
              script_calls: %{},
              # script owner monitor => object_id
              monitors: %{},
              # script loads sent or queued but not yet answered: they hold
              # capacity so a burst cannot overshoot script_max_objects
              script_loads: 0,
              restarts: [],
              spawn_attempt: 0,
              init_id: nil,
              reconciler: nil,
              exe: nil,
              args: []
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %State{reconciler: Keyword.get(opts, :reconciler, SalixAgent.Loops.Reconciler)}
    {:ok, state, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state), do: {:noreply, spawn_child(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       available: state.available,
       reason: state.reason,
       session_id: state.session_id,
       compiler: state.compiler,
       limits: state.limits,
       objects: map_size(state.objects),
       script_objects: script_count(state),
       script_loads: state.script_loads,
       outstanding: map_size(state.requests),
       queued: :queue.len(state.queue),
       host_calls: map_size(state.host_calls),
       restarts: length(state.restarts)
     }, state}
  end

  def handle_call(:objects, _from, state), do: {:reply, state.objects, state}

  def handle_call({:request, method, params, timeout}, from, state) do
    if state.available,
      do: {:noreply, enqueue_request(state, method, params, timeout, from)},
      else: {:reply, {:error, {:host_unavailable, state.reason}}, state}
  end

  def handle_call({:load, ref, params}, from, state) do
    cond do
      not state.available ->
        {:reply, {:error, {:host_unavailable, state.reason}}, state}

      script_ref?(ref) and script_count(state) + state.script_loads >= script_max_objects() ->
        {:reply, {:error, :script_capacity}, state}

      true ->
        state = if script_ref?(ref), do: reserve_script_load(state, 1), else: state

        {:noreply,
         enqueue_request(
           state,
           "sf.object.load",
           params,
           @load_request_timeout_ms,
           {:load, from, ref}
         )}
    end
  end

  def handle_call({:bind, object_id, loop}, _from, state) do
    if Map.has_key?(state.objects, object_id),
      do: {:reply, :ok, %{state | objects: Map.put(state.objects, object_id, loop)}},
      else: {:reply, {:error, :not_found}, state}
  end

  def handle_call({:forget, object_id}, _from, state),
    do: {:reply, :ok, forget_object(state, object_id)}

  # ---- port I/O ---------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %State{port: port} = state) do
    {:noreply, %{state | buf: state.buf <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %State{port: port} = state) do
    line = state.buf <> chunk
    state = %{state | buf: ""}

    case Jason.decode(line) do
      {:ok, %{} = message} -> {:noreply, handle_message(message, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    Logger.error("spinfoam exited with status #{status}")
    {:noreply, child_lost(state, {:exit_status, status})}
  end

  def handle_info({:EXIT, port, reason}, %State{port: port} = state) when is_port(port) do
    {:noreply, child_lost(state, {:port_exit, reason})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # A script owner exited: its object is unloaded and forgotten. spinfoam
  # cancels the object's pending host calls itself.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        {:noreply, state}

      {object_id, monitors} ->
        state = %{state | monitors: monitors}

        if Map.has_key?(state.objects, object_id) do
          state = forget_object(state, object_id)

          if state.available,
            do:
              {:noreply,
               enqueue_request(
                 state,
                 "sf.object.unload",
                 %{"object_id" => object_id},
                 @load_request_timeout_ms,
                 :discard
               )},
            else: {:noreply, state}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(:spawn, state), do: {:noreply, spawn_child(state)}

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from}, requests} ->
        reply_request(from, {:error, :timeout}, state)
        {:noreply, flush_queue(%{state | requests: requests})}
    end
  end

  def handle_info(:init_timeout, %State{available: false, init_id: id} = state)
      when not is_nil(id) do
    Logger.error("spinfoam did not answer sf.initialize within #{@initialize_timeout_ms} ms")
    {:noreply, child_lost(state, :initialize_timeout)}
  end

  def handle_info(:init_timeout, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)

    if state.available and map_size(state.objects) > 0,
      do:
        {:noreply,
         enqueue_request(
           state,
           "sf.object.list",
           %{"limit" => 256},
           @default_request_timeout_ms,
           :sweep
         )},
      else: {:noreply, state}
  end

  # ---- dependency job results (host.call) -------------------------------------

  def handle_info({:dependency_job_result, token, result}, state) do
    case Map.pop(state.host_calls, token) do
      {nil, _} ->
        {:noreply, state}

      {%{job: job, rpc_id: rpc_id}, host_calls} ->
        :ok = DependencyJob.complete(job)
        send_host_result(state, rpc_id, result)

        {:noreply,
         %{state | host_calls: host_calls, rpc_tokens: Map.delete(state.rpc_tokens, rpc_id)}}
    end
  end

  def handle_info({:dependency_job_timeout, token}, state) do
    case Map.pop(state.host_calls, token) do
      {nil, _} ->
        {:noreply, state}

      {%{job: job, rpc_id: rpc_id}, host_calls} ->
        :ok = DependencyJob.cancel(job, :timeout)
        send_host_error(state, rpc_id, "DEADLINE_EXCEEDED", "capability deadline exceeded")

        {:noreply,
         %{state | host_calls: host_calls, rpc_tokens: Map.delete(state.rpc_tokens, rpc_id)}}
    end
  end

  def handle_info({:dependency_job_down, token, reason}, state) do
    case Map.pop(state.host_calls, token) do
      {nil, _} ->
        {:noreply, state}

      {%{job: job, rpc_id: rpc_id}, host_calls} ->
        :ok = DependencyJob.complete(job)

        send_host_error(
          state,
          rpc_id,
          "HOST_ERROR",
          "capability crashed: " <> (inspect(reason) |> String.slice(0, 200))
        )

        {:noreply,
         %{state | host_calls: host_calls, rpc_tokens: Map.delete(state.rpc_tokens, rpc_id)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{port: port} = state) when is_port(port) do
    _ =
      port_send(port, %{
        "jsonrpc" => "2.0",
        "id" => "shutdown",
        "method" => "sf.shutdown",
        "params" => %{}
      })

    cancel_host_calls(state)
    safe_close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---- spawn / loss -----------------------------------------------------------

  defp spawn_child(state) do
    case command() do
      {:error, reason} ->
        Logger.warning("spinfoam unavailable on this node: #{inspect(reason)}")
        %{state | available: false, reason: reason, port: nil}

      {:ok, exe, args} ->
        try do
          port =
            Port.open({:spawn_executable, exe}, [
              :binary,
              :exit_status,
              {:line, @max_line},
              args: args
            ])

          id = "h:init:" <> Integer.to_string(state.next_id)

          payload = %{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "sf.initialize",
            "params" => %{"protocol_version" => @protocol_version}
          }

          :ok = port_send(port, payload)
          Process.send_after(self(), :init_timeout, @initialize_timeout_ms)

          %{
            state
            | port: port,
              exe: exe,
              args: args,
              init_id: id,
              next_id: state.next_id + 1,
              reason: :initializing,
              buf: ""
          }
        rescue
          error ->
            Logger.error("spinfoam spawn failed: #{Exception.message(error)}")

            schedule_respawn(%{
              state
              | port: nil,
                available: false,
                reason: {:spawn_failed, Exception.message(error)}
            })
        end
    end
  end

  @doc "The spinfoam executable this node runs, for out-of-band invocations such as `--dump-sdk`."
  @spec executable() :: {:ok, String.t()} | {:error, term()}
  def executable do
    case command() do
      {:ok, exe, _args} -> {:ok, exe}
      {:error, _} = error -> error
    end
  end

  defp command do
    case Application.get_env(:salix_agent, :spinfoam_cmd) do
      {exe, args} when is_binary(exe) and is_list(args) ->
        if File.exists?(exe),
          do: {:ok, exe, args ++ compiler_args()},
          else: {:error, {:missing_binary, exe}}

      :disabled ->
        {:error, :disabled}

      nil ->
        exe = Path.join(:code.priv_dir(:salix_agent), "spinfoam")
        if File.exists?(exe), do: {:ok, exe, compiler_args()}, else: {:error, :missing_binary}
    end
  end

  # spinfoam embeds its C compiler (TinyCC compiled to eBPF), so builds are
  # always requested; nothing on the node has to be probed or delegated for
  # them (DEPLOYMENT.md, "Background Loops").
  defp compiler_args, do: ["--enable-builds"]

  defp child_lost(state, reason) do
    if state.port, do: safe_close(state.port)
    cancel_host_calls(state)

    for {object_id, %{kind: :script, owner: owner}} <- state.objects do
      send(owner, {:script_terminal, object_id, :runtime_lost})
    end

    for {monitor, _object_id} <- state.monitors, do: Process.demonitor(monitor, [:flush])

    for {_id, %{from: from}} <- state.requests,
        do: reply_request(from, {:error, {:host_lost, reason}}, state)

    for {_m, _p, _t, from} <- :queue.to_list(state.queue),
        do: reply_request(from, {:error, {:host_lost, reason}}, state)

    Salix.Telemetry.emit_operation("salix_agent", "loop_host_restart", "loop", "error", 0)

    state = %{
      state
      | port: nil,
        available: false,
        reason: {:child_lost, reason},
        session_id: nil,
        requests: %{},
        queue: :queue.new(),
        objects: %{},
        host_calls: %{},
        rpc_tokens: %{},
        script_calls: %{},
        monitors: %{},
        script_loads: 0,
        init_id: nil,
        buf: ""
    }

    schedule_respawn(state)
  end

  defp schedule_respawn(state) do
    now = System.monotonic_time(:millisecond)
    restarts = Enum.filter([now | state.restarts], &(now - &1 < @restart_window_ms))

    if length(restarts) > @max_restarts_per_hour do
      Logger.error(
        "spinfoam restarted more than #{@max_restarts_per_hour} times in an hour; background loops are unavailable on this node until an operator intervenes"
      )

      CommaLog.log("loop_host_unavailable", %{restarts: length(restarts)})
      %{state | restarts: restarts, available: false, reason: :restart_budget_exhausted}
    else
      attempt = state.spawn_attempt
      backoff = Enum.at(@restart_backoff_ms, min(attempt, length(@restart_backoff_ms) - 1))
      Process.send_after(self(), :spawn, backoff)
      %{state | restarts: restarts, spawn_attempt: attempt + 1}
    end
  end

  defp cancel_host_calls(state) do
    for {_token, %{job: job}} <- state.host_calls, do: DependencyJob.cancel(job)
    :ok
  end

  # ---- incoming messages --------------------------------------------------------

  # A response to one of our requests.
  defp handle_message(%{"id" => id} = message, state)
       when is_binary(id) and not is_map_key(message, "method") do
    cond do
      id == state.init_id -> handle_initialize_reply(message, state)
      Map.has_key?(state.requests, id) -> handle_reply(id, message, state)
      true -> state
    end
  end

  # A reverse request from the guest.
  defp handle_message(%{"id" => id, "method" => "host.call", "params" => params}, state)
       when is_binary(id) do
    handle_host_call(id, params, state)
  end

  defp handle_message(%{"method" => "host.cancel", "params" => %{"id" => rpc_id}}, state) do
    case Map.pop(state.rpc_tokens, rpc_id) do
      {nil, _} ->
        {object_id, script_calls} = Map.pop(state.script_calls, rpc_id)

        with id when is_binary(id) <- object_id,
             %{kind: :script, owner: owner} <- Map.get(state.objects, id) do
          send(owner, {:script_host_cancel, id, rpc_id})
        end

        %{state | script_calls: script_calls}

      {token, rpc_tokens} ->
        {call, host_calls} = Map.pop(state.host_calls, token)
        if call, do: DependencyJob.cancel(call.job)
        %{state | host_calls: host_calls, rpc_tokens: rpc_tokens}
    end
  end

  defp handle_message(
         %{
           "method" => "sf.object.state",
           "params" => %{"object_id" => object_id, "state" => object_state} = status
         },
         state
       )
       when object_state in ["exited", "failed"] do
    settle_object(state, object_id, status)
  end

  defp handle_message(%{"method" => "sf.log", "params" => params}, state) do
    CommaLog.log("loop_guest_log", %{params: params})
    state
  end

  # An unknown request with an id gets a method-not-found reply so the child
  # never waits on us; unknown notifications are ignored.
  defp handle_message(%{"id" => id, "method" => method}, state) when is_binary(id) do
    _ =
      port_send(state.port, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "unknown method " <> to_string(method)}
      })

    state
  end

  defp handle_message(_message, state), do: state

  defp handle_initialize_reply(%{"result" => result}, state) do
    compiler = result["compiler"] || %{}

    Logger.info(
      "spinfoam ready: session #{result["session_id"]}, target #{result["target"]}, compiler available=#{compiler["available"] == true}"
    )

    Process.send_after(self(), :sweep, @sweep_ms)

    state = %{
      state
      | available: true,
        reason: nil,
        session_id: result["session_id"],
        compiler: compiler,
        limits: result["limits"] || %{},
        init_id: nil,
        spawn_attempt: 0
    }

    notify_reconciler(state, :host_ready)
    state
  end

  defp handle_initialize_reply(%{"error" => error}, state) do
    Logger.error("spinfoam refused initialize: #{inspect(error)}")
    child_lost(%{state | init_id: nil}, {:initialize_refused, error})
  end

  defp handle_reply(id, message, state) do
    {%{from: from, timer: timer, method: method}, requests} = Map.pop(state.requests, id)
    _ = Process.cancel_timer(timer)
    state = %{state | requests: requests}

    reply =
      case message do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, normalize_error(error)}
        _ -> {:error, :malformed_reply}
      end

    _ = method
    state = reply_request(from, reply, state)
    flush_queue(state)
  end

  defp normalize_error(%{} = error) do
    %{
      "code" => error["code"],
      "message" => error["message"],
      "kind" => get_in(error, ["data", "kind"])
    }
  end

  defp normalize_error(other), do: other

  # Replies come in three shapes: an ordinary caller, a load caller whose
  # object must be registered before it hears back, and the sweep.
  # Every answer to a script load, including a timeout, a refused request
  # and a lost child, releases the capacity reserved at admission; a loaded
  # object then holds it through `state.objects`.
  defp reply_request({:load, from, ref}, {:ok, %{"object_id" => object_id}}, state) do
    GenServer.reply(from, {:ok, object_id})
    state = %{state | objects: Map.put(state.objects, object_id, ref)}

    case ref do
      %{kind: :script, owner: owner} ->
        monitor = Process.monitor(owner)
        state = reserve_script_load(state, -1)
        %{state | monitors: Map.put(state.monitors, monitor, object_id)}

      _loop ->
        state
    end
  end

  defp reply_request({:load, from, ref}, reply, state) do
    GenServer.reply(from, reply)
    if script_ref?(ref), do: reserve_script_load(state, -1), else: state
  end

  defp reply_request(:sweep, {:ok, %{"objects" => objects} = page}, state) do
    state =
      Enum.reduce(objects, state, fn
        %{"object_id" => object_id, "state" => object_state} = status, acc
        when object_state in ["exited", "failed"] ->
          settle_object(acc, object_id, status)

        _other, acc ->
          acc
      end)

    # Listing is paginated; follow the cursor so every resident object is
    # checked once per sweep.
    case page["next"] do
      after_id when is_binary(after_id) ->
        enqueue_request(
          state,
          "sf.object.list",
          %{"limit" => 256, "after" => after_id},
          @default_request_timeout_ms,
          :sweep
        )

      _ ->
        state
    end
  end

  defp reply_request(:sweep, _reply, state), do: state
  defp reply_request(:discard, _reply, state), do: state

  defp reply_request(from, reply, state) do
    GenServer.reply(from, reply)
    state
  end

  # A terminal object: hand its outcome to the domain off the reader path,
  # unload it, and forget it. Duplicate notices (a notification plus the
  # sweep) are harmless: the domain fences on incarnation.
  defp settle_object(state, object_id, status) do
    case Map.pop(state.objects, object_id) do
      {nil, _} ->
        state

      {%{kind: :script, owner: owner}, _objects} ->
        send(owner, {:script_terminal, object_id, status})
        state = forget_object(state, object_id)

        enqueue_request(
          state,
          "sf.object.unload",
          %{"object_id" => object_id},
          @load_request_timeout_ms,
          :discard
        )

      {loop, objects} ->
        reconciler = state.reconciler
        host = self()

        Task.Supervisor.start_child(SalixAgent.TaskSup, fn ->
          try do
            reconciler.object_terminal(loop, object_id, status)
          after
            GenServer.cast(host, {:unload_object, object_id})
          end
        end)

        %{state | objects: objects}
    end
  end

  # Drop an object's registration, its owner monitor and its forwarded calls.
  defp forget_object(state, object_id) do
    {monitors, dropped} =
      Enum.split_with(state.monitors, fn {_monitor, id} -> id != object_id end)

    for {monitor, _} <- dropped, do: Process.demonitor(monitor, [:flush])

    %{
      state
      | objects: Map.delete(state.objects, object_id),
        monitors: Map.new(monitors),
        script_calls: Map.reject(state.script_calls, fn {_rpc, id} -> id == object_id end)
    }
  end

  @impl true
  def handle_cast({:host_reply, rpc_id, reply}, state) do
    case Map.pop(state.script_calls, rpc_id) do
      {nil, _} ->
        {:noreply, state}

      {_object_id, script_calls} ->
        send_host_result(state, rpc_id, reply)
        {:noreply, %{state | script_calls: script_calls}}
    end
  end

  def handle_cast({:unload_object, object_id}, state) do
    if state.available,
      do:
        {:noreply,
         enqueue_request(
           state,
           "sf.object.unload",
           %{"object_id" => object_id},
           @load_request_timeout_ms,
           :discard
         )},
      else: {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  # ---- host.call ------------------------------------------------------------------

  defp handle_host_call(rpc_id, params, state) do
    object_id = to_string(params["object_id"] || "")
    capability = to_string(params["capability"] || "")
    arguments = params["arguments"] || %{}

    case Map.get(state.objects, object_id) do
      nil ->
        send_host_error(
          state,
          rpc_id,
          "OBJECT_NOT_FOUND",
          "object is not registered with this host"
        )

        state

      %{kind: :script, owner: owner} ->
        # The owner is the tool call running this script: it executes the
        # capability inline under its own admission and deadline, so a
        # nested tool cannot saturate the per-tenant lane the outer call
        # already holds (`SalixAgent.ScriptRun`).
        send(owner, {:script_host_call, object_id, rpc_id, capability, arguments})
        %{state | script_calls: Map.put(state.script_calls, rpc_id, object_id)}

      loop ->
        deadline_ms = host_call_deadline(params)
        max_bytes = params["max_result_bytes"]

        dependency = fn -> Capabilities.call(loop, capability, arguments, max_bytes) end

        case DependencyJob.start(:tool, loop.tenant_id, dependency, timeout_ms: deadline_ms) do
          {:ok, job} ->
            entry = %{job: job, rpc_id: rpc_id, object_id: object_id}

            %{
              state
              | host_calls: Map.put(state.host_calls, job.token, entry),
                rpc_tokens: Map.put(state.rpc_tokens, rpc_id, job.token)
            }

          {:error, :dependency_saturated} ->
            send_host_error(state, rpc_id, "BUSY", "dependency admission is saturated")
            state

          {:error, reason} ->
            send_host_error(
              state,
              rpc_id,
              "HOST_ERROR",
              "dependency could not start: " <> inspect(reason)
            )

            state
        end
    end
  end

  # The operation's own deadline is what we enforce: the smaller of its
  # remaining absolute deadline and its original duration, clamped.
  defp host_call_deadline(params) do
    now = System.system_time(:millisecond)
    timeout = params["timeout_ms"]
    absolute = params["deadline_unix_ms"]

    candidates =
      [
        if(is_integer(timeout), do: timeout),
        if(is_integer(absolute), do: absolute - now)
      ]
      |> Enum.reject(&is_nil/1)

    case candidates do
      [] -> @default_request_timeout_ms
      values -> values |> Enum.min() |> max(@min_host_call_ms) |> min(@max_host_call_ms)
    end
  end

  defp send_host_result(state, rpc_id, {:ok, result}) do
    _ = port_send(state.port, %{"jsonrpc" => "2.0", "id" => rpc_id, "result" => result})
    :ok
  end

  defp send_host_result(state, rpc_id, {:error, message}) when is_binary(message),
    do: send_host_error(state, rpc_id, "HOST_ERROR", message)

  defp send_host_result(state, rpc_id, other),
    do:
      send_host_error(
        state,
        rpc_id,
        "HOST_ERROR",
        "capability returned " <> (inspect(other) |> String.slice(0, 200))
      )

  defp send_host_error(%State{port: nil}, _rpc_id, _kind, _message), do: :ok

  defp send_host_error(state, rpc_id, kind, message) do
    _ =
      port_send(state.port, %{
        "jsonrpc" => "2.0",
        "id" => rpc_id,
        "error" => %{"code" => -32000, "message" => message, "data" => %{"kind" => kind}}
      })

    :ok
  end

  # ---- outgoing requests ----------------------------------------------------------

  defp enqueue_request(state, method, params, timeout, from) do
    if map_size(state.requests) < @max_outstanding,
      do: send_request(state, method, params, timeout, from),
      else: %{state | queue: :queue.in({method, params, timeout, from}, state.queue)}
  end

  defp flush_queue(state) do
    if map_size(state.requests) < @max_outstanding do
      case :queue.out(state.queue) do
        {{:value, {method, params, timeout, from}}, queue} ->
          flush_queue(send_request(%{state | queue: queue}, method, params, timeout, from))

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp send_request(state, method, params, timeout, from) do
    id = "h:" <> Integer.to_string(state.next_id)
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case port_send(state.port, payload) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)

        %{
          state
          | next_id: state.next_id + 1,
            requests: Map.put(state.requests, id, %{from: from, method: method, timer: timer})
        }

      :error ->
        reply_request(from, {:error, :host_lost}, state)
    end
  end

  defp notify_reconciler(%State{reconciler: nil}, _event), do: :ok

  defp notify_reconciler(%State{reconciler: reconciler}, event) do
    if Process.whereis(reconciler), do: GenServer.cast(reconciler, event)
    :ok
  end

  # ---- port helpers ----------------------------------------------------------------

  defp port_send(nil, _payload), do: :error

  defp port_send(port, payload) do
    Port.command(port, [Jason.encode!(payload), "\n"])
    :ok
  rescue
    ArgumentError -> :error
  end

  defp safe_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
