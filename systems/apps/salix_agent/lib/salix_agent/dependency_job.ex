defmodule SalixAgent.DependencyJob do
  require SystemsRuntime.Proc

  require SystemsClock

  @moduledoc """
  Actor-owned handle for one user dependency execution.

  Admission is globally and per-tenant bounded by `DependencyAdmission`,
  except `:loop_control`: a background Loop's own checkpoint, ack, log and
  notify calls, and a session's own send to a Conversation or update of one
  (`SalixAgent.Tools`). Those are bounded Store writes, at most one in flight
  per resident Loop (a guest's `host.call` is synchronous) and at most a
  round's calls per session, and refusing them because model rounds hold the
  Tenant's slots makes a Loop lose its checkpoint or its wake, and a session
  its report. They are tracked for deadlines and telemetry but neither need
  nor take a slot. The owner receives a token-fenced result and an
  independent deadline message; completing, cancelling, timing out, or
  losing either process releases the admission exactly once.
  """

  defstruct [
    :kind,
    :tenant_id,
    :token,
    :ref,
    :pid,
    :timer_ref,
    :timeout_ms
  ]

  @type kind :: :llm | :compaction | :tool | :loop_control
  @type t :: %__MODULE__{
          kind: kind(),
          tenant_id: String.t(),
          token: reference(),
          ref: reference(),
          pid: pid(),
          timer_ref: reference(),
          timeout_ms: pos_integer()
        }

  @default_timeout_ms 120_000

  @spec start(kind(), String.t(), (-> term()), keyword()) ::
          {:ok, t()} | {:error, :dependency_saturated | term()}
  def start(kind, tenant_id, fun, opts \\ [])
      when kind in [:llm, :compaction, :tool, :loop_control] and
             is_binary(tenant_id) and
             is_function(fun, 0) do
    owner = SystemsRuntime.Proc.self()
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout_ms(kind))

    with true <- is_integer(timeout_ms) and timeout_ms > 0,
         {:ok, token, pid} <-
           SalixAgent.DependencyAdmission.start(owner, tenant_id, kind, fun) do
      timer_ref = SystemsClock.send_after(owner, {:dependency_job_timeout, token}, timeout_ms)

      {:ok,
       %__MODULE__{
         kind: kind,
         tenant_id: tenant_id,
         token: token,
         # `ref` remains the public stale-result identity used by actors/tests.
         ref: token,
         pid: pid,
         timer_ref: timer_ref,
         timeout_ms: timeout_ms
       }}
    else
      false -> {:error, :invalid_dependency_timeout}
      {:error, _} = error -> error
    end
  end

  @spec complete(t()) :: :ok
  def complete(%__MODULE__{} = job) do
    cancel_timer(job.timer_ref)
    SalixAgent.DependencyAdmission.release(job.token)
  end

  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{} = job) do
    cancel(job, :cancelled)
  end

  @spec cancel(t(), :cancelled | :timeout) :: :ok
  def cancel(%__MODULE__{} = job, outcome) when outcome in [:cancelled, :timeout] do
    cancel_timer(job.timer_ref)
    SalixAgent.DependencyAdmission.cancel(job.token, outcome)
  end

  @doc false
  @spec yield(t(), timeout()) :: {:ok, term()} | {:exit, term()} | nil
  def yield(%__MODULE__{} = job, timeout) do
    SystemsClock.vreceive do
      {:dependency_job_result, token, result} when token == job.token ->
        :ok = complete(job)
        {:ok, result}

      {:dependency_job_down, token, reason} when token == job.token ->
        :ok = complete(job)
        {:exit, reason}

      {:dependency_job_timeout, token} when token == job.token ->
        :ok = cancel(job, :timeout)
        {:exit, {:dependency_timeout, job.kind}}
    after
      timeout -> nil
    end
  end

  @spec timeout_ms(kind()) :: pos_integer()
  def timeout_ms(kind) do
    default = default_timeout_ms(kind)

    case SystemsRuntime.get_env(:salix_agent, :dependency_job_timeout_ms, default) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      timeouts when is_map(timeouts) ->
        map_timeout(timeouts, kind) || default

      _other ->
        default
    end
  end

  defp default_timeout_ms(kind) when kind in [:llm, :compaction],
    do: SalixAgent.LLM.request_timeout_ms()

  defp default_timeout_ms(_kind), do: @default_timeout_ms

  defp map_timeout(timeouts, kind) do
    value = Map.get(timeouts, kind) || Map.get(timeouts, Atom.to_string(kind))
    if is_integer(value) and value > 0, do: value
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = SystemsClock.cancel_timer(timer_ref)
    :ok
  end
end

