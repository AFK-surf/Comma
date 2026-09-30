defmodule SalixAgent.Browser.Driver do
  @moduledoc "Native CDP driver. One pending operation and a bounded stream lifecycle queue."
  use GenServer
  alias SalixStore.{BrowserSettings, BrowserBindings}
  alias SalixAgent.Browser.{Connection, Commands}

  def child_spec(row),
    do: %{
      id: {__MODULE__, row.agent_id, row.session_id},
      start: {__MODULE__, :start_link, [row]},
      restart: :temporary
    }

  def start_link(row), do: GenServer.start_link(__MODULE__, row, name: name(row))

  # The process address is cluster-wide. SQL admission remains authoritative
  # if distribution partitions or a driver disappears during an operation.
  defp name(row),
    do: {:global, {__MODULE__, row.agent_id, row.session_id, row.provider_id}}

  def ensure(row) do
    case GenServer.whereis(name(row)) do
      nil ->
        case DynamicSupervisor.start_child(SalixAgent.Browser.Supervisor, {__MODULE__, row}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          _ -> {:error, :browser_driver_unavailable}
        end

      pid ->
        {:ok, pid}
    end
  end

  def observe(row) do
    case GenServer.whereis(name(row)) do
      nil -> {:error, :browser_driver_unavailable}
      pid -> {:ok, pid}
    end
  end

  def activate(row) do
    with {:ok, pid} <- ensure(row), do: GenServer.call(pid, :activate)
  end

  def call(row, op, args \\ %{}) do
    driver =
      if op in ~w(storage_export stream_start stream_stop), do: observe(row), else: ensure(row)

    with {:ok, pid} <- driver, do: request(pid, op, args)
  end

  def request(pid, op, args), do: GenServer.call(pid, {:command, op, args}, 40_000)
  def frame(pid, tab), do: GenServer.call(pid, {:frame, tab}, 2000)

  def stop(row) do
    if pid = GenServer.whereis(name(row)),
      do: GenServer.stop(pid, :normal, 5000)

    :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :browser_driver, message: :redacted, log: []})

  @impl true
  def init(row) do
    with {:ok, token} <- BrowserSettings.unseal(row.token_ciphertext, row.credential_scope),
         {:ok, snapshot} <- SalixStore.BrowserStorage.load(row) do
      options = SalixAgent.Browser.provider().connection(row, token)

      init_connection(
        options ++
          [
            timeout: row.options["operation_timeout_ms"] || 15_000,
            origins: Map.keys(snapshot["origins"]),
            origin_access:
              Map.new(Map.keys(snapshot["origins"]), fn origin ->
                {origin, get_in(snapshot, ["last_used", "origin:" <> origin]) || 0}
              end),
            binding: row,
            snapshot: snapshot
          ]
      )
    else
      _ -> {:stop, :browser_driver_unavailable}
    end
  end

  # Also used by integration tests with a real local Chromium CDP endpoint.
  def init_connection(opts) do
    Process.flag(:trap_exit, true)

    case Connection.start_link(Keyword.put(opts, :owner, self())) do
      {:ok, conn} ->
        {:ok,
         %{
           commands:
             SalixAgent.Browser.Storage.seed(
               Commands.new(conn, Keyword.get(opts, :timeout, 15_000)),
               Keyword.get(opts, :snapshot, SalixStore.BrowserStorage.empty())
             ),
           pending: nil,
           pending_op: nil,
           queue: :queue.new(),
           idle: idle_timer(),
           binding: Keyword.get(opts, :binding),
           checkpoint_timer: nil,
           checkpoint_worker: nil,
           last_activity: System.monotonic_time(:millisecond)
         }}

      _ ->
        {:stop, :browser_driver_unavailable}
    end
  end

  @impl true
  def handle_call(:activate, _, state), do: {:reply, :ok, activity(state)}

  def handle_call({:command, op, args}, from, state) do
    state =
      if op in ~w(storage_export storage_restore stream_start stream_stop),
        do: state,
        else: activity(state)

    cond do
      is_nil(state.pending) ->
        {:noreply, start_command(state, op, args, from)}

      (op in ["stream_start", "stream_stop"] or state.pending_op == "storage_export") and
          :queue.len(state.queue) < 32 ->
        {:noreply, %{state | queue: :queue.in({op, args, from, deadline()}, state.queue)}}

      true ->
        {:reply, {:error, :browser_driver_busy}, state}
    end
  end

  def handle_call({:frame, tab}, _, state) do
    frame =
      if session = state.commands.tabs[tab], do: Connection.frame(state.commands.conn, session)

    frame = if frame, do: Map.put(frame, "tab_id", tab)
    {:reply, {:ok, frame}, state}
  end

  @impl true
  def handle_cast({:stop_stream, tab, viewer}, state) do
    args = %{"tab_id" => tab, "viewer_id" => viewer}

    cond do
      is_nil(state.pending) ->
        {:noreply, start_command(state, "stream_stop", args, nil)}

      :queue.len(state.queue) < 32 ->
        {:noreply,
         %{state | queue: :queue.in({"stream_stop", args, nil, deadline()}, state.queue)}}

      true ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:completed, pid, result}, %{pending: {pid, from, timer}} = state) do
    Process.cancel_timer(timer)

    {reply, commands} =
      case result do
        {:ok, value, commands} -> {{:ok, value}, commands}
        {:error, reason} -> {{:error, reason}, state.commands}
      end

    if from, do: GenServer.reply(from, reply)
    state = %{state | commands: commands, pending: nil, pending_op: nil}

    case :queue.out(state.queue) do
      {{:value, {op, args, from, deadline}}, queue} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          {:noreply, start_command(%{state | queue: queue}, op, args, from, remaining)}
        else
          {:stop, :normal, state}
        end

      {:empty, _} ->
        {:noreply, state}
    end
  end

  def handle_info(:checkpoint, state) do
    state = %{state | checkpoint_timer: nil}

    if state.binding && state.binding.options["shared_storage"] == true &&
         is_nil(state.checkpoint_worker) &&
         System.monotonic_time(:millisecond) - state.last_activity <
           (state.binding.options["idle_timeout_ms"] || 60000) do
      owner = self()
      binding = state.binding

      {pid, _} =
        spawn_monitor(fn ->
          SalixAgent.Browser.checkpoint(binding)
          send(owner, :checkpoint_finished)
        end)

      {:noreply, %{state | checkpoint_worker: pid}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:checkpoint_finished, state),
    do: {:noreply, schedule_checkpoint(%{state | checkpoint_worker: nil})}

  def handle_info({:DOWN, _, :process, pid, _}, %{checkpoint_worker: pid} = state),
    do: {:noreply, schedule_checkpoint(%{state | checkpoint_worker: nil})}

  def handle_info({:command_timeout, pid}, %{pending: {pid, _, _}} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, conn, _}, %{commands: %{conn: conn}} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _}, %{pending: {pid, _, _}} = state), do: {:stop, :normal, state}

  def handle_info(:idle, state) do
    Process.cancel_timer(state.idle)
    remaining = state.last_activity + 600_000 - System.monotonic_time(:millisecond)
    remaining = if remaining > 0, do: remaining, else: control_remaining(state.binding)

    if remaining > 0,
      do: {:noreply, %{state | idle: Process.send_after(self(), :idle, remaining)}},
      else: {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start_command(state, op, args, from, timeout \\ 35_000) do
    timeout =
      if op in ["storage_export", "storage_restore"],
        do: min(timeout, min(args["timeout_ms"] || 15_000, 15_000)),
        else: timeout

    owner = self()
    commands = state.commands

    pid =
      spawn_link(fn ->
        result =
          try do
            {value, commands} = Commands.execute(commands, op, args)
            {:ok, value, commands}
          rescue
            _ -> {:error, "browser_operation_failed"}
          catch
            {:browser_error, reason} -> {:error, reason}
            :exit, _ -> {:error, :browser_outcome_unknown}
          end

        send(owner, {:completed, self(), result})
      end)

    timer = Process.send_after(self(), {:command_timeout, pid}, timeout)
    %{state | pending: {pid, from, timer}, pending_op: op}
  end

  @impl true
  def terminate(_, state) do
    if state.pending do
      {pid, from, _} = state.pending
      Process.exit(pid, :kill)
      if from, do: GenServer.reply(from, {:error, :browser_outcome_unknown})
    end

    for {_, _, from, _} <- :queue.to_list(state.queue),
        from != nil,
        do: GenServer.reply(from, {:error, :browser_outcome_unknown})

    if Process.alive?(state.commands.conn), do: GenServer.stop(state.commands.conn, :normal)
    :ok
  end

  # One timer and at most one save per active Group. Observation streams do
  # not renew activity or keep an otherwise idle provider browser alive.
  defp schedule_checkpoint(%{binding: nil} = state), do: state

  defp schedule_checkpoint(%{checkpoint_timer: nil} = state),
    do: %{state | checkpoint_timer: Process.send_after(self(), :checkpoint, 15_000)}

  defp schedule_checkpoint(state), do: state

  defp deadline, do: System.monotonic_time(:millisecond) + 35_000
  defp idle_timer, do: Process.send_after(self(), :idle, 600_000)

  # Check one binding only at idle expiry, then at the active lease expiry.
  # Passive viewers never grant a lease or refresh command activity.
  defp control_remaining(nil), do: 0

  defp control_remaining(binding) do
    case BrowserBindings.get(binding) do
      %{provider_id: id, status: "ready", control: "human", controller_expires_at: expires}
      when id == binding.provider_id and not is_nil(expires) ->
        max(0, DateTime.diff(expires, DateTime.utc_now(), :millisecond))

      _ ->
        0
    end
  end

  defp activity(state) do
    Process.cancel_timer(state.idle)

    schedule_checkpoint(%{
      state
      | idle: idle_timer(),
        last_activity: System.monotonic_time(:millisecond)
    })
  end
end
