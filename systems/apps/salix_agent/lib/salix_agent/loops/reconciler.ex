defmodule SalixAgent.Loops.Reconciler do
  require SystemsRuntime.Proc

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
      pauses the Loop (with the object's last failed host call, which the
      Host adds to the status), a fault reloads it from its checkpoint
      within the restart budget or marks it failed.
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
      behind it. An archived Agent has its stranded Loops paused as
      undeliverable at once. A missing Agent gets the same pause only after
      this node has seen it missing for the whole grace: a read during a
      rollout or a data import can miss an Agent that exists.
    * each sweep also ends one page of active Loops past their `ends_at`,
      tells one page of Tasks that their Loop ended
      (`SalixAgent.Loops.TaskOwner`), and runs again one page of Task Loops
      paused as `undeliverable` whose Task has its Worker again.

  Adoption runs in a bounded task per Agent; a request that arrives while an
  adoption is in flight runs once more after it, never concurrently. A
  `release/1` or `release_loop/2` call that arrives while one is in flight
  waits for it and then unloads what it loaded. The release when a Server
  goes down and the sweep's release act at once: the adoption in flight may
  already be the next Server's. An adoption loads nothing for an Agent
  without a live Server here, and one that ends after the Server went down
  unloads what it loaded: no Server is left to release it.
  """

  use SystemsRuntime.Server
  require Logger

  alias SalixAgent.{Loops, OwnershipCell}
  alias SalixAgent.Loops.{Capabilities, Host, TaskOwner}
  alias SalixStore.Loops, as: Store

  @sweep_ms :timer.seconds(60)
  @default_stranded_page 200
  @default_agent_missing_grace_ms :timer.hours(24)
  @default_max_objects 2_000
  @release_timeout_ms 25_000

  def start_link(opts \\ []),
    do:
      SystemsRuntime.Server.start_link(__MODULE__, opts,
        name: Keyword.get(opts, :name, __MODULE__)
      )

  @doc "Load and start the Agent's active Loops on this node. Asynchronous, idempotent."
  @spec adopt(String.t()) :: :ok
  def adopt(agent_id) when is_binary(agent_id) do
    if SystemsRuntime.Proc.whereis(__MODULE__),
      do: SystemsRuntime.Server.cast(__MODULE__, {:adopt, agent_id})

    :ok
  end

  @doc "Stop and unload every object of the Agent on this node. Synchronous."
  @spec release(String.t()) :: :ok
  def release(agent_id) when is_binary(agent_id), do: release_here(agent_id, nil)

  @doc "Stop and unload one Loop's object on this node. Synchronous."
  @spec release_loop(String.t(), String.t()) :: :ok
  def release_loop(agent_id, loop_id) when is_binary(agent_id) and is_binary(loop_id),
    do: release_here(agent_id, loop_id)

  # The Reconciler releases inline when its own work leads here (a sweep
  # marking a Loop undeliverable): a call to itself could not be answered.
  defp release_here(agent_id, loop_id) do
    case SystemsRuntime.Proc.whereis(__MODULE__) do
      nil ->
        :ok

      reconciler ->
        if reconciler == SystemsRuntime.Proc.self(),
          do: do_release(agent_id, loop_id),
          else: SystemsClock.call(__MODULE__, {:release, agent_id, loop_id}, @release_timeout_ms)

        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Node-wide object capacity."
  @spec max_objects() :: pos_integer()
  def max_objects,
    do: SystemsRuntime.get_env(:salix_agent, :spinfoam_max_objects, @default_max_objects)

  @doc """
  Settle a terminal object. Called by the Host in a task; the Host has
  already forgotten the object and is unloading it.
  """
  @spec object_terminal(map(), String.t(), map()) :: :ok
  def object_terminal(loop, _object_id, %{"state" => "exited"} = status) do
    code = get_in(status, ["outcome", "exit_code"])
    Loops.record_exit(loop.loop_id, loop.incarnation, code, status["last_host_error"])
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
    schedule_sweep()

    {:ok,
     %{
       inflight: %{},
       pending: MapSet.new(),
       releases: %{},
       monitors: %{},
       recovery_cursor: nil,
       missing_agents: %{},
       settle_cursor: nil,
       undeliverable_cursor: nil,
       settle_task: nil
     }}
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
  def handle_call({:release, agent_id, loop_id}, from, state) do
    {:noreply, release(state, agent_id, loop_id, from)}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()

    # Objects of an Agent this node no longer holds must go; every locally
    # served Agent gets an idempotent adoption pass.
    resident_agents =
      Host.loop_objects() |> Map.values() |> Enum.map(& &1.agent_id) |> Enum.uniq()

    for agent_id <- resident_agents, OwnershipCell.fetch(agent_id) in [:fenced, :absent] do
      do_release(agent_id, nil)
    end

    local = local_agents()
    state = recover_stranded(local, state)
    state = start_task_sweep(state)
    {:noreply, Enum.reduce(local, state, &start_adoption(&2, &1))}
  end

  def handle_info({ref, {settle_cursor, undeliverable_cursor}}, %{settle_task: ref} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])

    {:noreply,
     %{
       state
       | settle_task: nil,
         settle_cursor: settle_cursor,
         undeliverable_cursor: undeliverable_cursor
     }}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{settle_task: ref} = state),
    do: {:noreply, %{state | settle_task: nil}}

  def handle_info({ref, _result}, state) when SystemsRuntime.Proc.is_ref(ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
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

  # The periodic pass. With `config :salix_agent, loops_sweep: false` (the test
  # configuration) a pass runs only when a `:sweep` message asks for one.
  defp schedule_sweep do
    if SystemsRuntime.get_env(:salix_agent, :loops_sweep, true),
      do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, @sweep_ms)
  end

  defp start_task_sweep(%{settle_task: nil} = state) do
    task =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        :ok = Loops.end_past_due()

        {TaskOwner.reconcile_settles(state.settle_cursor),
         Loops.recover_undeliverable_tasks(state.undeliverable_cursor)}
      end)

    %{state | settle_task: task.ref}
  end

  defp start_task_sweep(state), do: state

  # ---- adoption -----------------------------------------------------------------

  defp start_adoption(state, agent_id) do
    if Enum.any?(state.inflight, fn {_ref, id} -> id == agent_id end) do
      %{state | pending: MapSet.put(state.pending, agent_id)}
    else
      task =
        SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
          do_adopt(agent_id)
        end)

      state = monitor_server(state, agent_id)
      %{state | inflight: Map.put(state.inflight, task.ref, agent_id)}
    end
  end

  defp finish_adoption(state, ref) do
    {agent_id, inflight} = Map.pop(state.inflight, ref)
    state = %{state | inflight: inflight}
    {waiting, releases} = Map.pop(state.releases, agent_id, [])
    state = %{state | releases: releases}

    # The adoption may have loaded objects after a release was asked for:
    # unload them now, oldest request first.
    for {loop_id, from} <- Enum.reverse(waiting) do
      do_release(agent_id, loop_id)
      SystemsRuntime.Server.reply(from, :ok)
    end

    # The Server went down while the adoption ran: its release found nothing
    # loaded yet.
    if agent_id && not served?(agent_id), do: do_release(agent_id, nil)

    if agent_id && MapSet.member?(state.pending, agent_id),
      do: start_adoption(%{state | pending: MapSet.delete(state.pending, agent_id)}, agent_id),
      else: state
  end

  # Unloads the Agent's objects (one Loop's when `loop_id` is set) and answers
  # `from`. While an adoption of the Agent is in flight it could still load an
  # object after the unload, so the release waits for the adoption to end.
  # The caller is the Agent's own Server passivating or a caller that stopped
  # the Agent, so the adoption in flight is one that release ends.
  defp release(state, agent_id, loop_id, from) do
    if Enum.any?(state.inflight, fn {_ref, id} -> id == agent_id end) do
      waiting = [{loop_id, from} | Map.get(state.releases, agent_id, [])]
      %{state | releases: Map.put(state.releases, agent_id, waiting)}
    else
      do_release(agent_id, loop_id)
      SystemsRuntime.Server.reply(from, :ok)
      state
    end
  end

  # Release when the Agent's Server on this node goes away, whatever the
  # reason: a passivated, fenced or crashed Server no longer holds the lease.
  defp monitor_server(state, agent_id) do
    already = Enum.any?(state.monitors, fn {_ref, id} -> id == agent_id end)

    case {already, SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id)} do
      {false, [{pid, _}]} ->
        ref = SystemsRuntime.Proc.monitor(pid)
        %{state | monitors: Map.put(state.monitors, ref, agent_id)}

      _ ->
        state
    end
  end

  defp do_adopt(agent_id) do
    started = SystemsClock.monotonic_time()

    outcome =
      with {:ok, _epoch} <- owned?(agent_id),
           true <- served?(agent_id),
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

    emit("loop_reconcile", reconcile_outcome(outcome), SystemsClock.monotonic_time() - started)
    outcome
  end

  defp owned?(agent_id) do
    case OwnershipCell.fetch(agent_id) do
      {:ok, epoch} -> {:ok, epoch}
      _ -> {:error, :not_owned}
    end
  end

  # The ownership cell outlives a Server that stopped without passivating, so
  # it alone does not show that a Server here would release the objects.
  defp served?(agent_id) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] -> SystemsRuntime.Proc.alive?(pid)
      [] -> false
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
        # and the tools its product binding pins; the tool dispatch applies the
        # Agent's own disclosure per call.
        capabilities = Capabilities.load_capabilities(record)

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

  @doc false
  def loop_ref(record) do
    %{
      loop_id: record["id"],
      incarnation: record["incarnation"],
      agent_id: record["agent_id"],
      session_id: record["session_id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      task_conversation_id: record["task_conversation_id"],
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
  # The cursor of the next pass is after the last row of a full page, or `nil`
  # (wrap to the start) once a short page shows the set is exhausted.
  defp recover_stranded(local, state) do
    live = Enum.map([node() | Node.list()], &Atom.to_string/1)
    page = stranded_page()

    case Store.list_active_stranded(live, page, state.recovery_cursor) do
      {:ok, rows} ->
        missing =
          rows
          |> Enum.group_by(& &1["agent_id"])
          |> Enum.reject(fn {agent_id, _} -> agent_id in local end)
          |> Enum.reduce(fresh_missing(state.missing_agents), fn {agent_id, loops}, missing ->
            restart_owner(agent_id, loops, missing)
          end)

        cursor =
          case rows do
            [] -> nil
            _ when length(rows) < page -> nil
            _ -> (last = List.last(rows)) && {last["updated_at"], last["id"]}
          end

        %{state | recovery_cursor: cursor, missing_agents: missing}

      {:error, _} ->
        state
    end
  end

  defp stranded_page,
    do: SystemsRuntime.get_env(:salix_agent, :loops_recovery_page, @default_stranded_page)

  defp agent_missing_grace_ms do
    SystemsRuntime.get_env(
      :salix_agent,
      :loops_agent_missing_grace_ms,
      @default_agent_missing_grace_ms
    )
  end

  # An Agent this node has not seen missing for a whole grace came back or has
  # no stranded Loop left: its next miss starts a new grace.
  defp fresh_missing(missing) do
    now = SystemsClock.system_time(:millisecond)
    grace = agent_missing_grace_ms()
    Map.filter(missing, fn {_agent_id, %{seen: seen}} -> now - seen < grace end)
  end

  defp restart_owner(agent_id, loops, missing) do
    case SalixAgent.Placement.ensure_started(agent_id, create: false) do
      {:ok, _pid} ->
        emit("loop_reconcile", "retained")
        Map.delete(missing, agent_id)

      {:error, :not_found} ->
        agent_missing(agent_id, loops, missing)

      {:error, reason} when is_tuple(reason) and elem(reason, 0) == :bad_request ->
        pause_undeliverable(agent_id, loops, reason)
        Map.delete(missing, agent_id)

      {:error, reason} ->
        Logger.warning("agent #{agent_id} background loop recovery deferred: #{inspect(reason)}")
        emit("loop_reconcile", "error")
        missing
    end
  end

  defp agent_missing(agent_id, loops, missing) do
    now = SystemsClock.system_time(:millisecond)
    since = get_in(missing, [agent_id, :since]) || now

    if now - since >= agent_missing_grace_ms() do
      pause_undeliverable(agent_id, loops, :not_found)
      Map.delete(missing, agent_id)
    else
      Logger.warning(
        "agent #{agent_id} background loop recovery deferred: :not_found since #{since}"
      )

      emit("loop_reconcile", "error")
      Map.put(missing, agent_id, %{since: since, seen: now})
    end
  end

  defp pause_undeliverable(agent_id, loops, reason) do
    Logger.warning(
      "agent #{agent_id} cannot host its #{length(loops)} background loop(s): #{inspect(reason)}; pausing them as undeliverable"
    )

    Enum.each(loops, &Loops.mark_undeliverable(&1["id"], notify: true))
  end

  # Agents with a live Server on this node. Registry keys for Servers are the
  # bare agent id; session actors register under tuples.
  defp local_agents do
    if SystemsRuntime.Proc.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> SystemsRuntime.Registry.select([{{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}])
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
