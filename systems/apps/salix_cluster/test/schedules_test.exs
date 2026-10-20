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
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixStore.{Ids, Keys}
  alias SalixCluster.Schedules
  alias SalixStore.ScheduleRuns

  @t0 1_750_000_000_000
  @five_min 5 * 60_000

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_schedule_sink = SystemsRuntime.get_env(:salix_cluster, :schedule_diagnostic_sink)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.delete_env(:salix_cluster, :schedule_diagnostic_sink)
    start_supervised!(SalixStore.S3.Fake)

    # Schedules live in the node-global control Postgres now, which no
    # S3.Fake.reset can clear — every file expecting a clean slate truncates.
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
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

  defp capture_schedule_diagnostics do
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_cluster, :schedule_diagnostic_sink, fn diagnostic ->
      SystemsRuntime.Proc.send(parent, {:schedule_diagnostic, diagnostic})
    end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

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

    # The legacy "ambiguous claim PUT (landed, response lost)" scenario has no
    # PG counterpart: an insert-once claim either lands, conflicts, or errors —
    # there is no lost-response outcome to resolve. Concurrent-claim semantics
    # are covered by "two concurrent fires ... deliver exactly once" above.

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

      settle_receive({:schedule_diagnostic, diagnostic})
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
  end
end
