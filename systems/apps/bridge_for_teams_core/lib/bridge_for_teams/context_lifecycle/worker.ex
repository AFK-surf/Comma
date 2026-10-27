defmodule BridgeForTeams.ContextLifecycle.Worker do
  @moduledoc """
  Drains due Context Lifecycle requests.

  Each pass reads a bounded batch of requests that are pending, past their
  retry time, or whose processing lease expired, then claims and runs each one
  through `ContextLifecycle.claim/2` and `run_claim/2`. Claims are fenced by
  the lifecycle owner, so every Pod may run this worker.
  """
  use SystemsRuntime.Server

  require Logger

  import Ecto.Query

  alias BridgeForTeams.{ContextLifecycle, Repo}
  alias BridgeForTeams.Schema.ContextLifecycleRequest

  @default_interval_ms 30_000
  @default_batch 10

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Claims and runs one bounded batch of due requests."
  @spec run_once(keyword()) :: {:ok, %{ran: non_neg_integer(), errors: non_neg_integer()}}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    worker_id = Keyword.get(opts, :worker_id, "context-lifecycle:#{node()}")

    due =
      Repo.all(
        from(r in ContextLifecycleRequest,
          where:
            r.state == "pending" or
              (r.state == "retry_wait" and r.retry_not_before <= ^now) or
              (r.state == "processing" and r.lease_expires_at <= ^now),
          order_by: [asc: r.created_at, asc: r.id],
          limit: ^Keyword.get(opts, :batch, @default_batch),
          select: r.id
        )
      )

    {:ok,
     Enum.reduce(due, %{ran: 0, errors: 0}, fn id, acc ->
       with {:ok, claim} <- ContextLifecycle.claim(id, worker_id),
            {:ok, _result} <- ContextLifecycle.run_claim(claim) do
         %{acc | ran: acc.ran + 1}
       else
         other ->
           Logger.warning(
             "bridge_for_teams.context_lifecycle.worker.request_not_run request_id=#{id} reason=#{reason(other)}"
           )

           %{acc | errors: acc.errors + 1}
       end
     end)}
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
  def handle_info(:drain, state) do
    try do
      run_once()
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.context_lifecycle.worker.failed #{Exception.message(exception)}"
        )
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  # Stray messages (a late reply, a test double's note) are not work.
  def handle_info(_message, state), do: {:noreply, state}

  defp reason({:error, reason}) when is_atom(reason), do: reason
  defp reason({:error, {reason, _detail}}) when is_atom(reason), do: reason
  defp reason(_other), do: :unexpected

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :drain, interval_ms)
end
