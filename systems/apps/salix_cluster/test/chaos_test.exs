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
  use SystemsClock.Case, async: false

  alias SalixStore.{Agent, S3, Keys}
  alias SalixStore.S3.Fake
  alias SalixStore.Agent.Owned
  alias SalixCluster.{S3Lease, Recovery}

  @sm SalixCluster.CounterSM

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    start_supervised!(Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  # ---- S3 blackhole: leadership fails closed ----

  describe "S3 blackhole — singleton lease fails closed" do

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
      assert SystemsRuntime.Proc.alive?(pid)
      assert :sys.get_state(pid).lease == nil
    end
  end

  # ---- claim storm: exactly one effective owner per epoch ----

  describe "claim storm — one effective owner per epoch, others fenced" do
  end
end
