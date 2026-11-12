defmodule SalixAgent.DeliverIngressTest do
  @moduledoc """
  `SalixAgent.deliver/3` is the single delivery ingress: the source identity
  contract (no manufactured ids) and the per-caller `:session_check`
  declaration live here. The staged inbox/queue/absorb protocol is retired
  (rpc-direct-delivery §3.4): durable truth is the session-ledger commit.

  Ledger-level assertions use `no_wake: true`, which commits durably without
  scheduling a round.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.TestSupport.RetiredSessionFixture
  @session "ses1_0000000000000000801"

  defmodule CountingPlacement do
    @moduledoc false
    @behaviour SalixAgent.Placement

    # Counts only the agent under test: the placement is global, and other
    # agents' background work resolves through it whenever it runs.
    def ensure_started(agent_id, opts) do
      case SystemsRuntime.PersistentTerm.get({__MODULE__, :counter}) do
        {^agent_id, counter} -> :counters.add(counter, 1, 1)
        _ -> :ok
      end

      SalixAgent.Fleet.ensure_started(agent_id, opts)
    end

    def stop_existing(agent_id, opts), do: SalixAgent.Fleet.stop_existing(agent_id, opts)
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{})
    {:ok, agent: agent}
  end

  test "old source-summary retries preserve admitted input across owner restart",
       %{agent: agent_id} do
    source_id = "old-source"

    old = %{
      content: "Unchanged canonical command",
      role: "user",
      session_id: @session,
      pre_deliveries: [
        %{
          source_message_id: source_id <> ":source-context",
          role: "summary",
          content: "Internal source only"
        }
      ]
    }

    assert {:ok, :created} =
             SalixAgent.deliver(agent_id, old, source_message_id: source_id, no_wake: true)

    queue = fn ->
      {:ok, state} = SalixAgent.InternalSessionStore.read(agent_id, @session)
      SalixAgent.InternalSession.get(state, :input_queue)
    end

    admitted = queue.()
    assert length(admitted) == 2
    SalixAgent.TestSupport.stop_all_agents()

    revised =
      put_in(old, [:pre_deliveries], [
        %{
          source_message_id: source_id <> ":source-context",
          role: "summary",
          content: "Read-only investigation sources: new locator"
        }
      ])

    assert {:ok, :duplicate} =
             SalixAgent.deliver(agent_id, revised, source_message_id: source_id, no_wake: true)

    assert queue.() == admitted
    refute inspect(queue.()) =~ "new locator"

    later =
      put_in(
        revised,
        [:pre_deliveries, Access.at(0), :source_message_id],
        source_id <> "-later:source-context"
      )

    assert {:ok, :created} =
             SalixAgent.deliver(agent_id, later,
               source_message_id: source_id <> "-later",
               no_wake: true
             )

    assert length(queue.()) == 4
    assert inspect(queue.()) =~ "new locator"
  end

  test "an archived agent rejects deliveries from every caller path", %{agent: a} do
    assert {:ok, _} = SalixAgent.AgentControl.delete(a)

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.deliver(a, %{content: "tick"},
               create: false,
               no_wake: true,
               source_message_id: "timer:t1:1",
               session_check: :staging
             )
  end

  describe "rpc delivery (A2, docs/salix/conversation-owner-actor.md; the only protocol since §3.2 step 4)" do
    test "delivers via the actor with NO inbox/marker write, dedupes on the session ledger",
         %{agent: a} do
      payload = %{content: "hello rpc", session_id: @session}

      assert {:ok, :created} =
               SalixAgent.deliver(a, payload, source_message_id: "rpc-stable-1", no_wake: true)

      # The whole point of A2: durable truth lives in the session commit, the
      # staging structures are never touched.

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "rpc-stable-1")

      # The no_wake opt must survive the RPC path into the queue record —
      # losing it would run a round at commit time (a real regression class:
      # rpc_delivery_body overwrites payload-carried flags from opts).
      assert [%{"dedupe_key" => "rpc-stable-1", "wake" => false}] =
               SalixAgent.InternalSession.get(state, :input_queue)

      assert {:ok, :duplicate} =
               SalixAgent.deliver(a, payload, source_message_id: "rpc-stable-1", no_wake: true)
    end

    test "a saturated session queue refuses before commit; duplicates still ack", %{agent: a} do
      prev = SystemsRuntime.get_env(:salix_agent, :session_input_queue_limit)
      SystemsRuntime.put_env(:salix_agent, :session_input_queue_limit, 1)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "one", session_id: @session},
                 source_message_id: "sat-1",
                 no_wake: true
               )

      assert {:error, :saturated} =
               SalixAgent.deliver(a, %{content: "two", session_id: @session},
                 source_message_id: "sat-2",
                 no_wake: true
               )

      # Saturated refusal committed nothing: the refused id is absent from the
      # ledger, and the already-committed id keeps acking as a duplicate.
      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      refute MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "sat-2")

      assert {:ok, :duplicate} =
               SalixAgent.deliver(a, %{content: "one", session_id: @session},
                 source_message_id: "sat-1",
                 no_wake: true
               )
    end

    # "pre-cutover inbox residue dedupes against the rpc ledger" retired with
    # the staged engine and absorb (§3.4): residue cannot exist anymore, and
    # same-id ledger dedupe is pinned by the other tests in this describe.

    test "a stale owner commits nothing and answers :not_owner", %{agent: a} do
      # Force stale local placement to test the admission fence independently
      # of the cluster placement implementation.
      placement = SystemsRuntime.get_env(:salix_agent, :placement)
      SystemsRuntime.put_env(:salix_agent, :placement, SalixAgent.Placement.LocalFleet)

      on_exit(fn ->
        if placement,
          do: SystemsRuntime.put_env(:salix_agent, :placement, placement),
          else: SystemsRuntime.delete_env(:salix_agent, :placement)
      end)

      {:ok, _owned} = SalixStore.Agent.claim(a, "stale-owner@elsewhere", SalixAgent.State)

      assert {:error, :not_owner} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "stale-1",
                 no_wake: true
               )

      assert {:error, :not_owner} =
               SalixAgent.AgentActor.stage_rpc_delivery_local(
                 a,
                 %{content: "x", session_id: @session},
                 no_wake: true
               )

      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)
    end

    test "a session-less delivery to a router resolves its session at deliver time", %{agent: a} do
      # #871: the router role actor rewrites the delivery onto its persisted
      # canonical router session BEFORE the session commit — the same code
      # absorb ran — so a session-less schedule takes the rpc path with the
      # full contract (no inbox, ledger dedupe) and keeps its staged-mode
      # answer ({:ok, :created}).
      rt = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(rt, %{"role" => "router"})

      {:ok, record} = SalixAgent.Control.get_record(rt)
      {:ok, router_session} = SalixStore.RuntimeIds.persisted_router_session_id(record)

      assert {:ok, :created} =
               SalixAgent.deliver(rt, %{content: "scheduled prompt", role: "user"},
                 source_message_id: "rpc-sessionless-1",
                 session_check: :staging,
                 no_wake: true
               )

      {:ok, state} = SalixAgent.InternalSessionStore.read(rt, router_session)

      assert MapSet.member?(
               SalixAgent.InternalSession.get(state, :input_dedupe),
               "rpc-sessionless-1"
             )

      assert {:ok, :duplicate} =
               SalixAgent.deliver(rt, %{content: "scheduled prompt", role: "user"},
                 source_message_id: "rpc-sessionless-1",
                 session_check: :staging,
                 no_wake: true
               )

      # Re-read AFTER the duplicate answer: the assertion must see the
      # post-retry state, not a pre-duplicate snapshot (review test audit).
      {:ok, after_retry} = SalixAgent.InternalSessionStore.read(rt, router_session)

      assert Enum.count(
               SalixAgent.InternalSession.get(after_retry, :input_queue),
               &(&1["dedupe_key"] == "rpc-sessionless-1")
             ) == 1

      _ = a
    end

    test "delivery events cannot remove an earlier accepted input", %{agent: a} do
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "original work", session_id: @session},
                 source_message_id: "preserve-original",
                 no_wake: true
               )

      {:ok, before} = SalixAgent.InternalSessionStore.read(a, @session)
      before = SalixAgent.InternalSession.export(before)

      assert {:error, :invalid_delivery_events} =
               SalixAgent.deliver(
                 a,
                 %{
                   content: "later work",
                   session_id: @session,
                   events: [%{type: "queue_ack", queue_ack_id: 1}]
                 },
                 source_message_id: "later-delivery",
                 no_wake: true
               )

      {:ok, after_rejection} = SalixAgent.InternalSessionStore.read(a, @session)
      assert SalixAgent.InternalSession.export(after_rejection) == before

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "later work", session_id: @session},
                 source_message_id: "later-delivery",
                 no_wake: true
               )

      {:ok, durable} = SalixAgent.InternalSessionStore.read(a, @session)

      assert Enum.map(SalixAgent.InternalSession.get(durable, :input_queue), fn item ->
               item["payload"]["content"]
             end) == ["original work", "later work"]
    end

    test "a retired External Session id refuses delivery as read-only, with zero writes",
         %{agent: a} do
      # A birth marker an earlier release wrote for an External Session
      # that never stored its state: the id stays retired.
      put_retired_birth_marker!(a, @session)

      assert {:error, :session_read_only} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "retired-marker-1",
                 no_wake: true
               )

      assert {:error, :session_read_only} = SalixAgent.InternalSessionStore.read(a, @session)

      # A stored retired Session without a birth marker: its history is
      # read-only and no internal Session takes its id.
      stored = "ses1_0000000000000000804"
      {:ok, agent} = SalixAgent.Control.get_record(a)
      RetiredSessionFixture.put!(agent, stored)

      assert {:error, :session_read_only} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: stored},
                 source_message_id: "retired-stored-1",
                 no_wake: true
               )

      # The first delivery started the agent's Server but returned before its
      # claim landed. A call to the Server returns after the claim, so
      # prepare_create runs under this node's ownership.
      _ = SalixAgent.Server.info(a)

      assert {:error, :session_read_only} =
               SalixAgent.InternalSessionStore.prepare_create(a, stored)

      assert {:error, :session_read_only} = SalixAgent.InternalSessionStore.read(a, stored)
      assert {:error, :not_found} = SalixAgent.SessionBirth.side(a, stored)

      assert %{rows: rows} =
               SalixStore.Repo.query!(
                 "SELECT birth_kind,revision,control_payload,next_run_at FROM salix_sessions WHERE agent_id=$1 AND session_id=ANY($2)",
                 [a, [@session, stored]]
               )

      assert rows == [["retired", 0, nil, nil], ["retired", 0, nil, nil]]
    end

    test "a fork cannot replace work already accepted at its target",
         %{agent: a} do
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "src", role: "user", session_id: @session},
                 source_message_id: "pr873-fork-src",
                 no_wake: true
               )

      target = "ses1_0000000000000000803"

      assert {:ok, :created} =
               SalixAgent.deliver(
                 a,
                 %{content: "accepted target work", role: "user", session_id: target},
                 source_message_id: "pr873-fork-target",
                 no_wake: true
               )

      {:ok, before} = SalixAgent.InternalSessionStore.read(a, target)

      assert {:error, :fork_target_conflict} =
               SalixAgent.InternalAgentRuntime.fork_session(a, @session, %{
                 "fork_request_id" => "pr873-fork-1",
                 "target_session_id" => target
               })

      assert {:ok, :internal} = SalixAgent.InternalSessionStore.PG.birth(a, target)
      {:ok, state} = SalixAgent.InternalSessionStore.read(a, target)
      assert SalixAgent.InternalSession.export(state) == SalixAgent.InternalSession.export(before)
    end
  end

  # A birth marker an earlier release wrote for an External Session.
  defp put_retired_birth_marker!(agent_id, session_id) do
    assert {:ok, _} =
             SalixStore.S3.put(
               SalixStore.Keys.agent_session_birth(agent_id, session_id),
               Jason.encode!(%{"runtime" => "external"}),
               if_none_match: "*"
             )

    :ok = SalixAgent.InternalSessionStore.PG.import_birth!(agent_id, session_id, :retired)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
