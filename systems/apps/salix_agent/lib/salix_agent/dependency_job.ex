defmodule SalixAgent.DependencyJob do
  @moduledoc """
  Actor-owned handle for one user dependency execution.

  Admission is globally and per-tenant bounded by `DependencyAdmission`. The
  owner receives a token-fenced result and an independent deadline message;
  completing, cancelling, timing out, or losing either process releases the
  admission exactly once.
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

  @type kind :: :llm | :compaction | :external_runtime | :tool
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
      when kind in [:llm, :compaction, :external_runtime, :tool] and is_binary(tenant_id) and
             is_function(fun, 0) do
    owner = self()
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout_ms(kind))

    with true <- is_integer(timeout_ms) and timeout_ms > 0,
         {:ok, token, pid} <-
           SalixAgent.DependencyAdmission.start(owner, tenant_id, kind, fun) do
      timer_ref = Process.send_after(owner, {:dependency_job_timeout, token}, timeout_ms)

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
    receive do
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

    case Application.get_env(:salix_agent, :dependency_job_timeout_ms, default) do
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
    _ = Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end
end

defmodule SalixAgent.DependencyRunner do
  @moduledoc false

  use GenServer

  require Logger

  alias SalixAgent.DependencyJob

  defstruct jobs: %{}, keys: %{}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec start(DependencyJob.kind(), String.t(), (-> term()), keyword()) ::
          :ok | {:error, :dependency_already_running | :dependency_saturated | term()}
  def start(kind, tenant_id, fun, opts \\ []) do
    GenServer.call(__MODULE__, {:start, kind, tenant_id, fun, opts})
  end

  @doc false
  def active_count, do: GenServer.call(__MODULE__, :active_count)

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
  @moduledoc false

  use GenServer

  @default_global_limit 64
  @default_per_tenant_limit 8
  @kinds [:llm, :compaction, :external_runtime, :tool]

  defstruct jobs: %{},
            task_refs: %{},
            owner_refs: %{},
            tenant_counts: %{},
            kind_counts: %{},
            tenant_limits: %{}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def start(owner, tenant_id, kind, fun),
    do: GenServer.call(__MODULE__, {:start, owner, tenant_id, kind, fun})

  def release(token), do: GenServer.call(__MODULE__, {:release, token})

  def cancel(token, outcome \\ :cancelled) when outcome in [:cancelled, :timeout],
    do: GenServer.call(__MODULE__, {:cancel, token, outcome})

  @impl true
  def init(_opts) do
    state = %__MODULE__{}
    Enum.each(@kinds, &emit_active(&1, state))
    if tenant_limit_refresh_ms(), do: schedule_tenant_limit_refresh(0)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, owner, tenant_id, kind, fun}, _from, state) do
    if admitted?(state, tenant_id) do
      token = make_ref()

      case Task.Supervisor.start_child(SalixAgent.DependencyTaskSup, fn ->
             result = fun.()
             send(owner, {:dependency_job_result, token, result})
           end) do
        {:ok, pid} ->
          task_ref = Process.monitor(pid)
          owner_ref = Process.monitor(owner)

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

  @impl true
  def handle_info(:refresh_tenant_limits, state) do
    server = self()

    # Tenant profiles override the per-Tenant limit. The bounded read runs
    # outside admission; a failed read keeps the last known overrides.
    Task.start(fn ->
      try do
        send(server, {:tenant_limits, SalixStore.TenantProfiles.dependency_limits()})
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
            send(owner, {:dependency_job_down, token, reason})

          _other ->
            :ok
        end

        outcome = if reason == :normal, do: :ok, else: :crashed
        {:noreply, drop_job(state, token, false, outcome)}

      token = state.owner_refs[ref] ->
        {:noreply, drop_job(state, token, true, :cancelled)}

      true ->
        {:noreply, state}
    end
  end

  defp admitted?(state, tenant_id) do
    tenant_limit =
      Map.get_lazy(state.tenant_limits, tenant_id, fn ->
        limit(:dependency_max_children_per_tenant, @default_per_tenant_limit)
      end)

    map_size(state.jobs) < limit(:dependency_max_children, @default_global_limit) and
      Map.get(state.tenant_counts, tenant_id, 0) < tenant_limit
  end

  defp tenant_limit_refresh_ms,
    do: Application.get_env(:salix_agent, :dependency_tenant_limit_refresh_ms, 30_000)

  defp schedule_tenant_limit_refresh(ms) when is_integer(ms) and ms >= 0,
    do: Process.send_after(self(), :refresh_tenant_limits, ms)

  defp schedule_tenant_limit_refresh(_disabled), do: :ok

  defp limit(key, default) do
    case Application.get_env(:salix_agent, key, default) do
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
        tenant_counts: Map.update(state.tenant_counts, job.tenant_id, 1, &(&1 + 1)),
        kind_counts: Map.update(state.kind_counts, job.kind, 1, &(&1 + 1))
    }
  end

  defp drop_job(state, token, kill?, outcome) do
    case Map.pop(state.jobs, token) do
      {nil, _jobs} ->
        state

      {job, jobs} ->
        if kill? and Process.alive?(job.pid), do: Process.exit(job.pid, :kill)
        Process.demonitor(job.task_ref, [:flush])
        Process.demonitor(job.owner_ref, [:flush])

        tenant_counts =
          case Map.get(state.tenant_counts, job.tenant_id, 0) - 1 do
            remaining when remaining > 0 ->
              Map.put(state.tenant_counts, job.tenant_id, remaining)

            _zero ->
              Map.delete(state.tenant_counts, job.tenant_id)
          end

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
        state
    end
  end

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
