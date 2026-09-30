defmodule SalixStore.HeadCasLinearizabilityTest do
  @moduledoc """
  Adversarial Head-CAS linearizability coverage.

  The head.json ETag is the single commit point. Every former serializable
  transaction is realized as: write the journal segment create-once, then CAS
  the head with `if_match: etag`. If that CAS fails because the head moved, the
  writer is fenced and MUST make zero further effective writes.

  This module spawns many concurrent claimants + committers (`Task.async_stream`)
  against ONE agent and then audits the durable result. The invariants under
  test:

    1. **Distinct epoch per effective owner.** Each successful `claim/4` bumps
       `epoch` via head CAS; concurrent claimants can each win, but they win
       *different* epochs. No two owners share an epoch.

    2. **Fence is terminal.** Once a writer observes `:fenced` /
       `{:stale_etag, _}` / `:claim_exhausted`, it makes ZERO subsequent
       effective (`{:ok, _}`) commits. We enforce the "stop on first failure"
       discipline in the worker and then audit the recorded outcome stream.

    3. **Journal tail seq is strictly monotonic, gap-free, == #commits.**
       The winning lineage's `journal_tail.seq` advances by exactly 1 per
       committed head, so the final tail seq equals the total number of
       effective commits. No committed segment is skipped; none is double
       counted.

    4. **No orphan-then-reference.** A fenced writer may have create-once
       written a journal segment under its (now superseded) epoch, but replay
       resolves highest-epoch-per-seq and only follows the winning lineage. We
       verify by claiming fresh at the end: the replayed counter == sum of the
       `by` of EXACTLY the commits that returned `{:ok, _}`, and `ops` == the
       count of those commits. An orphan being referenced would inflate either.

  These run against the Fake backend (GenServer-serialized, giving the same
  per-object linearizable CAS as S3) so the interleavings are real concurrency
  without needing MinIO. The fault-injection scenario also needs the Fake.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SalixStore.{Agent, Keys}

  @sm SalixStore.TestSM

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    # Keep snapshots out of the picture for the contention runs so that the
    # journal-tail accounting is unambiguous; one scenario flips it on its own.
    prev_snap = Application.get_env(:salix_store, :snapshot_bytes)
    Application.put_env(:salix_store, :snapshot_bytes, 8 * 1024 * 1024)

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_store, :snapshot_bytes, prev_snap)
    end)

    {:ok, agent: "agent-#{System.unique_integer([:positive])}"}
  end

  # ---- worker -------------------------------------------------------------

  # One claimant+committer. Steals the agent, then drives `commits` increments
  # of +1 each. STOPS on the first non-:ok outcome (fence discipline). Returns a
  # record we can audit: the epoch it owned, and the ordered outcome stream.
  defp run_worker(agent, node_id, commits) do
    case Agent.claim(agent, node_id, @sm, steal: true) do
      {:ok, owned} ->
        {final, outcomes} = drive(owned, commits, [])
        %{node: node_id, claimed: true, epoch: owned.epoch, outcomes: outcomes, final: final}

      {:error, reason} ->
        %{node: node_id, claimed: false, epoch: nil, outcomes: [{:claim, reason}], final: nil}
    end
  end

  defp drive(owned, 0, acc), do: {owned, Enum.reverse(acc)}

  defp drive(owned, n, acc) do
    case Agent.commit(owned, [%{op: "inc", by: 1}]) do
      {:ok, next} ->
        # Record the durable tail seq we just achieved, for the monotonicity audit.
        drive(next, n - 1, [{:ok, next.epoch, next.head.journal_tail.seq} | acc])

      {:error, reason} ->
        # Fence is terminal: stop immediately, do not attempt further commits.
        {owned, Enum.reverse([{:error, reason} | acc])}
    end
  end

  defp ok_commits(record), do: Enum.filter(record.outcomes, &match?({:ok, _, _}, &1))

  # ---- shared audit -------------------------------------------------------

  # Given the collected worker records, assert every linearizability invariant
  # plus a durable replay cross-check (claim fresh, compare to the model).
  defp audit!(agent, records) do
    all_ok = Enum.flat_map(records, &ok_commits/1)
    total_ok = length(all_ok)

    # (1) Distinct epoch per effective owner: every owner that committed did so
    # under an epoch no other owner ever committed under. (Claims that won the
    # head CAS necessarily got a unique epoch via the monotonic bump.)
    ok_epochs = Enum.map(all_ok, fn {:ok, epoch, _seq} -> epoch end)
    epochs_with_writes = Enum.uniq(ok_epochs)

    for epoch <- epochs_with_writes do
      owners =
        records
        |> Enum.filter(fn r -> Enum.any?(ok_commits(r), fn {:ok, e, _} -> e == epoch end) end)
        |> Enum.map(& &1.node)
        |> Enum.uniq()

      assert length(owners) == 1,
             "epoch #{epoch} had >1 effective writer: #{inspect(owners)} — head CAS not linearizable"
    end

    # (2) Fence is terminal: in each worker's outcome stream, no :ok follows a
    # non-:ok. (drive/3 enforces this; we re-audit the recorded stream to catch
    # a regression where a fenced writer is allowed to keep committing.)
    for r <- records do
      refute had_ok_after_failure?(r.outcomes),
             "worker #{r.node} made an effective write after being fenced: #{inspect(r.outcomes)}"
    end

    # (3a) Per-worker seqs strictly increase by exactly 1 (a single owner's
    # commits are gap-free and ordered).
    for r <- records do
      seqs = ok_commits(r) |> Enum.map(fn {:ok, _e, seq} -> seq end)
      assert seqs == Enum.sort(seqs), "worker #{r.node} seqs out of order: #{inspect(seqs)}"
      assert seqs == Enum.uniq(seqs), "worker #{r.node} repeated a seq: #{inspect(seqs)}"

      Enum.chunk_every(seqs, 2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert b == a + 1, "worker #{r.node} seq gap #{a}->#{b} within one lineage"
      end)
    end

    # (3b) Across the WHOLE agent, the durable journal_tail.seq equals the total
    # number of effective commits: the winning lineage advanced seq by exactly 1
    # per commit, starting at 1. Any orphan referenced (or commit lost) breaks this.
    {:ok, head} = Agent.peek(agent)

    assert head.journal_tail.seq == total_ok,
           "durable journal_tail.seq=#{head.journal_tail.seq} != #{total_ok} effective commits"

    # The set of seqs that were ever effectively committed is exactly 1..total_ok
    # (strict monotonic, gap-free) when viewed across the winning lineage.
    committed_seqs = all_ok |> Enum.map(fn {:ok, _e, seq} -> seq end) |> Enum.sort()

    assert Enum.uniq(committed_seqs) == committed_seqs,
           "two effective commits claimed the same journal seq: #{inspect(committed_seqs)}"

    assert committed_seqs == Enum.to_list(1..total_ok//1) or total_ok == 0,
           "effective seqs are not the gap-free run 1..#{total_ok}: #{inspect(committed_seqs)}"

    # (4) No orphan-then-reference: a fresh claim replays ONLY the winning
    # lineage. Each effective commit is exactly one +1 inc event, so the replayed
    # counter == total_ok and ops == total_ok. An orphan being followed (or a
    # double-replay) would inflate either count.
    {:ok, fresh} =
      Agent.claim(agent, "auditor-#{System.unique_integer([:positive])}", @sm, steal: true)

    assert fresh.state.counter == total_ok,
           "replayed counter #{fresh.state.counter} != #{total_ok} effective commits — orphan referenced or commit lost"

    assert fresh.state.ops == total_ok,
           "replayed ops #{fresh.state.ops} != #{total_ok} — an event was double-applied or dropped"

    # The fresh claim's epoch must exceed every epoch any committer ever used:
    # epoch is monotonic through the head CAS chain.
    if epochs_with_writes != [] do
      assert fresh.epoch > Enum.max(epochs_with_writes),
             "fresh claim epoch #{fresh.epoch} did not advance past committed epochs #{inspect(epochs_with_writes)}"
    end

    total_ok
  end

  defp had_ok_after_failure?(outcomes) do
    outcomes
    |> Enum.drop_while(&match?({:ok, _, _}, &1))
    |> Enum.any?(&match?({:ok, _, _}, &1))
  end

  # =========================================================================
  # Scenarios
  # =========================================================================

  test "N concurrent steal+commit workers: one effective writer per epoch", %{agent: a} do
    {:ok, _} = Agent.create(a, "node-0", @sm)

    n = 12
    commits_each = 6

    records =
      1..n
      |> Task.async_stream(
        fn i -> run_worker(a, "node-#{i}", commits_each) end,
        max_concurrency: n,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    total_ok = audit!(a, records)

    # Liveness sanity: with this much contention, SOME commits must have landed
    # (otherwise the test isn't exercising the path at all).
    assert total_ok > 0, "no worker ever committed — contention test is vacuous"
  end

  test "many short-lived claimants thrash a single agent (high churn)", %{agent: a} do
    {:ok, _} = Agent.create(a, "seed", @sm)

    n = 24

    records =
      1..n
      |> Task.async_stream(
        # Each worker only tries a single commit, so claims churn fast and most
        # workers get fenced between claim and commit — the worst case for the
        # "fence is terminal" and "no orphan referenced" invariants.
        fn i -> run_worker(a, "w-#{i}", 1) end,
        max_concurrency: n,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    audit!(a, records)

    # Every worker that successfully claimed got a unique epoch (claim CAS bumps
    # epoch atomically; concurrent winners cannot collide).
    claimed_epochs = records |> Enum.filter(& &1.claimed) |> Enum.map(& &1.epoch)

    assert claimed_epochs == Enum.uniq(claimed_epochs),
           "two successful claims shared an epoch: #{inspect(claimed_epochs)}"
  end

  test "fenced original owner cannot interleave a commit with the thief", %{agent: a} do
    # Deterministic interleaving (no concurrency): proves the seq/epoch audit
    # also holds for a precisely-ordered fence, and that the thief's lineage —
    # not the orphan — is what replays.
    {:ok, o1} = Agent.create(a, "owner", @sm)
    {:ok, o1} = Agent.commit(o1, [%{op: "inc", by: 1}])
    # owner is at seq 1, epoch 1.

    {:ok, _thief} = Agent.claim(a, "thief", @sm, steal: true)
    {:ok, thief} = Agent.claim(a, "thief2", @sm, steal: true)
    {:ok, thief} = Agent.commit(thief, [%{op: "inc", by: 1}])
    # thief2 is the live owner at seq 2.

    # The orphaned owner's next commit is fenced; it must NOT land.
    assert {:error, fenced} = Agent.commit(o1, [%{op: "inc", by: 100}])
    assert fenced in [:fenced, :stale_etag] or match?({:stale_etag, _}, fenced)

    # Even though the orphan wrote a journal segment under epoch 1 at seq 2
    # (create-once, different epoch dir), replay follows the highest epoch per
    # seq — the thief's lineage. counter == 2 (two +1s), NOT 102.
    {:ok, fresh} = Agent.claim(a, "verify", @sm, steal: true)
    assert fresh.state.counter == 2, "orphan's epoch-1 seq-2 segment was wrongly replayed"
    assert fresh.state.ops == 2
    assert fresh.head.journal_tail.seq == 2
    assert fresh.epoch == thief.epoch + 1
  end

  test "ambiguous head PUT on commit never produces a double or lost write", %{agent: a} do
    # A commit head-CAS whose response is lost AFTER the write landed must be
    # adopted (not retried into a duplicate or treated as fenced) by the
    # SAME owner. set_fault :ambiguous_after applies the mutation then returns
    # {:ambiguous,_}; resolve_commit_ambiguity must GET-and-check commit_uuid.
    {:ok, o} = Agent.create(a, "solo", @sm)
    {:ok, o} = Agent.commit(o, [%{op: "inc", by: 1}])

    # Next head PUT lands but the ack is lost.
    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, Keys.agent_state(a)})

    assert {:ok, o} = Agent.commit(o, [%{op: "inc", by: 1}])
    assert o.state.counter == 2
    assert o.head.journal_tail.seq == 2

    # A normal commit afterward continues the same lineage cleanly.
    {:ok, o} = Agent.commit(o, [%{op: "inc", by: 1}])
    assert o.head.journal_tail.seq == 3

    # Durable replay agrees: exactly 3 effective +1s, no ghost from the lost ack.
    {:ok, fresh} = Agent.claim(a, "after", @sm, steal: true)
    assert fresh.state.counter == 3
    assert fresh.state.ops == 3
    assert fresh.head.journal_tail.seq == 3
  end

  test "ambiguous head PUT that did NOT land surfaces, then re-commit is clean", %{agent: a} do
    # The complementary case: :ambiguous_before does not apply the mutation. The
    # owner's ETag is therefore still valid; a retried commit at the same seq
    # (create-once segment already present, head unchanged) must succeed exactly
    # once and not advance past one effective write.
    {:ok, o} = Agent.create(a, "solo2", @sm)

    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, Keys.agent_state(a)})

    # The head PUT returns ambiguous; the write did not land. resolve_commit_
    # ambiguity GETs the head: commit_uuid is NOT ours and epoch/owner unchanged
    # ⇒ {:ambiguous_unresolved, etag}. The owner keeps its valid pre-commit ETag,
    # so it can safely retry the same logical commit.
    case Agent.commit(o, [%{op: "inc", by: 1}]) do
      {:ok, o2} ->
        # If the impl chose to treat the unchanged head as adoptable, the write
        # must still be effective exactly once.
        assert o2.head.journal_tail.seq == 1

      {:error, {:ambiguous_unresolved, _etag}} ->
        # Owner retries with its still-valid handle; segment create-once is
        # idempotent (head verified present), head CAS now succeeds.
        assert {:ok, o2} = Agent.commit(o, [%{op: "inc", by: 1}])
        assert o2.head.journal_tail.seq == 1
        assert o2.state.counter == 1
    end

    {:ok, fresh} = Agent.claim(a, "after2", @sm, steal: true)
    assert fresh.state.counter == 1, "ambiguous-before produced 0 or >1 effective writes"
    assert fresh.head.journal_tail.seq == 1
  end

  property "any concurrency width preserves replay == sum(effective commits)", %{agent: a} do
    # Model-based: across randomized worker counts / per-worker commit budgets,
    # the durable replayed state ALWAYS equals the count of {:ok,_} commits and
    # the journal tail equals that same count. This is the global linearizability
    # contract reduced to a single arithmetic identity that an orphan reference,
    # a lost commit, or a double-apply would each violate.
    check all(
            n <- integer(2..8),
            budget <- integer(1..5),
            max_runs: 12
          ) do
      # Fresh agent per trial (the outer setup agent is reused only as a name base).
      trial = "#{a}-#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.create(trial, "seed", @sm)

      records =
        1..n
        |> Task.async_stream(
          fn i -> run_worker(trial, "n#{i}", budget) end,
          max_concurrency: n,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      audit!(trial, records)
    end
  end
end
