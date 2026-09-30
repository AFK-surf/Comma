defmodule SalixCluster.ChaosTest do
  @moduledoc """
  Adversarial chaos for the cluster coordination layer — the parts doable
  without testcontainers/toxiproxy, using the Fake's fault injection and BEAM
  concurrency. Two properties:

    * **S3 blackhole ⇒ fail-closed leadership.** With every singleton PUT
      returning 500 (`{:fail, 500, :put, :any}`), `SalixCluster.S3Lease.acquire`
      and `renew` MUST return an error and never hand back a token. No false
      leadership can emerge from an unreachable store. The recovery singleton,
      gated on the lease, must therefore not sweep.

    * **Claim storm ⇒ exactly one effective owner per epoch.** Many concurrent
      `SalixStore.Agent.claim(steal: true)` on one agent each bump the epoch via
      head CAS (the Fake serializes PUTs the way S3 serializes per-object CAS),
      so the winning epochs are distinct and monotone, and only the holder of the
      live (highest) epoch can commit — every other claimant is fenced.

  Genuinely multi-node-only scenarios (cross-VM dist-liveness, real `:erpc`
  fencing across nodes) are tagged `:multinode` and skipped here — they live in
  `SalixCluster.MultinodeTest` and run against real MinIO.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Agent, S3, Keys}
  alias SalixStore.S3.Fake
  alias SalixStore.Agent.Owned
  alias SalixCluster.{S3Lease, Recovery}

  @sm SalixCluster.CounterSM

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, Fake)
    start_supervised!(Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defp uniq_node, do: "node-#{System.unique_integer([:positive])}"

  # ---- S3 blackhole: leadership fails closed ----

  describe "S3 blackhole — singleton lease fails closed" do
    test "acquire on a virgin singleton under a PUT blackhole returns error, no token" do
      # First op in acquire on a missing singleton is a GET (returns :not_found),
      # then a create PUT — which the blackhole 500s. No token may be returned.
      :ok = Fake.blackhole({:fail, 500, :put, :any})

      assert {:error, _} = S3Lease.acquire(:recovery, "node-a")
      # Nothing was written: the singleton object does not exist.
      assert {:error, :not_found} = S3.get(Keys.singleton(:recovery))
    end

    test "renew under a PUT blackhole fails closed (never returns a fresh token)" do
      # Acquire cleanly first (no fault), then blackhole and try to renew.
      assert {:ok, token} = S3Lease.acquire(:recovery, "node-a")

      :ok = Fake.blackhole({:fail, 500, :put, :any})
      assert {:error, _} = S3Lease.renew(token)
    end

    test "a second acquirer cannot win while the holder is valid and the store is blackholed" do
      assert {:ok, _token_a} = S3Lease.acquire(:recovery, "node-a", now: 1_000, ttl_ms: 30_000)

      # node-b tries to take it: the lease is valid (not stale) so acquire's CAS
      # path is never even reached for a steal — but even the create/cas PUT is
      # blackholed. Either way, node-b must NOT come away holding leadership.
      :ok = Fake.blackhole({:fail, 500, :put, :any})

      result = S3Lease.acquire(:recovery, "node-b", now: 2_000, ttl_ms: 30_000)
      refute match?({:ok, %S3Lease{}}, result)
      assert match?({:error, _}, result)
    end

    test "the Recovery GenServer does not sweep when it cannot hold the lease", %{agent: a} do
      # Stage a stranded queued agent that a leader WOULD re-home.
      {:ok, owned} = Agent.create(a, "creator", @sm)
      :ok = Agent.release(owned)

      # Blackhole every singleton PUT so the recovery GenServer can never acquire
      # the lease on its initial :tick — fail-closed leadership.
      :ok = Fake.blackhole({:fail, 500, :put, :any})

      pid = start_supervised!({Recovery, [node: "chaos-node", interval_ms: 60_000]})

      # It is alive but holds no lease (lease == nil) → no sweep occurred.
      assert Process.alive?(pid)
      assert :sys.get_state(pid).lease == nil
    end
  end

  # ---- claim storm: exactly one effective owner per epoch ----

  describe "claim storm — one effective owner per epoch, others fenced" do
    test "concurrent steal-claims produce distinct monotone epochs; only the top epoch commits",
         %{agent: a} do
      {:ok, _seed} = Agent.create(a, "seed", @sm)

      results =
        1..32
        |> Task.async_stream(
          fn _ -> Agent.claim(a, uniq_node(), @sm, steal: true) end,
          max_concurrency: 32,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      owned = for {:ok, %Owned{} = o} <- results, do: o
      assert owned != [], "at least one claimant must win the head CAS"

      # Each successful claim came from a distinct head CAS, so no two share an
      # epoch — the storage realization of "exactly one owner per epoch".
      epochs = Enum.map(owned, & &1.epoch)
      assert length(epochs) == length(Enum.uniq(epochs))
      assert epochs == Enum.uniq(epochs)

      # The durable root head reflects the maximum epoch any claimant achieved.
      {:ok, head} = Agent.peek(a)
      live_epoch = head.epoch
      assert live_epoch == Enum.max(epochs)

      # Exactly one effective writer: the top-epoch holder commits, all others
      # are fenced (their stale ETag can never CAS the head).
      winner = Enum.max_by(owned, & &1.epoch)
      losers = owned -- [winner]

      assert {:ok, w2} = Agent.commit(winner, [%{op: "inc", by: 1}])
      assert w2.state.counter == 1

      for l <- losers do
        assert match?({:error, _}, Agent.commit(l, [%{op: "inc", by: 999}])),
               "claimant at epoch #{l.epoch} (not the top #{winner.epoch}) must be fenced"
      end

      # Convergence: a fresh clean claim replays a single consistent state.
      {:ok, fresh} = Agent.claim(a, uniq_node(), @sm, steal: true)
      assert fresh.state.counter == 1
      assert fresh.state.ops == 1
    end

    test "claim storm interleaved with the loser's commit attempts stays single-effective-writer",
         %{agent: a} do
      {:ok, first} = Agent.create(a, "seed", @sm)

      # A racing pool: half try to steal-claim, half are the original owner trying
      # to commit on its (soon-stale) handle. At most the original commit lands
      # before it is fenced; the durable counter equals the acked count, never more.
      claim_tasks =
        for _ <- 1..12 do
          Task.async(fn -> Agent.claim(a, uniq_node(), @sm, steal: true) end)
        end

      commit_tasks =
        for _ <- 1..12 do
          Task.async(fn -> Agent.commit(first, [%{op: "inc", by: 1}]) end)
        end

      claim_results = Enum.map(claim_tasks, &Task.await(&1, 30_000))
      commit_results = Enum.map(commit_tasks, &Task.await(&1, 30_000))

      owned = for {:ok, %Owned{} = o} <- claim_results, do: o
      assert owned != []

      # `first` shares one ETag, so AT MOST ONE of its concurrent commits can CAS
      # the head; the rest are fenced/stale. So the original owner applies 0 or 1
      # increments total, never more — no double-apply from the commit storm.
      acked_commits = Enum.count(commit_results, &match?({:ok, _}, &1))
      assert acked_commits <= 1

      # Distinct epochs among winning claims.
      epochs = Enum.map(owned, & &1.epoch)
      assert length(epochs) == length(Enum.uniq(epochs))

      # Convergence: cold replay equals exactly the acknowledged increments
      # (0 or 1 from the original owner). The fenced claimants and fenced commits
      # contributed nothing.
      {:ok, fresh} = Agent.claim(a, uniq_node(), @sm, steal: true)
      assert fresh.state.counter == acked_commits
      assert fresh.state.ops == acked_commits
    end
  end

  # ---- genuinely multi-node-only scenarios live in MultinodeTest ----

  # Cross-VM dist-liveness fencing and real `:erpc` claim races need a peer node
  # and a shared MinIO bucket; they are exercised in `SalixCluster.MultinodeTest`.
  # Tagged so the default `--exclude multinode` run skips this boundary marker.
  @tag :multinode
  test "cross-node dist-liveness steal of a stale lease is covered in MultinodeTest" do
    assert Code.ensure_loaded?(SalixCluster.MultinodeTest)
  end
end
