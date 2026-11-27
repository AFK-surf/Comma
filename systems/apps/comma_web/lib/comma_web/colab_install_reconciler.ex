defmodule CommaWeb.ColabInstallReconciler do
  @moduledoc """
  Periodic and startup reconciler for unsynced Google Colab group install states
  (`colab_group_install_states` where `plugin_synced_generation < generation`).

  Runs an immediate bounded startup sweep on boot and then every 30s via
  `SystemsClock`, converging up to 16 unsynced groups per pass without requiring
  a user session or a detail page visit.

  Rows are read from the head of `(updated_at, tenant_id, group_id)` on each pass.
  Every row skipped (no Comma workspace, other tenant) or failing reconciliation is
  deferred to the back of the queue (`updated_at = GREATEST(updated_at + 1s, now)`),
  so neither unprocessable rows nor late-committed rows with older timestamps can
  ever be starved across ticks.
  """

  use SystemsRuntime.Server

  require Logger

  alias Comma.Workspaces
  alias CommaWeb.PluginConnections
  alias SalixAgent.Colab.Account

  @sweep_interval_ms 30_000
  @batch_limit 16

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @sweep_interval_ms),
      limit: Keyword.get(opts, :limit, @batch_limit)
    }

    {:ok, state, {:continue, :startup_sweep}}
  end

  @impl true
  def handle_continue(:startup_sweep, state) do
    _ = safe_sweep_once(state.limit)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = safe_sweep_once(state.limit)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(interval_ms) do
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, interval_ms)
  end

  @doc """
  Run one bounded reconciliation pass for up to `limit` unsynced Colab groups
  starting from the oldest `(updated_at, tenant_id, group_id)` head.
  """
  @spec sweep_once(pos_integer(), keyword()) :: {:ok, [term()]} | {:error, term()}
  def sweep_once(limit \\ @batch_limit, opts \\ [])
      when is_integer(limit) and limit > 0 and is_list(opts) do
    case Account.list_unsynced_group_install_states(limit, opts) do
      {:ok, states} when is_list(states) ->
        outcomes = Enum.map(states, &reconcile_and_defer/1)
        {:ok, outcomes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_sweep_once(limit) do
    sweep_once(limit)
  rescue
    error ->
      Logger.warning("colab_install_reconciler_sweep_failed: #{Exception.message(error)}")
      {:error, :sweep_failed}
  end

  defp reconcile_and_defer(state) do
    outcome = reconcile_state(state)

    # The defer is fenced on the row still being unsynced at this generation, so it
    # is a no-op for a row that this pass (or a concurrent writer) already moved on.
    case outcome do
      {:ok, _group_id, {:reconciled, _generation, _desired_state}} ->
        outcome

      _skipped_failed_or_unchanged ->
        defer(state)
        outcome
    end
  end

  defp defer(%{tenant_id: tenant_id, group_id: group_id, generation: generation}) do
    case Account.defer_unsynced_group_install_state(tenant_id, group_id, generation) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "colab_install_reconciler_defer_failed group_id=#{group_id} reason=#{inspect(reason)}"
        )
    end
  end

  defp defer(_state), do: :ok

  defp reconcile_state(%{tenant_id: tenant_id, group_id: group_id}) do
    case Workspaces.get_by_group(group_id) do
      {:ok, %{"salix_tenant_id" => ^tenant_id} = workspace} ->
        case PluginConnections.reconcile_workspace_colab_state_system(workspace) do
          {:ok, outcome} ->
            {:ok, group_id, outcome}

          {:error, reason} ->
            Logger.warning(
              "colab_install_reconciler_group_failed group_id=#{group_id} reason=#{inspect(reason)}"
            )

            {:error, group_id, reason}
        end

      {:ok, _other_tenant_workspace} ->
        {:skipped, group_id}

      {:error, :not_found} ->
        {:skipped, group_id}
    end
  end

  defp reconcile_state(_state), do: :skipped
end
