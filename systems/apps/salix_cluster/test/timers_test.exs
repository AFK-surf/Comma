defmodule SalixCluster.TimersTest do
  @moduledoc """
  The timers singleton: durable one-shot timer notifications fire
  from bucket-indexed markers, delivering a synthetic wake through the touch →
  inbox → marker pipeline, and clearing the timer marker only after the
  delivery is durable. Run against the Fake with injected clocks.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.{S3, Ids, Keys}
  alias SalixStore.S3.Fake
  alias SalixStore.Timers, as: StoreTimers
  alias SalixCluster.Timers

  # Fixed clock for deterministic bucket math (no sleeping on wall time).
  @t0 1_750_000_000_000

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_placement = SystemsRuntime.get_env(:salix_agent, :placement)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    # rpc delivery (the only protocol since plan §3.2 step 4) stages through
    # the owner actor, so the real placement must be able to start one. The
    # durable observable is the session ledger, which no consumer erases —
    # the old "a fast owner eats the staged inbox before assertion" hazard
    # died with the staged path.
    start_supervised!(Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)

    {:ok, agent: agent, session: Ids.new_session_id()}
  end

  describe "fire_due/1 — due deadlines" do
    test "a past-bucket deadline delivers one synthetic wake and clears the marker; refire is idempotent",
         %{agent: a, session: s} do
      deadline = @t0 - 120_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-1")
      :ok = register_wait_timer(a, s, "wait-1", deadline, %{"reason" => "compile"})

      assert {:ok, [fired]} = Timers.fire_due(now: @t0)

      assert %{agent: ^a, session: ^s, timer_id: "wait-1", bucket: ^bucket, status: :created} =
               fired

      assert fired.source_message_id == "wait-timeout:#{s}:wait-1"

      # rpc staging: durable truth is the session ledger; the staged inbox
      # protocol is never touched (no inbox object, no queue marker).

      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-1")

      # The committed queue item carries the expired wait as a runtime
      # message: the timer wake the agent actually sees.
      assert [item] = state.input_queue
      assert item["dedupe_key"] == "wait-timeout:#{s}:wait-1"
      assert item["kind"] == "runtime_message"
      assert item["wake"] == true
      assert item["payload"]["type"] == "wait_expired"
      assert item["payload"]["wait_id"] == "wait-1"

      # Timer marker cleared — only reachable after the delivery succeeded.
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-1", bucket))

      # Re-running is idempotent: the marker is gone, so nothing re-fires and
      # the ledger still holds exactly one entry for the id.
      assert {:ok, []} = Timers.fire_due(now: @t0)
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-1")
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-1", bucket))
    end

    test "stale and current wait ids in one bucket both settle; only the armed wait commits",
         %{agent: a, session: s} do
      deadline = @t0 - 1_000
      bucket = StoreTimers.minute_bucket(deadline)

      # One session holds ONE armed wait. "wait-b" is the live one; "wait-a"
      # is a stale timer from a superseded wait — delivering it is a no-op
      # (the stage answers :ignored) but its marker must still settle, or the
      # sweep re-fires it forever.
      arm_session_wait!(a, s, "wait-b")
      :ok = register_wait_timer(a, s, "wait-a", deadline, %{"reason" => "first"})
      :ok = register_wait_timer(a, s, "wait-b", deadline, %{"reason" => "second"})

      assert {:ok, fired} = Timers.fire_due(now: @t0)

      assert Enum.sort(Enum.map(fired, & &1.source_message_id)) == [
               "wait-timeout:#{s}:wait-a",
               "wait-timeout:#{s}:wait-b"
             ]

      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-b")
      refute MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-a")
      assert [%{"payload" => %{"wait_id" => "wait-b"}}] = state.input_queue

      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-a", bucket))
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-b", bucket))
    end
  end

  describe "fire_due/1 — future deadlines" do
    test "a deadline in a future bucket does not fire", %{agent: a, session: s} do
      deadline = @t0 + 120_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-future")
      :ok = register_wait_timer(a, s, "wait-future", deadline)

      assert {:ok, []} = Timers.fire_due(now: @t0)

      # No delivery happened, and the marker is still armed.
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      refute MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-future")
      assert {:ok, _} = S3.head(Keys.timer(a, s, "wait-future", bucket))

      # Once the clock passes the deadline's bucket, it fires.
      assert {:ok, [%{bucket: ^bucket}]} = Timers.fire_due(now: @t0 + 180_000)
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-future")
    end
  end

  describe "catch_up/1 — buckets behind the firing window" do
    test "a bucket the firing tick can no longer reach still fires and settles",
         %{agent: a, session: s} do
      deadline = @t0 - 10 * 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-stranded")
      :ok = register_wait_timer(a, s, "wait-stranded", deadline)

      # #758: the firing window has passed this bucket, and no later firing
      # pass will ever look at it again.
      assert {:ok, []} = Timers.fire_due(now: @t0)
      assert {:ok, _} = S3.head(Keys.timer(a, s, "wait-stranded", bucket))

      assert {:ok, %{fired: [fired]}} = Timers.catch_up(now: @t0)
      assert %{bucket: ^bucket, timer_id: "wait-stranded", status: :created} = fired

      # Fired late, but fired: the same synthetic wake the firing tick commits.
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-stranded")
      assert [%{"payload" => %{"wait_id" => "wait-stranded"}}] = state.input_queue
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-stranded", bucket))

      # And the object is gone for good, which is the other half of #758.
      assert {:ok, %{fired: []}} = Timers.catch_up(now: @t0)
    end
  end

  describe "catch_up/1 — fairness across a backlog" do
  end

  describe "fire_due/1 — delivery failure" do
    test "a failed inbox PUT leaves the timer marker armed for retry", %{agent: a, session: s} do
      deadline = @t0 - 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-failure")
      :ok = register_wait_timer(a, s, "wait-failure", deadline)

      # Fail the rpc delivery at its first store touch: the session-grain
      # birth probe (HEAD on the internal session key). A probe error is
      # never absence (fail-closed, #871 round 7), so the delivery refuses
      # and the sweep must leave the marker armed.
      session_key = Keys.agent_internal_runtime_session(a, s)
      :ok = Fake.blackhole({:fail, 503, :head, session_key})

      assert {:ok, []} = Timers.fire_due(now: @t0)

      # Nothing committed, timer marker still in place.
      assert {:ok, _} = S3.head(Keys.timer(a, s, "wait-failure", bucket))

      # Outage over: the next pass refires with the SAME source id and only
      # then clears the marker.
      :ok = Fake.clear_blackhole()
      assert {:ok, [fired]} = Timers.fire_due(now: @t0)
      assert fired.source_message_id == "wait-timeout:#{s}:wait-failure"

      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-failure")
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-failure", bucket))
    end
  end

  describe "location deadlines" do
    test "expires the tool after its session wait was cleared", ctx do
      request = location_request!(ctx, SystemsClock.system_time(:second) - 1)
      assert {:ok, [_]} = Timers.fire_due()
      assert_location_terminal(ctx, "failed")
      assert {:ok, %{"status" => "expired"}} = location_record(request)

      assert {:error, {:conflict, :already_settled}} =
               SalixAgent.CapabilityRequests.share_location(
                 request["group_id"],
                 request["request_id"],
                 %{"status" => "success", "location" => %{"latitude" => 1, "longitude" => 2}},
                 request["tenant_id"]
               )

      assert_location_terminal(ctx, "failed")
    end

    test "a deadline retry preserves a location response that won before expiry", ctx do
      request = location_request!(ctx, SystemsClock.system_time(:second) + 60)
      response = %{"status" => "success", "location" => %{"latitude" => 1, "longitude" => 2}}

      assert {:ok, %{"status" => "completed"}} =
               SalixAgent.CapabilityRequests.share_location(
                 request["group_id"],
                 request["request_id"],
                 response,
                 request["tenant_id"]
               )

      assert {:ok, [_]} = Timers.fire_due(now: request["expires_at"] * 1000)
      assert_location_terminal(ctx, "completed")
      assert {:ok, %{"response_payload" => ^response}} = location_record(request)
    end
  end

  defp location_request!(ctx, deadline) do
    seed_location_call!(ctx, deadline)
    {:ok, request} = create_location_request(ctx, deadline)
    request
  end

  defp seed_location_call!(ctx, deadline) do
    {:ok, _} =
      SalixAgent.InternalSessionStore.prepare_commit(ctx.agent, ctx.session, [
        %{"type" => "session_created", "session_id" => ctx.session},
        %{
          "type" => "async_tool_call_started",
          "session_id" => ctx.session,
          "tool_call_id" => "location-call",
          "tool_name" => "location.request",
          "status" => "running",
          "completion_mode" => "external_callback",
          "completion_owner" => "direct_poll",
          "started_at" => (deadline - 120) * 1000
        }
      ])

    :ok
  end

  defp create_location_request(ctx, deadline) do
    SalixAgent.CapabilityRequests.create_capability_request(%{
      "source_agent_id" => ctx.agent,
      "source_session_id" => ctx.session,
      "tool_call_id" => "location-call",
      "request_type" => "location",
      "request_payload" => %{"location" => %{"reason" => "test location"}},
      "expires_at" => deadline
    })
  end

  defp location_record(request) do
    SalixAgent.CapabilityRequests.get(
      request["group_id"],
      request["request_id"],
      request["tenant_id"]
    )
  end

  defp assert_location_terminal(ctx, status) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(ctx.agent, ctx.session)
    state = SalixAgent.InternalSession.export(session)
    refute state.async_tool_calls["location-call"]["status"] == "running"

    assert Enum.any?(
             state.async_results,
             &(&1["tool_call_id"] == "location-call" and &1["status"] == status)
           )

    # Result publication can precede request synchronization. The indexed
    # recovery path must retire that terminal projection without new input.
    assert %{failed: 0} = SalixAgent.SessionWorkRecovery.sweep()

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(ctx.agent, ctx.session)

             not Map.has_key?(
               SalixAgent.InternalSession.get(session, :async_tool_calls),
               "location-call"
             )
           end)
  end

  defp eventually(fun, retries \\ 1500) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp arm_session_wait!(agent, session, wait_id) do
    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent, session, [
        %{"type" => "session_created", "session_id" => session},
        %{
          "type" => "wait_set",
          "session_id" => session,
          "wait" => %{"wait_id" => wait_id, "reason" => "test wait"}
        }
      ])

    :ok
  end

  defp register_wait_timer(agent, session, wait_id, deadline, extra \\ %{}) do
    wait =
      %{
        "wait_id" => wait_id,
        "reason" => "timer test",
        "timeout_seconds" => 60,
        "deadline_ms" => deadline,
        "source" => "wait_for"
      }
      |> Map.merge(extra)

    StoreTimers.register(%{
      "timer_id" => wait_id,
      "kind" => "wait_timeout",
      "agent_id" => agent,
      "session_id" => session,
      "deadline_ms" => deadline,
      "source_message_id" => "wait-timeout:#{session}:#{wait_id}",
      "payload" => %{
        content: SalixAgent.Waits.timeout_content(wait),
        session_id: session,
        kind: "wait_timeout",
        type: "wait_expired",
        wait_id: wait_id,
        wait: wait
      }
    })
  end

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
