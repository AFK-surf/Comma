defmodule SalixAgent.DeliverIngressTest do
  @moduledoc """
  `SalixAgent.deliver/3` is the single delivery ingress: the source identity
  contract (no manufactured ids) and the per-caller `:session_check`
  declaration live here. The staged inbox/queue/absorb protocol is retired
  (rpc-direct-delivery §3.4): durable truth is the session-ledger commit.

  Ledger-level assertions use `no_wake: true`, which commits durably without
  scheduling a round.
  """
  use ExUnit.Case, async: false

  @session "ses1_0000000000000000801"

  defmodule StubRuntimeEnv do
    @moduledoc false
    # Minimal RuntimeEnvironment so begin_session can mint a capability in
    # the round-9 read_only regression (mirrors ExternalSessionStoreTest).
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"],
         "device_id" => config["device_id"],
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"],
         "device_runtime_id" => config["device_runtime_id"],
         "command" => "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "status" => "ready",
         "connector_run_id" => "test-connector-run",
         "device_runtime_id" => config["device_runtime_id"]
       }}
    end
  end

  defmodule CountingPlacement do
    @moduledoc false
    @behaviour SalixAgent.Placement

    def ensure_started(agent_id, opts) do
      :counters.add(:persistent_term.get({__MODULE__, :counter}), 1, 1)
      SalixAgent.Fleet.ensure_started(agent_id, opts)
    end

    def stop_existing(agent_id, opts), do: SalixAgent.Fleet.stop_existing(agent_id, opts)
  end

  defmodule FlipOncePlacement do
    @moduledoc false
    # Deterministic seam for the same-call runtime-flip race: the facade has
    # already classified the agent internal; placement runs between that read
    # and the stage's own routing read, so flipping here lands the flip
    # EXACTLY inside the race window of one public deliver/3 call.
    @behaviour SalixAgent.Placement

    def ensure_started(agent_id, opts) do
      if :persistent_term.get({__MODULE__, :armed}, false) do
        :persistent_term.put({__MODULE__, :armed}, false)

        {:ok, _} =
          SalixAgent.AgentControl.configure(agent_id, %{
            "runtime_config" => %{
              "kind" => "external",
              "provider" => "codex",
              "device_id" => "test-device",
              "runtime_id" => "test-runtime",
              "device_runtime_id" =>
                SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
            }
          })
      end

      SalixAgent.Fleet.ensure_started(agent_id, opts)
    end

    def stop_existing(agent_id, opts), do: SalixAgent.Fleet.stop_existing(agent_id, opts)
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      # External staging marks the PG-backed session work index; leave no
      # rows behind for suites that assert on the global discovery listing.
      SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{})
    {:ok, agent: agent}
  end

  test "old source-summary retries preserve admitted input across internal and external owner restart",
       %{agent: internal} do
    for {kind, agent_id} <- [{:internal, internal}, {:external, create_external_agent!()}] do
      source_id = "old-source-#{kind}"

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
        case kind do
          :internal ->
            {:ok, state} = SalixAgent.InternalSessionStore.read(agent_id, @session)
            SalixAgent.InternalSession.get(state, :input_queue)

          :external ->
            external_state!(agent_id)["input_message_queue"]
        end
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
  end

  defp create_external_agent! do
    ext = SalixAgent.TestSupport.new_agent_id()

    SalixAgent.TestSupport.create_control_agent!(ext, %{
      "role" => "worker",
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => "test-device",
        "runtime_id" => "test-runtime",
        "device_runtime_id" =>
          SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
      }
    })

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    ext
  end

  defp external_state!(agent_id) do
    key = SalixStore.Keys.agent_external_runtime_session(agent_id, @session)
    {:ok, %{body: body}} = SalixStore.S3.get(key)
    Jason.decode!(body)
  end

  # The staged engine and absorb are retired (§3.4); the "pre-cutover residue"
  # half of the #870 scenario can no longer exist. The surviving guarantee —
  # external same-id redelivery dedupes durably on the state.json ledger — is
  # pinned by "an external-runtime agent delivers via rpc" below.

  test "the direct external-runtime facade acks a same-id retry idempotently" do
    # Review finding: ExternalAgentRuntime.stage_delivery is the runtime-side
    # ingress (Slack direct-router inbound); a duplicate from the store used
    # to escape as a CaseClauseError instead of the facade's success shape.
    ext = create_external_agent!()

    delivery = %{
      source_message_id: "ext-facade-1",
      payload: %{
        "session_id" => @session,
        "role" => "user",
        "content" => "hello",
        "no_wake" => true
      }
    }

    assert {:ok, :external} = SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)
    assert {:ok, :external} = SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)

    state = external_state!(ext)

    assert Enum.count(state["input_message_queue"], &(&1["source_message_id"] == "ext-facade-1")) ==
             1
  end

  test "a committed id keeps acking as duplicate after the runtime binding changes" do
    # Review finding: the ledger lookup is read-only and must answer BEFORE
    # writability — otherwise the response-loss/same-id ack contract breaks
    # the moment the exact external binding rotates.
    ext = create_external_agent!()

    assert {:ok, :created} =
             SalixAgent.deliver(ext, %{content: "x", role: "user", session_id: @session},
               source_message_id: "ext-rebind-1",
               no_wake: true
             )

    {:ok, _} =
      SalixAgent.AgentControl.configure(ext, %{
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "other-device",
          "runtime_id" => "other-runtime",
          "device_runtime_id" =>
            SalixStore.RuntimeIds.device_runtime_id("other-device", "codex", "other-runtime")
        }
      })

    SalixAgent.TestSupport.stop_all_agents()

    assert {:ok, :duplicate} =
             SalixAgent.deliver(ext, %{content: "x", role: "user", session_id: @session},
               source_message_id: "ext-rebind-1",
               no_wake: true
             )

    # A NEW id under the rotated binding is still gated by writability.
    assert {:error, :external_session_read_only} =
             SalixAgent.deliver(ext, %{content: "y", role: "user", session_id: @session},
               source_message_id: "ext-rebind-2",
               no_wake: true
             )

    state = external_state!(ext)

    assert Enum.count(state["input_message_queue"], &(&1["source_message_id"] == "ext-rebind-1")) ==
             1

    refute "ext-rebind-2" in state["input_dedupe"]
  end

  test "a payload-level source id is the canonical ledger fallback on the public facade" do
    # Review round 2, finding 1: the public runtime ingress accepts deliveries
    # whose stable id lives in the payload, not the outer envelope — that
    # shape must hit the same ledger, never bypass it.
    ext = create_external_agent!()

    delivery = %{
      payload: %{
        "session_id" => @session,
        "role" => "user",
        "content" => "hello",
        "no_wake" => true,
        "source_message_id" => "payload-stable-1"
      }
    }

    assert {:ok, :external} = SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)
    assert {:ok, :external} = SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)

    state = external_state!(ext)
    assert "payload-stable-1" in state["input_dedupe"]

    assert Enum.count(
             state["input_message_queue"],
             &(&1["source_message_id"] == "payload-stable-1")
           ) == 1
  end

  test "a delivery with no stable id anywhere is rejected before any write" do
    ext = create_external_agent!()

    delivery = %{
      payload: %{
        "session_id" => @session,
        "role" => "user",
        "content" => "hello",
        "no_wake" => true
      }
    }

    assert {:error, {:bad_request, message}} =
             SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)

    assert message =~ "stable source_message_id"

    assert {:error, {:bad_request, _}} =
             SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)

    # An unledgered append must be impossible: nothing was created at all.
    assert {:error, :not_found} =
             SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(ext, @session))

    assert {:error, :not_found} =
             SalixStore.S3.get(
               SalixStore.Keys.agent_external_runtime_session_status(ext, @session)
             )
  end

  test "the public external session projection never exposes the dedupe ledger" do
    ext = create_external_agent!()

    delivery = %{
      source_message_id: "ext-public-1",
      payload: %{
        "session_id" => @session,
        "role" => "user",
        "content" => "hello",
        "no_wake" => true
      }
    }

    assert {:ok, :external} = SalixAgent.ExternalAgentRuntime.stage_delivery(ext, delivery)

    # The raw state carries the ledger; every public projection must drop it.
    assert "ext-public-1" in external_state!(ext)["input_dedupe"]

    {:ok, session} = SalixAgent.ExternalSessionStore.get_session(ext, @session)
    refute Map.has_key?(session, "input_dedupe")

    assert {:ok, [listed]} = SalixAgent.ExternalSessionStore.list_sessions(ext)
    refute Map.has_key?(listed, "input_dedupe")
  end

  test "a delivery without a source_message_id is rejected before staging", %{agent: a} do
    payload = %{content: "hello", session_id: @session}

    assert {:error, {:bad_request, message}} = SalixAgent.deliver(a, payload, create: false)
    assert message =~ "source_message_id"

    assert {:error, {:bad_request, _}} =
             SalixAgent.deliver(a, payload, create: false, source_message_id: "  ")
  end

  test "a string-keyed payload source_message_id is the dedupe identity", %{agent: a} do
    payload = %{
      "content" => "hello",
      "session_id" => @session,
      "source_message_id" => "src-stable-1"
    }

    assert {:ok, :created} = SalixAgent.deliver(a, payload, create: false, no_wake: true)
    assert {:ok, :duplicate} = SalixAgent.deliver(a, payload, create: false, no_wake: true)

    # rpc is the only path (§3.2 step 4): the identity lives on the session
    # ledger, and no inbox object is ever written.

    {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)

    assert Enum.count(
             SalixAgent.InternalSession.get(state, :input_queue),
             &(&1["dedupe_key"] == "src-stable-1")
           ) == 1
  end

  test "session_check: :staging no longer buys a session-less payload anything on a non-router",
       %{agent: a} do
    # Before §3.2 step 4 the staged path accepted this payload and
    # dead-lettered it at absorb — same loss, silent. The stage now answers
    # truthfully at the facade, with or without the pre-check, and writes
    # nothing anywhere (no inbox object, no session commit).
    payload = %{content: "scheduled prompt", role: "user"}

    assert {:error, :missing_session_id} =
             SalixAgent.deliver(a, payload,
               create: false,
               no_wake: true,
               source_message_id: "src-sched-1"
             )

    assert {:error, :missing_session_id} =
             SalixAgent.deliver(a, payload,
               create: false,
               no_wake: true,
               source_message_id: "src-sched-1",
               session_check: :staging
             )

    assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)
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

  # #928: the schedules sweeper re-attempts a blocked occurrence on every
  # sweep, on every pod, until the target is unarchived. Counting that
  # by-design refusal as "error" made one archived staging agent the entire
  # activation error volume (~5,400/day) and hid every real failure.
  test "a target-state refusal is telemetered as rejected, not error", %{agent: a} do
    assert {:ok, _} = SalixAgent.AgentControl.delete(a)
    outcomes = attach_activation_outcomes()

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.deliver(a, %{content: "tick"},
               create: false,
               no_wake: true,
               source_message_id: "schedule:sch-1:1",
               session_check: :staging
             )

    assert_receive {^outcomes, "rejected"}

    missing = SalixAgent.TestSupport.new_agent_id()

    assert {:error, :not_found} =
             SalixAgent.deliver(missing, %{content: "tick"},
               create: false,
               no_wake: true,
               source_message_id: "schedule:sch-2:1",
               session_check: :staging
             )

    assert_receive {^outcomes, "rejected"}
  end

  test "a delivery that really fails is still telemetered as error", %{agent: a} do
    outcomes = attach_activation_outcomes()

    assert {:error, _reason} =
             SalixAgent.deliver(a, %{content: "tick"},
               create: false,
               no_wake: true,
               session_check: :staging
             )

    assert_receive {^outcomes, "error"}
  end

  # #928 direction 3: the activation `surface` is the caller's own name.
  # `system` is the fallback for "nobody set one", not a label for internal
  # writers — otherwise every sweeper lands in one bucket and localizing a
  # constant error floor takes a live trace instead of a query.
  test "the activation surface is the caller's; system only when nobody set one",
       %{agent: a} do
    surfaces = attach_activation_surfaces()

    assert {:ok, :created} =
             SalixAgent.deliver(a, %{content: "tick", session_id: @session},
               source_message_id: "surface-1",
               no_wake: true,
               surface: "timer"
             )

    assert_receive {^surfaces, "timer"}

    assert {:ok, :created} =
             SalixAgent.deliver(a, %{content: "tick", session_id: @session},
               source_message_id: "surface-2",
               no_wake: true
             )

    assert_receive {^surfaces, "system"}
  end

  defp attach_activation_surfaces do
    handler_id = {__MODULE__, :activation_surfaces, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, _measurements, meta, _config ->
        if meta.operation == "activation",
          do: send(test_pid, {handler_id, meta.surface})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  defp attach_activation_outcomes do
    handler_id = {__MODULE__, :activation_outcomes, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, _measurements, meta, _config ->
        if meta.operation == "activation",
          do: send(test_pid, {handler_id, meta.outcome})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  describe "rpc delivery (A2, docs/salix/conversation-owner-actor.md; the only protocol since §3.2 step 4)" do
    test "a head prefetched before this node's claim does not refuse the delivery that claimed",
         %{agent: a} do
      # The durable head names another node whose lease already expired: the
      # callback ahead of the facade prefetches that observation, placement
      # then claims the agent here, and the owner fence must judge by the
      # head after that claim rather than by the observation before it.
      {:ok, _thief} = SalixStore.Agent.claim(a, "thief", SalixAgent.State, steal: true, ttl_ms: 1)
      Process.sleep(5)

      result =
        SalixStore.ReadScope.run(fn ->
          assert {:ok, %{owner_node: "thief"}} = SalixStore.Agent.peek_in_scope(a)

          SalixAgent.deliver(a, %{content: "takeover", session_id: @session},
            source_message_id: "rpc-takeover-1",
            no_wake: true
          )
        end)

      assert {:ok, :created} = result
      assert {:ok, %{owner_node: owner}} = SalixStore.Agent.peek(a)
      assert owner == to_string(node())
    end

    test "a caller's read still in flight is not waited for inside the delivery budget",
         %{agent: a} do
      started = System.monotonic_time(:millisecond)

      result =
        SalixStore.ReadScope.run(fn ->
          SalixStore.ReadScope.prefetch({:head, a}, fn ->
            Process.sleep(500)
            SalixStore.Agent.peek(a)
          end)

          SalixAgent.deliver(a, %{content: "bounded", session_id: @session},
            source_message_id: "rpc-bounded-1",
            no_wake: true,
            rpc_timeout: 250
          )
        end)

      assert {:ok, :created} = result
      assert System.monotonic_time(:millisecond) - started < 450
    end

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
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 1)
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

    test "internal batch admission refuses all inputs when side events exceed the remaining capacity",
         %{agent: a} do
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 3)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "first", session_id: @session},
                 source_message_id: "batch-first",
                 no_wake: true
               )

      payload = %{
        session_id: @session,
        content: "main",
        pre_deliveries: [%{content: "pre", source_message_id: "batch-pre"}],
        events: [
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "source_message_id" => "batch-side",
            "payload" => %{"content" => "side"}
          }
        ]
      }

      assert {:error, :saturated} =
               SalixAgent.deliver(a, payload, source_message_id: "batch-main", no_wake: true)

      {:ok, session} = SalixAgent.InternalSessionStore.read(a, @session)
      assert SalixAgent.InternalSession.input_queue_length(session) == 1
      refute SalixAgent.InternalSession.input_dedupe_member?(session, "batch-main")
      refute SalixAgent.InternalSession.input_dedupe_member?(session, "batch-pre")
      refute SalixAgent.InternalSession.input_dedupe_member?(session, "batch-side")
    end

    test "a hot provider reply obligation keeps distinct-target admission bounded", %{agent: a} do
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 1)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      target_a = %{
        "provider" => "slack",
        "connect_id" => "connect-1",
        "channel" => "C123",
        "thread_ts" => "1000.000001"
      }

      target_b = %{target_a | "thread_ts" => "1000.000002"}

      assert {:ok, :created} =
               SalixAgent.deliver(
                 a,
                 %{
                   content: "thread A",
                   session_id: @session,
                   provider_reply_obligation: target_a
                 },
                 source_message_id: "obligation-a-1",
                 no_wake: true
               )

      # Move the input from the bounded queue into the independently durable
      # hot obligation map, then restart the owner. Queue-length admission is
      # now empty; only the combined distinct-target bound can reject B.
      SalixAgent.TestSupport.stop_all_agents()
      {:ok, queued} = SalixAgent.InternalSessionStore.read(a, @session)

      {events, false, hwm} =
        SalixAgent.InternalSession.materialize_pending_input_events(queued)

      assert {:ok, hot} =
               SalixAgent.InternalSessionStore.prepare_commit(a, @session, events, hwm: hwm)

      assert SalixAgent.InternalSession.get(hot, :input_queue) == []
      assert SalixAgent.ProviderReplyObligation.pending_count(hot) == 1

      assert {:error, :saturated} =
               SalixAgent.deliver(
                 a,
                 %{
                   content: "thread B",
                   session_id: @session,
                   provider_reply_obligation: target_b
                 },
                 source_message_id: "obligation-b-1",
                 no_wake: true
               )

      {:ok, refused} = SalixAgent.InternalSessionStore.read(a, @session)

      refute MapSet.member?(
               SalixAgent.InternalSession.get(refused, :input_dedupe),
               "obligation-b-1"
             )

      assert SalixAgent.InternalSession.get(refused, :input_queue) == []

      # A second message for the already-counted target coalesces and remains
      # admissible even though the distinct-target capacity is fully used.
      assert {:ok, :created} =
               SalixAgent.deliver(
                 a,
                 %{
                   content: "thread A again",
                   session_id: @session,
                   provider_reply_obligation: target_a
                 },
                 source_message_id: "obligation-a-2",
                 no_wake: true
               )
    end

    test "a failed session commit writes nothing and the same id retries clean", %{agent: a} do
      key = SalixStore.Keys.agent_internal_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

      assert {:error, _reason} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "cas-1",
                 no_wake: true
               )

      # Failure matrix (plan §1.8): a failed commit is all-or-nothing — no
      # ledger entry, so the caller's same-id retry lands as :created, not
      # :duplicate, once the store recovers.
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "cas-1",
                 no_wake: true
               )
    end

    # "pre-cutover inbox residue dedupes against the rpc ledger" retired with
    # the staged engine and absorb (§3.4): residue cannot exist anymore, and
    # same-id ledger dedupe is pinned by the other tests in this describe.

    test "an external-runtime agent delivers via rpc: no inbox write, state-ledger dedupe",
         %{agent: a} do
      # Issue #870 lifted the external exclusion: the state.json ledger and
      # admission commit atomically with the queue append in one CAS, so the
      # rpc ack/retry contract holds on both runtimes.
      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "ext-rpc-1",
                 no_wake: true
               )

      # Direct, not staged: no inbox object; the ledger lives in state.json.

      state = external_state!(ext)
      assert "ext-rpc-1" in state["input_dedupe"]
      assert [item] = state["input_message_queue"]
      assert item["source_message_id"] == "ext-rpc-1"
      assert item["no_wake"] == true

      assert {:ok, :duplicate} =
               SalixAgent.deliver(ext, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "ext-rpc-1",
                 no_wake: true
               )

      assert [_item] = external_state!(ext)["input_message_queue"]
      _ = a
    end

    test "external saturated admission writes nothing; duplicate still wins", %{agent: a} do
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 1)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "one", role: "user", session_id: @session},
                 source_message_id: "ext-sat-1",
                 no_wake: true
               )

      assert {:error, :saturated} =
               SalixAgent.deliver(ext, %{content: "two", role: "user", session_id: @session},
                 source_message_id: "ext-sat-2",
                 no_wake: true
               )

      # Saturated refusal committed nothing: the refused id is absent from
      # the ledger, and the already-committed id keeps acking as duplicate.
      state = external_state!(ext)
      refute "ext-sat-2" in state["input_dedupe"]
      assert [_only] = state["input_message_queue"]

      assert {:ok, :duplicate} =
               SalixAgent.deliver(ext, %{content: "one", role: "user", session_id: @session},
                 source_message_id: "ext-sat-1",
                 no_wake: true
               )

      _ = a
    end

    test "external pre_deliveries count against the admission cap as one batch", %{agent: a} do
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 1)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      ext = create_external_agent!()
      pre = [%{source_message_id: "ext-pre-1", content: "context", role: "user"}]

      assert {:error, :saturated} =
               SalixAgent.deliver(
                 ext,
                 %{content: "main", role: "user", session_id: @session, pre_deliveries: pre},
                 source_message_id: "ext-batch-1",
                 no_wake: true
               )

      # Whole-batch refusal wrote NOTHING: admission for a not-yet-existing
      # session is decided before creation, so neither the state object nor
      # the status object exists (review finding: creating an empty session
      # behind a :saturated answer violated the zero-write guarantee).
      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(ext, @session))

      assert {:error, :not_found} =
               SalixStore.S3.get(
                 SalixStore.Keys.agent_external_runtime_session_status(ext, @session)
               )

      Application.put_env(:salix_agent, :session_input_queue_limit, 2)

      assert {:ok, :created} =
               SalixAgent.deliver(
                 ext,
                 %{content: "main", role: "user", session_id: @session, pre_deliveries: pre},
                 source_message_id: "ext-batch-1",
                 no_wake: true
               )

      assert length(external_state!(ext)["input_message_queue"]) == 2
      _ = a
    end

    test "external response loss: the landed commit answers the same-id retry as duplicate",
         %{agent: a} do
      # The #843 round-3 acceptance scenario, now on the external rpc path:
      # the state CAS lands but the reply is lost to the caller's deadline
      # (ambiguity row, plan §1.8) — the mandated same-id retry must fold
      # into :duplicate on the state ledger, never a second queue item.
      ext = create_external_agent!()
      key = SalixStore.Keys.agent_external_runtime_session(ext, @session)

      # Prime the session object so the delayed PUT below is the delivery CAS.
      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "prime", role: "user", session_id: @session},
                 source_message_id: "ext-loss-0",
                 no_wake: true
               )

      :ok = SalixStore.S3.Fake.set_fault({:delay, 400, :put, key})

      assert {:error, :timeout} =
               SalixAgent.deliver(ext, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "ext-loss-1",
                 no_wake: true,
                 rpc_timeout: 50
               )

      # The abandoned attempt still lands after the delay.
      assert eventually(fn -> "ext-loss-1" in external_state!(ext)["input_dedupe"] end)

      assert {:ok, :duplicate} =
               SalixAgent.deliver(ext, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "ext-loss-1",
                 no_wake: true
               )

      state = external_state!(ext)

      assert Enum.count(state["input_message_queue"], &(&1["source_message_id"] == "ext-loss-1")) ==
               1

      _ = a
    end

    test "a stale owner commits nothing and answers :not_owner", %{agent: a} do
      # Force stale local placement to test the admission fence independently
      # of the cluster placement implementation.
      placement = Application.get_env(:salix_agent, :placement)
      Application.put_env(:salix_agent, :placement, SalixAgent.Placement.LocalFleet)

      on_exit(fn ->
        if placement,
          do: Application.put_env(:salix_agent, :placement, placement),
          else: Application.delete_env(:salix_agent, :placement)
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

    test "the deadline covers the leading control read, not just the stage", %{agent: a} do
      # The re-review measured 716ms against a 100ms budget because the
      # control-plane GET ran before the old deadline started. The budget now
      # wraps the whole chain.
      :ok = SalixStore.S3.Fake.set_fault({:delay, 1_500, :get, SalixStore.Keys.ctl_agent(a)})

      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "ctl-budget-1",
                 no_wake: true,
                 rpc_timeout: 100
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 700
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

    test "a session-less delivery to a role that cannot resolve one answers honestly",
         %{agent: a} do
      # The staged path ACCEPTED this payload and dead-lettered it at absorb
      # (permanent_stage_error :missing_session_id) — same loss, silent. The
      # rpc path answers the truth synchronously and writes nothing. The
      # schedules receiver classifies this as an advancing "undeliverable"
      # occurrence, keeping schedule liveness identical to staged mode.
      assert {:error, :missing_session_id} =
               SalixAgent.deliver(a, %{content: "scheduled prompt", role: "user"},
                 source_message_id: "rpc-sessionless-2",
                 session_check: :staging,
                 no_wake: true
               )

      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      # ZERO side effects means zero: the rejection happens before placement,
      # so the cold agent was neither woken nor claimed (review finding: the
      # old rejection point started a Server and moved the durable head to
      # owner nonode@nohost / epoch 2). The preallocated head stays exactly
      # as agent creation left it: unowned, epoch 1.
      refute SalixAgent.Fleet.running?(a)
      assert {:ok, head} = SalixStore.Agent.peek(a)
      assert head.owner_node == nil
      assert head.epoch == 1
    end

    test "pre_deliveries count against the admission cap as one batch", %{agent: a} do
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 1)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      pre = [%{source_message_id: "pre-1", content: "context", role: "user"}]

      # One call would append 2 entries (the delivery + its pre_delivery)
      # against a cap of 1: refuse the WHOLE batch, write nothing.
      assert {:error, :saturated} =
               SalixAgent.deliver(
                 a,
                 %{content: "main", session_id: @session, pre_deliveries: pre},
                 source_message_id: "batch-1",
                 no_wake: true
               )

      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      # With room for the batch the same call commits both entries.
      Application.put_env(:salix_agent, :session_input_queue_limit, 2)

      assert {:ok, :created} =
               SalixAgent.deliver(
                 a,
                 %{content: "main", session_id: @session, pre_deliveries: pre},
                 source_message_id: "batch-1",
                 no_wake: true
               )

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert length(SalixAgent.InternalSession.get(state, :input_queue)) == 2
    end

    test "one deadline bounds the whole rpc delivery", %{agent: a} do
      key = SalixStore.Keys.agent_internal_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "budget-1",
                 no_wake: true,
                 rpc_timeout: 200
               )

      elapsed = System.monotonic_time(:millisecond) - started
      # The parked commit stalls the actor; the caller's budget, not the
      # inner call chain, decides when the ambiguity row is returned.
      assert elapsed < 2_000
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

    test "payload.events queue_appends count against the cap as the same batch", %{agent: a} do
      prev = Application.get_env(:salix_agent, :session_input_queue_limit)
      Application.put_env(:salix_agent, :session_input_queue_limit, 1)
      on_exit(fn -> restore_env(:salix_agent, :session_input_queue_limit, prev) end)

      extra_event = %{
        "type" => "queue_append",
        "session_id" => @session,
        "kind" => "user_message",
        "wake" => false,
        "dedupe_key" => "extra-1",
        "payload" => %{
          "content" => "extra",
          "role" => "user",
          "source_message_id" => "extra-1"
        }
      }

      # One call would append 2 queue entries (the delivery + the event)
      # against a cap of 1: refuse the WHOLE batch, write nothing.
      assert {:error, :saturated} =
               SalixAgent.deliver(
                 a,
                 %{content: "main", session_id: @session, events: [extra_event]},
                 source_message_id: "main-1",
                 no_wake: true
               )

      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      Application.put_env(:salix_agent, :session_input_queue_limit, 2)

      assert {:ok, :created} =
               SalixAgent.deliver(
                 a,
                 %{content: "main", session_id: @session, events: [extra_event]},
                 source_message_id: "main-1",
                 no_wake: true
               )

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert length(SalixAgent.InternalSession.get(state, :input_queue)) == 2
    end

    test "a permanently stale owner gets exactly two attempts, then :not_owner", %{agent: a} do
      # The bounded re-resolution is 2 attempts total (rpc_stage_attempts/4),
      # observed here by counting placement resolutions while the durable
      # head permanently names another node.
      {:ok, _owned} = SalixStore.Agent.claim(a, "stale-owner@elsewhere", SalixAgent.State)

      counter = :counters.new(1, [])
      prev_placement = Application.get_env(:salix_agent, :placement)
      :persistent_term.put({CountingPlacement, :counter}, counter)
      Application.put_env(:salix_agent, :placement, CountingPlacement)
      on_exit(fn -> restore_env(:salix_agent, :placement, prev_placement) end)

      assert {:error, :not_owner} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "stale-2",
                 no_wake: true
               )

      assert :counters.get(counter, 1) == 2
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)
    end

    test "the direct provider-router payload shape delivers to an EXTERNAL router" do
      # Review round 3: an external ROUTER is a legal control-plane
      # combination, and the direct Slack-router producer used to omit the
      # canonical role — external admission rejected the first-party shape.
      # The producer now sets role: "user" (asserted at the producer boundary
      # in salix_im's provider_test); this is the same shape through the real
      # facade against an external router on the rpc path.
      rt = SalixAgent.TestSupport.new_agent_id()

      SalixAgent.TestSupport.create_control_agent!(rt, %{
        "role" => "router",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "test-device",
          "runtime_id" => "test-runtime",
          "device_runtime_id" =>
            SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
        }
      })

      SalixStore.Repo.query!("TRUNCATE session_work_candidates")
      {:ok, record} = SalixAgent.Control.get_record(rt)
      {:ok, router_session} = SalixStore.RuntimeIds.persisted_router_session_id(record)

      payload = %{
        content: "please help",
        session_id: router_session,
        name: "Bridge chat",
        role: "user"
      }

      assert {:ok, :created} =
               SalixAgent.deliver(rt, payload,
                 source_message_id: "im_provider:slack:conn-1:C1:1.0",
                 kind: "im_provider",
                 create: true,
                 rpc_timeout: 2_500,
                 no_wake: true
               )

      # Exactly one external ledger entry, no inbox.
      key = SalixStore.Keys.agent_external_runtime_session(rt, router_session)
      {:ok, %{body: body}} = SalixStore.S3.get(key)
      state = Jason.decode!(body)
      assert "im_provider:slack:conn-1:C1:1.0" in state["input_dedupe"]
      assert [_one] = state["input_message_queue"]
    end

    test "a wakeable admission-race delivery executes on its session's own runtime",
         %{agent: a} do
      # Runtime-authority ruling (owner 2026-08-15, plan clause 2b): runtime
      # is a property of the SESSION, fixed at its birth; the agent record
      # only places new sessions and powers the best-effort admission fence.
      # The round-4 review's wakeable trace, asserted as SPECIFIED behavior:
      # a delivery that wins the admission race lands in a truthfully
      # internal session and EXECUTES there — no state lies, no work is
      # lost, nothing runs on a runtime its session does not carry
      # (RpcDeliver.tla WakeExecute / ExecutionOnSessionRuntime).
      prev_llm = Application.get_env(:salix_agent, :llm)
      Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
      on_exit(fn -> restore_env(:salix_agent, :llm, prev_llm) end)
      SalixAgent.LLM.Mock.script([{:final, "old-runtime-ran"}])
      key = SalixStore.Keys.agent_internal_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

      task =
        Task.async(fn ->
          SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
            source_message_id: "wake-flip-1"
          )
        end)

      assert eventually(fn -> SalixStore.S3.Fake.paused?() end)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      _ = SalixStore.S3.Fake.release_pause()
      assert {:ok, :created} = Task.await(task, 10_000)

      # The session is truthfully internal and the round ran THERE: the
      # scripted assistant reply lands in the internal session's messages.
      assert eventually(
               fn ->
                 case SalixAgent.InternalSessionStore.read(a, @session) do
                   {:ok, state} ->
                     Enum.any?(SalixAgent.InternalSession.get(state, :messages), fn msg ->
                       msg[:role] == "assistant" and
                         (msg[:content] || "") =~ "old-runtime-ran"
                     end)

                   _ ->
                     false
                 end
               end,
               200
             )

      # Nothing external was fabricated, no inbox detour; the agent record
      # is truthfully external for FUTURE sessions.
      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))

      {:ok, record} = SalixAgent.Control.get_record(a)
      assert SalixAgent.Control.runtime_kind(record) == "external"
    end

    test "a flip AFTER the stage routing read lands in a truthful old-runtime session (no wake)",
         %{agent: a} do
      # The dormant variant of the admission race (owner ruling above): with
      # no_wake the committed copy waits in the truthfully internal session,
      # ledgered and enumerable by the session work projection.
      key = SalixStore.Keys.agent_internal_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

      task =
        Task.async(fn ->
          SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
            source_message_id: "late-flip-1",
            no_wake: true
          )
        end)

      assert eventually(fn -> SalixStore.S3.Fake.paused?() end)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      _ = SalixStore.S3.Fake.release_pause()

      assert {:ok, :created} = Task.await(task, 10_000)

      # The residual, pinned: durable + ledgered in the OLD (internal) store,
      # nothing in the new runtime's store, no inbox.
      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "late-flip-1")

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))
    end

    test "a flip never splits an existing session: later deliveries follow the birth store",
         %{agent: a} do
      # Round 5 P1: routing chose the store from the mutable agent record on
      # EVERY delivery, so after a flip the next ordinary message to an
      # existing internal session fabricated an external session with the
      # same id (source A internal, source B external). Session-grain
      # routing resolves the birth store first; the agent record only
      # places genuinely new sessions.
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-source-a",
                 no_wake: true
               )

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      # An ordinary NEW source id to the same session id, well after the
      # flip: it must continue the internal-born session.
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "b", role: "user", session_id: @session},
                 source_message_id: "pr873-source-b",
                 no_wake: true
               )

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)

      assert MapSet.member?(
               SalixAgent.InternalSession.get(state, :input_dedupe),
               "pr873-source-a"
             )

      assert MapSet.member?(
               SalixAgent.InternalSession.get(state, :input_dedupe),
               "pr873-source-b"
             )

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))

      # The birth store also answers the same-id retry.
      assert {:ok, :duplicate} =
               SalixAgent.deliver(a, %{content: "b", role: "user", session_id: @session},
                 source_message_id: "pr873-source-b",
                 no_wake: true
               )

      # A genuinely NEW session id after the flip is new-session placement:
      # the agent record governs, and it lands external.
      new_session = "ses1_0000000000000000802"

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "c", role: "user", session_id: new_session},
                 source_message_id: "pr873-source-c",
                 no_wake: true
               )

      key = SalixStore.Keys.agent_external_runtime_session(a, new_session)
      {:ok, %{body: body}} = SalixStore.S3.get(key)
      new_state = Jason.decode!(body)
      assert "pr873-source-c" in new_state["input_dedupe"]
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, new_session)
    end

    test "the reverse flip (external -> internal) never fabricates an internal shell" do
      # Symmetric direction of the split above, with the asymmetric comma-31
      # answer: an external-born session stays with its birth store after
      # the agent record flips internal. Committed ids keep acking as
      # duplicates through the state ledger; NEW ids answer the read_only
      # contract (the birth binding is gone) instead of being rerouted into
      # a fabricated internal session with the same id.
      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-rev-a",
                 no_wake: true
               )

      {:ok, _} =
        SalixAgent.AgentControl.configure(ext, %{"runtime_config" => %{"kind" => "internal"}})

      assert {:ok, :duplicate} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-rev-a",
                 no_wake: true
               )

      assert {:error, :external_session_read_only} =
               SalixAgent.deliver(ext, %{content: "b", role: "user", session_id: @session},
                 source_message_id: "pr873-rev-b",
                 no_wake: true
               )

      state = external_state!(ext)
      assert "pr873-rev-a" in state["input_dedupe"]
      refute "pr873-rev-b" in state["input_dedupe"]
      assert [_only] = state["input_message_queue"]
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(ext, @session)
    end

    test "concurrent FIRST deliveries astride a flip land in ONE birth store", %{agent: a} do
      # Round 6 repro: two first deliveries to the same new session id,
      # concurrent with a runtime flip, used to both answer :created with
      # source A internal and source B external — the existence probe and
      # the store create are two objects, so the probe alone cannot close
      # the overlap. The create-once birth marker serializes the birth:
      # A claims :internal before parking on the session PUT; the flip
      # lands; B (classified external) loses the claim and follows the
      # recorded side into the SAME internal session.
      key = SalixStore.Keys.agent_internal_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

      task_a =
        Task.async(fn ->
          SalixAgent.deliver(a, %{content: "a", role: "user", session_id: @session},
            source_message_id: "pr873-birth-a",
            no_wake: true
          )
        end)

      assert eventually(fn -> SalixStore.S3.Fake.paused?() end)
      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, @session)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      task_b =
        Task.async(fn ->
          SalixAgent.deliver(a, %{content: "b", role: "user", session_id: @session},
            source_message_id: "pr873-birth-b",
            no_wake: true
          )
        end)

      _ = SalixStore.S3.Fake.release_pause()

      assert {:ok, :created} = Task.await(task_a, 10_000)
      assert {:ok, :created} = Task.await(task_b, 10_000)

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "pr873-birth-a")
      assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "pr873-birth-b")

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))

      # The birth store also answers the loser's same-id retry.
      assert {:ok, :duplicate} =
               SalixAgent.deliver(a, %{content: "b", role: "user", session_id: @session},
                 source_message_id: "pr873-birth-b",
                 no_wake: true
               )
    end

    test "an internal-side birth marker recovers after a crashed winner and a flip", %{agent: a} do
      # Crash window, internal side: the winner claimed :internal and died
      # before the store create; the agent record has since flipped
      # external. The next delivery loses the claim, follows the marker,
      # and CREATES the internal session there — the internal runtime is
      # always executable, so an internal-side birth is always
      # recoverable.
      assert {:ok, :internal} = SalixAgent.SessionBirth.claim(a, @session, :internal)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "pr873-crash-int-1",
                 no_wake: true
               )

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)

      assert MapSet.member?(
               SalixAgent.InternalSession.get(state, :input_dedupe),
               "pr873-crash-int-1"
             )

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))
    end

    test "an external-side birth marker whose binding left answers read_only, never an internal shell",
         %{agent: a} do
      # Crash window, external side: the winner claimed :external and died
      # before creating the session; the agent record is internal. The
      # binding that would execute this session is gone and the session
      # was never born — the delivery answers the comma-31 read_only family
      # with zero writes, instead of fabricating a same-id internal
      # session (the split the marker exists to prevent).
      assert {:ok, :external} = SalixAgent.SessionBirth.claim(a, @session, :external)

      assert {:error, :external_session_read_only} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "pr873-crash-ext-1",
                 no_wake: true
               )

      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))
    end

    test "a transient probe error NEVER re-births a legacy markerless session", %{agent: a} do
      # Round 7 P1: exists? collapsed every HEAD error into "absent", so a
      # pre-marker (markerless) internal session + one transient 503 on its
      # HEAD after a flip read as :new — the code claimed an EXTERNAL
      # marker and created a same-id external session. Fail-closed birth:
      # :new requires BOTH stores to CONFIRM not-found; a probe error
      # refuses the delivery with zero writes and the same-id retry
      # resolves it.
      {:ok, _} =
        SalixAgent.InternalSessionStore.prepare_commit(a, @session, [
          %{"type" => "session_created", "session_id" => @session, "platform" => "raft"}
        ])

      # Since round 8 every store-layer creation claims a marker; a LEGACY
      # pre-deploy session has none — simulate it by removing the marker
      # the seeding just wrote.
      :ok = SalixStore.S3.delete(SalixStore.Keys.agent_session_birth(a, @session))
      assert {:error, :not_found} = SalixAgent.SessionBirth.side(a, @session)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      internal_key = SalixStore.Keys.agent_internal_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :head, internal_key})

      assert {:error, {:unavailable, {:session_probe, {:http, 503}}}} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "pr873-probe-1",
                 no_wake: true
               )

      # Zero writes anywhere: no external session, no marker, the internal
      # ledger untouched.
      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))

      assert {:error, :not_found} = SalixAgent.SessionBirth.side(a, @session)
      {:ok, before_retry} = SalixAgent.InternalSessionStore.read(a, @session)

      refute MapSet.member?(
               SalixAgent.InternalSession.get(before_retry, :input_dedupe),
               "pr873-probe-1"
             )

      # The one-shot fault is consumed: the same-id retry probes cleanly,
      # finds the birth store, and continues the legacy session there —
      # still without ever creating a marker for it.
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "pr873-probe-1",
                 no_wake: true
               )

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "pr873-probe-1")
      assert {:error, :not_found} = SalixAgent.SessionBirth.side(a, @session)

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))
    end

    test "an external-side probe error also fails closed before any birth claim", %{agent: a} do
      # The symmetric branch: the internal probe confirms absence but the
      # EXTERNAL probe errors — a genuinely new session must not be placed
      # on a guess either.
      external_key = SalixStore.Keys.agent_external_runtime_session(a, @session)
      :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :head, external_key})

      assert {:error, {:unavailable, {:session_probe, {:http, 503}}}} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "pr873-probe-2",
                 no_wake: true
               )

      assert {:error, :not_found} = SalixAgent.SessionBirth.side(a, @session)
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      # Retry after the transient fault: both probes confirm, the birth
      # proceeds normally on the agent's (internal) side with its marker.
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "pr873-probe-2",
                 no_wake: true
               )

      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, @session)
      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)
      assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "pr873-probe-2")
    end

    test "the direct external-runtime facade cannot fabricate an external session for an internal-born id",
         %{agent: a} do
      # Round 8 bypass 1: ExternalAgentRuntime.stage_delivery reached the
      # external store without SessionDelivery's routing, so an
      # internal-born id gained a same-id external state after a flip. The
      # store-layer birth claim now refuses the create; the facade answers
      # its established {:ok, :internal} contract — deliver internally.
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-facade-a",
                 no_wake: true
               )

      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, @session)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      delivery = %{
        source_message_id: "pr873-facade-b",
        payload: %{
          "session_id" => @session,
          "role" => "user",
          "content" => "b",
          "no_wake" => true
        }
      }

      assert {:ok, :internal} = SalixAgent.ExternalAgentRuntime.stage_delivery(a, delivery)

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))

      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, @session)

      {:ok, state} = SalixAgent.InternalSessionStore.read(a, @session)

      refute MapSet.member?(
               SalixAgent.InternalSession.get(state, :input_dedupe),
               "pr873-facade-b"
             )
    end

    test "a fork target racing a flip converges on ONE store via the store-layer claim",
         %{agent: a} do
      # Round 8 bypass 2: fork seeded its internal target without any birth
      # claim; a delivery racing the parked seed claimed an EXTERNAL marker
      # off the flipped agent record and created the same id externally —
      # both public calls succeeded, both stores held the id. The seed now
      # claims the marker BEFORE its create-once write, so the racing
      # delivery loses the claim and joins the internal side.
      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "src", role: "user", session_id: @session},
                 source_message_id: "pr873-fork-src",
                 no_wake: true
               )

      target = "ses1_0000000000000000803"
      target_key = SalixStore.Keys.agent_internal_runtime_session(a, target)
      :ok = SalixStore.S3.Fake.set_fault({:pause, :put, target_key})

      task_fork =
        Task.async(fn ->
          SalixAgent.InternalAgentRuntime.fork_session(a, @session, %{
            "fork_request_id" => "pr873-fork-1",
            "target_session_id" => target
          })
        end)

      assert eventually(fn -> SalixStore.S3.Fake.paused?() end)
      # The fork claimed the target's birth BEFORE parking on the create.
      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, target)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      # An ordinary delivery to the fork target while the seed is parked:
      # it loses the birth claim to :internal and lands internally. It must
      # run async — the internal path queues behind the agent actor the
      # parked fork is holding — and the pause is released once the put_log
      # shows the delivery's losing marker-claim attempt (the Fake logs
      # precondition-rejected puts too).
      marker_key = SalixStore.Keys.agent_session_birth(a, target)
      claims_before = Enum.count(SalixStore.S3.Fake.put_log(), &(&1 == marker_key))

      task_deliver =
        Task.async(fn ->
          SalixAgent.deliver(a, %{content: "x", role: "user", session_id: target},
            source_message_id: "pr873-fork-race-1",
            no_wake: true
          )
        end)

      assert eventually(fn ->
               Enum.count(SalixStore.S3.Fake.put_log(), &(&1 == marker_key)) > claims_before
             end)

      _ = SalixStore.S3.Fake.release_pause()
      fork_result = Task.await(task_fork, 10_000)
      assert {:ok, :created} = Task.await(task_deliver, 10_000)

      # The fork either completed or truthfully reports the target already
      # materialized (the racing delivery created it first) — never a
      # second store.
      assert match?({:ok, _}, fork_result) or match?({:error, :exists}, fork_result)

      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, target)
      {:ok, state} = SalixAgent.InternalSessionStore.read(a, target)

      assert MapSet.member?(
               SalixAgent.InternalSession.get(state, :input_dedupe),
               "pr873-fork-race-1"
             )

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, target))
    end

    test "a MARKERLESS legacy internal session survives the direct external ingress", %{agent: a} do
      # Round 9 P1-1: the store guard consulted only the marker, and for the
      # pre-deploy markerless population absence is not authority — the
      # direct ingress could claim :external and split the legacy session.
      # An unmarked create now reconciles the OPPOSITE store first
      # (tri-state, fail-closed) and backfills the truthful marker.
      {:ok, _} =
        SalixAgent.InternalSessionStore.prepare_commit(a, @session, [
          %{"type" => "session_created", "session_id" => @session, "platform" => "raft"}
        ])

      :ok = SalixStore.S3.delete(SalixStore.Keys.agent_session_birth(a, @session))
      assert {:error, :not_found} = SalixAgent.SessionBirth.side(a, @session)

      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      delivery = %{
        source_message_id: "pr873-legacy-direct-1",
        payload: %{
          "session_id" => @session,
          "role" => "user",
          "content" => "x",
          "no_wake" => true
        }
      }

      assert {:ok, :internal} = SalixAgent.ExternalAgentRuntime.stage_delivery(a, delivery)

      assert {:error, :not_found} =
               SalixStore.S3.get(SalixStore.Keys.agent_external_runtime_session(a, @session))

      # The reconcile backfilled the legacy session's truthful marker.
      assert {:ok, :internal} = SalixAgent.SessionBirth.side(a, @session)
    end

    test "a MARKERLESS legacy external session survives a direct internal creator" do
      # The symmetric direction: a pre-deploy external session with no
      # marker, hit by a direct internal creator (prepare_create — the
      # fork/seed/commit family shares the same guard).
      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-legacy-ext-a",
                 no_wake: true
               )

      :ok = SalixStore.S3.delete(SalixStore.Keys.agent_session_birth(ext, @session))
      assert {:error, :not_found} = SalixAgent.SessionBirth.side(ext, @session)

      assert {:error, :session_born_external} =
               SalixAgent.InternalSessionStore.prepare_create(ext, @session)

      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(ext, @session)
      assert {:ok, :external} = SalixAgent.SessionBirth.side(ext, @session)
    end

    test "a minted capability does not admit NEW input after the binding leaves" do
      # Round 9 P1-2: ensure_writable's capability escape let a rebound
      # session keep accepting new ids. New-input admission is now a strict
      # binding check — after the flip only committed ids ack (as
      # duplicates); a new id answers read_only. The capability keeps
      # serving in-flight lifecycle work only.
      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-cap-a",
                 no_wake: true
               )

      prev_env = Application.get_env(:salix_agent, :runtime_environment_mod)
      Application.put_env(:salix_agent, :runtime_environment_mod, StubRuntimeEnv)
      on_exit(fn -> restore_env(:salix_agent, :runtime_environment_mod, prev_env) end)

      {:ok, agent_rec} = SalixAgent.AgentControl.get_record(ext)
      {:ok, pid} = SalixAgent.ExternalSessionFleet.ensure_started(ext, @session)

      assert {:ok, binding} =
               SalixAgent.ExternalSessionActor.begin_session(
                 pid,
                 agent_rec["tenant_id"],
                 agent_rec["runtime_config"]
               )

      assert is_binary(binding["runtime_capability"]["token"])
      state = external_state!(ext)
      assert is_binary(state["runtime_capability_token_hash"])

      {:ok, _} =
        SalixAgent.AgentControl.configure(ext, %{"runtime_config" => %{"kind" => "internal"}})

      assert {:error, :external_session_read_only} =
               SalixAgent.deliver(ext, %{content: "b", role: "user", session_id: @session},
                 source_message_id: "pr873-cap-b",
                 no_wake: true
               )

      assert {:ok, :duplicate} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-cap-a",
                 no_wake: true
               )

      state = external_state!(ext)
      assert "pr873-cap-a" in state["input_dedupe"]
      refute "pr873-cap-b" in state["input_dedupe"]
    end

    test "an in-flight wait still settles after the binding leaves, while new input refuses" do
      # Round-9b self-audit: external wait_timeout entries also flow through
      # stage_delivery, so the strict NEW-INPUT rule would have refused them
      # too — stranding a wait this session itself armed and leaving the
      # session waiting forever. Admission is decided by what the delivery
      # IS: a wait_timeout follows the lifecycle contract, everything else
      # the strict new-input contract.
      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-wait-a",
                 no_wake: true
               )

      # An ACTIVE session: capability minted, i.e. the state whose
      # wait_timeout the pre-round-9 code admitted and round-9 broke.
      prev_env = Application.get_env(:salix_agent, :runtime_environment_mod)
      Application.put_env(:salix_agent, :runtime_environment_mod, StubRuntimeEnv)
      on_exit(fn -> restore_env(:salix_agent, :runtime_environment_mod, prev_env) end)

      {:ok, agent_rec} = SalixAgent.AgentControl.get_record(ext)
      {:ok, pid} = SalixAgent.ExternalSessionFleet.ensure_started(ext, @session)

      assert {:ok, _binding} =
               SalixAgent.ExternalSessionActor.begin_session(
                 pid,
                 agent_rec["tenant_id"],
                 agent_rec["runtime_config"]
               )

      wait = %{
        "wait_id" => "wait-round9b",
        "reason" => "user_input",
        "deadline_ms" => System.system_time(:millisecond) + 60_000
      }

      key = SalixStore.Keys.agent_external_runtime_session(ext, @session)
      {:ok, %{body: body}} = SalixStore.S3.get(key)
      state = Jason.decode!(body)
      {:ok, _} = SalixStore.S3.put(key, Jason.encode!(Map.put(state, "wait", wait)), [])

      {:ok, _} =
        SalixAgent.AgentControl.configure(ext, %{"runtime_config" => %{"kind" => "internal"}})

      SalixAgent.TestSupport.stop_all_agents()

      {:ok, delivery} = SalixAgent.Waits.timeout_delivery(@session, wait)

      assert {:ok, :committed} =
               SalixAgent.ExternalSessionFleet.stage_wait_timeout(ext, @session, delivery, [])

      # ...while genuinely NEW input to the same abandoned session refuses.
      assert {:error, :external_session_read_only} =
               SalixAgent.deliver(ext, %{content: "b", role: "user", session_id: @session},
                 source_message_id: "pr873-wait-new",
                 no_wake: true
               )

      settled = external_state!(ext)
      # Durable proof of admission that survives a queue drain: the ledger.
      assert SalixAgent.Waits.timeout_source_message_id(@session, wait) in settled["input_dedupe"]
      refute "pr873-wait-new" in settled["input_dedupe"]
    end

    test "a refused internal birth leaves zero work-index residue" do
      # Round 10 blocker 1: the commit path synced the PG work index BEFORE
      # write_state's birth claim could refuse, leaking permanent recovery
      # candidates the sweep kept retaining as unproven. The claim now runs
      # at the creation decision point (read_or_new_for_update), before any
      # Postgres write.
      ext = create_external_agent!()

      assert {:ok, :created} =
               SalixAgent.deliver(ext, %{content: "a", role: "user", session_id: @session},
                 source_message_id: "pr873-residue-a",
                 no_wake: true
               )

      assert {:ok, :external} = SalixAgent.SessionBirth.side(ext, @session)

      assert {:error, :session_born_external} =
               SalixAgent.InternalSessionStore.prepare_commit(ext, @session, [
                 %{"type" => "session_created", "session_id" => @session, "platform" => "raft"},
                 %{
                   "type" => "delivery",
                   "from_queue" => true,
                   "session_id" => @session,
                   "message_id" => 1,
                   "content" => "leak probe"
                 }
               ])

      assert {:error, :session_born_external} =
               SalixAgent.InternalSessionStore.prepare_create(ext, @session)

      # Zero internal store writes AND zero PG recovery-candidate rows.
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(ext, @session)

      %{rows: rows} =
        SalixStore.Repo.query!(
          "SELECT candidate_token FROM session_work_candidates WHERE session_id = $1 AND runtime_kind = 'internal'",
          [@session]
        )

      assert rows == []
    end

    test "a same-call runtime flip reclassifies inside the deadline: no inbox, one ledgered commit",
         %{agent: a} do
      # Review round 2, finding 2: the refusal used to detour through the
      # staged inbox, acking at inbox durability — the widened contract's
      # AckImpliesDurable counterexample. The facade now re-classifies ONCE
      # inside the same deadline; the retry lands on the (ledgered) external
      # rpc path. The FlipOncePlacement seam flips the runtime exactly
      # between the facade's control read and the stage's routing read, in
      # ONE public deliver/3 call.
      prev_placement = Application.get_env(:salix_agent, :placement)
      :persistent_term.put({FlipOncePlacement, :armed}, true)
      Application.put_env(:salix_agent, :placement, FlipOncePlacement)

      on_exit(fn ->
        :persistent_term.erase({FlipOncePlacement, :armed})
        restore_env(:salix_agent, :placement, prev_placement)
      end)

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "same-call-flip-1",
                 no_wake: true
               )

      # No inbox detour, no internal commit: the single durable copy lives in
      # the external store with its ledger entry.
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)

      state = external_state!(a)
      assert "same-call-flip-1" in state["input_dedupe"]
      assert [item] = state["input_message_queue"]
      assert item["source_message_id"] == "same-call-flip-1"

      assert {:ok, :duplicate} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "same-call-flip-1",
                 no_wake: true
               )

      assert [_only] = external_state!(a)["input_message_queue"]
    end

    test "a runtime flip between classification and stage refuses, never writes external",
         %{agent: a} do
      # Owner-reproduced race: the facade classifies the agent internal, the
      # runtime flips to external before the stage, and the stage's own
      # routing read used to send the rpc entry into the ledgerless external
      # store — a same-id retry then duplicated. The boundary is now enforced
      # AT that routing read: an internal-only entry refuses instead.
      entry = %{
        source_message_id: "flip-1",
        payload: %{content: "x", session_id: @session, no_wake: true, kind: "user"},
        require_runtime: :internal
      }

      # Flip AFTER classification would have happened: this test enters at
      # the stage boundary, which IS the race window.
      {:ok, _} =
        SalixAgent.AgentControl.configure(a, %{
          "runtime_config" => %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "test-device",
            "runtime_id" => "test-runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
          }
        })

      assert {:error, :runtime_changed} =
               SalixAgent.AgentActor.stage_rpc_delivery(a, entry, timeout: 5_000, create: true)

      # Zero writes anywhere: no internal session, no inbox, and the retry
      # through the public facade reclassifies as external — since #870 that
      # takes the external rpc path with its own state-ledger dedupe.
      assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, @session)
      SalixStore.Repo.query!("TRUNCATE session_work_candidates")

      assert {:ok, :created} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "flip-1",
                 no_wake: true
               )

      assert {:ok, :duplicate} =
               SalixAgent.deliver(a, %{content: "x", role: "user", session_id: @session},
                 source_message_id: "flip-1",
                 no_wake: true
               )

      state = external_state!(a)
      assert "flip-1" in state["input_dedupe"]
      assert [_item] = state["input_message_queue"]
    end

    test "archived agents and missing ids are rejected before any RPC", %{agent: a} do
      assert {:error, {:bad_request, "source_message_id is required"}} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session})

      assert {:ok, _} = SalixAgent.AgentControl.delete(a)

      assert {:error, {:bad_request, "agent is archived"}} =
               SalixAgent.deliver(a, %{content: "x", session_id: @session},
                 source_message_id: "rpc-archived-1"
               )
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
