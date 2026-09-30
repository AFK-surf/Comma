defmodule SalixMeet.WatchdogTerminalizationTest do
  use ExUnit.Case, async: false

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
      send(Application.fetch_env!(:salix_meet, :watchdog_test_pid), {:probe, payload})
      Application.get_env(:salix_meet, :watchdog_test_answer, {:ok, :unavailable})
    end
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_dispatch = Application.get_env(:salix_meet, :meeting_dispatch_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :meeting_dispatch_mod, WatchdogDispatch)
    Application.put_env(:salix_meet, :watchdog_test_pid, self())

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if is_nil(previous_backend),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_backend)

      Application.put_env(:salix_meet, :meeting_dispatch_mod, previous_dispatch)
      Application.delete_env(:salix_meet, :watchdog_test_answer)
      Application.delete_env(:salix_meet, :watchdog_test_pid)
    end)

    :ok
  end

  defp attach_operations! do
    handler_id = "watchdog-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn _event, _measurements, metadata, _config -> send(parent, {:operation, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp seed_stuck_meeting(opts) do
    now_s = Keyword.fetch!(opts, :now_s)
    meeting_id = "mtg-watchdog-#{System.unique_integer([:positive])}"

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

  defp assert_watchdog_fails_closed(meeting_id, now_s) do
    assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
    refute_receive {:probe, _payload}, 100

    assert_receive {:operation,
                    %{
                      component: "salix_meet",
                      operation: "meeting_watchdog",
                      outcome: "error"
                    }}

    assert {:ok, meeting, _etag} = Store.get(meeting_id)
    assert meeting["state"]["status"] == "processing"
    refute Map.has_key?(meeting["state"], "watchdog")
  end

  defp malformed_scope_opts(field, invalid_value)
       when field in ~w(tenant_id group_id connect_id),
       do: [extra_state: %{field => invalid_value}]

  defp malformed_scope_opts("channel_id", invalid_value),
    do: [slack_ref: %{"channel_id" => invalid_value, "thread_ts" => "111.222"}]

  defp malformed_scope_opts("thread_ts", invalid_value),
    do: [slack_ref: %{"channel_id" => "C1", "thread_ts" => invalid_value}]

  defp seed_duplicate_slack_meetings(now_s) do
    shadow_id = seed_stuck_meeting(now_s: now_s)
    canonical_id = "mtg-canonical-#{System.unique_integer([:positive])}"

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

  defp wait_until(fun, attempts \\ 80)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false

  defp start_paused_retirement(shadow_id, now_s, op, key) do
    retire =
      Task.async(fn ->
        receive do
          :retire -> Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)
        end
      end)

    assert :ok = S3.Fake.set_fault_for(retire.pid, {:pause, op, key})
    send(retire.pid, :retire)
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
    assert :skipped = Task.await(retire)
    refute_receive {:probe, _payload}, 100

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
      now_s = System.system_time(:second)
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
    test "a legacy non-owner record is retired without posting over the canonical Slack thread" do
      attach_operations!()
      now_s = System.system_time(:second)
      {shadow_id, canonical_id, canonical_state} = seed_duplicate_slack_meetings(now_s)

      assert :watchdog_duplicate_retired =
               Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)

      refute_receive {:probe, _payload}, 100

      assert_receive {:operation,
                      %{
                        component: "salix_meet",
                        operation: "meeting_watchdog",
                        outcome: "ignored"
                      }}

      assert {:ok, shadow, _etag} = Store.get(shadow_id)
      assert shadow["state"]["status"] == "cancelled"

      assert shadow["state"]["watchdog"] == %{
               "reason" => "duplicate_slack_thread",
               "canonical_meeting_id" => canonical_id,
               "terminalized_at" => now_s
             }

      assert shadow["state"]["delivery"]["status"] == "failed_terminal"
      assert shadow["state"]["delivery"]["failure_kind"] == "duplicate_slack_thread"
      refute Map.has_key?(shadow["state"]["delivery"], "published_at")
      refute Map.has_key?(shadow["state"]["delivery"], "summary_message_ts")

      assert :not_claimable = Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)

      assert {:ok, canonical, _etag} = Store.get(canonical_id)
      assert canonical["state"] == canonical_state
    end

    for {race, put_name, read_name, _ambiguous_name} <- @shadow_races do
      test put_name do
        now_s = System.system_time(:second)
        {shadow_id, _canonical_id, _canonical_state} = seed_duplicate_slack_meetings(now_s)
        retire = start_paused_retirement(shadow_id, now_s, :put, Keys.meet_state(shadow_id))

        apply_shadow_race!(unquote(race), shadow_id, now_s)
        assert_shadow_race_won!(unquote(race), shadow_id, now_s, retire)
      end

      test read_name do
        now_s = System.system_time(:second)
        {shadow_id, canonical_id, _canonical_state} = seed_duplicate_slack_meetings(now_s)

        retire =
          start_paused_retirement(shadow_id, now_s, :get, Keys.meet_state(canonical_id))

        apply_shadow_race!(unquote(race), shadow_id, now_s)
        assert_shadow_race_won!(unquote(race), shadow_id, now_s, retire)
      end
    end

    test "ambiguous-applied duplicate retirement verifies the landed write" do
      attach_operations!()
      now_s = System.system_time(:second)
      {shadow_id, canonical_id, canonical_state} = seed_duplicate_slack_meetings(now_s)

      assert :ok =
               S3.Fake.set_fault({:ambiguous_after, :put, Keys.meet_state(shadow_id)})

      assert :watchdog_duplicate_retired =
               Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)

      refute_receive {:probe, _payload}, 100

      assert_receive {:operation,
                      %{
                        component: "salix_meet",
                        operation: "meeting_watchdog",
                        outcome: "ignored"
                      }}

      assert {:ok, shadow, _etag} = Store.get(shadow_id)
      assert shadow["state"]["status"] == "cancelled"
      assert shadow["state"]["watchdog"]["canonical_meeting_id"] == canonical_id

      assert {:ok, canonical, _etag} = Store.get(canonical_id)
      assert canonical["state"] == canonical_state
    end

    test "ambiguous-lost duplicate retirement verifies the miss and retries" do
      attach_operations!()
      now_s = System.system_time(:second)
      {shadow_id, _canonical_id, _canonical_state} = seed_duplicate_slack_meetings(now_s)

      assert :ok =
               S3.Fake.set_fault({:ambiguous_before, :put, Keys.meet_state(shadow_id)})

      assert :watchdog_duplicate_retired =
               Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)

      refute_receive {:probe, _payload}, 100

      assert_receive {:operation,
                      %{
                        component: "salix_meet",
                        operation: "meeting_watchdog",
                        outcome: "ignored"
                      }}

      assert {:ok, shadow, _etag} = Store.get(shadow_id)
      assert shadow["state"]["status"] == "cancelled"
      assert shadow["state"]["watchdog"]["reason"] == "duplicate_slack_thread"
    end

    for {race, _put_name, _read_name, ambiguous_name} <- @shadow_races do
      test ambiguous_name do
        now_s = System.system_time(:second)
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
      now_s = System.system_time(:second)
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

      Application.put_env(:salix_meet, :watchdog_test_answer, {:ok, :unavailable})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :watchdog_terminalized = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
        end)

      assert log =~ "meeting watchdog terminalized"
      assert_receive {:probe, %{"meeting_id" => ^meeting_id, "group_id" => "grp-watchdog"}}

      assert_receive {:operation,
                      %{component: "salix_meet", operation: "meeting_watchdog", outcome: "ok"}}

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

    test "an unreadable canonical Slack owner fails closed without probing the shadow" do
      attach_operations!()
      now_s = System.system_time(:second)
      shadow_id = seed_stuck_meeting(now_s: now_s)
      missing_canonical_id = "mtg-missing-#{System.unique_integer([:positive])}"

      assert {:ok, %{"meeting_id" => ^missing_canonical_id}} =
               SlackThreadIndex.claim(
                 %{
                   "tenant_id" => "ten-watchdog",
                   "group_id" => "grp-watchdog",
                   "connect_id" => "conn-watchdog"
                 },
                 "C1",
                 "111.222",
                 missing_canonical_id
               )

      assert :skipped = Delivery.deliver_one(shadow_id, watchdog_now_s: now_s)
      refute_receive {:probe, _payload}, 100

      assert_receive {:operation,
                      %{
                        component: "salix_meet",
                        operation: "meeting_watchdog",
                        outcome: "error"
                      }}

      assert {:ok, shadow, _etag} = Store.get(shadow_id)
      assert shadow["state"]["status"] == "processing"
      refute Map.has_key?(shadow["state"], "watchdog")
    end

    test "a malformed canonical state fails closed without crashing the sweep" do
      attach_operations!()
      now_s = System.system_time(:second)
      shadow_id = seed_stuck_meeting(now_s: now_s)
      canonical_id = "mtg-malformed-state-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} = Store.create_once(canonical_id, state: [])

      assert {:ok, %{"meeting_id" => ^canonical_id}} =
               SlackThreadIndex.claim(
                 %{
                   "tenant_id" => "ten-watchdog",
                   "group_id" => "grp-watchdog",
                   "connect_id" => "conn-watchdog"
                 },
                 "C1",
                 "111.222",
                 canonical_id
               )

      assert_watchdog_fails_closed(shadow_id, now_s)
    end

    test "a malformed canonical Slack ref fails closed without crashing the sweep" do
      attach_operations!()
      now_s = System.system_time(:second)
      shadow_id = seed_stuck_meeting(now_s: now_s)
      canonical_id = "mtg-malformed-ref-#{System.unique_integer([:positive])}"

      canonical_state = %{
        "tenant_id" => "ten-watchdog",
        "group_id" => "grp-watchdog",
        "provider" => "slack",
        "connect_id" => "conn-watchdog",
        "status" => "done",
        "slack_ref" => []
      }

      assert {:ok, _doc, _etag} = Store.create_once(canonical_id, state: canonical_state)

      assert {:ok, %{"meeting_id" => ^canonical_id}} =
               SlackThreadIndex.claim(canonical_state, "C1", "111.222", canonical_id)

      assert_watchdog_fails_closed(shadow_id, now_s)
    end

    test "an invalid shadow Slack scope fails closed instead of probing" do
      attach_operations!()
      now_s = System.system_time(:second)
      shadow_id = seed_stuck_meeting(now_s: now_s, drop: ["tenant_id"])

      assert_watchdog_fails_closed(shadow_id, now_s)
    end

    test "malformed raw Slack scope fields fail closed instead of probing" do
      attach_operations!()
      now_s = System.system_time(:second)

      fields = ~w(tenant_id group_id connect_id channel_id thread_ts)
      invalid_values = [123, true, %{}, [], nil]

      for field <- fields, invalid_value <- invalid_values do
        opts = malformed_scope_opts(field, invalid_value)
        shadow_id = seed_stuck_meeting(Keyword.put(opts, :now_s, now_s))
        assert_watchdog_fails_closed(shadow_id, now_s)
      end
    end

    test "a canonical Slack scope mismatch fails closed without probing the shadow" do
      attach_operations!()
      now_s = System.system_time(:second)
      shadow_id = seed_stuck_meeting(now_s: now_s)
      canonical_id = "mtg-scope-mismatch-#{System.unique_integer([:positive])}"

      canonical_state = %{
        "tenant_id" => "ten-watchdog",
        "group_id" => "other-group",
        "provider" => "slack",
        "connect_id" => "conn-watchdog",
        "status" => "done",
        "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
      }

      assert {:ok, _doc, _etag} = Store.create_once(canonical_id, state: canonical_state)

      assert {:ok, %{"meeting_id" => ^canonical_id}} =
               SlackThreadIndex.claim(
                 %{
                   "tenant_id" => "ten-watchdog",
                   "group_id" => "grp-watchdog",
                   "connect_id" => "conn-watchdog"
                 },
                 "C1",
                 "111.222",
                 canonical_id
               )

      assert_watchdog_fails_closed(shadow_id, now_s)
    end

    test "a definitely-live runtime extends the anchor instead of terminalizing" do
      now_s = System.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s)
      Application.put_env(:salix_meet, :watchdog_test_answer, {:ok, :live})

      assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      assert_receive {:probe, %{"meeting_id" => ^meeting_id}}

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "processing"
      assert doc["state"]["last_seen_live_at"] == now_s

      # The advanced anchor throttles the probe: the next sweep at the same
      # instant is not eligible and asks the runtime nothing.
      assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      refute_receive {:probe, _payload}, 100
    end

    test "a definitely-none runtime answer confirms only the terminal event was lost" do
      now_s = System.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s)
      Application.put_env(:salix_meet, :watchdog_test_answer, {:ok, :none})

      ExUnit.CaptureLog.capture_log(fn ->
        assert :watchdog_terminalized = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      end)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "failed"
    end

    test "a meeting without a provider thread is closed without a publish loop" do
      now_s = System.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s, thread: false)
      Application.put_env(:salix_meet, :watchdog_test_answer, {:ok, :unavailable})

      ExUnit.CaptureLog.capture_log(fn ->
        assert :watchdog_terminalized = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      end)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "failed"
      assert doc["state"]["delivery"]["status"] == "failed_terminal"
      assert doc["state"]["delivery"]["failure_kind"] == "runtime_lost_no_thread"

      assert :not_claimable = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
    end

    test "a dispatched meeting with no timestamp anchor is counted stuck, never terminalized" do
      attach_operations!()
      now_s = System.system_time(:second)

      meeting_id =
        seed_stuck_meeting(now_s: now_s, drop: ~w(joined_at left_at))

      assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      refute_receive {:probe, _payload}, 100

      assert_receive {:operation,
                      %{
                        component: "salix_meet",
                        operation: "meeting_stuck_nonterminal",
                        outcome: "retained"
                      }}

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "processing"
    end

    test "overlapping sweeps cannot let an unavailable answer kill a live-confirmed meeting" do
      now_s = System.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s)

      # Sweep A holds the meeting-level probe claim and is in flight.
      assert {:ok, gen_a} =
               Store.claim_watchdog_probe(meeting_id, "node-a", now_s: now_s)

      # Sweep B — overlapped after a lost global lease — must neither probe
      # nor decide while A's claim is fresh.
      Application.put_env(:salix_meet, :watchdog_test_answer, {:ok, :unavailable})

      assert :skipped =
               Delivery.deliver_one(meeting_id, watchdog_now_s: now_s, node: "node-b")

      refute_receive {:probe, _payload}, 100
      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "processing"

      # A's definitely-live answer lands under its fence and advances the
      # anchor, releasing the claim.
      assert {:ok, _doc, _etag} = Store.refresh_runtime_liveness(meeting_id, now_s, gen_a)
      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["last_seen_live_at"] == now_s
      refute Map.has_key?(doc["state"], "watchdog_probe")

      # The meeting is no longer eligible: nothing probes, nothing dies.
      assert :skipped =
               Delivery.deliver_one(meeting_id, watchdog_now_s: now_s, node: "node-b")

      refute_receive {:probe, _payload}, 100
      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "processing"
    end

    test "a stale stolen probe cannot decide with its old generation" do
      now_s = System.system_time(:second)
      t0 = System.system_time(:millisecond)
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

    test "a never-dispatched meeting is left to the calendar machinery" do
      now_s = System.system_time(:second)
      meeting_id = seed_stuck_meeting(now_s: now_s, join_requested_at: nil, drop: [])

      assert :skipped = Delivery.deliver_one(meeting_id, watchdog_now_s: now_s)
      refute_receive {:probe, _payload}, 100

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["status"] == "processing"
    end
  end

  describe "bounded retry convergence" do
    test "a delivery failing past both gates converges terminally on its final round" do
      now_ms = System.system_time(:millisecond)

      meeting_id = "mtg-gate-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "tenant_id" => "ten-gate",
                   "group_id" => "grp-gate",
                   "provider" => "slack",
                   "status" => "done",
                   "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
                   "delivery" => %{
                     "status" => "failed",
                     "attempt_count" => 12,
                     "first_failed_at" => now_ms - 25 * 60 * 60 * 1000,
                     "error" => "previous failure"
                   }
                 }
               )

      ExUnit.CaptureLog.capture_log(fn ->
        assert :terminal_failed = Delivery.deliver_one(meeting_id, node: "node-a")
      end)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["delivery"]["status"] == "failed_terminal"
      assert doc["state"]["delivery"]["failure_kind"] == "retry_budget_exhausted"

      assert :not_claimable = Delivery.deliver_one(meeting_id, node: "node-a")
    end

    test "a delivery inside the budget keeps retrying" do
      now_ms = System.system_time(:millisecond)
      meeting_id = "mtg-gate-fresh-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "tenant_id" => "ten-gate",
                   "group_id" => "grp-gate",
                   "provider" => "slack",
                   "status" => "done",
                   "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
                   "delivery" => %{
                     "status" => "failed",
                     "attempt_count" => 2,
                     "first_failed_at" => now_ms - 60_000,
                     "error" => "previous failure"
                   }
                 }
               )

      ExUnit.CaptureLog.capture_log(fn ->
        assert :failed = Delivery.deliver_one(meeting_id, node: "node-a")
      end)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      assert doc["state"]["delivery"]["status"] == "failed"
    end

    test "a disabled connect backs off and reports retained instead of error" do
      meeting_id = "mtg-disabled-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "tenant_id" => "ten-disabled",
                   "group_id" => "grp-disabled",
                   "provider" => "slack",
                   "status" => "done",
                   "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
                 }
               )

      assert {:ok, :delivery, _doc, _etag, claim} =
               Store.claim_terminal_work(meeting_id, "node-a", now: 1_000)

      # A delivery parked on a disabled connect is a known blocked state: it
      # stays exempt from the retry budget (so it can catch up on re-enable),
      # but it must not spin every sweep and must not be reported as a
      # delivery error — that is what would keep the error-rate alert
      # permanently breached for a connect nobody intends to fix.
      assert {:ok, doc, _etag} =
               Store.fail_delivery_retrying(
                 meeting_id,
                 claim,
                 inspect({:connect_unavailable, :disabled}),
                 now: 1_000,
                 retry_after_ms: 300_000
               )

      assert doc["state"]["delivery"]["next_attempt_at"] == 301_000

      # Inside the backoff the sweep does not reclaim it.
      assert {:error, :not_claimable} =
               Store.claim_terminal_work(meeting_id, "node-a", now: 300_999)

      # After it, the wait resumes exactly as before.
      assert {:ok, :delivery, _doc, _etag, next_claim} =
               Store.claim_terminal_work(meeting_id, "node-a", now: 301_000)

      # An ordinary failure clears the backoff rather than inheriting it.
      assert {:ok, cleared, _etag} =
               Store.fail_delivery_retrying(meeting_id, next_claim, "boom", now: 302_000)

      refute cleared["state"]["delivery"]["next_attempt_at"]

      assert {:ok, :delivery, _doc, _etag, _c} =
               Store.claim_terminal_work(meeting_id, "node-a", now: 302_001)
    end

    test "fail_delivery_retrying anchors first_failed_at once" do
      meeting_id = "mtg-first-failed-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id, state: %{"status" => "done"})

      assert {:ok, :delivery, _doc, _etag, claim} =
               Store.claim_terminal_work(meeting_id, "node-a", [])

      assert {:ok, doc, _etag} =
               Store.fail_delivery_retrying(meeting_id, claim, "first", now: 1_000)

      assert doc["state"]["delivery"]["first_failed_at"] == 1_000

      # Each retry round re-claims before failing again.
      assert {:ok, :delivery, _doc, _etag, claim} =
               Store.claim_terminal_work(meeting_id, "node-a", now: 1_500)

      assert {:ok, doc, _etag} =
               Store.fail_delivery_retrying(meeting_id, claim, "second", now: 2_000)

      assert doc["state"]["delivery"]["first_failed_at"] == 1_000
      assert doc["state"]["delivery"]["updated_at"] == 2_000
    end
  end
end
