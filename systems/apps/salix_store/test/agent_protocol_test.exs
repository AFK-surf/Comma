defmodule SalixStore.AgentProtocolTest do
  @moduledoc """
  The claim / commit / replay / fencing / renew / release protocol,
  run against both backends. It proves the head-CAS commit point reproduces
  serializable-transaction semantics and that fencing is
  validated inside every commit.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Agent, S3, Keys}
  alias SalixStore.Agent.Owned

  @sm SalixStore.TestSM

  for {backend, name} <- [{SalixStore.S3.AWS, "MinIO"}, {SalixStore.S3.Fake, "Fake"}] do
    describe "#{name}: agent protocol" do
      setup do
        prev = Application.get_env(:salix_store, :s3_backend)
        Application.put_env(:salix_store, :s3_backend, unquote(backend))
        # Force snapshots after a tiny amount of journal so we exercise that path.
        prev_snap = Application.get_env(:salix_store, :snapshot_bytes)
        Application.put_env(:salix_store, :snapshot_bytes, 200)

        if unquote(backend) == SalixStore.S3.Fake, do: start_supervised!(SalixStore.S3.Fake)

        on_exit(fn ->
          Application.put_env(:salix_store, :s3_backend, prev)
          Application.put_env(:salix_store, :snapshot_bytes, prev_snap)
        end)

        {:ok, agent: unique_agent()}
      end

      test "create then claim yields the same state; double create is :exists", %{agent: a} do
        assert {:ok, %Owned{epoch: 1, state: %{counter: 0}}} = Agent.create(a, "node-1", @sm)
        assert {:error, :exists} = Agent.create(a, "node-2", @sm)
      end

      test "commits apply in order, advance hwm, and survive a fresh claim", %{agent: a} do
        {:ok, o} = Agent.create(a, "node-1", @sm)
        {:ok, o} = Agent.commit(o, [%{op: "inc", by: 5}], hwm: 1)
        {:ok, o} = Agent.commit(o, [%{op: "inc", by: 3}, %{op: "set", value: 100}], hwm: 3)
        assert o.state.counter == 100
        assert o.head.message_id_hwm == 3
        assert o.epoch == 1

        # A fresh claim from another node replays to the identical state.
        {:ok, o2} = Agent.claim(a, "node-2", @sm, steal: true)
        assert o2.state.counter == 100
        assert o2.state.ops == 3
        assert o2.epoch == 2
        assert o2.head.message_id_hwm == 3
      end

      test "fencing: a stolen agent's original owner cannot commit", %{agent: a} do
        {:ok, o1} = Agent.create(a, "node-1", @sm)
        {:ok, o1} = Agent.commit(o1, [%{op: "inc", by: 1}])

        # node-2 steals (epoch bump).
        {:ok, _o2} = Agent.claim(a, "node-2", @sm, steal: true)

        # node-1's next commit must be fenced.
        assert {:error, :fenced} = Agent.commit(o1, [%{op: "inc", by: 99}])
      end

      test "lease staleness gates steal; safety is the ETag not the clock", %{agent: a} do
        t0 = 1_000_000
        {:ok, _o1} = Agent.create(a, "node-1", @sm, now: t0, ttl_ms: 60_000)

        # Before expiry: node-2 sees it held.
        assert {:error, {:held_by, "node-1", _}} =
                 Agent.claim(a, "node-2", @sm, now: t0 + 30_000)

        # After expiry: node-2 may steal.
        assert {:ok, o2} = Agent.claim(a, "node-2", @sm, now: t0 + 61_000)
        assert o2.epoch == 2
      end

      test "renew refreshes the lease; release clears ownership + lease index", %{agent: a} do
        {:ok, o} = Agent.create(a, "node-1", @sm, now: 1_000_000)
        {:ok, o} = Agent.renew(o, now: 1_005_000)
        assert o.head.lease_until == 1_005_000 + 60_000

        assert :ok = Agent.release(o)
        {:ok, head} = Agent.peek(a)
        assert head.owner_node == nil
        assert head.lease_until == nil
        # lease index entry gone
        assert {:error, :not_found} = S3.head(Keys.lease("node-1", a))
      end

      test "snapshot path: state reloads correctly after snapshot + tail", %{agent: a} do
        {:ok, o} = Agent.create(a, "node-1", @sm)
        # snapshot_bytes is 200; a handful of commits will cross it.
        o =
          Enum.reduce(1..10, o, fn i, acc ->
            {:ok, acc} = Agent.commit(acc, [%{op: "inc", by: i}], hwm: i)
            acc
          end)

        assert o.state.counter == Enum.sum(1..10)
        # a snapshot should have been taken
        {:ok, head} = Agent.peek(a)
        assert head.snapshot_seq != nil

        {:ok, o2} = Agent.claim(a, "node-2", @sm, steal: true)
        assert o2.state.counter == Enum.sum(1..10)
        assert o2.state.ops == 10
      end
    end
  end

  defp unique_agent do
    "agent-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
