defmodule SalixIM.ProviderIdentityScanLimiterTest do
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
  use ExUnit.Case, async: false

  alias SalixIM.ProviderIdentityScanLimiter

  setup do
    prev = Application.fetch_env(:salix_im, :identity_scan_max_concurrency)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:salix_im, :identity_scan_max_concurrency, value)
        :error -> Application.delete_env(:salix_im, :identity_scan_max_concurrency)
      end
    end)

    uniq = System.unique_integer([:positive])
    table = :"scan_permits_#{uniq}"
    limiter = :"limiter_#{uniq}"

    # The test process stands in for the application-start callback
    # process (application lifetime): it owns the
    # table, so killing/restarting the limiter never resets occupancy.
    ProviderIdentityScanLimiter.create_table!(table)
    start_supervised!({ProviderIdentityScanLimiter, table: table, name: limiter})

    {:ok, limiter: limiter, table: table}
  end

  defp set_cap(n), do: Application.put_env(:salix_im, :identity_scan_max_concurrency, n)

  # Acquire in a fresh process that holds the permit until told to stop;
  # returns {pid, result}.
  defp holder(limiter) do
    test = self()

    pid =
      spawn(fn ->
        result = ProviderIdentityScanLimiter.acquire(limiter)
        send(test, {:acquired, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:acquired, ^pid, result}, 1_000
    {pid, result}
  end

  @eventually_tries 200

  # The polled condition must survive the admission owner being ABSENT.
  # Several tests here kill it on purpose, and `count/1` is a
  # `GenServer.call` that EXITS on a dead or unregistered name rather than
  # returning a value — so a predicate built on it turns the very window
  # this loop exists to wait through into a hard failure, and surfaces it
  # as a bare `** (exit) exited in: GenServer.call(...)` with no hint that
  # a poll was in progress.
  #
  # Treating that exit as "not yet" is the whole point of a retry loop. A
  # genuinely absent owner still fails, just at the deadline and with the
  # last result named.
  defp eventually(fun, tries \\ @eventually_tries) do
    case probe(fun) do
      true ->
        :ok

      last when tries <= 0 ->
        flunk(
          "condition not reached after #{@eventually_tries} polls; last result: #{inspect(last)}"
        )

      _last ->
        Process.sleep(5)
        eventually(fun, tries - 1)
    end
  end

  defp probe(fun) do
    fun.()
  catch
    :exit, reason -> {:exit, reason}
  end

  # Has the owner been replaced? Decided from ONE observation, which the
  # caller passes in.
  #
  # This took the observation as a NAME and read the registry twice:
  # `is_pid(Process.whereis(l)) and Process.whereis(l) != old`. Those two
  # reads can disagree. If the name went away between them the first says
  # `is_pid` and the second returns `nil`, which is `!= old`, so the
  # conjunction reports "restarted" from two observations that were never
  # simultaneously true — and the caller proceeds against a name
  # registered to nobody, whose next `count/1` exits.
  #
  # Taking the pid as an argument is what makes that unrepresentable: the
  # single read is visible at the call site, and what is left here is a
  # total function over one observation.
  defp restarted?(nil, _old), do: false
  defp restarted?(current, old) when is_pid(current), do: current != old

  describe "the polling helpers themselves" do
    # These guard the harness, not the limiter. Both defects below made a
    # transient owner absence — which several tests below CREATE ON PURPOSE
    # — into a hard failure, so the suite was flaky in a way that pointed at
    # the limiter rather than at its own poll loop.

    test "the poll waits through an absent owner instead of exiting", %{table: table} do
      name = :"late_limiter_#{System.unique_integer([:positive])}"

      # Baseline, so this test cannot pass vacuously: the predicate really
      # does EXIT while the name is unregistered. `count/1` is a
      # GenServer.call, not a lookup.
      assert catch_exit(ProviderIdentityScanLimiter.count(name))

      starter =
        Task.async(fn ->
          Process.sleep(60)
          ProviderIdentityScanLimiter.start_link(table: table, name: name)
        end)

      # Polls straight through the window in which the predicate exits.
      assert eventually(fn -> ProviderIdentityScanLimiter.count(name) == 0 end) == :ok

      {:ok, pid} = Task.await(starter)
      :ok = GenServer.stop(pid)
    end

    test "a poll that never settles still fails, at the deadline" do
      # The tolerance above must not turn a permanently dead condition into
      # a pass. Two tries so the test is fast.
      assert_raise ExUnit.AssertionError, ~r/condition not reached after/, fn ->
        eventually(fn -> ProviderIdentityScanLimiter.count(:never_registered_limiter) == 0 end, 2)
      end
    end

    test "the restart guard is total over one observation", %{limiter: limiter} do
      running = Process.whereis(limiter)

      # An absent registration is NOT a restart — the case the old
      # two-read form could get wrong, and the reason this takes a pid
      # rather than a name.
      refute restarted?(nil, running)

      # The same owner still registered is not a restart either.
      refute restarted?(running, running)

      # A live registration that is not the pid we started from is.
      assert restarted?(running, spawn(fn -> :ok end))
    end
  end

  test "N truly simultaneous cold-start callers never exceed the cap", %{table: table} do
    set_cap(2)

    # Cold start: a FRESH limiter with zero prior traffic, and all N
    # acquires in flight concurrently the instant it is up (the round-8
    # persistent_term shape lost exactly this race; the single owner
    # serializes it by construction).
    uniq = System.unique_integer([:positive])
    limiter = :"cold_limiter_#{uniq}"
    test = self()

    pids =
      for _ <- 1..6 do
        spawn(fn ->
          receive do: (:go -> :ok)
          result = ProviderIdentityScanLimiter.acquire(limiter)
          send(test, {:acquired, self(), result})
          receive do: (:stop -> :ok)
        end)
      end

    start_supervised!({ProviderIdentityScanLimiter, table: table, name: limiter},
      id: :cold_limiter
    )

    Enum.each(pids, &send(&1, :go))

    results =
      for _ <- pids do
        assert_receive {:acquired, pid, result}, 2_000
        {pid, result}
      end

    oks = Enum.count(results, fn {_pid, r} -> match?({:ok, _}, r) end)
    rejected = Enum.count(results, fn {_pid, r} -> r == {:error, :scan_capacity_exhausted} end)

    assert oks == 2
    assert rejected == 4

    Enum.each(pids, &send(&1, :stop))
  end

  test "a killed holder's permit is reclaimed, not leaked", %{limiter: limiter} do
    set_cap(1)

    {pid, {:ok, _permit}} = holder(limiter)
    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}

    # Kill without releasing: try/after would not run in the real path.
    Process.exit(pid, :kill)

    eventually(fn -> ProviderIdentityScanLimiter.count(limiter) == 0 end)
    assert {:ok, _} = ProviderIdentityScanLimiter.acquire(limiter)
  end

  test "normal release frees exactly one slot and is idempotent", %{limiter: limiter} do
    set_cap(1)

    assert {:ok, permit} = ProviderIdentityScanLimiter.acquire(limiter)
    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}

    assert ProviderIdentityScanLimiter.release(limiter, permit) == :ok
    eventually(fn -> ProviderIdentityScanLimiter.count(limiter) == 0 end)

    # A second release must not drive the count negative / over-free.
    assert ProviderIdentityScanLimiter.release(limiter, permit) == :ok
    assert ProviderIdentityScanLimiter.count(limiter) == 0

    assert {:ok, _} = ProviderIdentityScanLimiter.acquire(limiter)
    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}
  end

  test "cap 0 rejects every acquire", %{limiter: limiter} do
    set_cap(0)
    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}
  end

  test "an absent owner fails CLOSED, never open" do
    set_cap(1_000_000)

    assert ProviderIdentityScanLimiter.acquire(:no_such_limiter_process) ==
             {:error, :scan_capacity_exhausted}
  end

  test "an invalid cap value fails CLOSED, never open via term ordering", %{limiter: limiter} do
    # Erlang term ordering makes `count < "1"` true for every count — the
    # round-10 witness admitted 5/5 permits. Non-integer caps must reject.
    set_cap("1")
    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}

    set_cap(-3)
    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}
  end

  test "an owner restart preserves occupancy — old + new scans never exceed the cap",
       %{limiter: limiter} do
    set_cap(1)

    {pid_a, {:ok, _permit}} = holder(limiter)

    # Crash the admission owner; the supervisor restarts it while the
    # holder's scan is still running. The application-lifetime table
    # survives, so the replacement adopts the permit.
    old = Process.whereis(limiter)
    Process.exit(old, :kill)
    eventually(fn -> restarted?(Process.whereis(limiter), old) end)

    assert ProviderIdentityScanLimiter.acquire(limiter) == {:error, :scan_capacity_exhausted}

    # The adopted permit is still monitor-tied: killing the holder frees it.
    Process.exit(pid_a, :kill)
    eventually(fn -> ProviderIdentityScanLimiter.count(limiter) == 0 end)
    assert {:ok, _} = ProviderIdentityScanLimiter.acquire(limiter)
  end

  test "a release while the owner is down is never resurrected by the next owner",
       %{table: table} do
    set_cap(1)

    uniq = System.unique_integer([:positive])
    limiter = :"manual_limiter_#{uniq}"
    {:ok, _pid} = ProviderIdentityScanLimiter.start_link(table: table, name: limiter)

    assert {:ok, permit} = ProviderIdentityScanLimiter.acquire(limiter)
    :ok = GenServer.stop(limiter)

    # The holder finishes while no owner is running: the row is deleted
    # directly; the cast goes nowhere.
    assert ProviderIdentityScanLimiter.release(limiter, permit) == :ok

    {:ok, _pid} = ProviderIdentityScanLimiter.start_link(table: table, name: limiter)
    assert ProviderIdentityScanLimiter.count(limiter) == 0
    assert {:ok, _} = ProviderIdentityScanLimiter.acquire(limiter)
    :ok = GenServer.stop(limiter)
  end

  test "a normal release after adoption drops the replacement monitor", %{
    limiter: limiter
  } do
    set_cap(1)

    {pid_a, {:ok, permit}} = holder(limiter)

    old = Process.whereis(limiter)
    Process.exit(old, :kill)
    eventually(fn -> restarted?(Process.whereis(limiter), old) end)
    new_owner = Process.whereis(limiter)

    # Give the replacement time to adopt, then release normally.
    eventually(fn -> ProviderIdentityScanLimiter.count(limiter) == 1 end)
    assert ProviderIdentityScanLimiter.release(limiter, permit) == :ok
    eventually(fn -> ProviderIdentityScanLimiter.count(limiter) == 0 end)

    # The adopted monitor must be dropped with the release — a leaked
    # monitor would fire a phantom :DOWN bookkeeping entry later.
    eventually(fn ->
      {:monitors, monitors} = Process.info(new_owner, :monitors)
      not Enum.any?(monitors, fn {:process, pid} -> pid == pid_a end)
    end)

    send(pid_a, :stop)
    assert {:ok, _} = ProviderIdentityScanLimiter.acquire(limiter)
  end

  test "same-owner: a rejected, still-live caller leaves occupancy at zero", %{limiter: limiter} do
    set_cap(1)

    :ok = :sys.suspend(Process.whereis(limiter))

    # The caller times out and is told "rejected" — its call stays
    # queued in the suspended owner, and its cancellation is queued
    # strictly behind it (message ordering).
    assert ProviderIdentityScanLimiter.acquire(limiter, 50) == {:error, :scan_capacity_exhausted}

    :ok = :sys.resume(Process.whereis(limiter))

    # On resume the owner grants the queued call (the reply goes
    # nowhere) and then processes the cancellation, which revokes the
    # undelivered lease. The caller (this test process) stays alive the
    # whole time — occupancy must still settle at zero without waiting
    # for any process exit.
    eventually(fn -> ProviderIdentityScanLimiter.count(limiter) == 0 end)
    assert {:ok, _} = ProviderIdentityScanLimiter.acquire(limiter)
  end
end
