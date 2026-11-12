defmodule Comma.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    started_at = SystemsClock.monotonic_time()
    enabled = Comma.enabled_subsystems()
    validate!(enabled)
    :ok = Comma.PodLifecycle.boot(enabled)

    Logger.info("comma: starting subsystems #{inspect(enabled)}")

    # Peers connect while the rest of the node still starts; their placement
    # rings take it in only once `join_ring/1` says it is ready.
    SystemsRuntime.put_env(:salix_cluster, :placement_ready, false)

    # :permanent, not the default :temporary: these apps (and their dep apps,
    # e.g. :postgrex) are in :load mode in the release, so the type given here
    # is the only thing deciding what happens when one of them terminates.
    # Temporary apps die silently — a crashed :postgrex left the node running
    # but unable to authenticate to the DB (SCRAM cache noproc) until the pod
    # was restarted by hand. Permanent apps take the node down so the
    # orchestrator restarts it cleanly.
    for subsystem <- enabled, app <- Comma.apps(subsystem) do
      {elapsed_us, result} =
        :timer.tc(fn -> Application.ensure_all_started(app, type: :permanent) end)

      case result do
        {:ok, _started} ->
          Logger.info("comma: started #{app} in #{div(elapsed_us, 1000)}ms")

        {:error, reason} ->
          raise "comma: failed to start #{app} (subsystem #{subsystem}): #{inspect(reason)}"
      end
    end

    join_ring(enabled)
    emit_startup(started_at)

    # The launcher owns no children of its own; the subsystems run under their
    # own application supervision trees. A trivial supervisor satisfies the
    # Application start contract.
    SystemsRuntime.Supervisor.start_link([], strategy: :one_for_one, name: Comma.Supervisor)
  end

  # Every application of the node is up: peers may now place keys here. The
  # launcher has no compile-time dependency on the subsystem apps (mix.exs).
  defp join_ring(enabled) do
    SystemsRuntime.put_env(:salix_cluster, :placement_ready, true)
    if :salix in enabled, do: :ok = apply(SalixCluster.Ring, :ready, [])
    :ok
  end

  defp emit_startup(started_at) do
    SystemsRuntime.Telemetry.execute(
      [:comma_system, :startup, :stop],
      %{duration: SystemsClock.monotonic_time() - started_at},
      %{}
    )
  end

  defp validate!(enabled) do
    case enabled -- Comma.known_subsystems() do
      [] ->
        :ok

      unknown ->
        raise "comma: unknown subsystem(s) #{inspect(unknown)} " <>
                "(COMMA_SUBSYSTEMS); known: #{inspect(Comma.known_subsystems())}"
    end
  end
end
