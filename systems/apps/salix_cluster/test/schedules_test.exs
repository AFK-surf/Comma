defmodule SalixCluster.SchedulesTest do
  @moduledoc """
  Schedules use CAS definitions, deterministic due
  math under clock injection, and create-once run claims giving exactly one
  delivery per `(schedule_id, scheduled_for)` by key construction. Run against
  the Fake backend. Since plan §3.2 step 4, rpc is the only delivery protocol:
  a fire stages straight into the owner-routed role actor, so the real
  placement starts the owner and firings are observed at the durable layers —
  run objects plus the internal session ledger (`input_dedupe` /
  `input_queue`); the staged inbox protocol is never touched.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Ids, Keys}
  alias SalixCluster.Schedules
  alias SalixStore.ScheduleRuns

  @t0 1_750_000_000_000
  @five_min 5 * 60_000

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_schedule_sink = Application.get_env(:salix_cluster, :schedule_diagnostic_sink)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.delete_env(:salix_cluster, :schedule_diagnostic_sink)
    start_supervised!(SalixStore.S3.Fake)

    # Schedules live in the node-global control Postgres now, which no
    # S3.Fake.reset can clear — every file expecting a clean slate truncates.
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      restore_env(:salix_cluster, :schedule_diagnostic_sink, prev_schedule_sink)
    end)

    # Delivery now goes through the SalixAgent.deliver ingress, which reads
    # the control record, so the target agent must exist on the control plane.
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{})

    {:ok, id: Ids.new_schedule_id(), agent: agent}
  end

  defp params(agent),
    do: %{
      agent_id: agent,
      session_id: "ses1_1200000000000000001",
      interval_minutes: 5,
      prompt: "do the thing"
    }

  defp run_objects(id), do: ScheduleRuns.list_for(id)

  # Archive by writing the control record directly, bypassing
  # AgentControl.delete/1 and therefore the pause-on-archive hook (#849):
  # the S3-written / Postgres-not-yet-paused gap, or an agent archived before
  # the hook existed. Only the blocked backstop stands between such a
  # definition and the sweeper.
  defp archive_record_directly!(agent_id) do
    key = SalixStore.Keys.ctl_agent(agent_id)
    {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)
    archived = body |> Jason.decode!() |> Map.put("archived_at", @t0)
    {:ok, _} = SalixStore.S3.put(key, Jason.encode!(archived), if_match: etag)
    :ok
  end

  defp capture_schedule_diagnostics do
    parent = self()

    Application.put_env(:salix_cluster, :schedule_diagnostic_sink, fn diagnostic ->
      send(parent, {:schedule_diagnostic, diagnostic})
    end)
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "definition CRUD" do
    test "create/get/update/delete round-trip; create is create-once", %{id: id, agent: a} do
      assert {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      assert sched["id"] == id
      assert sched["agent_id"] == a
      assert sched["interval_minutes"] == 5
      assert sched["created_at"] == @t0
      assert sched["last_run"] == nil

      assert {:ok, ^sched} = Schedules.get(id)

      # create-once: same id 412s
      assert {:error, :already_exists} = Schedules.create(id, params(a), now: @t0 + 1)

      # update via CAS merges changes, preserves id
      assert {:ok, updated} = Schedules.update(id, %{prompt: "new prompt", interval_minutes: 10})
      assert updated["prompt"] == "new prompt"
      assert updated["interval_minutes"] == 10
      assert updated["id"] == id
      assert {:ok, ^updated} = Schedules.get(id)

      assert {:ok, scheds} = Schedules.list()
      assert Enum.any?(scheds, &(&1["id"] == id))

      assert :ok = Schedules.delete(id)
      assert {:error, :not_found} = Schedules.get(id)
      # idempotent delete
      assert :ok = Schedules.delete(id)
      assert {:error, :not_found} = Schedules.update(id, %{prompt: "x"})
    end

    test "create rejects a Task definition carrying an agent_id", %{id: id, agent: a} do
      assert {:error, :invalid_schedule} =
               Schedules.create(
                 id,
                 %{
                   receiver: "task",
                   agent_id: a,
                   payload: %{agent_group_id: "grp_b", conversation_id: "conv_b"},
                   interval_minutes: 5
                 },
                 now: @t0
               )
    end

    test "create accepts only the bounded Triage follow-up receiver payload", %{id: id, agent: a} do
      run_at = @t0 + 90_000

      assert {:ok, schedule} =
               Schedules.create(
                 id,
                 %{
                   receiver: "triage_follow_up",
                   payload: %{
                     entry_id: "triage-context-entry-1",
                     authority_generation: "01M199TRIAGEFOLLOWUP000000"
                   },
                   run_at: run_at
                 },
                 now: @t0
               )

      assert schedule["receiver"] == "triage_follow_up"

      assert schedule["payload"] == %{
               "entry_id" => "triage-context-entry-1",
               "authority_generation" => "01M199TRIAGEFOLLOWUP000000"
             }

      assert {:error, :invalid_schedule} =
               Schedules.create(
                 Ids.new_schedule_id(),
                 %{
                   receiver: "triage_follow_up",
                   agent_id: a,
                   payload: schedule["payload"],
                   run_at: run_at
                 },
                 now: @t0
               )

      assert {:error, :invalid_schedule} =
               Schedules.create(
                 Ids.new_schedule_id(),
                 %{
                   receiver: "triage_follow_up",
                   payload: Map.put(schedule["payload"], "prompt", "private execution seam"),
                   run_at: run_at
                 },
                 now: @t0
               )
    end

    test "create rejects malformed params", %{id: id, agent: a} do
      assert {:error, :invalid_schedule} =
               Schedules.create(id, %{agent_id: a, prompt: "p", interval_minutes: 0}, now: @t0)

      assert {:error, :invalid_schedule} =
               Schedules.create(id, %{agent_id: a, interval_minutes: 5}, now: @t0)

      assert {:error, :invalid_schedule} =
               Schedules.create(
                 id,
                 %{agent_id: a, prompt: "p", cron: "0 9 * * *", run_at: @t0 + 60_000},
                 now: @t0
               )

      assert {:error, :invalid_schedule} =
               Schedules.create(
                 id,
                 %{agent_id: a, prompt: "p", interval_minutes: 5, run_at: @t0 + 60_000},
                 now: @t0
               )
    end
  end

  describe "due/1 math" do
    test "next fire is (last_run || created_at) + interval; boundary inclusive", %{
      id: id,
      agent: a
    } do
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)

      assert Schedules.next_fire_ms(sched) == @t0 + @five_min

      assert {:ok, []} = Schedules.due(@t0)
      assert {:ok, []} = Schedules.due(@t0 + @five_min - 1)
      assert {:ok, [due]} = Schedules.due(@t0 + @five_min)
      assert due["id"] == id

      # after a run, the anchor moves to last_run
      {:ok, _} = Schedules.update(id, %{last_run: @t0 + @five_min})
      assert {:ok, []} = Schedules.due(@t0 + @five_min)
      assert {:ok, []} = Schedules.due(@t0 + 2 * @five_min - 1)
      assert {:ok, [_]} = Schedules.due(@t0 + 2 * @five_min)
    end

    test "one-shot run_at fires once and removes its definition after delivery", %{
      id: id,
      agent: a
    } do
      run_at = @t0 + 90_000

      assert {:ok, sched} =
               Schedules.create(
                 id,
                 %{
                   agent_id: a,
                   session_id: "ses1_1200000000000000001",
                   run_at: run_at,
                   prompt: "meeting"
                 },
                 now: @t0
               )

      assert Schedules.next_fire_ms(sched) == run_at
      assert {:ok, []} = Schedules.due(run_at - 1)
      assert {:ok, [%{"id" => ^id}]} = Schedules.due(run_at)
      assert {:ok, %{fired: [^id], already_fired: []}} = Schedules.run_once(now: run_at)
      assert {:error, :not_found} = Schedules.get(id)
      assert {:ok, %{fired: [], already_fired: []}} = Schedules.run_once(now: run_at + 1)

      assert {:ok, runs} = run_objects(id)
      assert length(runs) == 1

      # rpc delivery: the durable exactly-once record is the session ledger's
      # dedupe entry, not a staged inbox object.
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{run_at}")
    end
  end

  describe "fire/3 exactly-once claim" do
    test "run_once reports partial execution and schedule enumeration failures", %{
      id: id,
      agent: a
    } do
      handler = {__MODULE__, self()}

      :ok =
        :telemetry.attach(
          handler,
          [:salix, :operation, :stop],
          fn event, measurements, metadata, pid ->
            if metadata[:component] == "salix_cluster" and metadata[:operation] == "schedule" do
              send(pid, {event, measurements, metadata})
            end
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      due = Schedules.next_fire_ms(sched)

      # Fail the rpc delivery at its first store touch: the session-grain
      # birth probe (HEAD on the internal session key). A probe error is
      # never absence (fail-closed), so the delivery refuses and the fire
      # reports the failure without advancing.
      session_key = Keys.agent_internal_runtime_session(a, "ses1_1200000000000000001")
      :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :head, session_key})

      assert {:ok, %{failed: [{^id, {:unavailable, {:session_probe, {:http, 503}}}}]}} =
               Schedules.run_once(now: due)

      :ok = SalixStore.S3.Fake.clear_blackhole()

      assert_receive {[:salix, :operation, :stop], %{duration: duration}, %{outcome: "error"}}
      assert duration >= 0

      # Candidate enumeration failure (control Postgres down) fails the sweep
      # closed rather than reporting an empty pass.
      SalixStore.Repo.query!("ALTER TABLE schedules RENAME TO schedules_tmp")
      on_exit(fn -> SalixStore.Repo.query!("ALTER TABLE schedules_tmp RENAME TO schedules") end)

      assert {:error, :unavailable} = Schedules.run_once(now: due)

      assert_receive {[:salix, :operation, :stop], %{duration: duration}, %{outcome: "error"}}
      assert duration >= 0
    end

    test "two concurrent fires for the same (id, scheduled_for) deliver exactly once",
         %{id: id, agent: a} do
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      scheduled_for = Schedules.next_fire_ms(sched)

      results =
        [sched, sched]
        |> Task.async_stream(
          fn s -> Schedules.fire(s, scheduled_for, now: scheduled_for) end,
          max_concurrency: 2,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.sort(results) == [{:ok, :already_fired}, {:ok, :fired}]

      # exactly one run object claimed the window
      assert {:ok, [_]} = run_objects(id)

      # exactly one delivery committed into the session ledger, carrying the
      # schedule payload. The dedupe entry is durable forever; the payload is
      # either still queued or already consumed into the transcript by the
      # woken round — exactly one copy across both, never two.
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{scheduled_for}")

      queued = Enum.count(state.input_queue, &(&1["payload"]["content"] == "do the thing"))
      absorbed = Enum.count(state.messages, &(&1.content == "do the thing"))
      assert queued + absorbed == 1

      # rpc staging never touches the staged inbox protocol; the winner
      # advanced last_run by CAS
      assert {:ok, after_fire} = Schedules.get(id)
      assert after_fire["last_run"] == scheduled_for
    end

    test "refire after the interval claims a NEW run object", %{id: id, agent: a} do
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)

      t1 = @t0 + @five_min
      assert {:ok, %{fired: [^id], already_fired: []}} = Schedules.run_once(now: t1)

      # the same window cannot fire twice, even from a stale definition
      assert {:ok, :already_fired} = Schedules.fire(sched, t1, now: t1)
      # and the sweep finds nothing due until the next window
      assert {:ok, %{fired: [], already_fired: []}} = Schedules.run_once(now: t1)

      t2 = t1 + @five_min
      assert {:ok, %{fired: [^id], already_fired: []}} = Schedules.run_once(now: t2)

      # different scheduled_for ⇒ second run object, second ledger entry
      assert {:ok, runs} = run_objects(id)
      assert length(runs) == 2
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t1}")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t2}")

      assert {:ok, after_runs} = Schedules.get(id)
      assert after_runs["last_run"] == t2
    end

    # The legacy "ambiguous claim PUT (landed, response lost)" scenario has no
    # PG counterpart: an insert-once claim either lands, conflicts, or errors —
    # there is no lost-response outcome to resolve. Concurrent-claim semantics
    # are covered by "two concurrent fires ... deliver exactly once" above.

    # #928 direction 3: the sweeper names its own activation surface, so its
    # volume — including a blocked occurrence re-attempted every sweep — is
    # one query away instead of hiding in the `system` fallback.
    test "a fired occurrence activates under the schedule surface", %{id: id, agent: a} do
      surfaces = attach_activation_surfaces()
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      t1 = Schedules.next_fire_ms(sched)

      assert {:ok, :fired} = Schedules.fire(sched, t1, now: t1)
      assert_receive {^surfaces, "schedule"}
    end

    test "delivery failures emit schedule diagnostics without prompt content", %{
      id: id,
      agent: a
    } do
      capture_schedule_diagnostics()

      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      t1 = Schedules.next_fire_ms(sched)

      # Fail the rpc delivery at its first store touch (the fail-closed
      # session birth probe) so the fire surfaces a delivery failure.
      session_key = Keys.agent_internal_runtime_session(a, "ses1_1200000000000000001")
      :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :head, session_key})

      assert {:error, {:unavailable, {:session_probe, {:http, 503}}}} =
               Schedules.fire(sched, t1,
                 now: t1,
                 request_id: "req-schedule-fire",
                 client_request_id: "client-schedule-fire",
                 invocation_id: "inv-schedule-fire"
               )

      :ok = SalixStore.S3.Fake.clear_blackhole()

      assert_receive {:schedule_diagnostic, diagnostic}
      assert diagnostic.status == "failed"
      assert diagnostic.event_type == "schedule.fire.failed"
      assert diagnostic.severity == "error"
      assert diagnostic.reason_class == "unavailable"
      assert diagnostic.stage == "receiver"
      assert diagnostic.schedule_id == id
      assert diagnostic.agent_id == a
      assert diagnostic.correlation_id == "req-schedule-fire"
      assert diagnostic.request_id == "req-schedule-fire"
      assert diagnostic.client_request_id == "client-schedule-fire"
      assert diagnostic.invocation_id == "inv-schedule-fire"
      refute inspect(diagnostic) =~ "do the thing"
    end

    test "without a configured diagnostic sink a delivery failure is still logged", %{
      id: id,
      agent: a
    } do
      # Setup leaves :schedule_diagnostic_sink unset; the logging floor must
      # keep the loss visible instead of silently returning :ok.
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      t1 = Schedules.next_fire_ms(sched)

      # Same first-store-touch failure as above: the fail-closed session
      # birth probe refuses the rpc delivery.
      session_key = Keys.agent_internal_runtime_session(a, "ses1_1200000000000000001")
      :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :head, session_key})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:unavailable, {:session_probe, {:http, 503}}}} =
                   Schedules.fire(sched, t1, now: t1)
        end)

      :ok = SalixStore.S3.Fake.clear_blackhole()

      assert log =~ "schedule dispatch failed"
      assert log =~ id
      refute log =~ "do the thing"
    end

    # Archival is recoverable (AgentControl.unarchive/2), so an archived
    # target must neither delete the schedule nor spam failures: the fire is
    # BLOCKED — definition, claimed window, and anchor all preserved — and
    # after unarchive the same stable-id occurrence delivers exactly once,
    # only then advancing (ScheduleDispatch.tla receiver-ACK-before-advance).
    # #849: "an archived agent's schedules do not fire" is a lifecycle
    # invariant — archive pauses them (they leave the due scan), unarchive
    # resumes exactly those — instead of a blocked re-attempt rediscovered on
    # every sweep, on every pod, for as long as the agent stays archived.
    test "archiving the target pauses its schedules; unarchive resumes and delivers", %{
      id: id,
      agent: a
    } do
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      t1 = Schedules.next_fire_ms(sched)
      {:ok, rec} = SalixAgent.AgentControl.get(a)
      tenant_id = rec["tenant_id"]
      {:ok, _} = SalixAgent.AgentControl.delete(a)

      # Paused at the lifecycle, marked as archive-paused, gone from the due
      # scan: the sweep neither fires nor blocks it.
      assert {:ok, %{"status" => "paused", "paused_by" => "archive"}} = Schedules.get(id)
      assert {:ok, %{fired: [], blocked: [], failed: []}} = Schedules.run_once(now: t1 + 1)

      assert {:error, :not_found} =
               SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")

      # Unarchive resumes it; the preserved window delivers its stable id
      # once and the anchor advances past it.
      assert {:ok, _} = SalixAgent.AgentControl.unarchive(a, tenant_id)
      assert {:ok, %{"status" => "active"} = resumed} = Schedules.get(id)
      refute Map.has_key?(resumed, "paused_by")
      assert {:ok, %{fired: [^id], blocked: [], failed: []}} = Schedules.run_once(now: t1 + 1)
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t1}")
      assert {:ok, %{fired: [], blocked: [], failed: []}} = Schedules.run_once(now: t1 + 1)

      # Hygiene: schedules are node-global Postgres rows; do not leak an
      # active definition into later test files.
      :ok = Schedules.delete(id)
    end

    test "a schedule the user paused before the archive stays paused after unarchive", %{
      id: id,
      agent: a
    } do
      {:ok, _} = Schedules.create(id, params(a), now: @t0)
      {:ok, _} = SalixStore.Schedules.set_status(id, "paused")
      {:ok, rec} = SalixAgent.AgentControl.get(a)
      {:ok, _} = SalixAgent.AgentControl.delete(a)

      assert {:ok, %{"status" => "paused"} = paused} = Schedules.get(id)
      refute Map.has_key?(paused, "paused_by")

      assert {:ok, _} = SalixAgent.AgentControl.unarchive(a, rec["tenant_id"])
      assert {:ok, %{"status" => "paused"}} = Schedules.get(id)

      :ok = Schedules.delete(id)
    end

    # The archive record (S3) and the pause (Postgres) are not one write. A
    # definition the pause never reached — the gap, or an agent archived
    # before the pause existed — is still caught at fire time: blocked, not
    # failed, nothing deleted, re-attempted until unarchive or the
    # archived-schedule sweep. #840's semantics, now as the backstop.
    test "an archive the pause never reached still blocks at fire time (backstop)", %{
      id: id,
      agent: a
    } do
      capture_schedule_diagnostics()
      {:ok, sched} = Schedules.create(id, params(a), now: @t0)
      t1 = Schedules.next_fire_ms(sched)

      :ok = archive_record_directly!(a)

      assert {:ok, :blocked} = Schedules.fire(sched, t1, now: t1)
      assert_receive {:schedule_diagnostic, diagnostic}
      assert diagnostic.status == "blocked"
      assert diagnostic.reason_class == "archived"
      assert {:ok, %{"status" => "active"}} = Schedules.get(id)
      assert {:ok, %{blocked: [^id], fired: [], failed: []}} = Schedules.run_once(now: t1 + 1)

      :ok = Schedules.delete(id)
    end

    # #871: in :rpc mode a session-less delivery to a role that cannot
    # resolve one answers {:error, :missing_session_id} synchronously. For a
    # schedule that is a DEFINITION defect, not a transient failure — the
    # fire must advance with a visible diagnostic. Blocking would re-attempt
    # the same occurrence forever; the staged path reached the same loss
    # silently (the absorbed entry dead-lettered).
    test "a session-less fire at a non-router target advances as undeliverable in :rpc mode",
         %{id: id, agent: a} do
      capture_schedule_diagnostics()
      {:ok, sched} = Schedules.create(id, Map.delete(params(a), :session_id), now: @t0)
      t1 = Schedules.next_fire_ms(sched)

      assert {:ok, :undeliverable} = Schedules.fire(sched, t1, now: t1)

      assert_receive {:schedule_diagnostic, diagnostic}
      assert diagnostic.status == "undeliverable"
      assert diagnostic.event_type == "schedule.fire.undeliverable"
      assert diagnostic.severity == "warning"
      assert diagnostic.reason_class == "missing_session_id"
      assert diagnostic.schedule_id == id

      # The durable run claim tells the truth BEFORE the anchor moved
      # (AdvanceRequiresDurableOutcome): disposition is terminal
      # "undeliverable", never a clean "dispatch".
      assert {:ok, :undeliverable} = ScheduleRuns.disposition(id, t1)
      assert {:ok, [run]} = run_objects(id)
      assert run["disposition"] == "undeliverable"

      # And the PUBLIC run history projects it truthfully — never a clean
      # "dispatched" with no error (the review repro).
      {:ok, agent_rec} = SalixAgent.AgentControl.get_record(a)

      assert {:ok, [public_run]} =
               SalixAgent.Schedules.list_runs(a, id, agent_rec["tenant_id"])

      assert public_run["status"] == "undeliverable"
      assert public_run["error"] =~ "cannot resolve"

      # No delivery reached the agent, and the anchor ADVANCED: the next
      # sweep does not re-attempt this occurrence (liveness identical to the
      # staged path's silent dead-letter, minus the silence).
      assert {:ok, sched_after} = Schedules.get(id)
      assert sched_after["last_run"] == t1

      assert {:ok, %{fired: [], blocked: [], undeliverable: [], failed: []}} =
               Schedules.run_once(now: t1 + 1)

      :ok = Schedules.delete(id)
    end

    test "a due session-less sweep reports the undeliverable bucket and advances", %{
      agent: a
    } do
      # The run_once surface must SHOW the outcome — an all-empty result
      # while the anchor silently moved was the review repro.
      id = Ids.new_schedule_id()
      {:ok, sched} = Schedules.create(id, Map.delete(params(a), :session_id), now: @t0)
      t1 = Schedules.next_fire_ms(sched)

      assert {:ok, %{undeliverable: [^id], fired: [], failed: []}} = Schedules.run_once(now: t1)
      assert {:ok, %{undeliverable: [], fired: [], failed: []}} = Schedules.run_once(now: t1 + 1)

      :ok = Schedules.delete(id)
    end

    test "a blocking diagnostic sink never gates the durable settle or the sweep", %{
      agent: a
    } do
      # Repository rule: telemetry failure must not change scheduling
      # results. The sink here blocks FOREVER and is never released; the
      # undeliverable occurrence must still settle durably and a second due
      # schedule must still fire in the same sweep.
      Application.put_env(:salix_cluster, :schedule_diagnostic_sink, fn _diagnostic ->
        Process.sleep(:infinity)
      end)

      undeliverable_id = Ids.new_schedule_id()
      ok_id = Ids.new_schedule_id()

      {:ok, s1} =
        Schedules.create(undeliverable_id, Map.delete(params(a), :session_id), now: @t0)

      {:ok, _s2} = Schedules.create(ok_id, params(a), now: @t0)
      t1 = Schedules.next_fire_ms(s1)

      assert {:ok, %{undeliverable: [^undeliverable_id], failed: []} = result} =
               Schedules.run_once(now: t1)

      assert ok_id in result.fired

      # The durable settle happened despite the stuck sink.
      assert {:ok, :undeliverable} = ScheduleRuns.disposition(undeliverable_id, t1)
      assert {:ok, after_sweep} = Schedules.get(undeliverable_id)
      assert after_sweep["last_run"] == t1

      :ok = Schedules.delete(undeliverable_id)
      :ok = Schedules.delete(ok_id)
    end

    test "the frozen claim target survives a retarget: no cross-session duplicate", %{
      id: id,
      agent: a
    } do
      # Occurrence authority (owner 2026-08-15): the claim freezes its
      # delivery target at insert-once time; definition retargets affect
      # only FUTURE windows. Review round-3 trace 1 under the new authority:
      # deliver to the frozen session A, retarget the definition to B, then
      # let a stale session-less snapshot re-fire the SAME window — it must
      # redeliver to A (ledger duplicate), never to B.
      session_a = "ses1_1200000000000000001"
      session_b = "ses1_1200000000000000002"

      {:ok, sched_a} = Schedules.create(id, params(a), now: @t0)
      stale_sessionless = Map.delete(sched_a, "session_id")
      t1 = Schedules.next_fire_ms(sched_a)

      # Winner claims with the frozen target A and delivers there.
      assert {:ok, :fired} = Schedules.fire(sched_a, t1, now: t1)

      assert {:ok, %{disposition: :dispatch, target: {:session, ^session_a}}} =
               ScheduleRuns.claim_state(id, t1)

      {:ok, state_a} = SalixAgent.TestSupport.SessionData.read(a, session_a)
      assert MapSet.member?(state_a.input_dedupe, "schedule:#{id}:#{t1}")

      # Retarget the definition to B, then re-fire the same window from a
      # STALE session-less snapshot: it follows the CLAIM's frozen target A,
      # dedupes on A's ledger, and never touches B.
      {:ok, _} = Schedules.update(id, %{session_id: session_b})
      assert {:ok, :already_fired} = Schedules.fire(stale_sessionless, t1, now: t1)

      assert {:ok, %{disposition: :dispatch}} = ScheduleRuns.claim_state(id, t1)
      assert {:error, :not_found} = SalixAgent.TestSupport.SessionData.read(a, session_b)

      {:ok, after_stale} = SalixAgent.TestSupport.SessionData.read(a, session_a)
      assert MapSet.member?(after_stale.input_dedupe, "schedule:#{id}:#{t1}")

      # Public run history never says undeliverable for a committed run, and
      # it reports the FROZEN target A — not the retargeted definition's B.
      {:ok, agent_rec} = SalixAgent.AgentControl.get_record(a)
      assert {:ok, [run]} = SalixAgent.Schedules.list_runs(a, id, agent_rec["tenant_id"])
      assert run["status"] == "dispatched"
      assert run["error"] == nil
      assert run["session_id"] == session_a

      # The NEXT window follows the retargeted definition: its public run
      # reports B while t1 keeps reporting the frozen A (#874 round 4: the
      # projection used to rewrite the old run's target with the current
      # definition).
      {:ok, advanced} = Schedules.get(id)
      t2 = Schedules.next_fire_ms(advanced)
      assert t2 > t1
      assert {:ok, :fired} = Schedules.fire(advanced, t2, now: t2)

      assert {:ok, runs} = SalixAgent.Schedules.list_runs(a, id, agent_rec["tenant_id"])
      run_t1 = Enum.find(runs, &(&1["scheduled_for"] == div(t1, 1000)))
      run_t2 = Enum.find(runs, &(&1["scheduled_for"] == div(t2, 1000)))
      assert run_t1["session_id"] == session_a
      assert run_t2["session_id"] == session_b
      assert run_t2["status"] == "dispatched"

      :ok = Schedules.delete(id)
    end

    test "a frozen session-less claim answers undeliverable identically forever", %{
      id: id,
      agent: a
    } do
      # Review round-3 trace 2 under the new authority: the claim froze
      # "session-less"; a later definition update (or deletion) cannot
      # redirect or re-answer this occurrence — every sweeper computes the
      # same terminal outcome from the frozen target, at any time.
      capture_schedule_diagnostics()
      {:ok, stale_snapshot} = Schedules.create(id, Map.delete(params(a), :session_id), now: @t0)
      t1 = Schedules.next_fire_ms(stale_snapshot)

      # The winner freezes "session-less" and settles undeliverable.
      assert {:ok, :undeliverable} = Schedules.fire(stale_snapshot, t1, now: t1)

      assert {:ok, %{disposition: :undeliverable, target: :sessionless}} =
               ScheduleRuns.claim_state(id, t1)

      # Updating the definition afterwards changes only FUTURE windows: the
      # same window re-fired from the updated snapshot follows the durable
      # terminal decision — no delivery, no rewrite, same answer.
      {:ok, _} = Schedules.update(id, %{session_id: "ses1_1200000000000000001"})
      {:ok, fresh_snapshot} = Schedules.get(id)
      assert {:ok, :undeliverable} = Schedules.fire(fresh_snapshot, t1, now: t1)

      assert {:ok, %{disposition: :undeliverable}} = ScheduleRuns.claim_state(id, t1)

      assert {:error, :not_found} =
               SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")

      # The NEXT window delivers to the new target.
      {:ok, advanced} = Schedules.get(id)
      t2 = Schedules.next_fire_ms(advanced)
      assert t2 > t1
      assert {:ok, :fired} = Schedules.fire(advanced, t2, now: t2)

      assert {:ok, %{disposition: :dispatch, target: {:session, "ses1_1200000000000000001"}}} =
               ScheduleRuns.claim_state(id, t2)

      # Public run history (#874 round 4): t1's frozen session-less answer
      # stays ABSENT — never borrowed from the definition's later target —
      # while t2 reports the session it actually delivered to.
      {:ok, agent_rec} = SalixAgent.AgentControl.get_record(a)
      assert {:ok, runs} = SalixAgent.Schedules.list_runs(a, id, agent_rec["tenant_id"])
      run_t1 = Enum.find(runs, &(&1["scheduled_for"] == div(t1, 1000)))
      run_t2 = Enum.find(runs, &(&1["scheduled_for"] == div(t2, 1000)))
      assert run_t1["status"] == "undeliverable"
      assert run_t1["session_id"] == nil
      assert run_t2["status"] == "dispatched"
      assert run_t2["session_id"] == "ses1_1200000000000000001"

      :ok = Schedules.delete(id)
    end

    test "a delivered one-shot stays dispatched after its definition is deleted", %{agent: a} do
      # Review round-3 trace 2's one-shot variant under the new authority:
      # normal one-shot advance deletes the definition; a stale sweeper
      # re-firing the window afterwards follows the CLAIM (frozen target +
      # dispatch disposition) — it redelivers to the frozen session, dedupes
      # on the ledger, and can never rewrite the durable run.
      id = Ids.new_schedule_id()
      run_at = @t0 + 90_000
      session_a = "ses1_1200000000000000001"

      {:ok, sched} =
        Schedules.create(
          id,
          %{agent_id: a, session_id: session_a, run_at: run_at, prompt: "meeting"},
          now: @t0
        )

      stale_snapshot = sched

      assert {:ok, :fired} = Schedules.fire(sched, run_at, now: run_at)
      assert {:error, :not_found} = Schedules.get(id)

      # Stale re-fire after deletion: follows the claim, answers coherently,
      # rewrites nothing, no second ledger entry.
      assert {:ok, :already_fired} = Schedules.fire(stale_snapshot, run_at, now: run_at)

      assert {:ok, %{disposition: :dispatch, target: {:session, ^session_a}}} =
               ScheduleRuns.claim_state(id, run_at)

      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, session_a)
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{run_at}")
    end

    test "a default-role heartbeat through the public API settles undeliverable end to end" do
      # The #871 review's first-party repro: upsert_heartbeat creates an
      # ACTIVE session-less schedule on a default-role (worker) agent via the
      # public API. The occurrence must not vanish as a clean "dispatched" —
      # the whole chain has to tell the truth: run_once bucket, durable run
      # disposition, public run history, and only then the advanced anchor.
      agent = SalixAgent.TestSupport.new_agent_id()

      rec =
        SalixAgent.TestSupport.create_control_agent!(agent, %{
          "heartbeat_schedule_id" => Ids.new_schedule_id()
        })

      assert rec["role"] == "worker"
      tenant = rec["tenant_id"]
      {:ok, control} = SalixAgent.AgentControl.get_record(agent)
      hb_id = control["heartbeat_schedule_id"]
      assert is_binary(hb_id)

      assert {:ok, _hb} =
               SalixAgent.Schedules.upsert_heartbeat(
                 agent,
                 %{"interval_minutes" => 5, "status" => "active"},
                 tenant
               )

      {:ok, sched} = Schedules.get(hb_id)
      t1 = Schedules.next_fire_ms(sched)

      assert {:ok, %{undeliverable: [^hb_id], fired: [], failed: []}} =
               Schedules.run_once(now: t1)

      assert {:ok, :undeliverable} = ScheduleRuns.disposition(hb_id, t1)
      assert {:ok, [%{"disposition" => "undeliverable"}]} = ScheduleRuns.list_for(hb_id)
      _ = tenant

      assert {:ok, after_sweep} = Schedules.get(hb_id)
      assert after_sweep["last_run"] == t1

      :ok = Schedules.delete(hb_id)
    end

    # Retention must never eat an UNRESOLVED dispatch claim: if it did, the
    # next sweep would see the still-due cron window as stale-and-unclaimed,
    # write skipped_stale, and advance without a receiver ACK — after
    # unarchive the original occurrence would be gone (the exact sequence the
    # #840 re-review reproduced; ScheduleDispatch.tla immutable-disposition).
    test "a blocked cron claim survives retention and delivers after unarchive", %{agent: a} do
      id = Ids.new_schedule_id()

      {:ok, sched} =
        Schedules.create(
          id,
          %{
            agent_id: a,
            session_id: "ses1_1200000000000000001",
            cron: "0 9 * * *",
            timezone: "Etc/UTC",
            prompt: "daily"
          },
          now: @t0
        )

      t1 = Schedules.next_fire_ms(sched)
      {:ok, rec} = SalixAgent.AgentControl.get(a)
      tenant_id = rec["tenant_id"]
      # A blocked claim now only arises in the archive-record/pause gap
      # (#849 pauses the definition on a normal archive), so reach it there.
      :ok = archive_record_directly!(a)

      assert {:ok, :blocked} = Schedules.fire(sched, t1, now: t1)

      # Age the claim far past the retention window, then prune: the
      # unresolved dispatch claim must survive.
      SalixStore.Repo.query!("UPDATE schedule_runs SET inserted_at = now() - interval '40 days'")
      assert {:ok, 0} = ScheduleRuns.prune_older_than(30)
      assert {:ok, [run]} = ScheduleRuns.list_for(id)
      assert run["disposition"] == "dispatch"

      # A much later sweep follows the preserved claim (blocked again) instead
      # of rewriting the window as skipped_stale and advancing.
      month_later = t1 + 31 * 24 * 60 * 60 * 1000

      assert {:ok, %{blocked: [^id], skipped: [], fired: []}} =
               Schedules.run_once(now: month_later)

      assert {:ok, [run]} = ScheduleRuns.list_for(id)
      assert run["disposition"] == "dispatch"

      # Unarchive: the ORIGINAL occurrence delivers exactly once, then the
      # anchor advances past it.
      assert {:ok, _} = SalixAgent.AgentControl.unarchive(a, tenant_id)
      assert {:ok, %{blocked: [], failed: []}} = Schedules.run_once(now: month_later)
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t1}")

      # Once resolved (anchor advanced past the window), retention may prune.
      SalixStore.Repo.query!("UPDATE schedule_runs SET inserted_at = now() - interval '40 days'")
      assert {:ok, pruned} = ScheduleRuns.prune_older_than(30)
      assert pruned >= 1

      :ok = Schedules.delete(id)
    end
  end

  describe "cron schedules" do
    defp at(date, time), do: DateTime.to_unix(DateTime.new!(date, time, "UTC"), :millisecond)

    defp cron_params(agent, overrides \\ %{}) do
      Map.merge(
        %{
          agent_id: agent,
          session_id: "ses1_1200000000000000001",
          cron: "0 9 * * *",
          timezone: "UTC",
          prompt: "daily"
        },
        overrides
      )
    end

    test "next fire is the first occurrence strictly after the anchor; due is inclusive",
         %{id: id, agent: a} do
      created = at(~D[2026-06-18], ~T[08:00:00])
      {:ok, sched} = Schedules.create(id, cron_params(a), now: created)

      nine = at(~D[2026-06-18], ~T[09:00:00])
      assert Schedules.next_fire_ms(sched) == nine

      assert {:ok, []} = Schedules.due(nine - 1)
      assert {:ok, [due]} = Schedules.due(nine)
      assert due["id"] == id
    end

    test "a schedule created exactly on a boundary does not fire that instant",
         %{id: id, agent: a} do
      created = at(~D[2026-06-18], ~T[09:00:00])
      {:ok, sched} = Schedules.create(id, cron_params(a), now: created)

      # strictly-after ⇒ the next day's 09:00, never `created` itself
      assert Schedules.next_fire_ms(sched) == at(~D[2026-06-19], ~T[09:00:00])
      assert {:ok, []} = Schedules.due(created)
    end

    test "refire on the next occurrence claims a NEW run object and advances last_run",
         %{id: id, agent: a} do
      created = at(~D[2026-06-18], ~T[08:00:00])
      {:ok, _} = Schedules.create(id, cron_params(a), now: created)

      t1 = at(~D[2026-06-18], ~T[09:00:00])
      assert {:ok, %{fired: [^id], skipped: []}} = Schedules.run_once(now: t1)

      t2 = at(~D[2026-06-19], ~T[09:00:00])
      assert {:ok, %{fired: [^id], skipped: []}} = Schedules.run_once(now: t2)

      assert {:ok, runs} = run_objects(id)
      assert length(runs) == 2
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t1}")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t2}")

      assert {:ok, after_runs} = Schedules.get(id)
      assert after_runs["last_run"] == t2
    end

    test "skip-stale: a missed daily cron advances past the gap WITHOUT delivering",
         %{id: id, agent: a} do
      capture_schedule_diagnostics()

      # Created 3 days before `now`; the node was effectively down in between.
      created = at(~D[2026-06-15], ~T[09:00:00])
      {:ok, _} = Schedules.create(id, cron_params(a), now: created)

      now = at(~D[2026-06-18], ~T[10:00:00])

      assert {:ok, %{fired: [], skipped: [^id]}} =
               Schedules.run_once(now: now, stale_grace_ms: 60_000)

      # anchor jumped to the latest past occurrence; nothing delivered
      assert {:ok, after_skip} = Schedules.get(id)
      assert after_skip["last_run"] == at(~D[2026-06-18], ~T[09:00:00])
      assert {:ok, [run]} = run_objects(id)
      assert run["disposition"] == "skipped_stale"

      assert {:error, :claim_not_dispatch} =
               Schedules.recover_claim(id, run["scheduled_for_ms"])

      # nothing delivered: no session ledger was ever created
      assert {:error, :not_found} =
               SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")

      assert_receive {:schedule_diagnostic, diagnostic}
      assert diagnostic.status == "skipped"
      assert diagnostic.event_type == "schedule.fire.skipped"
      assert diagnostic.severity == "warning"
      assert diagnostic.reason_class == "stale_window"
      assert diagnostic.stage == "stale_window"
      assert diagnostic.schedule_id == id
      assert diagnostic.agent_id == a
      assert diagnostic.scheduled_for_ms == at(~D[2026-06-18], ~T[09:00:00])
      refute inspect(diagnostic) =~ "daily"

      # the next future occurrence fires normally
      t_next = at(~D[2026-06-19], ~T[09:00:00])
      assert {:ok, %{fired: [^id], skipped: []}} = Schedules.run_once(now: t_next)
      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t_next}")
    end

    test "skip-stale is idempotent under concurrency", %{id: id, agent: a} do
      created = at(~D[2026-06-15], ~T[09:00:00])
      {:ok, _} = Schedules.create(id, cron_params(a), now: created)

      now = at(~D[2026-06-18], ~T[10:00:00])
      opts = [now: now, stale_grace_ms: 60_000]

      [opts, opts]
      |> Task.async_stream(fn o -> Schedules.run_once(o) end, max_concurrency: 2, timeout: 10_000)
      |> Stream.run()

      assert {:ok, after_skip} = Schedules.get(id)
      assert after_skip["last_run"] == at(~D[2026-06-18], ~T[09:00:00])
      assert {:ok, [run]} = run_objects(id)
      assert run["disposition"] == "skipped_stale"

      # neither concurrent sweep delivered: no session ledger exists
      assert {:error, :not_found} =
               SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
    end

    test "a stale sweep honors a concurrent durable dispatch decision", %{
      id: id,
      agent: a
    } do
      created = at(~D[2026-06-15], ~T[08:00:00])
      {:ok, schedule} = Schedules.create(id, cron_params(a), now: created)
      due = Schedules.next_fire_ms(schedule)
      now = at(~D[2026-06-18], ~T[10:00:00])

      # A racing sweeper's dispatch claim landed first: its durable decision
      # must win — the stale sweep re-dispatches and advances instead of
      # skipping the window.
      assert :claimed =
               Schedules.claim_window(id, due, %{
                 "receiver" => "agent",
                 "agent_id" => a,
                 "disposition" => "dispatch",
                 "fired_at" => now
               })

      assert {:ok, %{already_fired: [^id], skipped: []}} =
               Schedules.run_once(now: now, stale_grace_ms: 60_000)

      {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, "ses1_1200000000000000001")
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{due}")
      assert {:ok, %{"last_run" => ^due}} = Schedules.get(id)
    end

    test "interval schedules are NOT skip-stale'd even when far in the past",
         %{id: id, agent: a} do
      # An interval schedule overdue by hours still fires (existing backfill
      # contract preserved), regardless of a tiny stale grace.
      {:ok, _} = Schedules.create(id, params(a), now: @t0)
      overdue = @t0 + 10 * @five_min

      assert {:ok, %{fired: [^id]}} = Schedules.run_once(now: overdue, stale_grace_ms: 1)
      assert {:ok, [_]} = run_objects(id)
    end

    test "validation: interval XOR cron, parseable cron, known timezone",
         %{id: id, agent: a} do
      # both interval and cron
      assert {:error, :invalid_schedule} =
               Schedules.create(id, cron_params(a, %{interval_minutes: 5}), now: @t0)

      # neither
      assert {:error, :invalid_schedule} =
               Schedules.create(id, %{agent_id: a, prompt: "p"}, now: @t0)

      # unparseable cron
      assert {:error, :invalid_schedule} =
               Schedules.create(id, cron_params(a, %{cron: "not a cron"}), now: @t0)

      # unknown timezone
      assert {:error, :invalid_schedule} =
               Schedules.create(id, cron_params(a, %{timezone: "Mars/Phobos"}), now: @t0)
    end

    test "timezone defaults to UTC when omitted", %{id: id, agent: a} do
      created = at(~D[2026-06-18], ~T[08:00:00])
      params = cron_params(a) |> Map.delete(:timezone)
      {:ok, sched} = Schedules.create(id, params, now: created)

      refute Map.has_key?(sched, "timezone")
      assert Schedules.next_fire_ms(sched) == at(~D[2026-06-18], ~T[09:00:00])
    end
  end
end
