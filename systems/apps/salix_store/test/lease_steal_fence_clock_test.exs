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
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SalixStore.{Agent, S3, Keys}
  alias SalixStore.Agent.Owned

  @sm SalixStore.TestSM

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: "agent-#{System.unique_integer([:positive])}"}
  end

  defp uid, do: "agent-#{System.unique_integer([:positive])}"

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
        Task.async(fn -> {node, Agent.claim(a, node, @sm, now: now, ttl_ms: ttl)} end)
      end

    results = Task.await_many(tasks, 5_000)

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
  # Scenario C — LIVENESS: held_by before expiry, stealable at/after expiry
  # =====================================================================
  # This is the clock-DEPENDENT half (liveness, not safety). We sweep `now`
  # across the lease boundary and assert the gate flips exactly at lease_until.
  property "steal-eligibility flips precisely at lease_until (boundary inclusive)", %{agent: _} do
    check all(
            t0 <- integer(0..1_000_000_000),
            ttl <- integer(1_000..600_000),
            # offsets that straddle the boundary; -ttl..-1 = before, 0.. = at/after
            offset <- integer(-ttl..(2 * ttl))
          ) do
      a = uid()
      {:ok, _o} = Agent.create(a, "owner", @sm, now: t0, ttl_ms: ttl)
      lease_until = t0 + ttl
      probe = t0 + ttl + offset

      result = Agent.claim(a, "thief", @sm, now: probe, ttl_ms: ttl)

      cond do
        probe < lease_until ->
          # Before expiry: not stealable; the truthful owner/lease is reported.
          assert {:error, {:held_by, "owner", ^lease_until}} = result

        true ->
          # At or after expiry (lease_until <= now): stealable, epoch bumps to 2.
          assert {:ok, %Owned{epoch: 2, node_id: "thief"}} = result
      end
    end
  end

  # =====================================================================
  # Scenario D — release clears the lease index; renew extends without epoch bump
  # =====================================================================
  test "renew extends lease_until without bumping epoch; release clears the index", %{agent: a} do
    t0 = 3_000_000
    ttl = 60_000
    {:ok, o} = Agent.create(a, "node-1", @sm, now: t0, ttl_ms: ttl)
    assert o.head.lease_until == t0 + ttl
    assert o.epoch == 1

    # The live-lease index exists after create.
    assert {:ok, _} = S3.head(Keys.lease("node-1", a))

    # renew: pure CAS, extends lease_until to now + ttl, epoch unchanged.
    {:ok, o} = Agent.renew(o, now: t0 + 30_000)
    assert o.head.lease_until == t0 + 30_000 + ttl
    assert o.epoch == 1
    assert live_head(a).lease_until == t0 + 30_000 + ttl
    assert live_head(a).epoch == 1

    # renew is fenceable too: if someone steals, our renew must fail (not silently
    # resurrect a dead lease). Steal from another node, then try to renew the old
    # handle.
    {:ok, _thief} = Agent.claim(a, "node-2", @sm, steal: true)
    assert {:error, :fenced} = Agent.renew(o, now: t0 + 40_000)

    # release with a fenced handle is a safe no-op (head CAS 412 → :ok), and it
    # must NOT delete the new owner's records — but it WILL try to delete its own
    # node's lease key. Verify node-2 stays the owner.
    assert :ok = Agent.release(o)
    assert live_head(a).owner_node == "node-2"

    # Now exercise a clean release by the live owner: clears owner + lease index.
    {:ok, owner2} = Agent.claim(a, "node-2", @sm, now: t0 + 50_000)
    assert :ok = Agent.release(owner2)
    head = live_head(a)
    assert head.owner_node == nil
    assert head.lease_until == nil
    assert {:error, :not_found} = S3.head(Keys.lease("node-2", a))

    # A released agent is freely claimable by anyone (owner_node == nil path),
    # no steal flag needed, regardless of clock.
    assert {:ok, %Owned{node_id: "node-3"}} =
             Agent.claim(a, "node-3", @sm, now: t0 + 1)
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

  # =====================================================================
  # Scenario F — work admission closes before the steal boundary
  # =====================================================================
  test "work-owner verification rejects the guard window even while identity still matches", %{
    agent: a
  } do
    t0 = 5_000_000
    ttl = 60_000
    guard_ms = 5_000
    {:ok, owner} = Agent.create(a, "node-1", @sm, now: t0, ttl_ms: ttl)

    assert :ok =
             Agent.verify_work_owner(owner,
               now: t0 + ttl - guard_ms - 1,
               guard_ms: guard_ms
             )

    assert {:error, :lease_expiring} =
             Agent.verify_work_owner(owner,
               now: t0 + ttl - guard_ms,
               guard_ms: guard_ms
             )

    # This is not fencing: the same handle remains the live owner and can
    # release cleanly. It is specifically a fail-closed decision not to start
    # another bounded work unit near expiry.
    assert live_head(a).owner_node == "node-1"
    assert :ok = Agent.release(owner)
  end
end
