defmodule BridgeForTeams.DailyBrief.DeliveryWorker do
  @moduledoc """
  Sends due briefs. Each tick claims at most `batch` due members and sends
  their briefs one at a time, so the per-Pod load per tick is bounded whatever
  the number of members; then it posts the team briefs that are due.
  """
  use SystemsRuntime.Server

  require Logger

  alias BridgeForTeams.DailyBrief.Delivery

  @default_interval_ms 60_000
  @default_batch 2

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run_once(keyword()) :: {:ok, non_neg_integer()}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    due = Delivery.claim_due(now, Keyword.get(opts, :batch, @default_batch))

    # One member's failure must not cost the rest of the batch their brief.
    Enum.each(due, fn {settings, member} ->
      try do
        Delivery.deliver(settings, member, Keyword.put(opts, :now, now))
      rescue
        exception ->
          Logger.error(
            "bridge_for_teams.daily_brief.delivery.crashed #{Exception.message(exception)}"
          )

          Delivery.release_claim(settings, member, now)
      catch
        kind, reason ->
          Logger.error(
            "bridge_for_teams.daily_brief.delivery.exited #{kind} #{inspect(reason, limit: 5)}"
          )

          Delivery.release_claim(settings, member, now)
      end
    end)

    # Then the team briefs whose time has come.
    try do
      Delivery.post_team_briefs(now, opts)
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.daily_brief.team_brief.crashed #{Exception.message(exception)}"
        )
    end

    {:ok, length(due)}
  end

  @impl true
  def init(opts) do
    cfg = SystemsRuntime.get_env(:bridge_for_teams_core, __MODULE__, [])

    interval =
      Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @default_interval_ms))

    schedule(interval)
    # `:run_opts` are passed to each run (an injected model in tests).
    {:ok, %{interval_ms: interval, run_opts: Keyword.get(opts, :run_opts, [])}}
  end

  @impl true
  def handle_info(:deliver, state) do
    try do
      run_once(state.run_opts)
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.daily_brief.delivery_worker.failed #{Exception.message(exception)}"
        )
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  # Stray messages (a late reply, a test double's note) are not work.
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :deliver, interval_ms)
end
