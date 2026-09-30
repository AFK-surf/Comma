defmodule SalixAgent.Loops.Reconciler do
  @moduledoc """
  Keeps the spinfoam objects on this node equal to the active Loops of the
  Agents this node holds (docs/salix/tasks-background-execution.md, "Background
  loops").

  A Loop runs where its Agent's root head is held: the existing
  `SalixAgent.Server` claim, `SalixAgent.OwnershipCell` mirror and
  `SalixCluster.Placement` routing decide placement, and this module only
  follows them. There is no scheduler of its own.

    * `adopt/1` after a claim (and after `loop.create`, `loop.resume`,
      unarchive) loads and starts every active Loop of the Agent that is not
      resident here, bumping each Loop's incarnation first.
    * `release/1` on passivation, fencing, archive, or the Server going down
      stops and unloads the Agent's objects.
    * `object_terminal/3` settles an object that exited or faulted: exit
      pauses the Loop, a fault reloads it from its checkpoint within the
      restart budget or marks it failed.
    * a periodic sweep re-checks ownership for every resident Agent and
      adopts every locally served Agent, so a lost notification cannot leave
      a Loop stranded or a superseded node running a Loop.
    * the same sweep is the bounded recovery owner for stranded Loops:
      active rows with no object attached, or attached on a node that is no
      longer a cluster member, get their Agent's Server started through
      `SalixAgent.Placement`, which claims the lease and adopts them. Each
      pass takes one page after a keyset cursor kept across passes and wraps
      to the start once the set is exhausted, so a page whose Agents cannot
      be started (or are served here and unloaded) never starves the rows
      behind it. An Agent that no longer exists or is archived has its
      stranded Loops paused as undeliverable instead of retried forever.

  Adoption runs in a bounded task per Agent; a request that arrives while an
  adoption is in flight runs once more after it, never concurrently.
  """

  use GenServer
  require Logger

  alias SalixAgent.{Loops, OwnershipCell}
  alias SalixAgent.Loops.{Capabilities, Host}
  alias SalixStore.Loops, as: Store

  @sweep_ms :timer.seconds(60)
  @default_stranded_page 200
  @default_max_objects 2_000
  @release_timeout_ms 25_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Load and start the Agent's active Loops on this node. Asynchronous, idempotent."
  @spec adopt(String.t()) :: :ok
  def adopt(agent_id) when is_binary(agent_id) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:adopt, agent_id})
    :ok
  end

  @doc "Stop and unload every object of the Agent on this node. Synchronous."
  @spec release(String.t()) :: :ok
  def release(agent_id) when is_binary(agent_id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:release, agent_id, nil}, @release_timeout_ms)

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Stop and unload one Loop's object on this node. Synchronous."
  @spec release_loop(String.t(), String.t()) :: :ok
  def release_loop(agent_id, loop_id) when is_binary(agent_id) and is_binary(loop_id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:release, agent_id, loop_id}, @release_timeout_ms)

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Node-wide object capacity."
  @spec max_objects() :: pos_integer()
  def max_objects,
    do: Application.get_env(:salix_agent, :spinfoam_max_objects, @default_max_objects)

  @doc """
  Settle a terminal object. Called by the Host in a task; the Host has
  already forgotten the object and is unloading it.
  """
  @spec object_terminal(map(), String.t(), map()) :: :ok
  def object_terminal(loop, _object_id, %{"state" => "exited"} = status) do
    code = get_in(status, ["outcome", "exit_code"])
    Loops.record_exit(loop.loop_id, loop.incarnation, code)
    emit("loop_reconcile", "ok")
    :ok
  end

  def object_terminal(loop, _object_id, %{"state" => "failed"} = status) do
    diagnostic =
      case status["outcome"] do
        %{"error" => error} -> to_string(error)
        other -> inspect(other)
      end

    case Loops.record_failure(loop.loop_id, loop.incarnation, diagnostic) do
      {:ok, :restart} ->
        emit("loop_reconcile", "retained")
        adopt(loop.agent_id)

      {:ok, :failed} ->
        emit("loop_reconcile", "failed")

      {:error, _stale} ->
        :ok
    end

    :ok
  end

  def object_terminal(_loop, _object_id, _status), do: :ok

  # ---- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{inflight: %{}, pending: MapSet.new(), monitors: %{}, recovery_cursor: nil}}
  end

  @impl true
  def handle_cast({:adopt, agent_id}, state), do: {:noreply, start_adoption(state, agent_id)}

  def handle_cast(:host_ready, state) do
    # A fresh spinfoam session holds nothing: every locally served Agent
    # needs its Loops back, each at a new incarnation.
    {:noreply, Enum.reduce(local_agents(), state, &start_adoption(&2, &1))}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:release, agent_id, loop_id}, _from, state) do
    do_release(agent_id, loop_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)

    # Objects of an Agent this node no longer holds must go; every locally
    # served Agent gets an idempotent adoption pass.
    resident_agents =
      Host.loop_objects() |> Map.values() |> Enum.map(& &1.agent_id) |> Enum.uniq()

    for agent_id <- resident_agents, OwnershipCell.fetch(agent_id) in [:fenced, :absent] do
      do_release(agent_id, nil)
    end

    local = local_agents()
    state = %{state | recovery_cursor: recover_stranded(local, state.recovery_cursor)}
    {:noreply, Enum.reduce(local, state, &start_adoption(&2, &1))}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_adoption(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.inflight, ref) ->
        {:noreply, finish_adoption(state, ref)}

      Map.has_key?(state.monitors, ref) ->
        {agent_id, monitors} = Map.pop(state.monitors, ref)
        do_release(agent_id, nil)
        {:noreply, %{state | monitors: monitors}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---- adoption -----------------------------------------------------------------

  defp start_adoption(state, agent_id) do
    if Enum.any?(state.inflight, fn {_ref, id} -> id == agent_id end) do
      %{state | pending: MapSet.put(state.pending, agent_id)}
    else
      task = Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn -> do_adopt(agent_id) end)
      state = monitor_server(state, agent_id)
      %{state | inflight: Map.put(state.inflight, task.ref, agent_id)}
    end
  end

  defp finish_adoption(state, ref) do
    {agent_id, inflight} = Map.pop(state.inflight, ref)
    state = %{state | inflight: inflight}

    if agent_id && MapSet.member?(state.pending, agent_id),
      do: start_adoption(%{state | pending: MapSet.delete(state.pending, agent_id)}, agent_id),
      else: state
  end

  # Release when the Agent's Server on this node goes away, whatever the
  # reason: a passivated, fenced or crashed Server no longer holds the lease.
  defp monitor_server(state, agent_id) do
    already = Enum.any?(state.monitors, fn {_ref, id} -> id == agent_id end)

    case {already, Registry.lookup(SalixAgent.Registry, agent_id)} do
      {false, [{pid, _}]} ->
        ref = Process.monitor(pid)
        %{state | monitors: Map.put(state.monitors, ref, agent_id)}

      _ ->
        state
    end
  end

  defp do_adopt(agent_id) do
    started = System.monotonic_time()

    outcome =
      with {:ok, _epoch} <- owned?(agent_id),
           %{available: true, session_id: session} <- Host.status(),
           {:ok, loops} <- Store.list_active_by_agent(agent_id) do
        resident = resident_by_loop(agent_id)
        active_ids = MapSet.new(loops, & &1["id"])

        # Objects whose Loop is no longer active here are stale residents.
        for {loop_id, object_id} <- resident, not MapSet.member?(active_ids, loop_id) do
          _ = Host.object_unload(object_id)
        end

        outcome =
          loops
          |> Enum.reject(&Map.has_key?(resident, &1["id"]))
          |> Enum.reduce(:ok, fn loop, acc ->
            case load_loop(loop, session) do
              :ok -> acc
              {:error, :capacity} -> {:error, :capacity}
              {:error, _} -> if(acc == :ok, do: :partial, else: acc)
            end
          end)

        Enum.each(loops, &Loops.reconcile_events(&1["id"]))
        outcome
      else
        {:error, :not_owned} ->
          :skipped

        %{available: false} ->
          case Store.list_active_by_agent(agent_id) do
            {:ok, loops} -> Enum.each(loops, &Loops.reconcile_events(&1["id"]))
            _ -> :ok
          end

          :skipped

        {:error, reason} ->
          {:error, reason}

        _ ->
          :skipped
      end

    emit("loop_reconcile", reconcile_outcome(outcome), System.monotonic_time() - started)
    outcome
  end

  defp owned?(agent_id) do
    case OwnershipCell.fetch(agent_id) do
      {:ok, epoch} -> {:ok, epoch}
      _ -> {:error, :not_owned}
    end
  end

  defp resident_by_loop(agent_id) do
    Host.loop_objects()
    |> Enum.filter(fn {_object_id, ref} -> ref.agent_id == agent_id end)
    |> Map.new(fn {object_id, ref} -> {ref.loop_id, object_id} end)
  end

  defp load_loop(loop, host_session) do
    if map_size(Host.objects()) >= max_objects() do
      Logger.warning(
        "spinfoam object capacity reached on this node; loop #{loop["id"]} stays unloaded until capacity frees"
      )

      {:error, :capacity}
    else
      with {:ok, record} <-
             Loops.begin_incarnation(loop["id"], Atom.to_string(node()), host_session) do
        ref = loop_ref(record)
        config = load_config(record)
        # No per-Loop grants: every object is loaded with the whole allowlist
        # and the tool dispatch applies the Agent's own disclosure per call.
        capabilities = Capabilities.load_capabilities()

        case Loops.artifact(record) do
          {:ok, elf} ->
            load_object(ref, elf, config, capabilities)

          {:error, reason} ->
            settle_load_failure(ref, "artifact #{ref.elf_path}: #{inspect(reason)}")
        end
      end
    end
  end

  defp load_object(ref, elf, config, capabilities) do
    case Host.object_load(ref, elf, config, capabilities) do
      {:ok, object_id} ->
        with :ok <- Loops.attach_object(ref.loop_id, ref.incarnation, object_id),
             :ok <- Host.object_start(object_id) do
          :ok
        else
          {:error, reason} ->
            _ = Host.object_unload(object_id)
            settle_load_failure(ref, "start failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        settle_load_failure(ref, "load failed: " <> load_error_text(reason))
    end
  end

  defp settle_load_failure(ref, diagnostic) do
    Logger.warning("loop #{ref.loop_id} #{diagnostic}")

    case Loops.record_failure(ref.loop_id, ref.incarnation, diagnostic) do
      {:ok, :restart} -> {:error, :retry}
      _ -> {:error, :failed}
    end
  end

  defp load_error_text(%{"message" => message, "kind" => kind}), do: "#{kind}: #{message}"
  defp load_error_text(other), do: inspect(other) |> String.slice(0, 500)

  # The guest's config carries its own identity and the last checkpoint, so
  # a reload resumes from explicit application state rather than a stack.
  defp load_config(record) do
    (record["config"] || %{})
    |> Map.put("loop_id", record["id"])
    |> Map.put("incarnation", record["incarnation"])
    |> Map.put("state", record["checkpoint"])
  end

  defp loop_ref(record) do
    %{
      loop_id: record["id"],
      incarnation: record["incarnation"],
      agent_id: record["agent_id"],
      session_id: record["session_id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      name: record["name"],
      elf_path: record["elf_path"],
      ifc: record["ifc"] || %{}
    }
  end

  # ---- release -------------------------------------------------------------------

  defp do_release(agent_id, loop_id) do
    Host.loop_objects()
    |> Enum.filter(fn {_object_id, ref} ->
      ref.agent_id == agent_id and (is_nil(loop_id) or ref.loop_id == loop_id)
    end)
    |> Enum.each(fn {object_id, ref} ->
      _ = Host.object_unload(object_id)
      Loops.end_incarnation(ref.loop_id, ref.incarnation)
    end)

    :ok
  end

  # ---- recovery ------------------------------------------------------------------

  # Active Loops without a live incarnation belong to Agents whose Server is
  # not running anywhere (node loss, a crash, a cold start). Starting the
  # Server through the placement seam routes to the owner node, where the
  # claim adopts them; every node runs this pass, and a start for an Agent
  # that already has a Server is a no-op, so duplicates are harmless.
  # Returns the cursor for the next pass: after the last row of a full page,
  # or `nil` (wrap to the start) once a short page shows the set is exhausted.
  defp recover_stranded(local, cursor) do
    live = Enum.map([node() | Node.list()], &Atom.to_string/1)
    page = stranded_page()

    case Store.list_active_stranded(live, page, cursor) do
      {:ok, rows} ->
        rows
        |> Enum.group_by(& &1["agent_id"])
        |> Enum.reject(fn {agent_id, _} -> agent_id in local end)
        |> Enum.each(fn {agent_id, loops} -> restart_owner(agent_id, loops) end)

        case rows do
          [] -> nil
          _ when length(rows) < page -> nil
          _ -> (last = List.last(rows)) && {last["updated_at"], last["id"]}
        end

      {:error, _} ->
        cursor
    end
  end

  defp stranded_page,
    do: Application.get_env(:salix_agent, :loops_recovery_page, @default_stranded_page)

  defp restart_owner(agent_id, loops) do
    case SalixAgent.Placement.ensure_started(agent_id, create: false) do
      {:ok, _pid} ->
        emit("loop_reconcile", "retained")

      {:error, reason}
      when reason == :not_found or (is_tuple(reason) and elem(reason, 0) == :bad_request) ->
        Logger.warning(
          "agent #{agent_id} cannot host its #{length(loops)} background loop(s): #{inspect(reason)}; pausing them as undeliverable"
        )

        Enum.each(loops, &Loops.mark_undeliverable(&1["id"]))

      {:error, reason} ->
        Logger.warning("agent #{agent_id} background loop recovery deferred: #{inspect(reason)}")
        emit("loop_reconcile", "error")
    end
  end

  # Agents with a live Server on this node. Registry keys for Servers are the
  # bare agent id; session actors register under tuples.
  defp local_agents do
    if Process.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> Registry.select([{{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}])
      |> Enum.uniq()
    else
      []
    end
  end

  defp reconcile_outcome(:ok), do: "ok"
  defp reconcile_outcome(:partial), do: "partial"
  defp reconcile_outcome(:skipped), do: "skipped"
  defp reconcile_outcome({:error, :capacity}), do: "over_budget"
  defp reconcile_outcome({:error, _}), do: "error"

  defp emit(operation, outcome, duration \\ 0) do
    Salix.Telemetry.emit_operation("salix_agent", operation, "loop", outcome, duration)
  end
end
