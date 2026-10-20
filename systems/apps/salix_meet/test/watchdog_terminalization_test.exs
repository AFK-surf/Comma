defmodule SalixMeet.WatchdogTerminalizationTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  alias SalixMeet.{Delivery, RuntimeEvents, SlackThreadIndex, Store}
  alias SalixStore.{Keys, S3}

  @hour_s 60 * 60

  defmodule WatchdogDispatch do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:error, :not_configured}

    @impl true
    def send_chat(_payload), do: {:error, :not_configured}

    @impl true
    def session_status(payload) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :watchdog_test_pid),
        {:probe, payload}
      )

      SystemsRuntime.get_env(:salix_meet, :watchdog_test_answer, {:ok, :unavailable})
    end
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_dispatch = SystemsRuntime.get_env(:salix_meet, :meeting_dispatch_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_meet, :meeting_dispatch_mod, WatchdogDispatch)
    SystemsRuntime.put_env(:salix_meet, :watchdog_test_pid, SystemsRuntime.Proc.self())

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)

      SystemsRuntime.put_env(:salix_meet, :meeting_dispatch_mod, previous_dispatch)
      SystemsRuntime.delete_env(:salix_meet, :watchdog_test_answer)
      SystemsRuntime.delete_env(:salix_meet, :watchdog_test_pid)
    end)

    :ok
  end

  defp attach_operations! do
    handler_id = "watchdog-telemetry-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn _event, _measurements, metadata, _config ->
          SystemsRuntime.Proc.send(parent, {:operation, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
  end

  defp seed_stuck_meeting(opts) do
    now_s = Keyword.fetch!(opts, :now_s)
    meeting_id = "mtg-watchdog-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    state =
      %{
        "tenant_id" => "ten-watchdog",
        "group_id" => "grp-watchdog",
        "provider" => "slack",
        "connect_id" => "conn-watchdog",
        "runtime_source" => "connected_runtime",
        "status" => Keyword.get(opts, :status, "processing"),
        "join_requested_at" =>
          Keyword.get(opts, :join_requested_at, (now_s - 4 * @hour_s) * 1000),
        "joined_at" => Keyword.get(opts, :joined_at, now_s - 4 * @hour_s),
        "left_at" => Keyword.get(opts, :left_at, now_s - 3 * @hour_s)
      }
      |> Map.merge(Keyword.get(opts, :extra_state, %{}))

    state =
      if Keyword.get(opts, :thread, true) do
        slack_ref =
          Keyword.get(opts, :slack_ref, %{"channel_id" => "C1", "thread_ts" => "111.222"})

        Map.put(state, "slack_ref", slack_ref)
      else
        state
      end

    state =
      Enum.reduce(Keyword.get(opts, :drop, []), state, fn key, acc -> Map.delete(acc, key) end)

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
    meeting_id
  end

  defp seed_duplicate_slack_meetings(now_s) do
    shadow_id = seed_stuck_meeting(now_s: now_s)
    canonical_id = "mtg-canonical-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    canonical_state = %{
      "tenant_id" => "ten-watchdog",
      "group_id" => "grp-watchdog",
      "provider" => "slack",
      "connect_id" => "conn-watchdog",
      "status" => "done",
      "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
      "delivery" => %{
        "status" => "published",
        "published_at" => now_s - @hour_s,
        "summary_message_kind" => "summary",
        "summary_message_ts" => "111.333"
      }
    }

    assert {:ok, _doc, _etag} = Store.create_once(canonical_id, state: canonical_state)

    assert {:ok, %{"meeting_id" => ^canonical_id}} =
             SlackThreadIndex.claim(canonical_state, "C1", "111.222", canonical_id)

    {shadow_id, canonical_id, canonical_state}
  end

  defp wait_until(fun, attempts \\ 6000)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      SystemsClock.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false

  defp start_paused_retirement(shadow_id, now_s, op, key) do
    retire =
      SystemsRuntime.Task.async(fn ->
        SystemsRuntime.Proc.receive do
          :retire -> Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)
        end
      end)

    assert :ok = S3.Fake.set_fault_for(retire.pid, {:pause, op, key})
    SystemsRuntime.Proc.send(retire.pid, :retire)
    on_exit(fn -> if S3.Fake.paused?(), do: S3.Fake.release_pause() end)
    assert wait_until(&S3.Fake.paused?/0)
    retire
  end

  defp start_paused_reducer_read(shadow_id, canonical_id, now_s) do
    retire =
      start_paused_retirement(shadow_id, now_s, :get, Keys.meet_state(canonical_id))

    assert :ok =
             S3.Fake.set_fault_for(
               retire.pid,
               {:pause, :get, Keys.meet_state(shadow_id)}
             )

    assert :ok = S3.Fake.release_pause()
    assert wait_until(&S3.Fake.paused?/0)
    retire
  end

  # A shadow write that lands while duplicate retirement is paused must win:
  # either the runtime reports a terminal status or delivery publishes.
  @shadow_races [
    {:terminal, "a terminal runtime event racing duplicate retirement wins the shadow CAS",
     "a terminal runtime event before the first retirement reducer read is preserved",
     "a terminal race after an ambiguous-lost CAS wins the verified retry"},
    {:published, "a published summary racing duplicate retirement wins the shadow CAS",
     "a published summary before the first retirement reducer read is preserved",
     "a published race after an ambiguous-lost CAS wins the verified retry"}
  ]

  defp apply_shadow_race!(:terminal, shadow_id, now_s) do
    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(shadow_id, fn state ->
               state
               |> Map.put("status", "done")
               |> Map.put("ended_at", now_s)
             end)
  end

  defp apply_shadow_race!(:published, shadow_id, now_s) do
    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(shadow_id, fn state ->
               delivery =
                 Map.merge(state["delivery"] || %{}, %{
                   "status" => "published",
                   "published_at" => now_s * 1_000,
                   "summary_message_ts" => "111.999"
                 })

               Map.put(state, "delivery", delivery)
             end)
  end

  defp assert_shadow_race_won!(race, shadow_id, now_s, retire) do
    assert :ok = S3.Fake.release_pause()
    assert :skipped = settled_await(retire)
    settle_refute_receive({:probe, _payload}, 10)
    assert {:ok, shadow, _etag} = Store.get(shadow_id)

    case race do
      :terminal ->
        assert shadow["state"]["status"] == "done"
        assert shadow["state"]["ended_at"] == now_s

      :published ->
        assert shadow["state"]["status"] == "processing"
        assert shadow["state"]["delivery"]["status"] == "published"
        assert shadow["state"]["delivery"]["summary_message_ts"] == "111.999"
    end

    refute Map.has_key?(shadow["state"], "watchdog")
  end

  describe "watchdog eligibility" do
    test "the predicate demands dispatch, non-abandonment, and an expired anchor" do
      now_s = SystemsClock.system_time(:second)
      cutoff = Store.watchdog_cutoff_s()

      doc = fn state -> %{"join_requested_at" => nil, "state" => state} end

      assert :terminal = Store.watchdog_eligibility(doc.(%{"status" => "done"}), now_s, cutoff)

      assert :not_dispatched =
               Store.watchdog_eligibility(doc.(%{"status" => "processing"}), now_s, cutoff)

      assert :abandoned =
               Store.watchdog_eligibility(
                 doc.(%{
                   "status" => "provisioning",
                   "join_requested_at" => 1,
                   "calendar_autojoin_abandoned_at" => 1
                 }),
                 now_s,
                 cutoff
               )

      assert :no_anchor =
               Store.watchdog_eligibility(
                 doc.(%{"status" => "processing", "join_requested_at" => 1}),
                 now_s,
                 cutoff
               )

      assert :not_due =
               Store.watchdog_eligibility(
                 doc.(%{
                   "status" => "processing",
                   "join_requested_at" => 1,
                   "left_at" => now_s - 60
                 }),
                 now_s,
                 cutoff
               )

      assert {:eligible, _deadline} =
               Store.watchdog_eligibility(
                 doc.(%{
                   "status" => "processing",
                   "join_requested_at" => 1,
                   "left_at" => now_s - cutoff - 60
                 }),
                 now_s,
                 cutoff
               )

      # A definitely-live probe advances the anchor through last_seen_live_at.
      assert :not_due =
               Store.watchdog_eligibility(
                 doc.(%{
                   "status" => "processing",
                   "join_requested_at" => 1,
                   "left_at" => now_s - cutoff - 60,
                   "last_seen_live_at" => now_s - 60
                 }),
                 now_s,
                 cutoff
               )
    end
  end

  describe "watchdog terminalization" do
    for {race, put_name, read_name, _ambiguous_name} <- @shadow_races do
      test put_name do
        now_s = SystemsClock.system_time(:second)
        {shadow_id, _canonical_id, _canonical_state} = seed_duplicate_slack_meetings(now_s)
        retire = start_paused_retirement(shadow_id, now_s, :put, Keys.meet_state(shadow_id))

        apply_shadow_race!(unquote(race), shadow_id, now_s)
        assert_shadow_race_won!(unquote(race), shadow_id, now_s, retire)
      end

      test read_name do
        now_s = SystemsClock.system_time(:second)
        {shadow_id, canonical_id, _canonical_state} = seed_duplicate_slack_meetings(now_s)

        retire =
          start_paused_retirement(shadow_id, now_s, :get, Keys.meet_state(canonical_id))

        apply_shadow_race!(unquote(race), shadow_id, now_s)
        assert_shadow_race_won!(unquote(race), shadow_id, now_s, retire)
      end
    end

    for {race, _put_name, _read_name, ambiguous_name} <- @shadow_races do
      test ambiguous_name do
        now_s = SystemsClock.system_time(:second)
        {shadow_id, canonical_id, _canonical_state} = seed_duplicate_slack_meetings(now_s)
        key = Keys.meet_state(shadow_id)
        retire = start_paused_reducer_read(shadow_id, canonical_id, now_s)

        assert :ok = S3.Fake.set_fault_for(retire.pid, {:ambiguous_before, :put, key})
        assert :ok = S3.Fake.set_fault_for(retire.pid, {:pause, :get, key})
        assert :ok = S3.Fake.release_pause()
        assert wait_until(&S3.Fake.paused?/0)

        apply_shadow_race!(unquote(race), shadow_id, now_s)
        assert_shadow_race_won!(unquote(race), shadow_id, now_s, retire)
      end
    end

    test "an unreachable runtime past the cutoff is terminalized as runtime_lost" do
      attach_operations!()
      now_s = SystemsClock.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s)

      assert {:ok, %{"meeting_id" => ^meeting_id}} =
               SlackThreadIndex.claim(
                 %{
                   "tenant_id" => "ten-watchdog",
                   "group_id" => "grp-watchdog",
                   "connect_id" => "conn-watchdog"
                 },
                 "C1",
                 "111.222",
                 meeting_id
               )

      SystemsRuntime.put_env(:salix_meet, :watchdog_test_answer, {:ok, :unavailable})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :watchdog_terminalized = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
        end)

      assert log =~ "meeting watchdog terminalized"
      settle_receive({:probe, %{"meeting_id" => ^meeting_id, "group_id" => "grp-watchdog"}})

      settle_receive(
        {:operation, %{component: "salix_meet", operation: "meeting_watchdog", outcome: "ok"}}
      )

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "failed"
      assert doc["state"]["watchdog"]["reason"] == "runtime_lost"
      assert doc["state"]["error"] =~ "runtime lost"
      # A provider thread exists, so the delivery stays claimable for the
      # incomplete-record notice.
      refute doc["state"]["delivery"]["status"] == "failed_terminal"

      # The PR2 terminal valve keeps the verdict: a late done event cannot
      # resurrect the meeting or smuggle in a late summary.
      late = %{
        "type" => "meeting_runtime_update",
        "meeting_id" => meeting_id,
        "status" => "done",
        "summary" => %{"title" => "Late", "action_items" => []}
      }

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, late)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = RuntimeEvents.apply(prepared, "watchdog-late-done")
      end)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "failed"
      assert doc["state"]["late_runtime_status"]["status"] == "done"
    end

    test "a definitely-live runtime extends the anchor instead of terminalizing" do
      now_s = SystemsClock.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s)
      SystemsRuntime.put_env(:salix_meet, :watchdog_test_answer, {:ok, :live})

      assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      settle_receive({:probe, %{"meeting_id" => ^meeting_id}})
      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "processing"
      assert doc["state"]["last_seen_live_at"] == now_s

      # The advanced anchor throttles the probe: the next sweep at the same
      # instant is not eligible and asks the runtime nothing.
      assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      settle_refute_receive({:probe, _payload}, 10)
    end

    test "a stale stolen probe cannot decide with its old generation" do
      now_s = SystemsClock.system_time(:second)
      t0 = SystemsClock.system_time(:millisecond)
      meeting_id = seed_stuck_meeting(now_s: now_s)

      assert {:ok, gen_a} =
               Store.claim_watchdog_probe(meeting_id, "node-a", now: t0, now_s: now_s)

      # A fresh claim is not stealable...
      assert {:error, :probe_held} =
               Store.claim_watchdog_probe(meeting_id, "node-b", now: t0 + 1_000, now_s: now_s)

      # ...but a crashed holder's claim is, after the probe TTL.
      assert {:ok, gen_b} =
               Store.claim_watchdog_probe(meeting_id, "node-b", now: t0 + 61_000, now_s: now_s)

      # The stale holder's late answers lose the generation fence, in both
      # directions.
      assert {:error, :fenced} = Store.refresh_runtime_liveness(meeting_id, now_s, gen_a)

      assert {:error, :fenced} =
               Store.mark_runtime_lost(meeting_id, now_s: now_s, generation: gen_a)

      # The current holder still decides.
      assert {:ok, _doc, _etag} =
               Store.mark_runtime_lost(meeting_id, now_s: now_s, generation: gen_b)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "failed"
      refute Map.has_key?(doc["state"], "watchdog_probe")
    end
  end

  describe "bounded retry convergence" do
  end
end
