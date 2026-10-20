defmodule CommaWeb.TelegramOIDC.ProviderOwner do
  require SystemsRuntime.Proc

  @moduledoc """
  Isolates Telegram provider failures from Comma Web's supervision restart budget.

  Owns one linked SDK worker or one delayed restart timer. The SDK stops on
  discovery/JWKS errors, so a fresh worker retries the complete loading sequence.
  This also avoids OIDCC 3.9's JWKS retry path skipping unchanged discovery.

  Lifecycle modeled in `tla/salix/CommaTelegramOIDCRecovery.tla`.
  """

  use SystemsRuntime.Server

  alias Oidcc.ProviderConfiguration.Worker

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.trap_exit(true)

    state = %{
      worker: nil,
      restart_timer: nil,
      restart_delay_ms: Map.get(opts, :restart_delay_ms, 5_000),
      restart_jitter_ms: Map.get(opts, :restart_jitter_ms, 5_000),
      worker_opts:
        opts
        |> Map.drop([:restart_delay_ms, :restart_jitter_ms])
        |> Map.put(:backoff_type, :stop)
    }

    {:ok, state, {:continue, :start_worker}}
  end

  @impl true
  def handle_continue(:start_worker, state) do
    case Worker.start_link(state.worker_opts) do
      {:ok, worker} -> {:noreply, %{state | worker: worker}}
      {:error, _reason} -> {:noreply, schedule_restart(state)}
    end
  end

  @impl true
  def handle_info({:EXIT, worker, _reason}, %{worker: worker} = state)
      when SystemsRuntime.Proc.is_process(worker) do
    {:noreply, schedule_restart(%{state | worker: nil})}
  end

  def handle_info({:timeout, timer, :restart_worker}, %{restart_timer: timer} = state) do
    {:noreply, %{state | restart_timer: nil}, {:continue, :start_worker}}
  end

  # A failed start_link can also leave its child's EXIT in the mailbox. It is
  # already represented by the pending restart; never create another timer.
  def handle_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.restart_timer, do: SystemsClock.cancel_timer(state.restart_timer)
    if state.worker, do: SystemsRuntime.Proc.exit(state.worker, :shutdown)
    :ok
  end

  defp schedule_restart(%{worker: nil, restart_timer: nil} = state) do
    delay = state.restart_delay_ms + SystemsRuntime.Proc.uniform(state.restart_jitter_ms + 1) - 1
    timer = SystemsClock.start_timer(delay, SystemsRuntime.Proc.self(), :restart_worker)
    emit_restart()
    %{state | restart_timer: timer}
  end

  defp emit_restart do
    CommaProduct.Telemetry.emit_operation(:telegram_oidc_restart, :unavailable, 0)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
