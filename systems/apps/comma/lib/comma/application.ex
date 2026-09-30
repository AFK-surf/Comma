defmodule Comma.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    started_at = System.monotonic_time()
    enabled = Comma.enabled_subsystems()
    validate!(enabled)
    :ok = Comma.PodLifecycle.boot(enabled)

    Logger.info("comma: starting subsystems #{inspect(enabled)}")

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

    emit_startup(started_at)

    # The launcher owns no children of its own; the subsystems run under their
    # own application supervision trees. A trivial supervisor satisfies the
    # Application start contract.
    Supervisor.start_link([], strategy: :one_for_one, name: Comma.Supervisor)
  end

  defp emit_startup(started_at) do
    :telemetry.execute(
      [:comma_system, :startup, :stop],
      %{duration: System.monotonic_time() - started_at},
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
