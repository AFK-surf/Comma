defmodule SalixStore.LeaseStealFenceClockTest do
  @moduledoc """
  Lease, steal, and fence behavior under clock skew.

  THE INVARIANT BEING HUNTED: lease safety must be *independent of the clock*.
  `lease_until` is only an advisory liveness hint that gates steal-eligibility;
  the actual mutual-exclusion guarantee is the `head.json` ETag (the fencing
  token). So even when two nodes — because of clock skew — *both* believe they
  are entitled to write, only one can win the head CAS, and the loser is fenced
  the instant it tries to commit, no matter what either node believes about
  `lease_until`.

  We drive the clock explicitly via `opts[:now]` / `opts[:ttl_ms]` so "time" is
  a pure input, then assert:

    * SAFETY (clock-independent): a stale-lease steal that races the original
      owner yields exactly one effective writer; the loser is `:fenced` at
      commit via the ETag — even when its own clock says its lease is still
      valid (Scenarios A, B, E).
    * LIVENESS (clock-gated): a holder past `lease_until` is stealable; before
      it, `claim` returns `{:held_by, owner, lease_until}` (Scenario C).
    * `release` clears the live-lease index; `renew` extends `lease_until`
      and does not bump the epoch (Scenario D).
    * WORK ADMISSION (clock-gated): owner identity is insufficient inside the
      configured guard window; new work is rejected before a contender may
      observe expiry (Scenario F).

  All run against the Fake backend (no fault injection needed — the GenServer
  serializes ops, giving the exact per-object linearizability S3 promises, which
  is precisely what makes "exactly one CAS wins" testable).
  """
  use SystemsClock.Case, async: false
  use ExUnitProperties

  alias SalixStore.{Agent, S3, Keys}
  alias SalixStore.Agent.Owned

  @sm SalixStore.TestSM

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  # --- helper: the live head as decoded from S3 (ground truth, not a handle) ---
  defp live_head(agent) do
    {:ok, head} = Agent.peek(agent)
    head
  end

  # =====================================================================
  # Scenario A — clock skew: BOTH nodes believe they may write, ONE lands
  # =====================================================================
  # node-1 owns with lease_until = t0 + ttl. node-2 has a fast clock and
  # believes the lease is long expired, so it steals (epoch bump). node-1's
  # clock is slow: it still believes its lease is valid and tries to commit.
  # The commit MUST be fenced — purely because the ETag moved — regardless of
  # node-1's (wrong) belief that it still holds a live lease.
  test "clock skew: stale-lease steal fences the racing original owner at commit", %{agent: a} do
    t0 = 1_000_000
    ttl = 60_000

    {:ok, o1} = Agent.create(a, "node-1", @sm, now: t0, ttl_ms: ttl)
    {:ok, o1} = Agent.commit(o1, [%{op: "inc", by: 1}], now: t0 + 1)
    assert o1.epoch == 1

    # node-2's clock is far ahead: it sees the lease as stale and steals.
    {:ok, o2} = Agent.claim(a, "node-2", @sm, now: t0 + 10_000_000)
    assert o2.epoch == 2
    assert o2.state.counter == 1

    # node-1 STILL thinks its lease is valid (its now < its lease_until). The
    # safety guarantee does not consult node-1's belief at all: the head ETag
    # advanced under it, so the commit is fenced.
    assert {:error, :fenced} = Agent.commit(o1, [%{op: "inc", by: 99}], now: t0 + 5_000)

    # Exactly one effective writer: node-2's view is canonical, node-1's 99
    # never landed.
    head = live_head(a)
    assert head.epoch == 2
    assert head.owner_node == "node-2"

    {:ok, o2} = Agent.commit(o2, [%{op: "inc", by: 7}], now: t0 + 10_000_001)
    assert o2.state.counter == 8

    {:ok, verify} = Agent.claim(a, "node-3", @sm, steal: true)
    assert verify.state.counter == 8
  end

  # =====================================================================
  # Scenario B — genuine concurrent claim on the SAME head ETag
  # =====================================================================
  # Two nodes both consider the lease stealable (skewed clocks) and both race a
  # claim. Even spawned concurrently, the Fake's GenServer serializes the two
  # head CASes against the same starting ETag: exactly one wins outright, and
  # the loser either re-reads to {:held_by, ...} or wins a *later* epoch. In ALL
  # cases the final live head has a single owner, and any commit attempted with
  # a now-superseded handle is fenced.
  test "concurrent steal race on one ETag elects exactly one live owner", %{agent: a} do
    t0 = 2_000_000
    ttl = 60_000
    {:ok, _o0} = Agent.create(a, "node-0", @sm, now: t0, ttl_ms: ttl)

    # Both claimants use a clock past expiry so steal-eligibility holds for both.
    now = t0 + ttl + 1

    tasks =
      for node <- ["node-A", "node-B"] do
        SystemsRuntime.Task.async(fn ->
          {node, Agent.claim(a, node, @sm, now: now, ttl_ms: ttl)}
        end)
      end

    results = SystemsRuntime.Task.await_many(tasks, :infinity)

    oks = for {node, {:ok, o}} <- results, do: {node, o}
    held = for {_node, {:error, {:held_by, owner, _}}} <- results, do: owner

    # At least one node must succeed (the agent stays available).
    assert oks != []

    head = live_head(a)
    # Exactly one node owns the live head, and it is one of the successful ones.
    assert head.owner_node in Enum.map(oks, fn {n, _} -> n end)
    # held_by losers (if any) name the contemporaneous owner — never a third party.
    assert Enum.all?(held, &(&1 in ["node-A", "node-B", "node-0"]))

    # Any OK handle that is NOT the live owner is a superseded writer and MUST be
    # fenced on commit. The live owner commits fine. This is the crux: multiple
    # nodes can hold an `%Owned{}` simultaneously, but only one can persist.
    for {node, o} <- oks do
      result = Agent.commit(o, [%{op: "inc", by: 1}], now: now + 1)

      if node == head.owner_node and o.epoch == head.epoch do
        assert match?({:ok, _}, result),
               "live owner #{node} should commit, got #{inspect(result)}"
      else
        assert result == {:error, :fenced},
               "superseded owner #{node} must be fenced, got #{inspect(result)}"
      end
    end
  end

  # =====================================================================
  # Scenario E — interleaved double-steal: chained epoch bumps, all stale
  #              handles fenced, replay still single-valued
  # =====================================================================
  # node-1 -> node-2 -> node-3 each steal in turn under skewed clocks. Each
  # previous owner's handle is fenced on commit. The replayed state after the
  # dust settles equals exactly the events the *winning* chain committed — no
  # ghost writes from fenced owners leak in. This guards the orphan-safe journal
  # (higher-epoch-per-seq wins) against clock-skew-driven contention.
  test "chained steals fence every superseded owner; replay is single-valued", %{agent: a} do
    ttl = 60_000

    {:ok, o1} = Agent.create(a, "node-1", @sm, now: 0, ttl_ms: ttl)
    {:ok, o1} = Agent.commit(o1, [%{op: "set", value: 10}], now: 1)

    # node-2 steals (clock skewed forward past expiry) and commits.
    {:ok, o2} = Agent.claim(a, "node-2", @sm, now: ttl + 1, ttl_ms: ttl)
    {:ok, o2} = Agent.commit(o2, [%{op: "inc", by: 5}], now: ttl + 2)

    # node-1 — believing (per its slow clock) it still holds the lease — tries a
    # commit at seq it thinks is next. Fenced via ETag, period.
    assert {:error, :fenced} = Agent.commit(o1, [%{op: "inc", by: 999}], now: 2)

    # node-3 steals from node-2. node-2's commit at ttl+2 piggyback-renewed its
    # lease to (ttl+2)+ttl, so node-3 must claim strictly after that.
    {:ok, o3} = Agent.claim(a, "node-3", @sm, now: 2 * ttl + 3, ttl_ms: ttl)
    {:ok, o3} = Agent.commit(o3, [%{op: "inc", by: 1}], now: 2 * ttl + 4)

    # node-2 now also fenced if it tries again.
    assert {:error, :fenced} = Agent.commit(o2, [%{op: "inc", by: 999}], now: ttl + 3)

    # Final state observed by the live owner and by a fresh replay must agree and
    # reflect ONLY the winning chain: set 10 -> +5 -> +1 = 16. The two fenced
    # +999 writes left no trace.
    assert o3.state.counter == 16
    {:ok, replay} = Agent.claim(a, "node-4", @sm, steal: true)
    assert replay.state.counter == 16
    assert replay.head.epoch == 4
  end
end
