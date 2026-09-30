defmodule Comma.PodLifecycle do
  @moduledoc """
  Launcher-owned, node-local lifecycle state for the statically known Comma
  subsystems.

  Readiness is deliberately local and side-effect free. It checks only drain
  state, started OTP applications, the Comma schema contract when applicable,
  and whether this pod may accept durable work. Remote provider health is
  reported by domain operations and telemetry, never by readiness.
  """

  @state_key {__MODULE__, :state}
  @surfaces %{
    salix: :salix,
    comma_product: :comma_product,
    bridge_for_teams: :bridge_for_teams
  }
  @oban_queues [:comma_external, :comma_discovery]

  @type surface :: :salix | :comma_product | :bridge_for_teams

  @doc false
  def boot(enabled) when is_list(enabled) do
    :persistent_term.put(@state_key, %{
      enabled: MapSet.new(enabled),
      draining: false,
      jobs_accepting: true
    })

    :ok
  end

  @doc "Liveness proves only that the BEAM serving this request is alive."
  def live, do: :ok

  @doc "Return the local, side-effect-free readiness result for a public surface."
  @spec ready(surface()) :: :ok | {:error, atom()}
  def ready(surface) when is_map_key(@surfaces, surface) do
    state = state()
    subsystem = Map.fetch!(@surfaces, surface)

    cond do
      state.draining -> {:error, :draining}
      not state.jobs_accepting -> {:error, :jobs_quiet}
      not MapSet.member?(state.enabled, subsystem) -> {:error, :subsystem_disabled}
      not apps_started?(subsystem) -> {:error, :apps_starting}
      surface == :comma_product and not comma_schema_ready?() -> {:error, :schema_not_ready}
      surface == :salix and not salix_cutover_ready?() -> {:error, :cutover_not_ready}
      surface == :salix and salix_draining?() -> {:error, :draining}
      true -> :ok
    end
  end

  def ready(_surface), do: {:error, :unknown_surface}

  @doc "Whether HTTP adapters may accept a new non-health request on this pod."
  def accepting_requests? do
    state = state()
    not state.draining and state.jobs_accepting
  end

  @doc "Immediately remove this pod from readiness and reject new work."
  def begin_drain do
    update(fn state -> %{state | draining: true, jobs_accepting: false} end)

    if subsystem_running?(:salix) do
      maybe_apply(SalixCluster.NodeLifecycle, :mark_draining, [])
    end

    :ok
  end

  @doc """
  Execute the pod preStop order: withdraw readiness and pause local Oban
  producers, allow endpoint propagation, wait a bounded grace for running jobs,
  then end live voice calls with a spoken notice, drain Salix actors and
  confirm local connector socket shutdown before
  their node becomes unreachable. Connector cleanup has a 15-second total
  deadline; failure is reported, never converted into an owner-stop proof.
  """
  def pre_stop(opts \\ []) do
    :ok = begin_drain()
    emit_pre_stop(:readiness_withdrawn)
    pause_local_queues()
    emit_pre_stop(:jobs_quiet)
    sleep_bounded(Keyword.get(opts, :propagation_ms, propagation_ms()), 10_000)
    job_result = wait_for_running_jobs(Keyword.get(opts, :job_grace_ms, job_grace_ms()))
    emit_pre_stop(:job_grace_complete, job_result)
    # Live voice calls hear a short notice and end (bounded, about 10 s) while
    # their Router still runs; readiness is already withdrawn, so no new call
    # is admitted. A remaining call is reported, never blocks the drain.
    voice_result =
      if subsystem_running?(:salix),
        do: maybe_apply(SalixVoice.Drain, :drain, [], :ok),
        else: :ok

    emit_pre_stop(:voice_drain_complete, voice_result)
    drain_result = drain_salix()
    emit_pre_stop(:salix_drain_complete, drain_result)

    connector_result =
      if subsystem_running?(:salix),
        do: maybe_apply(SalixWeb.ConnectorDrain, :drain, [], :ok),
        else: :ok

    emit_pre_stop(:connector_drain_complete, connector_result)
    if connector_result == :ok, do: drain_result, else: connector_result
  end

  @doc false
  def reset_for_test do
    boot(Comma.enabled_subsystems())
    maybe_apply(SalixCluster.NodeLifecycle, :clear_draining, [])
    :ok
  end

  defp state do
    :persistent_term.get(@state_key, %{
      enabled: MapSet.new(Comma.enabled_subsystems()),
      draining: false,
      jobs_accepting: true
    })
  end

  defp update(fun) do
    :persistent_term.put(@state_key, fun.(state()))
  end

  defp apps_started?(subsystem) do
    started = Application.started_applications() |> MapSet.new(fn {app, _, _} -> app end)
    Enum.all?(Comma.apps(subsystem), &MapSet.member?(started, &1))
  end

  defp comma_schema_ready? do
    maybe_apply(Comma.SchemaReadiness, :ready?, [], false) == true
  end

  # The tenant-api-key cutover marker must exist before this pod serves salix
  # key auth (docs/storage-search.md). Post-cutover keys are
  # PG-only; runtime.exs makes the control DB mandatory for salix in prod, so a
  # salix node always runs the readiness probe. This replaces the retired
  # per-request cutover gate — serving code reads Postgres directly once ready.
  # Every control-metadata cutover must have completed before this pod serves
  # salix: one readiness probe per migrated dataset, all required. Post-cutover
  # each dataset is PG-only; runtime.exs makes the control DB mandatory for
  # salix in prod, so a salix node always runs the probes.
  defp salix_cutover_ready? do
    maybe_apply(SalixStore.TenantApiKeyReadiness, :ready?, [], false) == true and
      maybe_apply(SalixStore.ProviderCredentialsReadiness, :ready?, [], false) == true and
      maybe_apply(SalixStore.TenantConfigsReadiness, :ready?, [], false) == true and
      maybe_apply(SalixStore.SchedulesReadiness, :ready?, [], false) == true and
      maybe_apply(SalixStore.OAuthAppsReadiness, :ready?, [], false) == true
  end

  defp salix_draining? do
    maybe_apply(SalixCluster.NodeLifecycle, :draining?, [], false) == true
  end

  defp pause_local_queues do
    oban = Module.concat([Oban])

    if Code.ensure_loaded?(oban) and Process.whereis(Comma.Oban) do
      Enum.each(@oban_queues, fn queue ->
        _ = apply(oban, :pause_queue, [Comma.Oban, [queue: queue, local_only: true]])
      end)
    end

    :ok
  end

  defp wait_for_running_jobs(grace_ms) do
    deadline = System.monotonic_time(:millisecond) + bounded_ms(grace_ms, 30_000)
    do_wait_for_running_jobs(deadline)
  end

  defp do_wait_for_running_jobs(deadline) do
    cond do
      running_job_count() == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :job_grace_exhausted}

      true ->
        Process.sleep(100)
        do_wait_for_running_jobs(deadline)
    end
  end

  defp running_job_count do
    oban = Module.concat([Oban])

    if Code.ensure_loaded?(oban) and Process.whereis(Comma.Oban) do
      Enum.reduce(@oban_queues, 0, fn queue, count ->
        case apply(oban, :check_queue, [Comma.Oban, [queue: queue]]) do
          %{running: running} when is_list(running) -> count + length(running)
          _ -> count
        end
      end)
    else
      0
    end
  end

  defp drain_salix do
    if subsystem_running?(:salix) do
      case maybe_apply(SalixCluster.Drain, :drain, [[mark_draining: false]], :not_running) do
        :not_running -> empty_salix_drain()
        result -> result
      end
    else
      empty_salix_drain()
    end
  end

  defp subsystem_running?(subsystem) do
    MapSet.member?(state().enabled, subsystem) and apps_started?(subsystem)
  end

  defp empty_salix_drain, do: {:ok, %{drained: [], handed_off: 0, failed: []}}

  defp propagation_ms,
    do: Application.get_env(:comma, :pre_stop_propagation_ms, 5_000)

  defp job_grace_ms,
    do: Application.get_env(:comma, :pre_stop_job_grace_ms, 25_000)

  defp sleep_bounded(value, max) do
    case bounded_ms(value, max) do
      0 -> :ok
      ms -> Process.sleep(ms)
    end
  end

  defp bounded_ms(value, max) when is_integer(value), do: value |> max(0) |> min(max)
  defp bounded_ms(_value, _max), do: 0

  defp emit_pre_stop(stage, result \\ :ok) do
    :telemetry.execute(
      [:comma, :pod_lifecycle, :pre_stop],
      %{count: 1},
      %{stage: stage, result: result}
    )
  end

  defp maybe_apply(module, function, args, fallback \\ :ok) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      fallback
    end
  end
end
