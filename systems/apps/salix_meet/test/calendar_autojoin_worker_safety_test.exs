defmodule SalixMeet.CalendarAutojoinWorkerSafetyTest do
  use ExUnit.Case, async: false

  alias SalixMeet.{CalendarAutojoin, CalendarProjection, Meeting, Store}
  alias SalixStore.{Keys, S3}

  @lease_key "ctl/meet/calendar_autojoin/lease.json"
  @now 10_000_000

  defmodule S3Control do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{test_pid: nil, block_projection?: false, events: [], max_active: 0, active: 0}
        end,
        name: __MODULE__
      )
    end

    def configure(test_pid, opts \\ []) do
      Agent.update(__MODULE__, fn _state ->
        %{
          test_pid: test_pid,
          block_projection?: Keyword.get(opts, :block_projection, false),
          rate_limit_lease?: Keyword.get(opts, :rate_limit_lease, false),
          events: [],
          max_active: 0,
          active: 0
        }
      end)
    end

    def begin_put(key, caller) do
      projection? = String.starts_with?(key, "ctl/meet/calendar_autojoin/groups/")

      {test_pid, block?} =
        Agent.get_and_update(__MODULE__, fn state ->
          active = if projection?, do: state.active + 1, else: state.active

          state = %{
            state
            | active: active,
              max_active: max(state.max_active, active),
              events: state.events ++ [{:put_started, key, caller}]
          }

          {{state.test_pid, projection? and state.block_projection?}, state}
        end)

      send(test_pid, {:s3_put_started, caller, key})
      block?
    end

    def finish_put(key, caller, result) do
      projection? = String.starts_with?(key, "ctl/meet/calendar_autojoin/groups/")

      test_pid =
        Agent.get_and_update(__MODULE__, fn state ->
          active = if projection?, do: max(state.active - 1, 0), else: state.active

          {state.test_pid,
           %{
             state
             | active: active,
               events: state.events ++ [{:put_finished, key, caller, result}]
           }}
        end)

      send(test_pid, {:s3_put_finished, caller, key, result})
      :ok
    end

    def events, do: Agent.get(__MODULE__, & &1.events)
    def max_active, do: Agent.get(__MODULE__, & &1.max_active)

    def rate_limit_lease?(key) do
      Agent.get(__MODULE__, fn state ->
        state[:rate_limit_lease?] and key == "ctl/meet/calendar_autojoin/lease.json" and
          Enum.count(state.events, &match?({:put_started, ^key, _}, &1)) > 1
      end)
    end

    def record_head(key, result) do
      caller = self()

      Agent.update(
        __MODULE__,
        &%{&1 | events: &1.events ++ [{:head_finished, key, caller, result}]}
      )

      result
    end
  end

  defmodule ControlledS3 do
    @behaviour SalixStore.S3

    @impl true
    def put(key, body, opts) do
      caller = self()
      block? = S3Control.begin_put(key, caller)

      if block? do
        receive do
          {:release_s3_put, ^key} -> :ok
        end
      end

      result =
        if S3Control.rate_limit_lease?(key),
          do: {:error, {:http, 429}},
          else: SalixStore.S3.Fake.put(key, body, opts)

      S3Control.finish_put(key, caller, result)
      result
    end

    @impl true
    def put_stream(key, stream, opts), do: SalixStore.S3.Fake.put_stream(key, stream, opts)

    @impl true
    def get(key, opts), do: SalixStore.S3.Fake.get(key, opts)

    @impl true
    def stream(key, opts), do: SalixStore.S3.Fake.stream(key, opts)

    @impl true
    def head(key), do: S3Control.record_head(key, SalixStore.S3.Fake.head(key))

    @impl true
    def delete(key, opts), do: SalixStore.S3.Fake.delete(key, opts)

    @impl true
    def list(prefix, opts), do: SalixStore.S3.Fake.list(prefix, opts)

    @impl true
    def multipart_create(key, opts), do: SalixStore.S3.Fake.multipart_create(key, opts)

    @impl true
    def multipart_upload_part(key, upload_id, part_number, body),
      do: SalixStore.S3.Fake.multipart_upload_part(key, upload_id, part_number, body)

    @impl true
    def multipart_complete(key, upload_id, parts),
      do: SalixStore.S3.Fake.multipart_complete(key, upload_id, parts)

    @impl true
    def multipart_abort(key, upload_id),
      do: SalixStore.S3.Fake.multipart_abort(key, upload_id)
  end

  defmodule TestCalendar do
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(group, _t0_ms, _t1_ms) do
      config = Application.fetch_env!(:salix_meet, :calendar_worker_safety_test)
      events = get_in(config, [:events_by_group, group["group_id"]]) || []

      if config[:block_upcoming?] do
        send(config.test_pid, {:calendar_upcoming_started, self(), group["group_id"]})

        receive do
          :release_calendar_upcoming -> {:ok, events}
        end
      else
        {:ok, events}
      end
    end

    @impl true
    def revalidate(_group, _event), do: :ok
  end

  defmodule TestChannel do
    @behaviour SalixMeet.Ports.MeetingChannel

    @impl true
    def resolve(_group), do: {:error, :unexpected_channel_resolution}
  end

  defmodule SlowRuntimeTracker do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

    def configure(test_pid), do: GenServer.call(__MODULE__, {:configure, test_pid})
    def begin(caller, doc), do: GenServer.call(__MODULE__, {:begin, caller, doc})
    def snapshot, do: GenServer.call(__MODULE__, :snapshot)

    @impl true
    def init(_opts), do: {:ok, empty(nil)}

    @impl true
    def handle_call({:configure, test_pid}, _from, _state),
      do: {:reply, :ok, empty(test_pid)}

    def handle_call({:begin, caller, doc}, _from, state) do
      ref = Process.monitor(caller)
      active = Map.put(state.active, ref, caller)
      call = %{caller: caller, doc: doc}
      send(state.test_pid, {:slow_runtime_started, caller, doc})

      {:reply, :ok,
       %{
         state
         | active: active,
           max_active: max(state.max_active, map_size(active)),
           calls: state.calls ++ [call]
       }}
    end

    def handle_call(:snapshot, _from, state), do: {:reply, state, state}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
      do: {:noreply, %{state | active: Map.delete(state.active, ref)}}

    defp empty(test_pid), do: %{test_pid: test_pid, active: %{}, max_active: 0, calls: []}
  end

  defmodule SlowRuntimeDriver do
    @behaviour SalixMeet.RuntimeDriver

    @impl true
    def join(doc) do
      :ok = SlowRuntimeTracker.begin(self(), doc)

      receive do
        {:release_slow_runtime, result} -> result
      end
    end
  end

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      calendar: Application.get_env(:salix_meet, :calendar_occurrences_mod),
      channel: Application.get_env(:salix_meet, :meeting_channel_mod),
      runtime_driver: Application.get_env(:salix_meet, :runtime_driver),
      copilot_enabled: Application.get_env(:salix_meet, :copilot_enabled),
      calendar_test: Application.get_env(:salix_meet, :calendar_worker_safety_test)
    }

    stop_all_meetings()
    ensure_started!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    start_supervised!(S3Control)
    start_supervised!(SlowRuntimeTracker)

    Application.put_env(:salix_store, :s3_backend, ControlledS3)
    Application.put_env(:salix_meet, :calendar_occurrences_mod, TestCalendar)
    Application.put_env(:salix_meet, :meeting_channel_mod, TestChannel)
    Application.put_env(:salix_meet, :runtime_driver, SlowRuntimeDriver)
    Application.put_env(:salix_meet, :copilot_enabled, false)

    configure_calendar([])
    S3Control.configure(self())
    SlowRuntimeTracker.configure(self())

    on_exit(fn ->
      stop_all_meetings()
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_meet, :calendar_occurrences_mod, previous.calendar)
      restore_env(:salix_meet, :meeting_channel_mod, previous.channel)
      restore_env(:salix_meet, :runtime_driver, previous.runtime_driver)
      restore_env(:salix_meet, :copilot_enabled, previous.copilot_enabled)
      restore_env(:salix_meet, :calendar_worker_safety_test, previous.calendar_test)
    end)

    :ok
  end

  @tag :lease_rate_limit
  test "a scan checkpoints without another lease mutation while its acquired lease is fresh" do
    group = group("lease-rate-limit")
    configure_calendar([{group, []}])
    S3Control.configure(self(), rate_limit_lease: true)

    worker = start_worker!([group], max_concurrency: 1)

    assert eventually(fn -> match?({:ok, _}, S3.get(Keys.ctl_meet_calendar_scan_cursor())) end)
    assert {:ok, _} = S3.get(CalendarProjection.key(group["group_id"]))
    assert :sys.get_state(worker).lease

    assert Enum.count(S3Control.events(), &match?({:put_started, @lease_key, _}, &1)) == 1
  end

  @tag :lease_rate_limit
  test "a long scan renews before its remaining lease falls below its whole wave budget" do
    groups = Enum.map(1..25, &group("lease-budget-#{&1}"))
    configure_calendar(Enum.map(groups, &{&1, []}))
    worker = start_worker!(groups, max_concurrency: 5, task_timeout_ms: 30_000)
    assert eventually(fn -> match?({:ok, _}, S3.get(Keys.ctl_meet_calendar_scan_cursor())) end)

    state = :sys.get_state(worker)
    # 200 seconds exceeds half the TTL, but does not cover a 150-second
    # work wave plus the existing 120-second request margin.
    assert {:ok, aged} =
             SalixStore.Lease.renew(state.lease,
               now: System.system_time(:millisecond) - 100_000,
               ttl_ms: 300_000
             )

    :sys.replace_state(worker, &%{&1 | lease: aged})
    SalixStore.S3.Fake.reset_put_log()

    send(worker, :scan_tick)
    assert :sys.get_state(worker).lease.lease_until > aged.lease_until
    assert Enum.count(SalixStore.S3.Fake.put_log(), &(&1 == @lease_key)) == 1
  end

  test "a stale projection checkpoint cannot advance the production scan cursor" do
    group = group("stale")
    initial = event("initial", @now + 30_000)
    worker_event = event("worker", @now + 40_000)
    competing_event = event("competitor", @now + 50_000)
    seed_projection!(group, [initial])
    configure_calendar([{group, [worker_event]}], block_upcoming: true)

    _worker = start_worker!([group], max_concurrency: 1)
    assert_receive {:calendar_upcoming_started, group_task, "group-stale"}, 1_000

    assert {:ok, competing_snapshot} =
             CalendarProjection.load(group, max_events: 1, lease_epoch: 999, now: @now + 1)

    assert {:ok, competing_projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(competing_snapshot, [competing_event], %{},
               max_events: 1,
               now: @now + 1
             )

    assert {:ok, _projection} = CalendarProjection.checkpoint(competing_projection)
    send(group_task, :release_calendar_upcoming)

    projection_key = CalendarProjection.key(group["group_id"])

    assert eventually(fn -> not Process.alive?(group_task) end)

    assert eventually(fn ->
             Enum.count(SalixStore.S3.Fake.put_log(), &(&1 == projection_key)) >= 3
           end)

    assert {:error, :not_found} = S3.get(Keys.ctl_meet_calendar_scan_cursor())

    assert {:ok, persisted} = CalendarProjection.load(group, max_events: 1)

    assert [%{"event" => %{"event_id" => "competitor"}}] =
             CalendarProjection.to_map(persisted)["fresh"]

    stop_supervised!(CalendarAutojoin)
  end

  # A rolling deploy stops the lease holder. Before this the lease object was
  # left to age out (@lease_ttl_ms = 5 minutes), so the successor node could
  # not run a single join pass for up to that long — longer than a meeting's
  # whole T-2 window. Supervisor shutdown must reach terminate/2 and release.
  test "supervisor shutdown releases the autojoin lease instead of leaving it to expire" do
    group = group("lease-release")
    configure_calendar([{group, [event("worker", @now + 30_000)]}])

    _worker = start_worker!([group], max_concurrency: 1)
    assert eventually(fn -> match?({:ok, _}, S3.get(@lease_key)) end)

    stop_supervised!(CalendarAutojoin)

    assert {:error, :not_found} = S3.get(@lease_key)
  end

  # Trapping exits (for the release above) makes every linked helper's exit a mailbox message. In
  # production the S3 client runs each request in a `Task.async`, so the very first store call after boot
  # delivers `{:EXIT, task, :normal}` to the worker; the fake store in tests never does, which is how the
  # crash loop reached staging unnoticed. Simulate the linked exits directly.
  test "linked helper exits do not crash the trapping worker" do
    group = group("linked-exit")
    configure_calendar([{group, [event("worker", @now + 30_000)]}])

    worker = start_worker!([group], max_concurrency: 1)
    assert eventually(fn -> match?({:ok, _}, S3.get(@lease_key)) end)

    normal = spawn(fn -> Process.link(worker) end)

    abnormal =
      spawn(fn ->
        Process.link(worker)
        exit({:shutdown, :helper_failed})
      end)

    assert eventually(fn -> not Process.alive?(normal) and not Process.alive?(abnormal) end)

    assert :sys.get_state(worker)
    assert Process.alive?(worker)
    assert {:ok, _} = S3.get(@lease_key)
  end

  test "lease loss after group work prevents projection and scan-cursor checkpoints" do
    group = group("lease-loss")
    configure_calendar([{group, [event("worker", @now + 30_000)]}], block_upcoming: true)

    worker = start_worker!([group], max_concurrency: 1)
    assert_receive {:calendar_upcoming_started, group_task, "group-lease-loss"}, 1_000

    stolen_lease = %{
      holder: "other-worker",
      epoch: 999,
      lease_until: System.system_time(:millisecond) + 300_000
    }

    assert {:ok, _} =
             SalixStore.S3.Fake.put(@lease_key, Jason.encode!(stolen_lease), [])

    send(group_task, :release_calendar_upcoming)

    assert eventually(fn -> not Process.alive?(group_task) end)

    assert eventually(fn -> :sys.get_state(worker).lease == nil end)

    assert {:error, :not_found} = S3.get(CalendarProjection.key(group["group_id"]))
    assert {:error, :not_found} = S3.get(Keys.ctl_meet_calendar_scan_cursor())

    stop_supervised!(CalendarAutojoin)
  end

  test "projection checkpoints respect max concurrency and surround the cursor with owner checks" do
    groups = Enum.map(1..3, &group("checkpoint-#{&1}"))
    configure_calendar(Enum.map(groups, &{&1, []}))
    S3Control.configure(self(), block_projection: true)

    _worker = start_worker!(groups, max_concurrency: 2, task_timeout_ms: 1_000)

    first_two =
      for _ <- 1..2 do
        receive_projection_started!()
      end

    refute_receive {:s3_put_started, _pid, "ctl/meet/calendar_autojoin/groups/" <> _}, 75

    Enum.each(first_two, fn {pid, key} -> send(pid, {:release_s3_put, key}) end)

    assert_receive {:s3_put_started, third_pid,
                    "ctl/meet/calendar_autojoin/groups/" <> _ = third_key},
                   1_000

    send(third_pid, {:release_s3_put, third_key})

    assert eventually(fn -> match?({:ok, _}, S3.get(Keys.ctl_meet_calendar_scan_cursor())) end)
    assert S3Control.max_active() == 2

    assert eventually(fn ->
             events = S3Control.events()
             scan_cursor_key = Keys.ctl_meet_calendar_scan_cursor()

             cursor_index =
               Enum.find_index(events, &match?({:put_started, ^scan_cursor_key, _}, &1))

             is_integer(cursor_index) and
               events
               |> Enum.drop(cursor_index + 1)
               |> Enum.any?(&match?({:head_finished, @lease_key, _, {:ok, _}}, &1))
           end)

    events = S3Control.events()
    scan_cursor_key = Keys.ctl_meet_calendar_scan_cursor()

    cursor_index =
      event_index!(events, fn event -> match?({:put_started, ^scan_cursor_key, _}, event) end)

    projection_finished_indexes =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:put_finished, "ctl/meet/calendar_autojoin/groups/" <> _, _, _}, index} -> [index]
        _ -> []
      end)

    owner_check_indexes =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:head_finished, @lease_key, _, {:ok, _}}, index} -> [index]
        _ -> []
      end)

    assert Enum.max(projection_finished_indexes) < cursor_index

    assert Enum.any?(
             owner_check_indexes,
             &(&1 > Enum.max(projection_finished_indexes) and &1 < cursor_index)
           )

    assert Enum.any?(owner_check_indexes, &(&1 > cursor_index))

    stop_supervised!(CalendarAutojoin)
  end

  test "a timed-out projection checkpoint wave does not advance the scan cursor" do
    groups = Enum.map(1..3, &group("checkpoint-timeout-#{&1}"))
    configure_calendar(Enum.map(groups, &{&1, []}))
    S3Control.configure(self(), block_projection: true)

    _worker = start_worker!(groups, max_concurrency: 2, task_timeout_ms: 50)

    projection_tasks =
      for _ <- 1..3 do
        {pid, _key} = receive_projection_started!()
        pid
      end

    assert eventually(fn -> Enum.all?(projection_tasks, &(not Process.alive?(&1))) end)

    assert eventually(fn ->
             match?({:ok, _}, S3.get(Keys.ctl_meet_calendar_join_cursor()))
           end)

    assert {:error, :not_found} = S3.get(Keys.ctl_meet_calendar_scan_cursor())

    stop_supervised!(CalendarAutojoin)
  end

  test "slow runtime calls stay within calendar concurrency and die with timed-out callers" do
    groups = Enum.map(1..4, &group("slow-runtime-#{&1}"))

    meeting_pids =
      Enum.map(groups, fn group ->
        event = event("event-#{group["group_id"]}", @now + 30_000)
        seed_projection!(group, [event])
        seed_meeting!(group, event)
      end)

    results =
      CalendarAutojoin.join_sweep(groups,
        now: @now,
        group_bounded: true,
        max_groups_per_pass: 4,
        max_joins_per_pass: 4,
        max_events_per_group: 1,
        max_concurrency: 2,
        task_timeout_ms: 75
      )

    assert length(results) == 4
    assert Enum.all?(results, &match?(%{action: :error, reason: {:task_exit, :timeout}}, &1))
    assert eventually(fn -> map_size(SlowRuntimeTracker.snapshot().active) == 0 end)

    tracker = SlowRuntimeTracker.snapshot()
    assert tracker.max_active == 2
    assert length(tracker.calls) == 4
    assert Enum.all?(tracker.calls, &(&1.caller not in meeting_pids))
    assert Enum.all?(tracker.calls, &(not Process.alive?(&1.caller)))
    assert Enum.all?(meeting_pids, &Process.alive?/1)

    for group <- groups do
      event = event("event-#{group["group_id"]}", @now + 30_000)
      mid = CalendarAutojoin.meeting_id(group, event)
      assert Meeting.leader?(mid)
      assert {:ok, doc, _etag} = Store.get(mid)
      assert get_in(doc, ["state", "join_dispatch", "status"]) == "dispatching"
    end

    assert [] =
             CalendarAutojoin.join_sweep(groups,
               now: @now,
               group_bounded: true,
               max_groups_per_pass: 4,
               max_joins_per_pass: 4,
               max_events_per_group: 1,
               max_concurrency: 2,
               task_timeout_ms: 75
             )

    assert length(SlowRuntimeTracker.snapshot().calls) == 4
  end

  defp start_worker!(groups, opts) do
    start_supervised!(
      {CalendarAutojoin,
       [
         name: :calendar_autojoin_worker_safety_test,
         node: "calendar-autojoin-worker-safety-test",
         groups: groups,
         scan_interval_ms: 60_000,
         join_interval_ms: 60_000,
         max_groups_per_pass: length(groups),
         max_events_per_group: 1
       ] ++ opts}
    )
  end

  defp seed_projection!(group, events) do
    assert {:ok, empty} = CalendarProjection.load(group, max_events: 1, now: @now)

    assert {:ok, projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(empty, events, %{}, max_events: 1, now: @now)

    assert {:ok, checkpointed} = CalendarProjection.checkpoint(projection)
    checkpointed
  end

  defp seed_meeting!(group, event) do
    mid = CalendarAutojoin.meeting_id(group, event)
    start_s = div(event["start_ms"], 1_000)
    end_s = div(event["end_ms"], 1_000)

    state = %{
      "tenant_id" => group["tenant_id"],
      "group_id" => group["group_id"],
      "connect_id" => "slack-worker-safety",
      "slack_ref" => %{"channel_id" => "C-worker-safety", "thread_ts" => "111.222"},
      "meet_url" => event["meet_url"],
      "start_at" => start_s,
      "end_at" => end_s,
      "status" => "provisioning",
      "source" => %{
        "kind" => "calendar",
        "event_id" => event["event_id"],
        "calendar_id" => event["calendar_id"],
        "calendar_item_id" => event["calendar_item_id"],
        "occurrence_ref" => event["occurrence_ref"],
        "meeting_plan_id" => event["meeting_plan_id"],
        "workspace_id" => "T-worker-safety"
      }
    }

    assert {:ok, _doc, _etag} = Store.create_once(mid, state: state, now: @now)

    assert {:ok, pid} =
             SalixMeet.Application.start_meeting(mid,
               node: "calendar-worker-safety-#{group["group_id"]}",
               interval_ms: 60_000
             )

    assert eventually(fn -> Meeting.leader?(mid) end)
    pid
  end

  defp configure_calendar(group_events, opts \\ []) do
    events_by_group = Map.new(group_events, fn {group, events} -> {group["group_id"], events} end)

    Application.put_env(:salix_meet, :calendar_worker_safety_test, %{
      test_pid: self(),
      block_upcoming?: Keyword.get(opts, :block_upcoming, false),
      events_by_group: events_by_group
    })
  end

  defp group(suffix) do
    %{
      "tenant_id" => "tenant-worker-safety",
      "group_id" => "group-#{suffix}",
      "calendar_id" => "primary@example.com",
      "calendar_connected_account_id" => "ca-worker-safety"
    }
  end

  defp event(id, start_ms) do
    %{
      "event_id" => id,
      "calendar_item_id" => "item-#{id}",
      "occurrence_ref" => occurrence_ref(id, start_ms),
      "meeting_plan_id" => "plan-#{id}",
      "start_ms" => start_ms,
      "end_ms" => start_ms + 1_800_000,
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "title" => "Calendar #{id}",
      "calendar_id" => "primary@example.com",
      "calendar_connected_account_id" => "ca-worker-safety"
    }
  end

  defp occurrence_ref(id, start_ms) do
    %{
      "calendar_id" => "primary@example.com",
      "scheduling_link_id" => "link-#{id}",
      "recurrence_key" => %{"kind" => "recurring", "value" => "slot-#{start_ms}"}
    }
  end

  defp event_index!(events, predicate) do
    Enum.find_index(events, predicate) || flunk("expected event not found: #{inspect(events)}")
  end

  defp receive_projection_started! do
    receive do
      {:s3_put_started, pid, "ctl/meet/calendar_autojoin/groups/" <> _ = key} ->
        {pid, key}

      _other ->
        receive_projection_started!()
    after
      1_000 ->
        flunk("timed out waiting for a projection checkpoint")
    end
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp stop_all_meetings do
    if Process.whereis(SalixMeet.MeetingSup) do
      SalixMeet.MeetingSup
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
      end)
    end

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
