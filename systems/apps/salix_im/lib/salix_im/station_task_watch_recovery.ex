defmodule SalixIM.StationTaskWatchRecovery do
  @moduledoc """
  Starts the owners of the active station Tasks placed on this node after it
  starts, so each Task's `SalixIM.StationTaskWatch` is armed again.

  A Task's owner (`SalixIM.ConversationActor`) starts on demand and nothing
  starts it again after a node restart or a placement change: reads do not
  start owners, and a station Task whose Worker sits idle is touched by
  nobody. Its watch is the only thing that reminds the Worker and reports the
  stall, and the watch's timer lives in the owner, so every deployment
  silenced stall detection for every in-flight delegation until something
  wrote to the Task. This server starts the owner of each active station Task
  that placement puts on this node (`SalixIM.ConversationPlacement.owner?/2`,
  then `ensure_started/2`, local for an owned Task); the owner's watch then
  rebuilds the delegation from the Messages and reminds or reports as it
  would have. Every node sweeps at its own start and at each placement
  change, so together the nodes cover every Task once, without remote calls.

  Runs once `first_sweep_ms` after this server starts, when the node is
  ready to own keys (`node_ready/0`, from the placement ring), and after each
  placement change (`ring_changed/0`). Pokes within `debounce_ms` of each
  other run one sweep. A sweep already running is not interrupted.

  Bound: one page read of `page_size` Tasks per `page_size` active station
  Tasks (`SalixStore.StationTaskSessions.active_tasks/2`: Tasks with a
  station row whose record is `active`), one placement lookup per such
  Task, and one local `ensure_started` per Task placed here. An owner
  already running costs a registry lookup. Ended Tasks and Tasks with no
  station cost nothing. No scan per request: sweeps happen at node start
  and placement change only, one at a time per node.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.ConversationPlacement
  alias SalixStore.StationTaskSessions

  @page_size 100
  @first_sweep_ms :timer.seconds(60)
  @debounce_ms :timer.seconds(5)
  @event "station_task_watch_recovery"

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "This node is ready to own keys: sweep soon. Only sends."
  @spec node_ready() :: :ok
  def node_ready, do: poke()

  @doc "Placement changed: sweep soon. Only sends."
  @spec ring_changed() :: :ok
  def ring_changed, do: poke()

  @doc """
  One sweep now, in the caller: the owners of the active station Tasks
  placed on this node are started. `{:ok, %{tasks, started, skipped,
  failed}}`: `tasks` the active station Tasks read, `skipped` those placed
  on another node, `failed` the Tasks whose start failed with why;
  `{:error, reason}` when the page read failed. `group_id: id` keeps to one
  Group's Tasks (a test or an operator; the node's own sweeps read all).
  """
  @spec sweep(keyword()) :: {:ok, map()} | {:error, term()}
  def sweep(opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @page_size)
    read = [group: Keyword.get(opts, :group_id)]
    started_at = SystemsClock.monotonic_time(:millisecond)

    case pages(nil, page_size, read, %{tasks: 0, started: 0, skipped: 0, failed: []}) do
      {:ok, result} ->
        result = %{result | failed: Enum.reverse(result.failed)}

        Logger.log(
          if(result.failed == [], do: :info, else: :warning),
          "station Task owners started after node start: tasks=#{result.tasks} started=#{result.started} skipped=#{result.skipped} failed=#{length(result.failed)}",
          event: @event,
          component: "salix_im",
          tasks: result.tasks,
          started: result.started,
          skipped: result.skipped,
          failed: length(result.failed),
          duration_ms: SystemsClock.monotonic_time(:millisecond) - started_at
        )

        {:ok, result}

      {:error, reason} = error ->
        Logger.warning("station Task owners not started after node start: #{inspect(reason)}",
          event: @event,
          component: "salix_im"
        )

        error
    end
  end

  defp pages(cursor, page_size, read, acc) do
    case StationTaskSessions.active_tasks(cursor, page_size, read) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, tasks} ->
        acc = Enum.reduce(tasks, acc, &start_owner/2)

        if length(tasks) < page_size,
          do: {:ok, acc},
          else: pages(List.last(tasks), page_size, read, acc)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_owner({group_id, conversation_id} = task, acc) do
    acc = %{acc | tasks: acc.tasks + 1}

    if ConversationPlacement.owner?(group_id, conversation_id),
      do: start_owned(task, acc),
      else: %{acc | skipped: acc.skipped + 1}
  end

  # Placed here, so the start is local; its own node sweeps a Task placed
  # elsewhere.
  defp start_owned({group_id, conversation_id} = task, acc) do
    case ConversationPlacement.ensure_started(group_id, conversation_id) do
      {:ok, _pid} ->
        %{acc | started: acc.started + 1}

      {:error, reason} ->
        Logger.warning(
          "station Task #{conversation_id} owner not started after node start: #{inspect(reason)}",
          event: @event,
          component: "salix_im",
          group_id: group_id,
          conversation_id: conversation_id
        )

        %{acc | failed: [{task, reason} | acc.failed]}
    end
  end

  defp poke do
    case SystemsRuntime.Proc.whereis(__MODULE__) do
      nil -> :ok
      pid -> SystemsRuntime.Proc.send(pid, :poke)
    end

    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      page_size: Keyword.get(opts, :page_size, @page_size),
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      timer: nil
    }

    # Without a first delay (nil) only pokes sweep.
    {:ok, arm(state, Keyword.get(opts, :first_sweep_ms, @first_sweep_ms))}
  end

  @impl true
  def handle_info(:poke, state), do: {:noreply, arm(state, state.debounce_ms)}

  def handle_info(:sweep, state) do
    _ = sweep(page_size: state.page_size)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One timer at a time: a poke while one is armed changes nothing.
  defp arm(%{timer: nil} = state, delay) when is_integer(delay),
    do: %{state | timer: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, delay)}

  defp arm(state, _delay), do: state
end
