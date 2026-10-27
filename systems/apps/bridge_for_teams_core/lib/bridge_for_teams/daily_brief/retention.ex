defmodule BridgeForTeams.DailyBrief.Retention do
  @moduledoc """
  Scheduled retention for daily brief storage.

  `BridgeForTeams.DailyBrief.prune_expired/1` is the pruning boundary. Each pass
  deletes bounded batches until a batch comes back short, then waits for the
  next interval. Row locks with `SKIP LOCKED` let every Pod run it.
  """
  use SystemsRuntime.Server

  require Logger

  alias BridgeForTeams.DailyBrief

  @default_interval_ms 3_600_000
  @max_batches_per_pass 20

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one pass of bounded batches. Returns the deleted counts."
  @spec run_once(keyword()) :: {:ok, %{atom() => non_neg_integer()}}
  def run_once(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    zero = %{runs: 0}

    Enum.reduce_while(1..@max_batches_per_pass, {:ok, zero}, fn _batch, {:ok, acc} ->
      {:ok, counts} = DailyBrief.prune_expired(Keyword.put(opts, :limit, limit))
      acc = Map.merge(acc, counts, fn _key, total, count -> total + count end)

      if Enum.all?(Map.values(counts), &(&1 < limit)),
        do: {:halt, {:ok, acc}},
        else: {:cont, {:ok, acc}}
    end)
  end

  @impl true
  def init(opts) do
    cfg = SystemsRuntime.get_env(:bridge_for_teams_core, __MODULE__, [])

    interval =
      Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @default_interval_ms))

    schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:prune, state) do
    try do
      run_once()
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.daily_brief.retention.failed #{Exception.message(exception)}"
        )
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  # Stray messages (a late reply, a test double's note) are not work.
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :prune, interval_ms)
end
