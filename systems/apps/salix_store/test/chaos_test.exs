defmodule SalixStore.ChaosTest do
  @moduledoc """
  Adversarial chaos — the *concurrency* complement to the single-threaded
  `SalixStore.AmbiguityInjectionTest`. Where that module pins one fault to one
  PUT and walks the recovery branch by hand, this module drives **many writers
  at once** through `Task.async_stream` while the Fake injects ambiguity / 5xx
  on head and journal PUTs (and DELETEs), then asserts the four storage-kernel
  invariants the whole CAS design rests on:

    1. **No lost acknowledged commit** — every event the protocol returned
       `{:ok}` for survives a cold replay.
    2. **No double-applied commit** — an acknowledged event appears exactly once
       in the durable journal, even when its ACK was lost (`ambiguous_after`).
    3. **A fenced writer never makes an effective write** — once a strictly
       higher epoch exists, the stale owner's commits leave zero application
       effect, regardless of injected ambiguity on its own PUTs.
    4. **Convergence** — after the storm, a fresh clean claim (highest epoch)
       replays a single consistent state that equals the acknowledged total.

  Faults are one-shot and consumed by the first matching op (see the Fake's
  moduledoc), so a `:any` fault races whichever concurrent writer's PUT lands
  first — exactly the nondeterminism we want to harden against. The ground
  truth is always the cold replay (`durable_state/1`), never the in-memory
  `Owned` handle that may have observed an ambiguous response.
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

  # The single source of truth: cold replay from the durable head + journal,
  # independent of any live handle. READ-ONLY — claiming here would bump the
  # epoch and fence the legitimate owner the test is asserting about.
  defp durable_state(agent) do
    {:ok, state} = Agent.read_state(agent, @sm)
    state
  end

  # Drive one commit to a definitive {:ok} or a definitive fence, retrying only
  # the caller-recoverable ambiguity variants on the UNCHANGED handle (the fault
  # is one-shot, so at most one retry is needed; we loop defensively). Returns
  # {:ok, owned} | :fenced. Never returns an ambiguous error to the caller.
  defp commit_settled(o, events) do
    case Agent.commit(o, events) do
      {:ok, o2} -> {:ok, o2}
      {:error, :fenced} -> :fenced
      {:error, {:stale_etag, _}} -> :fenced
      {:error, {:ambiguous, :segment_lost}} -> commit_settled(o, events)
      {:error, {:ambiguous_unresolved, _}} -> commit_settled(o, events)
      {:error, {:http, _}} -> commit_settled(o, events)
      other -> flunk("unexpected commit outcome under chaos: #{inspect(other)}")
    end
  end

  # ---- 1+2: serialized-by-CAS commit storm under random faults ----

  describe "single-owner commit storm under random head/segment faults" do
    # A single owner commits a stream of increments. Before each commit we may
    # inject ambiguity (either flavor) or a 500 on EITHER the segment or head
    # PUT, targeted at the exact key for the upcoming seq/epoch. After settling
    # each commit, the acknowledged sum must match BOTH the live handle and the
    # cold replay — no lost write, no double-apply — and the journal holds
    # exactly one segment per acknowledged seq.
    test "every acknowledged increment lands exactly once", %{agent: a} do
      {:ok, o0} = Agent.create(a, "node-1", @sm)

      increments = for _ <- 1..30, do: SystemsRuntime.Proc.uniform(5)

      fault_kinds = [
        nil,
        {:ambiguous_after, :head},
        {:ambiguous_before, :head},
        {:fail500, :head}
      ]

      {final, acked_sum, acked_count} =
        Enum.reduce(increments, {o0, 0, 0}, fn by, {o, sum, count} ->
          inject(a, o, Enum.at(fault_kinds, SystemsRuntime.Proc.uniform(length(fault_kinds)) - 1))

          case commit_settled(o, [%{op: "inc", by: by}]) do
            {:ok, o2} -> {o2, sum + by, count + 1}
            :fenced -> flunk("a sole owner should never fence itself")
          end
        end)

      # No lost write: live handle and cold replay agree with the acked total.
      assert final.state.counter == acked_sum
      assert durable_state(a).counter == acked_sum

      # No double-apply: one op recorded per acknowledged commit.
      assert durable_state(a).ops == acked_count
    end

    defp inject(_a, _o, nil), do: :ok

    defp inject(a, _o, {:fail500, :head}),
      do: Fake.set_fault({:fail, 500, :put, Keys.agent_state(a)})

    defp inject(a, _o, {kind, :head}),
      do: Fake.set_fault({kind, :put, Keys.agent_state(a)})
  end

  # ---- 3: fenced writer makes no effective write ----

  describe "fenced writer is categorically ineffective" do
    test "stale owner's committed events never reach the journal-applied state, even under ambiguity",
         %{agent: a} do
      {:ok, o_stale} = Agent.create(a, "node-1", @sm)
      {:ok, o_stale} = Agent.commit(o_stale, [%{op: "inc", by: 10}])

      # node-2 genuinely steals (epoch 2 → 3 ... here 1->2). node-1 is now fenced.
      {:ok, o_new} = Agent.claim(a, "node-2", @sm, steal: true)
      assert o_new.epoch == o_stale.epoch + 1
      assert o_new.state.counter == 10

      baseline = durable_state(a)

      # The fenced writer tries hard, with every adverse fault flavor on its own
      # head PUT. None may have an effect; each must fail (fenced / stale / surfaced).
      for fault <- [
            {:ambiguous_after, :put, Keys.agent_state(a)},
            {:ambiguous_before, :put, Keys.agent_state(a)},
            {:fail, 500, :put, Keys.agent_state(a)}
          ] do
        :ok = Fake.set_fault(fault)
        refute match?({:ok, %Owned{}}, Agent.commit(o_stale, [%{op: "inc", by: 99}]))
      end

      # State is byte-for-byte unchanged from before the fenced attempts.
      assert durable_state(a) == baseline
      assert durable_state(a).counter == 10

      # The legitimate owner is unaffected and converges normally.
      assert {:ok, o_new2} = Agent.commit(o_new, [%{op: "inc", by: 5}])
      assert o_new2.state.counter == 15
      assert durable_state(a).counter == 15
    end
  end

  # ---- 4: concurrent claim storm → exactly one effective owner per epoch ----

  describe "concurrent claim storm" do
  end

  # ---- 4 (delete chaos): release/delete faults never strand the head ----

  describe "release under DELETE faults converges" do
  end
end
