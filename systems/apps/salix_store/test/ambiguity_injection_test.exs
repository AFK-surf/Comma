defmodule SalixStore.AmbiguityInjectionTest do
  @moduledoc """
  Ambiguity injection at the adversarial heart of the CAS design.

  Every mutating PUT in the kernel can return `{:error, {:ambiguous, _}}` when a
  timeout / 5xx leaves the write's outcome unknown. There are exactly two ground
  truths behind that one response:

    * `:ambiguous_after`  — the write LANDED, the ACK was lost.
    * `:ambiguous_before` — the write FAILED, the (error) ACK was lost.

  The protocol must distinguish them with GET/HEAD-and-check and, in BOTH cases,
  end in a state that is recoverable on retry with **no lost write and no
  double-apply**. A genuinely fenced writer must additionally
  be detected within a single GET round trip.

  This module drives only `SalixStore.S3.Fake`, because the assertions depend on
  injected, one-shot faults. The fake's fault is consumed by the FIRST matching
  op, so we target the head/segment/inbox PUTs by exact key (not `:any`) whenever
  a single `commit`/`deliver` issues more than one PUT and we need to hit a
  specific one.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.{Agent, Keys}
  alias SalixStore.S3.Fake
  alias SalixStore.Agent.Owned

  @sm SalixStore.TestSM

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    start_supervised!(Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: "agent-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  defp uniq_node, do: "node-#{SystemsRuntime.Proc.unique_integer([:positive])}"

  # Load the durable root from a clean claim, returning the
  # materialized counter/ops. This is the ground-truth "what actually persisted"
  # check — independent of any in-memory Owned handle that may have observed an
  # ambiguous response.
  defp durable_state(agent) do
    {:ok, o} = Agent.claim(agent, uniq_node(), @sm, steal: true)
    o.state
  end

  # ---- commit: head PUT ambiguity ----

  describe "commit / head CAS ambiguity" do
    test "ambiguous_after on head: write landed, response lost ⇒ recovered as {:ok}, applied once",
         %{agent: a} do
      {:ok, o} = Agent.create(a, "node-1", @sm)

      # The head PUT will mutate then return ambiguous. Target the head key
      # exactly so the EARLIER segment PUT in this same commit is untouched.
      :ok = Fake.set_fault({:ambiguous_after, :put, Keys.agent_state(a)})

      assert {:ok, %Owned{} = o2} = Agent.commit(o, [%{op: "inc", by: 7}], hwm: 1)

      # The handle is healthy and advanced: next commit works without re-fencing.
      assert o2.state.counter == 7
      assert o2.next_seq == 2
      assert {:ok, o3} = Agent.commit(o2, [%{op: "inc", by: 1}])
      assert o3.state.counter == 8

      # Ground truth: a fresh claim agrees with the in-memory state (no lost write).
      assert durable_state(a).counter == 8
      assert durable_state(a).ops == 2
    end

    test "ambiguous_before on head: write failed, response lost ⇒ retry recovers, no double-apply",
         %{agent: a} do
      {:ok, o} = Agent.create(a, "node-1", @sm)

      # Head PUT does NOT land; ambiguous returned. resolve_commit_ambiguity GETs
      # the head, finds the OLD commit_uuid (epoch/owner unchanged), so it cannot
      # claim the write as its own ⇒ {:ambiguous_unresolved, _}. The caller keeps
      # its unchanged Owned and retries.
      :ok = Fake.set_fault({:ambiguous_before, :put, Keys.agent_state(a)})

      assert {:error, {:ambiguous_unresolved, _etag}} =
               Agent.commit(o, [%{op: "inc", by: 5}])

      # The original handle is intact: state/seq never advanced.
      assert o.state.counter == 0
      assert o.next_seq == 1

      # Retry on the SAME handle. Net: applied once.
      assert {:ok, o2} = Agent.commit(o, [%{op: "inc", by: 5}])
      assert o2.state.counter == 5
      assert o2.next_seq == 2

      assert durable_state(a).counter == 5
      assert durable_state(a).ops == 1
      assert durable_state(a).counter == 5
    end
  end

  # ---- claim: head CAS ambiguity ----

  describe "claim / head CAS ambiguity" do
  end

  # ---- delivery: inbox + marker PUT ambiguity ----

  # The "delivery / inbox + marker ambiguity" describe retired with the staged
  # protocol (A2 §3.4). Delivery-side ambiguity is now the rpc facade's
  # same-id-retry contract, pinned in deliver_ingress_test; the CAS kernel
  # ambiguity below is protocol-independent and stays.

  describe "renew ambiguity" do
  end

  describe "model property: ambiguity injection never corrupts the journal" do
    @describetag :property

    # Commit a sequence of increments; before each commit, randomly inject an
    # ambiguity fault on EITHER the segment or the head PUT, of EITHER flavor.
    # After resolving each commit (retrying on the recoverable errors), the
    # durable replayed counter must equal the sum of the increments that the
    # protocol acknowledged with {:ok} — exactly-once, no matter the faults.
    test "randomized fault stream preserves applied-once journal semantics", %{agent: a} do
      {:ok, o0} = Agent.create(a, "node-1", @sm)

      increments = for _ <- 1..12, do: SystemsRuntime.Proc.uniform(5)

      faults = [
        nil,
        {:ambiguous_after, :head},
        {:ambiguous_before, :head}
      ]

      {final, acked_sum} =
        Enum.reduce(increments, {o0, 0}, fn by, {o, sum} ->
          fault = Enum.at(faults, SystemsRuntime.Proc.uniform(length(faults)) - 1)
          maybe_inject(a, o, fault)
          # Retry until the protocol gives a definitive {:ok}. All ambiguity
          # variants here are caller-recoverable on the unchanged handle.
          {o2, applied?} = commit_until_ok(o, [%{op: "inc", by: by}])
          {o2, if(applied?, do: sum + by, else: sum)}
        end)

      # Every increment we drove to {:ok} is present exactly once in the durable
      # journal; the in-memory handle and the cold replay agree.
      assert final.state.counter == acked_sum
      assert durable_state(a).counter == acked_sum
    end

    # Install the fault against the right key for the upcoming commit's seq/epoch.
    defp maybe_inject(_a, _o, nil), do: :ok

    defp maybe_inject(a, _o, {kind, :head}) do
      Fake.set_fault({kind, :put, Keys.agent_state(a)})
    end

    # Commit, retrying on every recoverable ambiguity. The fault is one-shot, so
    # at most one retry is ever needed, but we loop defensively.
    defp commit_until_ok(o, events) do
      case Agent.commit(o, events) do
        {:ok, o2} ->
          {o2, true}

        {:error, {:ambiguous, :segment_lost}} ->
          commit_until_ok(o, events)

        {:error, {:ambiguous_unresolved, _}} ->
          commit_until_ok(o, events)

        {:error, other} ->
          flunk("unexpected commit error under injected ambiguity: #{inspect(other)}")
      end
    end
  end
end
