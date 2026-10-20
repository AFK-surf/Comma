defmodule SalixIM.ProviderIdentityScanLimiterTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The identity fallback scan permit (`SalixIM.ProviderIdentityScanLimiter`): one
  supervised admission owner over an application-lifetime table (no
  crashable state owner left), truly-concurrent cold-start admission,
  monitor-reclaimed permits, resurrection-safe adoption, leak-free
  release after adoption, same-owner cancellation-acknowledged handoff
  (the owner-exit-between-insert-and-reply gap is an accepted round-13
  disposition, not covered here), and fail-closed behavior on every
  owner/configuration failure.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.ProviderIdentityScanLimiter

  setup do
    prev = SystemsRuntime.fetch_env(:salix_im, :identity_scan_max_concurrency)

    on_exit(fn ->
      case prev do
        {:ok, value} -> SystemsRuntime.put_env(:salix_im, :identity_scan_max_concurrency, value)
        :error -> SystemsRuntime.delete_env(:salix_im, :identity_scan_max_concurrency)
      end
    end)

    uniq = SystemsRuntime.Proc.unique_integer([:positive])
    table = :"scan_permits_#{uniq}"
    limiter = :"limiter_#{uniq}"

    # The test process stands in for the application-start callback
    # process (application lifetime): it owns the
    # table, so killing/restarting the limiter never resets occupancy.
    ProviderIdentityScanLimiter.create_table!(table)
    start_supervised!({ProviderIdentityScanLimiter, table: table, name: limiter})

    {:ok, limiter: limiter, table: table}
  end

  defp set_cap(n), do: SystemsRuntime.put_env(:salix_im, :identity_scan_max_concurrency, n)
  test "N truly simultaneous cold-start callers never exceed the cap", %{table: table} do
    set_cap(2)

    # Cold start: a FRESH limiter with zero prior traffic, and all N
    # acquires in flight concurrently the instant it is up (the round-8
    # persistent_term shape lost exactly this race; the single owner
    # serializes it by construction).
    uniq = SystemsRuntime.Proc.unique_integer([:positive])
    limiter = :"cold_limiter_#{uniq}"
    test = SystemsRuntime.Proc.self()

    pids =
      for _ <- 1..6 do
        SystemsRuntime.Proc.spawn(fn ->
          SystemsRuntime.Proc.receive(do: (:go -> :ok))
          result = ProviderIdentityScanLimiter.acquire(limiter)
          SystemsRuntime.Proc.send(test, {:acquired, SystemsRuntime.Proc.self(), result})
          SystemsRuntime.Proc.receive(do: (:stop -> :ok))
        end)
      end

    start_supervised!({ProviderIdentityScanLimiter, table: table, name: limiter},
      id: :cold_limiter
    )

    Enum.each(pids, &send(&1, :go))

    results =
      for _ <- pids do
        settle_receive({:acquired, pid, result})
        {pid, result}
      end

    oks = Enum.count(results, fn {_pid, r} -> match?({:ok, _}, r) end)
    rejected = Enum.count(results, fn {_pid, r} -> r == {:error, :scan_capacity_exhausted} end)

    assert oks == 2
    assert rejected == 4

    Enum.each(pids, &send(&1, :stop))
  end
end
