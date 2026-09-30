defmodule SalixCluster.TimersTest do
  @moduledoc """
  The timers singleton: durable one-shot timer notifications fire
  from bucket-indexed markers, delivering a synthetic wake through the touch →
  inbox → marker pipeline, and clearing the timer marker only after the
  delivery is durable. Run against the Fake with injected clocks.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{S3, Ids, Keys}
  alias SalixStore.S3.Fake
  alias SalixStore.Timers, as: StoreTimers
  alias SalixCluster.Timers

  # Fixed clock for deterministic bucket math (no sleeping on wall time).
  @t0 1_750_000_000_000

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_placement = Application.get_env(:salix_agent, :placement)
    Application.put_env(:salix_store, :s3_backend, Fake)
    # rpc delivery (the only protocol since plan §3.2 step 4) stages through
    # the owner actor, so the real placement must be able to start one. The
    # durable observable is the session ledger, which no consumer erases —
    # the old "a fast owner eats the staged inbox before assertion" hazard
    # died with the staged path.
    start_supervised!(Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)

    {:ok, agent: agent, session: Ids.new_session_id()}
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

  describe "fire_due/1 — due deadlines" do
    # #928 direction 3: the sweeper names its own activation surface instead
    # of falling through to `system` (see SchedulesTest for the twin).
    test "a fired wake activates under the timer surface", %{agent: a, session: s} do
      surfaces = attach_activation_surfaces()
      deadline = @t0 - 120_000
      arm_session_wait!(a, s, "wait-surface")
      :ok = register_wait_timer(a, s, "wait-surface", deadline, %{"reason" => "compile"})

      assert {:ok, [_fired]} = Timers.fire_due(now: @t0)
      assert_receive {^surfaces, "timer"}
    end

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

    test "buckets older than the lookback window need an explicit wider lookback",
         %{agent: a, session: s} do
      deadline = @t0 - 10 * 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      :ok = register_wait_timer(a, s, "wait-old", deadline)

      # Default lookback (5 minutes) does not reach a 10-minute-old bucket.
      assert {:ok, []} = Timers.fire_due(now: @t0)
      assert {:ok, _} = S3.head(Keys.timer(a, s, "wait-old", bucket))

      # A wider sweep fires it — as does `catch_up/1`, which needs no caller to
      # know how far back to look (see its own describe block below).
      assert {:ok, [%{bucket: ^bucket}]} = Timers.fire_due(now: @t0, lookback_minutes: 15)
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-old", bucket))
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

    test "a bucket still inside the firing window is left to the firing tick",
         %{agent: a, session: s} do
      deadline = @t0 - 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-live")
      :ok = register_wait_timer(a, s, "wait-live", deadline)

      # The two passes partition the buckets between them: nothing the firing
      # tick still owns is delivered twice.
      assert {:ok, %{fired: []}} = Timers.catch_up(now: @t0)
      assert {:ok, _} = S3.head(Keys.timer(a, s, "wait-live", bucket))

      assert {:ok, [%{bucket: ^bucket}]} = Timers.fire_due(now: @t0)
    end

    test "a future bucket is never taken", %{agent: a, session: s} do
      deadline = @t0 + 120_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-future")
      :ok = register_wait_timer(a, s, "wait-future", deadline)

      assert {:ok, %{fired: [], next: nil}} = Timers.catch_up(now: @t0)
      assert {:ok, _} = S3.head(Keys.timer(a, s, "wait-future", bucket))

      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      refute MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-future")
    end

    test "one pass takes a bounded number of buckets, oldest first, and the next resumes",
         %{agent: a, session: s} do
      oldest = @t0 - 30 * 60_000
      middle = @t0 - 20 * 60_000
      newest = @t0 - 10 * 60_000

      arm_session_wait!(a, s, "wait-newest")

      for {wait_id, deadline} <- [
            {"wait-oldest", oldest},
            {"wait-middle", middle},
            {"wait-newest", newest}
          ] do
        :ok = register_wait_timer(a, s, wait_id, deadline)
      end

      assert {:ok, %{fired: fired, next: cursor}} = Timers.catch_up(now: @t0, max_buckets: 2)

      assert Enum.map(fired, & &1.timer_id) == ["wait-oldest", "wait-middle"]

      assert Enum.map(fired, & &1.bucket) == [
               StoreTimers.minute_bucket(oldest),
               StoreTimers.minute_bucket(middle)
             ]

      # The bucket this pass did not take is still armed, not lost.
      assert {:ok, _} =
               S3.head(Keys.timer(a, s, "wait-newest", StoreTimers.minute_bucket(newest)))

      assert {:ok, %{fired: [%{timer_id: "wait-newest"}]}} =
               Timers.catch_up(now: @t0, max_buckets: 2, after: cursor)

      # Only the armed wait commits; the two superseded ids settle their
      # markers without touching session state (same contract as the firing
      # tick).
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, s)
      assert MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-newest")
      refute MapSet.member?(state.input_dedupe, "wait-timeout:#{s}:wait-oldest")

      assert {:ok, %{fired: []}} = Timers.catch_up(now: @t0)
    end
  end

  describe "catch_up/1 — fairness across a backlog" do
    test "a full pass of undrainable buckets does not starve the healthy bucket behind them",
         %{agent: a, session: s} do
      # A marker whose clear fails stays armed on purpose, so its bucket never
      # empties. Fill one whole pass with such buckets: taking the oldest N
      # every time would mean the pass never reaches anything behind them.
      stuck =
        for minutes <- 31..40 do
          deadline = @t0 - minutes * 60_000
          wait_id = "wait-stuck-#{minutes}"
          :ok = register_wait_timer(a, s, wait_id, deadline)

          bucket = StoreTimers.minute_bucket(deadline)
          :ok = Fake.blackhole({:fail, 503, :delete, {:prefix, Keys.timer_minute_prefix(bucket)}})

          {wait_id, bucket}
        end

      healthy_deadline = @t0 - 20 * 60_000
      healthy_bucket = StoreTimers.minute_bucket(healthy_deadline)
      arm_session_wait!(a, s, "wait-healthy")
      :ok = register_wait_timer(a, s, "wait-healthy", healthy_deadline)

      assert length(stuck) == 10

      {fired_ids, _cursor} =
        Enum.reduce(1..3, {[], nil}, fn _, {acc, cursor} ->
          assert {:ok, %{fired: fired, next: next}} = Timers.catch_up(now: @t0, after: cursor)
          {acc ++ Enum.map(fired, & &1.timer_id), next}
        end)

      assert "wait-healthy" in fired_ids
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-healthy", healthy_bucket))

      # The undrainable buckets are still there — retained, not lost, exactly
      # as a failed clear should be.
      for {wait_id, bucket} <- stuck do
        assert {:ok, _} = S3.head(Keys.timer(a, s, wait_id, bucket))
      end
    end

    test "the cursor wraps, so an undrainable bucket is retried rather than skipped forever",
         %{agent: a, session: s} do
      deadline = @t0 - 31 * 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      arm_session_wait!(a, s, "wait-retry")
      :ok = register_wait_timer(a, s, "wait-retry", deadline)
      :ok = Fake.blackhole({:fail, 503, :delete, {:prefix, Keys.timer_minute_prefix(bucket)}})

      assert {:ok, %{fired: [_], next: cursor}} = Timers.catch_up(now: @t0)
      assert is_binary(cursor)

      # Nothing behind it: the pass wraps instead of parking past the backlog.
      assert {:ok, %{fired: [], next: nil}} = Timers.catch_up(now: @t0, after: cursor)

      # Clears work again; the wrapped pass settles the marker it skipped.
      :ok = Fake.clear_blackhole()
      assert {:ok, %{fired: [%{timer_id: "wait-retry"}], next: _}} = Timers.catch_up(now: @t0)
      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-retry", bucket))
    end

    test "one pass delivers a bounded number of markers, not a whole bucket",
         %{agent: a, session: s} do
      deadline = @t0 - 30 * 60_000
      bucket = StoreTimers.minute_bucket(deadline)

      for index <- 1..6 do
        :ok = register_wait_timer(a, s, "wait-bulk-#{index}", deadline)
      end

      assert {:ok, %{fired: fired}} = Timers.catch_up(now: @t0, max_markers: 2)
      assert length(fired) == 2

      assert {:ok, %{objects: remaining}} =
               S3.list(Keys.timer_minute_prefix(bucket), [])

      assert length(remaining) == 4
    end
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

    # Behavior inverted by #839: this used to assert the marker stayed armed.
    # It cannot pay off — the sweep's lookback window closes long before an
    # unarchive, so the marker was only ever a leak (staging carried two for
    # 36 days) plus one failed delivery per tick while its bucket was live.
    test "an archived agent settles the timer marker without staging delivery", %{
      agent: a,
      session: s
    } do
      prev_group_context = Application.get_env(:salix_agent, :group_context_mod)

      on_exit(fn ->
        if prev_group_context do
          Application.put_env(:salix_agent, :group_context_mod, prev_group_context)
        else
          Application.delete_env(:salix_agent, :group_context_mod)
        end
      end)

      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, _archived} = SalixAgent.Control.delete(a)

      deadline = @t0 - 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      :ok = register_wait_timer(a, s, "wait-archived", deadline)

      assert {:ok, []} = Timers.fire_due(now: @t0)

      assert {:error, :not_found} = S3.head(Keys.timer(a, s, "wait-archived", bucket))

      # And it stays gone: no second attempt, nothing left to sweep.
      assert {:ok, []} = Timers.fire_due(now: @t0)
    end

    test "a target with no control record settles the timer marker", %{session: s} do
      missing = SalixAgent.TestSupport.new_agent_id()
      deadline = @t0 - 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      :ok = register_wait_timer(missing, s, "wait-missing", deadline)

      assert {:ok, []} = Timers.fire_due(now: @t0)

      assert {:error, :not_found} = S3.head(Keys.timer(missing, s, "wait-missing", bucket))
    end

    test "a marker whose settle fails stays armed for the next pass", %{agent: a, session: s} do
      SalixAgent.TestSupport.create_control_agent!(a)
      assert {:ok, _archived} = SalixAgent.Control.delete(a)

      deadline = @t0 - 60_000
      bucket = StoreTimers.minute_bucket(deadline)
      :ok = register_wait_timer(a, s, "wait-clear-fails", deadline)

      timer_key = Keys.timer(a, s, "wait-clear-fails", bucket)
      :ok = Fake.blackhole({:fail, 503, :delete, timer_key})

      assert {:ok, []} = Timers.fire_due(now: @t0)
      assert {:ok, _} = S3.head(timer_key)

      # Outage over: the next pass reaches the same terminal branch and
      # settles it, without ever staging a delivery.
      :ok = Fake.clear_blackhole()
      assert {:ok, []} = Timers.fire_due(now: @t0)
      assert {:error, :not_found} = S3.head(timer_key)
    end
  end

  describe "location deadlines" do
    test "expires the tool after its session wait was cleared", ctx do
      request = location_request!(ctx, System.system_time(:second) - 1)
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

    test "retains a deadline that fires before async-call admission", ctx do
      {:ok, request} = create_location_request(ctx, System.system_time(:second) - 1)
      assert {:ok, []} = Timers.fire_due()
      bucket = StoreTimers.minute_bucket(request["expires_at"] * 1000)
      assert {:ok, [_]} = StoreTimers.sweep(bucket)

      seed_location_call!(ctx, request["expires_at"])
      assert {:ok, [_]} = Timers.fire_due()
      assert_location_terminal(ctx, "failed")
    end

    test "retains a deadline while its agent is archived", ctx do
      request = location_request!(ctx, System.system_time(:second) - 1)
      assert {:ok, _} = SalixAgent.Control.delete(ctx.agent)
      assert {:ok, []} = Timers.fire_due()
      bucket = StoreTimers.minute_bucket(request["expires_at"] * 1000)
      assert {:ok, [_]} = StoreTimers.sweep(bucket)

      assert {:ok, _} = SalixAgent.Control.unarchive(ctx.agent, request["tenant_id"])
      assert {:ok, [_]} = Timers.fire_due()
      assert_location_terminal(ctx, "failed")
    end

    test "retains a timeout until the session accepts its terminal result", ctx do
      request = location_request!(ctx, System.system_time(:second) - 1)
      key = Keys.agent_internal_runtime_session(ctx.agent, ctx.session)
      :ok = Fake.blackhole({:fail, 503, :get, key})
      assert {:ok, []} = Timers.fire_due()

      assert {:ok, %{"status" => "expired", "result" => %{"status" => "failed"} = result}} =
               location_record(request)

      assert {:ok, [_]} =
               StoreTimers.sweep(StoreTimers.minute_bucket(request["expires_at"] * 1000))

      :ok = Fake.clear_blackhole()
      assert {:ok, [_]} = Timers.fire_due()
      assert_location_terminal(ctx, "failed")
      assert {:ok, %{"result" => ^result}} = location_record(request)
      assert {:ok, []} = Timers.fire_due()
    end

    test "a deadline retry preserves a location response that won before expiry", ctx do
      request = location_request!(ctx, System.system_time(:second) + 60)
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

    test "retires the deadline after execution failure has settled the request", ctx do
      request = location_request!(ctx, System.system_time(:second) + 60)

      result = %{
        "status" => "failed",
        "error" => true,
        "content" => "Location provider unavailable",
        "error_class" => "location_unavailable"
      }

      assert {:ok, %{"status" => "failed", "result" => ^result}} =
               SalixAgent.CapabilityRequests.reconcile_capability_request(
                 ctx.agent,
                 ctx.session,
                 "location-call",
                 result
               )

      key = Keys.agent_internal_runtime_session(ctx.agent, ctx.session)
      :ok = Fake.blackhole({:fail, 503, :get, key})
      assert {:ok, []} = Timers.fire_due(now: request["expires_at"] * 1000)
      assert {:ok, %{"status" => "failed", "result" => ^result}} = location_record(request)

      timer_key =
        Keys.timer(
          ctx.agent,
          ctx.session,
          "location-timeout:" <> request["request_id"],
          StoreTimers.minute_bucket(request["expires_at"] * 1000)
        )

      assert {:ok, _} = S3.head(timer_key)

      :ok = Fake.clear_blackhole()
      assert {:ok, [_]} = Timers.fire_due(now: request["expires_at"] * 1000)
      assert_location_terminal(ctx, "failed")
      assert {:ok, %{"result" => ^result}} = location_record(request)
      assert {:ok, []} = Timers.fire_due(now: request["expires_at"] * 1000)

      assert {:error, {:conflict, :already_settled}} =
               SalixAgent.CapabilityRequests.share_location(
                 request["group_id"],
                 request["request_id"],
                 %{"status" => "success", "location" => %{"latitude" => 1, "longitude" => 2}},
                 request["tenant_id"]
               )

      assert {:ok, %{"status" => "failed", "result" => ^result}} = location_record(request)
    end

    test "does not accept a running request if its durable timer cannot be registered", ctx do
      deadline = System.system_time(:second) + 60
      prefix = Keys.timer_minute_prefix(StoreTimers.minute_bucket(deadline * 1000))
      :ok = Fake.blackhole({:fail, 503, :put, {:prefix, prefix}})
      assert {:error, _} = create_location_request(ctx, deadline)
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

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
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

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
