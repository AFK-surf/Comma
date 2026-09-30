defmodule SalixStore.Convergence.Worker do
  @moduledoc """
  Generic periodic driver for a `SalixStore.Convergence` implementation.

  Runs a convergence attempt shortly after boot and keeps reconciling on the
  implementation's interval — derived data must keep healing drift, so the
  worker never treats convergence as finished. Each `ensure` is
  page-bounded: `{:ok, :partial}` reschedules soon to continue the same
  cursor-persisted pass.

  Cadence is FIXED-DELAY from the persisted completion anchor
  (`completed_at`, sampled at logical pass completion — see
  `SalixStore.Convergence`): after a completed pass the worker reschedules
  via `Convergence.next_due_in/2` (completion I/O counts toward the
  interval, so slow persistence shortens the wait); after a restart it
  aligns to the same marker via `{:ok, :fresh, remaining_ms}`. When the
  anchor is successfully read, both paths derive the same BASE delay from
  the same persisted value; they deliberately diverge when it cannot be
  read (full-interval degradation here, the retry path on a failed boot
  ensure) and in which jitter budget applies (steady vs boot).

  Every delay is jittered so a fleet of nodes spreads its passes: the boot
  attempt (a rolling deploy starts many pods together), the failure retry
  (a shared S3 fault would otherwise re-align the fleet), the partial
  continuation, and the steady reconcile interval.

      children = [
        {SalixStore.Convergence.Worker, impl: MyApp.SomethingConvergence}
      ]
  """

  use GenServer

  require Logger

  alias SalixStore.Convergence

  @retry_ms 60_000
  @boot_jitter_ms 10_000
  @partial_delay_ms 1_000
  @jitter_ms 600_000

  def start_link(opts) do
    impl = Keyword.fetch!(opts, :impl)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, impl))
  end

  def child_spec(opts) do
    impl = Keyword.fetch!(opts, :impl)
    %{id: {__MODULE__, impl}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(opts) do
    impl = Keyword.fetch!(opts, :impl)

    state = %{
      impl: impl,
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      reconcile_ms: Keyword.get(opts, :reconcile_ms, Convergence.impl_reconcile_ms(impl)),
      jitter_ms: Keyword.get(opts, :jitter_ms, @jitter_ms),
      boot_jitter_ms: Keyword.get(opts, :boot_jitter_ms, @boot_jitter_ms),
      partial_delay_ms: Keyword.get(opts, :partial_delay_ms, @partial_delay_ms)
    }

    Process.send_after(self(), :ensure, jitter(state.boot_jitter_ms))
    {:ok, state}
  end

  @impl true
  def handle_info(:ensure, state), do: ensure(state)

  defp ensure(state) do
    delay =
      case Convergence.ensure(state.impl, reconcile_ms: state.reconcile_ms) do
        # A completed pass reschedules from the PERSISTED anchor, not from
        # "now": completed_at is sampled before the completion writes are
        # settled, so slow completion persistence must shorten the wait —
        # exactly what a Worker restarted at this same marker would do.
        {:ok, :complete} ->
          min(
            Convergence.next_due_in(state.impl, state.reconcile_ms),
            state.reconcile_ms
          ) + jitter(state.jitter_ms)

        # The durable marker is still fresh (typical right after a restart):
        # schedule against its REMAINING deadline, not a whole new interval
        # — restarts must not stretch the implementation's cadence, and
        # repeated restarts must not defer it indefinitely.
        {:ok, :fresh, remaining_ms} ->
          min(remaining_ms, state.reconcile_ms) + jitter(state.jitter_ms)

        {:ok, :partial} ->
          state.partial_delay_ms + jitter(state.partial_delay_ms)

        {:error, reason} ->
          Logger.warning("convergence #{state.impl.name()} attempt failed: #{inspect(reason)}")

          state.retry_ms + jitter(state.retry_ms)
      end

    Process.send_after(self(), :ensure, delay)
    {:noreply, state}
  end

  defp jitter(max_ms) when max_ms <= 0, do: 0
  defp jitter(max_ms), do: :rand.uniform(max_ms)
end