defmodule SalixAgent.DependencyRunner do
  @moduledoc false

  use SystemsRuntime.Server

  require Logger

  alias SalixAgent.DependencyJob

  defstruct jobs: %{}, keys: %{}

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @spec start(DependencyJob.kind(), String.t(), (-> term()), keyword()) ::
          :ok | {:error, :dependency_already_running | :dependency_saturated | term()}
  def start(kind, tenant_id, fun, opts \\ []) do
    SystemsRuntime.Server.call(__MODULE__, {:start, kind, tenant_id, fun, opts})
  end

  @doc false
  def active_count, do: SystemsRuntime.Server.call(__MODULE__, :active_count)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:start, kind, tenant_id, fun, opts}, _from, state) do
    key = Keyword.get(opts, :key)
    label = Keyword.get(opts, :label, kind)

    if not is_nil(key) and Map.has_key?(state.keys, key) do
      {:reply, {:error, :dependency_already_running}, state}
    else
      case DependencyJob.start(kind, tenant_id, fun, opts) do
        {:ok, job} ->
          entry = %{job: job, key: key, label: label}

          state = %{
            state
            | jobs: Map.put(state.jobs, job.token, entry),
              keys: if(is_nil(key), do: state.keys, else: Map.put(state.keys, key, job.token))
          }

          {:reply, :ok, state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(:active_count, _from, state), do: {:reply, map_size(state.jobs), state}

  @impl true
  def handle_info({:dependency_job_result, token, _result}, state) do
    {:noreply, finish(state, token, :complete)}
  end

  def handle_info({:dependency_job_timeout, token}, state) do
    case state.jobs[token] do
      %{label: label} -> Logger.warning("background dependency timed out: #{inspect(label)}")
      nil -> :ok
    end

    {:noreply, finish(state, token, :timeout)}
  end

  def handle_info({:dependency_job_down, token, reason}, state) do
    case state.jobs[token] do
      %{label: label} ->
        Logger.warning("background dependency crashed: #{inspect(label)} #{inspect(reason)}")

      nil ->
        :ok
    end

    {:noreply, finish(state, token, :complete)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, token, action) do
    case Map.pop(state.jobs, token) do
      {nil, _jobs} ->
        state

      {%{job: job, key: key}, jobs} ->
        case action do
          :timeout -> DependencyJob.cancel(job, :timeout)
          :complete -> DependencyJob.complete(job)
        end

        keys = if is_nil(key), do: state.keys, else: Map.delete(state.keys, key)
        %{state | jobs: jobs, keys: keys}
    end
  end
end

defmodule SalixAgent.DependencyAdmission do
  require SystemsRuntime.Proc

  @moduledoc false

  use SystemsRuntime.Server

  @default_global_limit 64
  @default_per_tenant_limit 8
  @kinds [:llm, :compaction, :tool, :loop_control]
  # Kinds admitted without a global or per-Tenant slot (see `DependencyJob`).
  @unmetered_kinds [:loop_control]

  defstruct jobs: %{},
            task_refs: %{},
            owner_refs: %{},
            tenant_counts: %{},
            kind_counts: %{},
            tenant_limits: %{},
            capacity_watches: %{},
            capacity_watch_refs: %{},
            capacity_watch_order: 0

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  # Admission starts a job that waits for its function, and the owner sends
  # the function to the job directly. Passing it through this server and the
  # task supervisor would copy it twice more, and a round's closure can hold
  # hundreds of kilobytes.
  def start(owner, tenant_id, kind, fun) do
    unless owner == SystemsRuntime.Proc.self(),
      do: raise(FunctionClauseError, module: __MODULE__, function: :start, arity: 4)

    with {:ok, token, pid} <-
           SystemsRuntime.Server.call(__MODULE__, {:start, owner, tenant_id, kind}) do
      SystemsRuntime.Proc.send(pid, {:dependency_job_fun, token, fun})
      {:ok, token, pid}
    end
  end

  def release(token), do: SystemsRuntime.Server.call(__MODULE__, {:release, token})

  def cancel(token, outcome \\ :cancelled) when outcome in [:cancelled, :timeout],
    do: SystemsRuntime.Server.call(__MODULE__, {:cancel, token, outcome})

  # A notification is only a hint to retry normal admission, not a reserved slot.
  # Checking capacity in the same call closes the release-before-watch race.
  @spec watch_capacity(String.t(), SalixAgent.DependencyJob.kind(), reference()) ::
          :ok | {:error, :saturated}
  def watch_capacity(tenant_id, kind, token)
      when is_binary(tenant_id) and kind in @kinds and is_reference(token),
      do: SystemsRuntime.Server.call(__MODULE__, {:watch_capacity, tenant_id, kind, token})

  @spec cancel_capacity_watch(reference()) :: :ok
  def cancel_capacity_watch(token) when is_reference(token),
    do: SystemsRuntime.Server.call(__MODULE__, {:cancel_capacity_watch, token})

  @impl true
  def init(_opts) do
    state = %__MODULE__{}
    Enum.each(@kinds, &emit_active(&1, state))
    if tenant_limit_refresh_ms(), do: schedule_tenant_limit_refresh(0)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, owner, tenant_id, kind}, _from, state) do
    if admitted?(state, tenant_id, kind) do
      token = SystemsRuntime.Proc.make_ref()

      case SystemsRuntime.TaskSupervisor.start_child(SalixAgent.DependencyTaskSup, fn ->
             await_and_run(owner, token)
           end) do
        {:ok, pid} ->
          task_ref = SystemsRuntime.Proc.monitor(pid)
          owner_ref = SystemsRuntime.Proc.monitor(owner)

          job = %{
            owner: owner,
            owner_ref: owner_ref,
            tenant_id: tenant_id,
            kind: kind,
            pid: pid,
            task_ref: task_ref
          }

          state = put_job(state, token, job)
          emit_active(kind, state)
          {:reply, {:ok, token, pid}, state}

        {:error, :max_children} ->
          Salix.Telemetry.emit_dependency_job(kind, :saturated)
          {:reply, {:error, :dependency_saturated}, state}

        {:error, reason} ->
          Salix.Telemetry.emit_dependency_job(kind, :error)
          {:reply, {:error, {:dependency_start_failed, reason}}, state}
      end
    else
      Salix.Telemetry.emit_dependency_job(kind, :saturated)
      {:reply, {:error, :dependency_saturated}, state}
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, drop_job(state, token, false, :ok)}
  end

  def handle_call({:cancel, token, outcome}, _from, state) do
    {:reply, :ok, drop_job(state, token, true, outcome)}
  end

  def handle_call({:watch_capacity, tenant_id, kind, token}, {owner, _tag}, state) do
    state = drop_capacity_watch(state, owner)

    cond do
      admitted?(state, tenant_id, kind) ->
        SystemsRuntime.Proc.send(owner, {:dependency_capacity_available, token})
        {:reply, :ok, state}

      map_size(state.capacity_watches) <
          limit(:dependency_max_children, @default_global_limit) ->
        ref = SystemsRuntime.Proc.monitor(owner)
        order = state.capacity_watch_order + 1
        watch = %{token: token, tenant_id: tenant_id, kind: kind, ref: ref, order: order}

        {:reply, :ok,
         %{
           state
           | capacity_watches: Map.put(state.capacity_watches, owner, watch),
             capacity_watch_refs: Map.put(state.capacity_watch_refs, ref, owner),
             capacity_watch_order: order
         }}

      true ->
        # The owner's existing retry timer remains the fallback when full.
        {:reply, {:error, :saturated}, state}
    end
  end

  def handle_call({:cancel_capacity_watch, token}, {owner, _tag}, state) do
    state =
      case state.capacity_watches[owner] do
        %{token: ^token} -> drop_capacity_watch(state, owner)
        _other -> state
      end

    {:reply, :ok, state}
  end

  # Admission also kills a job whose owner exits. The monitor covers an owner
  # that exits before it sends the function while admission is restarting.
  defp await_and_run(owner, token) do
    monitor = SystemsRuntime.Proc.monitor(owner)

    SystemsRuntime.Proc.receive do
      {:dependency_job_fun, ^token, fun} ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        result = fun.()
        SystemsRuntime.Proc.send(owner, {:dependency_job_result, token, result})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok
    end
  end

  @impl true
  def handle_info(:refresh_tenant_limits, state) do
    server = SystemsRuntime.Proc.self()

    # Tenant profiles override the per-Tenant limit. The bounded read runs
    # outside admission; a failed read keeps the last known overrides.
    SystemsRuntime.Task.start(fn ->
      try do
        SystemsRuntime.Proc.send(
          server,
          {:tenant_limits, SalixStore.TenantProfiles.dependency_limits()}
        )
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end
    end)

    schedule_tenant_limit_refresh(tenant_limit_refresh_ms())
    {:noreply, state}
  end

  def handle_info({:tenant_limits, limits}, state) when is_map(limits),
    do: {:noreply, %{state | tenant_limits: limits}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      token = state.task_refs[ref] ->
        case state.jobs[token] do
          %{owner: owner} when reason != :normal ->
            SystemsRuntime.Proc.send(owner, {:dependency_job_down, token, reason})

          _other ->
            :ok
        end

        outcome = if reason == :normal, do: :ok, else: :crashed
        {:noreply, drop_job(state, token, false, outcome)}

      token = state.owner_refs[ref] ->
        {:noreply, drop_job(state, token, true, :cancelled)}

      owner = state.capacity_watch_refs[ref] ->
        {:noreply, drop_capacity_watch(state, owner)}

      true ->
        {:noreply, state}
    end
  end

  defp admitted?(_state, _tenant_id, kind) when kind in @unmetered_kinds, do: true

  defp admitted?(state, tenant_id, _kind) do
    tenant_limit =
      Map.get_lazy(state.tenant_limits, tenant_id, fn ->
        limit(:dependency_max_children_per_tenant, @default_per_tenant_limit)
      end)

    metered_count(state) < limit(:dependency_max_children, @default_global_limit) and
      Map.get(state.tenant_counts, tenant_id, 0) < tenant_limit
  end

  defp metered_count(state) do
    map_size(state.jobs) -
      Enum.reduce(@unmetered_kinds, 0, &(Map.get(state.kind_counts, &1, 0) + &2))
  end

  defp tenant_limit_refresh_ms,
    do: SystemsRuntime.get_env(:salix_agent, :dependency_tenant_limit_refresh_ms, 30_000)

  defp schedule_tenant_limit_refresh(ms) when is_integer(ms) and ms >= 0,
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :refresh_tenant_limits, ms)

  defp schedule_tenant_limit_refresh(_disabled), do: :ok

  defp limit(key, default) do
    case SystemsRuntime.get_env(:salix_agent, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp put_job(state, token, job) do
    %{
      state
      | jobs: Map.put(state.jobs, token, job),
        task_refs: Map.put(state.task_refs, job.task_ref, token),
        owner_refs: Map.put(state.owner_refs, job.owner_ref, token),
        tenant_counts: count_tenant(state.tenant_counts, job),
        kind_counts: Map.update(state.kind_counts, job.kind, 1, &(&1 + 1))
    }
  end

  defp drop_job(state, token, kill?, outcome) do
    case Map.pop(state.jobs, token) do
      {nil, _jobs} ->
        state

      {job, jobs} ->
        if kill? and SystemsRuntime.Proc.alive?(job.pid),
          do: SystemsRuntime.Proc.exit(job.pid, :kill)

        SystemsRuntime.Proc.demonitor(job.task_ref, [:flush])
        SystemsRuntime.Proc.demonitor(job.owner_ref, [:flush])

        tenant_counts =
          if job.kind in @unmetered_kinds,
            do: state.tenant_counts,
            else: decrement_count(state.tenant_counts, job.tenant_id)

        kind_counts = decrement_count(state.kind_counts, job.kind)

        state = %{
          state
          | jobs: jobs,
            task_refs: Map.delete(state.task_refs, job.task_ref),
            owner_refs: Map.delete(state.owner_refs, job.owner_ref),
            tenant_counts: tenant_counts,
            kind_counts: kind_counts
        }

        Salix.Telemetry.emit_dependency_job(job.kind, outcome)
        emit_active(job.kind, state)
        if job.kind in @unmetered_kinds, do: state, else: notify_capacity_watch(state)
    end
  end

  defp notify_capacity_watch(state) do
    # Both the scan and its retained state are bounded by the global job limit.
    # A release can help another Tenant, so eligibility uses all current limits.
    state.capacity_watches
    |> Enum.filter(fn {_owner, watch} -> admitted?(state, watch.tenant_id, watch.kind) end)
    |> Enum.min_by(fn {_owner, watch} -> watch.order end, fn -> nil end)
    |> case do
      nil ->
        state

      {owner, watch} ->
        state = drop_capacity_watch(state, owner)
        SystemsRuntime.Proc.send(owner, {:dependency_capacity_available, watch.token})
        state
    end
  end

  defp drop_capacity_watch(state, owner) do
    case Map.pop(state.capacity_watches, owner) do
      {nil, _watches} ->
        state

      {watch, watches} ->
        SystemsRuntime.Proc.demonitor(watch.ref, [:flush])

        %{
          state
          | capacity_watches: watches,
            capacity_watch_refs: Map.delete(state.capacity_watch_refs, watch.ref)
        }
    end
  end

  defp count_tenant(counts, %{kind: kind}) when kind in @unmetered_kinds, do: counts
  defp count_tenant(counts, job), do: Map.update(counts, job.tenant_id, 1, &(&1 + 1))

  defp decrement_count(counts, key) do
    case Map.get(counts, key, 0) do
      count when count <= 1 -> Map.delete(counts, key)
      count -> Map.put(counts, key, count - 1)
    end
  end

  defp emit_active(kind, state) do
    Salix.Telemetry.emit_dependency_job_active(kind, Map.get(state.kind_counts, kind, 0))
  end
end
