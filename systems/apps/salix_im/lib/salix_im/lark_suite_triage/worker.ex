defmodule SalixIM.LarkSuiteTriage.Worker do
  @moduledoc """
  Claims the Feishu and Lark triage batches whose debounce window closed and
  processes them (`SalixIM.LarkSuiteTriage.process_batch/2`).

  One timer per node, every #{2_000} ms. Each tick claims at most
  #{8} batches (`FOR UPDATE SKIP LOCKED`, so nodes never take the same
  batch) and processes them with bounded concurrency; a batch whose claim
  lapsed (a node stopped mid-batch) is claimed again after its lease.
  The work per tick is bounded by the claim limit, not by the number of
  watched chats. Tests call `process_once/1`.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.LarkSuiteTriage
  alias SalixStore.LarkSuiteTriage, as: Store

  @interval_ms 2_000
  @claim_limit 8
  @concurrency 4
  @batch_timeout_ms 90_000

  def start_link(opts \\ []),
    do:
      SystemsRuntime.Server.start_link(__MODULE__, opts,
        name: Keyword.get(opts, :name, __MODULE__)
      )

  @impl true
  def init(opts), do: {:ok, %{opts: opts, timer: schedule()}}

  @impl true
  def handle_info(:tick, state) do
    _ = process_once(state.opts)
    {:noreply, %{state | timer: schedule()}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule, do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, @interval_ms)

  @doc """
  Claims and processes one round of due batches. Returns the settled batch
  ids with their outcome states. `opts` pass to `process_batch/2`, plus
  `:holder` and `:now`.
  """
  @spec process_once(keyword()) :: [{String.t(), String.t()}]
  def process_once(opts \\ []) do
    holder = Keyword.get_lazy(opts, :holder, fn -> "lark-triage:" <> to_string(node()) end)
    store_opts = Keyword.take(opts, [:now])

    case Store.claim_due_batches(holder, @claim_limit, store_opts) do
      {:ok, []} ->
        []

      {:ok, batches} ->
        batches
        |> SystemsClock.async_stream(&settle(&1, holder, opts, store_opts),
          max_concurrency: @concurrency,
          timeout: @batch_timeout_ms,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.flat_map(fn
          {:ok, settled} -> [settled]
          {:exit, _reason} -> []
        end)

      {:error, reason} ->
        Logger.warning("lark_suite_triage_claim_failed reason=#{inspect(reason)}")
        []
    end
  end

  defp settle(batch, holder, opts, store_opts) do
    outcome = LarkSuiteTriage.process_batch(batch, opts)

    case Store.complete_batch(batch.id, holder, outcome, store_opts) do
      :ok ->
        {batch.id, outcome.state}

      {:error, reason} ->
        Logger.warning("lark_suite_triage_complete_failed reason=#{inspect(reason)}")
        {batch.id, "unsettled"}
    end
  end
end
