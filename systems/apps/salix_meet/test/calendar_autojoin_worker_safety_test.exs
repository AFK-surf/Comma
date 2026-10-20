defmodule SalixMeet.CalendarAutojoinWorkerSafetyTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

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

      SystemsRuntime.Proc.send(test_pid, {:s3_put_started, caller, key})
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

      SystemsRuntime.Proc.send(test_pid, {:s3_put_finished, caller, key, result})
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
      caller = SystemsRuntime.Proc.self()

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
      caller = SystemsRuntime.Proc.self()
      block? = S3Control.begin_put(key, caller)

      if block? do
        SystemsRuntime.Proc.receive do
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
      config = SystemsRuntime.fetch_env!(:salix_meet, :calendar_worker_safety_test)
      events = get_in(config, [:events_by_group, group["group_id"]]) || []

      if config[:block_upcoming?] do
        SystemsRuntime.Proc.send(
          config.test_pid,
          {:calendar_upcoming_started, SystemsRuntime.Proc.self(), group["group_id"]}
        )

        SystemsRuntime.Proc.receive do
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
      ref = SystemsRuntime.Proc.monitor(caller)
      active = Map.put(state.active, ref, caller)
      call = %{caller: caller, doc: doc}
      SystemsRuntime.Proc.send(state.test_pid, {:slow_runtime_started, caller, doc})

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
      :ok = SlowRuntimeTracker.begin(SystemsRuntime.Proc.self(), doc)

      SystemsRuntime.Proc.receive do
        {:release_slow_runtime, result} -> result
      end
    end
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      calendar: SystemsRuntime.get_env(:salix_meet, :calendar_occurrences_mod),
      channel: SystemsRuntime.get_env(:salix_meet, :meeting_channel_mod),
      runtime_driver: SystemsRuntime.get_env(:salix_meet, :runtime_driver),
      copilot_enabled: SystemsRuntime.get_env(:salix_meet, :copilot_enabled),
      calendar_test: SystemsRuntime.get_env(:salix_meet, :calendar_worker_safety_test)
    }

    stop_all_meetings()
    ensure_started!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    start_supervised!(S3Control)
    start_supervised!(SlowRuntimeTracker)

    SystemsRuntime.put_env(:salix_store, :s3_backend, ControlledS3)
    SystemsRuntime.put_env(:salix_meet, :calendar_occurrences_mod, TestCalendar)
    SystemsRuntime.put_env(:salix_meet, :meeting_channel_mod, TestChannel)
    SystemsRuntime.put_env(:salix_meet, :runtime_driver, SlowRuntimeDriver)
    SystemsRuntime.put_env(:salix_meet, :copilot_enabled, false)

    configure_calendar([])
    S3Control.configure(SystemsRuntime.Proc.self())
    SlowRuntimeTracker.configure(SystemsRuntime.Proc.self())

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

  test "a stale projection checkpoint cannot advance the production scan cursor" do
    group = group("stale")
    initial = event("initial", @now + 30_000)
    worker_event = event("worker", @now + 40_000)
    competing_event = event("competitor", @now + 50_000)
    seed_projection!(group, [initial])
    configure_calendar([{group, [worker_event]}], block_upcoming: true)

    _worker = start_worker!([group], max_concurrency: 1)
    assert_receive {:calendar_upcoming_started, group_task, "group-stale"}

    assert {:ok, competing_snapshot} =
             CalendarProjection.load(group, max_events: 1, lease_epoch: 999, now: @now + 1)

    assert {:ok, competing_projection, %{partial_errors: []}} =
             CalendarProjection.reconcile(competing_snapshot, [competing_event], %{},
               max_events: 1,
               now: @now + 1
             )

    assert {:ok, _projection} = CalendarProjection.checkpoint(competing_projection)
    SystemsRuntime.Proc.send(group_task, :release_calendar_upcoming)

    projection_key = CalendarProjection.key(group["group_id"])

    assert eventually(fn -> not SystemsRuntime.Proc.alive?(group_task) end)

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

    normal = SystemsRuntime.Proc.spawn(fn -> SystemsRuntime.Proc.link(worker) end)

    abnormal =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.link(worker)
        exit({:shutdown, :helper_failed})
      end)

    assert eventually(fn ->
             not SystemsRuntime.Proc.alive?(normal) and not SystemsRuntime.Proc.alive?(abnormal)
           end)

    assert :sys.get_state(worker)
    assert SystemsRuntime.Proc.alive?(worker)
    assert {:ok, _} = S3.get(@lease_key)
  end

  test "lease loss after group work prevents projection and scan-cursor checkpoints" do
    group = group("lease-loss")
    configure_calendar([{group, [event("worker", @now + 30_000)]}], block_upcoming: true)

    worker = start_worker!([group], max_concurrency: 1)
    assert_receive {:calendar_upcoming_started, group_task, "group-lease-loss"}

    stolen_lease = %{
      holder: "other-worker",
      epoch: 999,
      lease_until: SystemsClock.system_time(:millisecond) + 300_000
    }

    assert {:ok, _} =
             SalixStore.S3.Fake.put(@lease_key, Jason.encode!(stolen_lease), [])

    SystemsRuntime.Proc.send(group_task, :release_calendar_upcoming)

    assert eventually(fn -> not SystemsRuntime.Proc.alive?(group_task) end)

    assert eventually(fn -> :sys.get_state(worker).lease == nil end)

    assert {:error, :not_found} = S3.get(CalendarProjection.key(group["group_id"]))
    assert {:error, :not_found} = S3.get(Keys.ctl_meet_calendar_scan_cursor())

    stop_supervised!(CalendarAutojoin)
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

  defp configure_calendar(group_events, opts \\ []) do
    events_by_group = Map.new(group_events, fn {group, events} -> {group["group_id"], events} end)

    SystemsRuntime.put_env(:salix_meet, :calendar_worker_safety_test, %{
      test_pid: SystemsRuntime.Proc.self(),
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

  defp eventually(fun, retries \\ 1500) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp ensure_started!(module) do
    case SystemsRuntime.Proc.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp stop_all_meetings do
    if SystemsRuntime.Proc.whereis(SalixMeet.MeetingSup) do
      SalixMeet.MeetingSup
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
      end)
    end

    :ok
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
