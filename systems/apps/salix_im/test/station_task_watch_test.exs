defmodule SalixIM.StationTaskWatchTest do
  @moduledoc """
  A Task that runs on a station is watched for a delegation its Worker does
  not answer (`SalixIM.StationTaskWatch`): the watch reads the Task's
  Messages and the station's standing, logs one `station_task_stalled` per
  delegation and stage, counts it, and records every delegation's first
  reply. It writes nothing into the Task. The station answers as the test
  says (`Stations`); the Task is real.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias SalixIM.{
    ConversationActor,
    ConversationPlacement,
    ConversationServer,
    Conversations,
    TaskConversationInput
  }

  alias SalixStore.{Ids, Keys}

  @stalled [:salix_im, :station_task, :stalled]
  @answered [:salix_im, :station_task, :answered]
  @thresholds [
    vm_not_ready_ms: 1_000,
    station_offline_ms: 1_000,
    not_given_ms: 1_000,
    given_no_reply_ms: 10_000,
    running_ms: 3_000,
    idle_no_reply_ms: 2_000,
    cannot_start_ms: 3_000,
    recheck_ms: 1_000,
    stale_ms: 60_000
  ]
  @nudge SalixIM.TaskWorkerWatch.nudge_type()
  @notify SalixIM.TaskWorkerWatch.notify_type()
  @given {:ok, %{place: :cloud_vm, connected?: true, sent: 1, vm_status: "ready"}}

  defmodule Stations do
    @moduledoc "The stations Tasks run on (`SalixIM.Ports.TaskStations`): where one stands, as the test says."
    @behaviour SalixIM.Ports.TaskStations
    use Agent

    def start_link(_),
      do:
        SystemsRuntime.Agent.start_link(
          fn -> %{standing: :not_station, session: :unknown, asked: 0, asked_session: 0} end,
          name: __MODULE__
        )

    def answer(standing), do: SystemsRuntime.Agent.update(__MODULE__, &%{&1 | standing: standing})
    def asked, do: SystemsRuntime.Agent.get(__MODULE__, & &1.asked)

    @doc "What the station says of its Session when asked (`task.status`); `:unknown` is a station that cannot say."
    def session(status), do: SystemsRuntime.Agent.update(__MODULE__, &%{&1 | session: status})
    def asked_session, do: SystemsRuntime.Agent.get(__MODULE__, & &1.asked_session)

    @impl true
    def invite(_invitation), do: {:ok, "ember:c-1"}

    @impl true
    def joined(_row), do: :ok

    @impl true
    def appended(_group_id, _conversation_id), do: :ok

    @impl true
    def sandbox(_reservation), do: {:error, :no_sandboxes}

    @impl true
    def task_status(_group_id, _conversation_id, _status), do: :ok

    @impl true
    def standing(_group_id, _conversation_id) do
      case SystemsRuntime.Agent.get_and_update(
             __MODULE__,
             &{&1.standing, %{&1 | asked: &1.asked + 1}}
           ) do
        :raise -> raise "the station port fell over"
        standing -> standing
      end
    end

    @impl true
    def session_status(_group_id, _conversation_id) do
      SystemsRuntime.Agent.get_and_update(
        __MODULE__,
        &{&1.session, %{&1 | asked_session: &1.asked_session + 1}}
      )
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery},
      {:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity},
      {:salix_im, :task_stations_mod, Stations},
      {:salix_im, :station_task_watch, @thresholds}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)

    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)
    start_supervised!(Stations)

    test_pid = SystemsRuntime.Proc.self()
    handler = "station-task-watch-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [@stalled, @answered],
        fn event, measurements, metadata, pid ->
          SystemsRuntime.Proc.send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        Enum.each(previous, fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, value} -> SystemsRuntime.put_env(app, key, value)
        end)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Station Task watch"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok,
     group_id: group_id,
     router_id: router["agent_id"],
     worker_id: worker["agent_id"],
     device_id: "dev-station-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  test "a Task whose Worker is a Salix Session is left to the Worker watch", ctx do
    {_conversation_id, watch, _worker_pid} = start_task(ctx, "plain-task", false)

    settle_after(2_000)
    assert %{worker_agent_id: nil, pending: nil} = :sys.get_state(watch, :infinity)
    assert Stations.asked() == 0
    refute_received {:telemetry, _, _, _}
  end

  test "an unanswered delegation is reported once per stage, and its reply once reported", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "stalled-task")
    assert %{pending: %{epoch: 1, reported: [], timer: timer}} = :sys.get_state(watch, :infinity)
    assert is_reference(timer)

    # The Group's Cloud VM has not come back for the delegation: the Router
    # is told once, nothing else says so.
    Stations.answer({:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "waking"}})
    log = capture_log(fn -> settle_after(1_000) end)

    assert log =~
             "station Task delegation unanswered: stage=vm_not_ready place=cloud_vm vm_status=waking epoch=1"

    assert log =~ "canary=false"

    assert_received {:telemetry, @stalled, %{count: 1},
                     %{phase: :vm_not_ready, kind: :cloud_vm, canary: false}}

    assert %{pending: %{epoch: 1, reported: [:vm_not_ready]}} = :sys.get_state(watch, :infinity)
    router_pid = router_participant(ctx, conversation_id)
    assert [{@notify, [^router_pid], told}] = watch_messages(ctx, conversation_id)
    assert told["reason"] == "vm_not_ready"
    assert told["vm_status"] == "waking"
    assert {:ok, [message]} = messages_of_type(ctx, conversation_id, @notify)

    assert text(message["content"]) =~
             "the VM has not come up for it (vm_not_ready: its status is waking)"

    # The same stage again says nothing more.
    log = capture_log(fn -> settle_after(1_000) end)
    refute log =~ "station Task delegation unanswered"
    refute_received {:telemetry, @stalled, _, _}
    assert length(watch_messages(ctx, conversation_id)) == 1

    # The VM came up, but the station is not connected: a new stage.
    Stations.answer({:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "ready"}})
    log = capture_log(fn -> settle_after(1_000) end)
    assert log =~ "stage=station_offline place=cloud_vm vm_status=ready epoch=1"
    assert_received {:telemetry, @stalled, _, %{phase: :station_offline, kind: :cloud_vm}}

    # Given and silent, 4 s in: not yet past that stage's threshold of 10 s.
    Stations.answer({:ok, %{place: :cloud_vm, connected?: true, sent: 1, vm_status: "ready"}})
    log = capture_log(fn -> settle_after(1_000) end)
    refute log =~ "station Task delegation unanswered"
    refute_received {:telemetry, @stalled, _, _}

    # Past it, with a station that cannot say where its Session stands (one
    # from before task.status): the last stage of this delegation, checked
    # every second meanwhile.
    log = capture_log(fn -> settle_after(6_000) end)
    assert log =~ "stage=given_no_reply place=cloud_vm vm_status=ready epoch=1"
    assert_received {:telemetry, @stalled, _, %{phase: :given_no_reply, kind: :cloud_vm}}
    refute_received {:telemetry, @stalled, _, _}
    assert Stations.asked_session() > 0

    # The VM's station Session answers: the wait is recorded, the stall is over.
    vm = SalixStore.RuntimeIds.cloud_vm_device_id(ctx.group_id)

    log =
      capture_log(fn ->
        assert {:ok, _reply} =
                 station_post(
                   %{ctx | device_id: vm},
                   conversation_id,
                   worker_pid,
                   "done",
                   "all_done"
                 )

        settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
      end)

    assert log =~
             "station Task delegation answered after a stall: stage=given_no_reply place=cloud_vm epoch=1"

    assert_received {:telemetry, @answered, %{duration: waited},
                     %{kind: :cloud_vm, canary: false}}

    assert waited >= 10_000

    # Nothing more of the watch's went into the Task: the Router was told once.
    assert [{@notify, _, %{"reason" => "vm_not_ready"}}, "agent"] =
             watch_messages(ctx, conversation_id, true)

    settle_after(2_000)
    refute_received {:telemetry, @stalled, _, _}
  end

  test "a Session that runs is waited for: no stall, no reminder, one note past running_ms",
       ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "running-task")
    Stations.answer(@given)
    Stations.session({:ok, %{state: :running, pending: 0, for_ms: 500, last_failure: nil}})

    log = capture_log(fn -> settle_after(2_500) end)
    refute log =~ "station Task delegation unanswered"
    refute log =~ "still being worked on"
    refute_received {:telemetry, @stalled, _, _}

    log = capture_log(fn -> settle_after(1_500) end)

    assert log =~
             "still being worked on: stage=running place=cloud_vm station_state=running epoch=1"

    refute_received {:telemetry, @stalled, _, _}

    # Said once; an agent waiting on work it started is the same stage.
    Stations.session({:ok, %{state: :waiting, pending: 0, for_ms: 0, last_failure: nil}})
    log = capture_log(fn -> settle_after(2_000) end)
    refute log =~ "still being worked on"
    assert watch_messages(ctx, conversation_id) == []

    assert {:ok, _reply} = station_post(ctx, conversation_id, worker_pid, "done", "all_done")
    settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
    assert_received {:telemetry, @answered, _, _}
    refute_received {:telemetry, @stalled, _, _}
  end

  test "a Session idle without a reply is reminded once, then the Router is told once", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "idle-task")
    Stations.answer(@given)

    # Idle only just (the station measures it): at the 2 s check the delegation is old enough, the idleness is not.
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 500, last_failure: nil}})
    settle_after(2_500)
    assert watch_messages(ctx, conversation_id) == []

    # Idle long enough: the Worker is reminded, in the Task, as a Worker inside Salix is.
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 5_000, last_failure: nil}})
    log = capture_log(fn -> settle_after(1_000) end)
    assert log =~ "station Task Worker reminded: its Session is idle without a reply: epoch=1"
    assert [{@nudge, [^worker_pid], facts}] = watch_messages(ctx, conversation_id)
    assert facts == %{"epoch_seq" => 1, "issue" => nil, "station_state" => "idle"}
    refute log =~ "station Task delegation unanswered"
    refute_received {:telemetry, @stalled, _, _}
    # The reminder is no new delegation, and no reply.
    assert %{pending: %{epoch: 1}} = :sys.get_state(watch, :infinity)

    # The reminder's turn runs: nothing more while it does.
    Stations.session({:ok, %{state: :running, pending: 0, for_ms: 0, last_failure: nil}})
    settle_after(2_000)
    assert [{@nudge, _, _}] = watch_messages(ctx, conversation_id)

    # Idle again, long enough, still no reply: the Router is told, and the stall reported.
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 5_000, last_failure: nil}})
    log = capture_log(fn -> settle_after(1_000) end)

    assert log =~
             "station Task delegation unanswered: stage=idle_no_reply place=cloud_vm vm_status=ready epoch=1"

    assert log =~ "canary=false station_state=idle"

    assert_received {:telemetry, @stalled, %{count: 1},
                     %{phase: :idle_no_reply, kind: :cloud_vm, canary: false}}

    router_pid = router_participant(ctx, conversation_id)

    assert [{@nudge, _, _}, {@notify, [^router_pid], notified}] =
             watch_messages(ctx, conversation_id)

    assert notified["reason"] == "stopped_after_reminder"
    assert notified["epoch_seq"] == 1

    # Checked on: nothing twice.
    log = capture_log(fn -> settle_after(2_500) end)
    refute log =~ "reminded"
    refute log =~ "station Task delegation unanswered"
    refute_received {:telemetry, @stalled, _, _}
    assert length(watch_messages(ctx, conversation_id)) == 2

    # Answered after all: recovered, and a new delegation is a new epoch with its own reminder.
    vm = SalixStore.RuntimeIds.cloud_vm_device_id(ctx.group_id)

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 station_post(
                   %{ctx | device_id: vm},
                   conversation_id,
                   worker_pid,
                   "done",
                   "all_done"
                 )

        settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
      end)

    assert log =~ "answered after a stall: stage=idle_no_reply place=cloud_vm epoch=1"
    assert_received {:telemetry, @answered, _, %{kind: :cloud_vm}}

    assert {:ok, %{"seq" => seq}} = delegate(ctx, conversation_id, worker_pid, "and now test it")
    settle_until(fn -> match?(%{pending: %{epoch: ^seq}}, :sys.get_state(watch, :infinity)) end)
    Stations.answer({:ok, %{place: :cloud_vm, connected?: true, sent: seq, vm_status: "ready"}})
    settle_after(2_500)

    # The reply, the new delegation, and the new epoch's own reminder.
    assert [_, _, "agent", "agent", {@nudge, [^worker_pid], %{"epoch_seq" => ^seq}}] =
             watch_messages(ctx, conversation_id, true)
  end

  test "a restarted watch finds its reminder in the Task and does not remind again", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "restart-task")
    Stations.answer(@given)
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 5_000, last_failure: nil}})
    settle_until(fn -> watch_messages(ctx, conversation_id) != [] end)
    assert [{@nudge, [^worker_pid], _}] = watch_messages(ctx, conversation_id)

    # The Task's owner and its watch go, and come back.
    SalixIM.TestSupport.Fleet.stop_all!()
    refute Process.alive?(watch)
    assert {:ok, owner} = ConversationPlacement.ensure_started(ctx.group_id, conversation_id)
    assert {:ok, watch} = ConversationActor.station_task_watch(owner)
    settle_until(fn -> match?(%{pending: %{epoch: 1}}, :sys.get_state(watch, :infinity)) end)

    log = capture_log(fn -> settle_after(2_500) end)
    refute log =~ "reminded"
    router_pid = router_participant(ctx, conversation_id)

    assert [{@nudge, _, _}, {@notify, [^router_pid], %{"reason" => "stopped_after_reminder"}}] =
             watch_messages(ctx, conversation_id)

    assert_received {:telemetry, @stalled, _, %{phase: :idle_no_reply}}

    # And once more: the notification is found too.
    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:ok, owner} = ConversationPlacement.ensure_started(ctx.group_id, conversation_id)
    assert {:ok, watch} = ConversationActor.station_task_watch(owner)
    settle_until(fn -> match?(%{pending: %{epoch: 1}}, :sys.get_state(watch, :infinity)) end)
    settle_after(2_500)
    assert length(watch_messages(ctx, conversation_id)) == 2
  end

  test "a runtime that cannot start is reported to the Router without a reminder", ctx do
    {conversation_id, _watch, _worker_pid} = start_task(ctx, "cannot-start-task")
    Stations.answer(@given)

    Stations.session(
      {:ok,
       %{state: :cannot_start, pending: 1, for_ms: 0, last_failure: "the runner did not start"}}
    )

    # Not old enough: the station keeps trying by itself.
    settle_after(2_000)
    assert watch_messages(ctx, conversation_id) == []
    refute_received {:telemetry, @stalled, _, _}

    log = capture_log(fn -> settle_after(2_000) end)

    assert log =~ "stage=cannot_start place=cloud_vm vm_status=ready epoch=1"
    assert log =~ "canary=false station_state=cannot_start"

    assert_received {:telemetry, @stalled, _, %{phase: :cannot_start, kind: :cloud_vm}}
    router_pid = router_participant(ctx, conversation_id)
    assert [{@notify, [^router_pid], facts}] = watch_messages(ctx, conversation_id)
    assert facts["reason"] == "cannot_start"
    assert facts["last_failure"] == "the runner did not start"
    assert {:ok, [message]} = messages_of_type(ctx, conversation_id, @notify)

    assert text(message["content"]) =~
             "cannot start a turn for it (cannot_start): the runner did not start"

    settle_after(2_500)
    assert length(watch_messages(ctx, conversation_id)) == 1
    refute_received {:telemetry, @stalled, _, _}
  end

  test "a start failure that reads as sign-in or quota is reported to the Router at once", ctx do
    {conversation_id, _watch, _worker_pid} = start_task(ctx, "no-login-task")
    Stations.answer(@given)

    Stations.session(
      {:ok,
       %{
         state: :cannot_start,
         pending: 1,
         for_ms: 0,
         last_failure: "the machine login's token runs out"
       }}
    )

    settle_after(1_500)
    router_pid = router_participant(ctx, conversation_id)

    assert [{@notify, [^router_pid], %{"reason" => "cannot_start"}}] =
             watch_messages(ctx, conversation_id)

    assert_received {:telemetry, @stalled, _, %{phase: :cannot_start}}
  end

  test "a watch Message that fails to append is retried, and the stage waits for it", ctx do
    {conversation_id, _watch, worker_pid} = start_task(ctx, "retry-task")
    Stations.answer(@given)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :task_worker_watch_fail_next_append) end)
    SystemsRuntime.put_env(:salix_im, :task_worker_watch_fail_next_append, true)
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 5_000, last_failure: nil}})

    # The reminder is due at 2 s, and its append fails.
    log = capture_log(fn -> settle_after(2_500) end)
    assert log =~ "task_worker_nudge append failed"
    refute log =~ "reminded"
    assert watch_messages(ctx, conversation_id) == []

    # Appended at the retry, two seconds on.
    log = capture_log(fn -> settle_after(2_500) end)
    assert log =~ "reminded"
    assert [{@nudge, [^worker_pid], _}] = watch_messages(ctx, conversation_id)
  end

  test "a reminder whose appends keep failing is given up after five tries, and made at the next check",
       ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "give-up-task")
    Stations.answer(@given)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :task_worker_watch_fail_next_append) end)
    SystemsRuntime.put_env(:salix_im, :task_worker_watch_fail_next_append, 6)
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 5_000, last_failure: nil}})

    # Due at 2 s; retried 2, 4, 6, 8 and 10 s after each failure, then given up.
    # (The clock moves in one step and then settles, so each retry is reached
    # with its own step.)
    logs =
      for wait <- [2_500, 2_000, 4_000, 6_000, 8_000, 10_000],
          do: capture_log(fn -> settle_after(wait) end)

    log = Enum.join(logs)
    assert length(Regex.scan(~r/task_worker_nudge append failed/, log)) == 6
    assert log =~ "was not appended in 5 tries; checked again"
    assert watch_messages(ctx, conversation_id) == []
    assert %{pending: %{attempts: 0, timer: timer}} = :sys.get_state(watch, :infinity)
    assert is_reference(timer)

    # The next check, a second on, appends it.
    log = capture_log(fn -> settle_after(1_500) end)
    assert log =~ "reminded"
    assert [{@nudge, [^worker_pid], _}] = watch_messages(ctx, conversation_id)
  end

  test "a Task with no Router participant to tell still has its stall reported once", ctx do
    {conversation_id, watch, _worker_pid} = start_task(ctx, "no-router-task")
    Stations.answer(@given)
    :sys.replace_state(watch, &%{&1 | delegator_agent_id: nil})

    Stations.session(
      {:ok,
       %{state: :cannot_start, pending: 1, for_ms: 0, last_failure: "the runner did not start"}}
    )

    log = capture_log(fn -> settle_after(4_000) end)
    assert log =~ "no Router participant to notify"
    assert log =~ "stage=cannot_start place=cloud_vm vm_status=ready epoch=1"
    assert_received {:telemetry, @stalled, _, %{phase: :cannot_start}}
    assert watch_messages(ctx, conversation_id) == []

    log = capture_log(fn -> settle_after(2_500) end)
    refute log =~ "station Task delegation unanswered"
    refute_received {:telemetry, @stalled, _, _}
  end

  test "a Session idle with Messages pending is waited out, not reminded", ctx do
    {conversation_id, _watch, _worker_pid} = start_task(ctx, "held-task")
    Stations.answer(@given)
    Stations.session({:ok, %{state: :idle, pending: 2, for_ms: nil, last_failure: nil}})

    log = capture_log(fn -> settle_after(10_500) end)
    refute log =~ "reminded"
    assert watch_messages(ctx, conversation_id) == []
    assert log =~ "stage=given_no_reply place=cloud_vm vm_status=ready epoch=1"
    assert_received {:telemetry, @stalled, _, %{phase: :given_no_reply}}
  end

  test "a reply before the threshold reports nothing and records the wait", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "answered-task")
    Stations.answer({:ok, %{place: :device, connected?: true, sent: 1, vm_status: nil}})

    settle_after(500)
    assert {:ok, _reply} = station_post(ctx, conversation_id, worker_pid, "on it", nil)
    settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
    assert_received {:telemetry, @answered, %{duration: waited}, %{kind: :device}}
    assert waited in 500..600

    settle_after(4_000)
    assert Stations.asked() == 0
    refute_received {:telemetry, @stalled, _, _}
  end

  test "milestones alone from the Worker answer no delegation; its reply does", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "milestone-task")
    Stations.answer({:ok, %{place: :device, connected?: true, sent: 1, vm_status: nil}})

    assert {:ok, _milestones} =
             station_post(
               ctx,
               conversation_id,
               worker_pid,
               [%{"type" => "milestone", "title" => "Found the failing test"}],
               nil
             )

    settle_after(500)
    assert %{pending: %{epoch: 1}} = :sys.get_state(watch, :infinity)
    refute_received {:telemetry, @answered, _, _}

    assert {:ok, _reply} = station_post(ctx, conversation_id, worker_pid, "fixed it", nil)
    settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
    assert_received {:telemetry, @answered, _, %{kind: :device}}
  end

  test "a new delegation is a new epoch, and a Task that leaves active is not watched", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "epoch-task")
    Stations.answer({:ok, %{place: :device, connected?: true, sent: 1, vm_status: nil}})
    assert {:ok, _reply} = station_post(ctx, conversation_id, worker_pid, "done", "all_done")
    settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
    assert_received {:telemetry, @answered, _, _}

    # The Router gives the Worker more to do: the station was not given it yet.
    assert {:ok, %{"seq" => seq}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group_id,
               conversation_id,
               ctx.router_id,
               %{
                 "content" => "and now test it",
                 "client_request_id" => "epoch-task-2",
                 "delivery_filter" => %{"participant_ids" => [worker_pid]},
                 "metadata" => %{"message_type" => "task_command"}
               }
             )

    settle_until(fn -> match?(%{pending: %{epoch: ^seq}}, :sys.get_state(watch, :infinity)) end)
    Stations.answer({:ok, %{place: :device, connected?: true, sent: seq - 1, vm_status: nil}})
    log = capture_log(fn -> settle_after(1_000) end)
    assert log =~ "stage=not_given place=device vm_status=- epoch=#{seq}"
    assert_received {:telemetry, @stalled, _, %{phase: :not_given, kind: :device}}

    # The Router ends the Task: its timer is void, and no reply is waited for.
    assert {:ok, _conversation} =
             ConversationServer.update_group_conversation(ctx.group_id, conversation_id, %{
               "status" => "ready_for_review"
             })

    settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
    asked = Stations.asked()
    settle_after(3_000)
    assert Stations.asked() == asked
    refute_received {:telemetry, _, _, _}
  end

  test "a station that left its Task is told to the Router once, and the wait ends", ctx do
    # Where the Task runs is on its record: no standing was read, and the
    # Group's Cloud VM left (its Sessions of the Task ended, it answered
    # `gone` to what it was given) before the watch ever saw it there.
    vm = SalixStore.RuntimeIds.cloud_vm_device_id(ctx.group_id)
    {conversation_id, watch, _worker_pid} = start_task(%{ctx | device_id: vm}, "left-task")
    assert Stations.asked() == 0
    assert :sys.get_state(watch, :infinity).place == :cloud_vm

    log = capture_log(fn -> settle_after(1_000) end)

    assert log =~
             "station Task delegation unanswered: stage=station_left place=cloud_vm vm_status=- epoch=1"

    assert_received {:telemetry, @stalled, %{count: 1},
                     %{phase: :station_left, kind: :cloud_vm, canary: false}}

    router_pid = router_participant(ctx, conversation_id)
    assert [{@notify, [^router_pid], told}] = watch_messages(ctx, conversation_id)
    assert told["reason"] == "station_left"
    assert told["epoch_seq"] == 1
    assert told["issue"] == nil

    # Nothing to check on: no timer, no more reads, nothing twice.
    assert %{pending: nil, place: :cloud_vm} = :sys.get_state(watch, :infinity)
    assert Stations.asked() == 1
    settle_after(3_000)
    assert Stations.asked() == 1
    assert length(watch_messages(ctx, conversation_id)) == 1
    refute_received {:telemetry, _, _, _}
  end

  test "a station that leaves after the Router was told is not told again", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "left-after-told-task")
    Stations.answer(@given)
    Stations.session({:ok, %{state: :idle, pending: 0, for_ms: 5_000, last_failure: nil}})

    # Reminded at 1 s, told at 2 s: the epoch's one notification is in the Task.
    settle_until(fn -> length(watch_messages(ctx, conversation_id)) == 2 end)
    router_pid = router_participant(ctx, conversation_id)

    assert [
             {@nudge, [^worker_pid], _},
             {@notify, [^router_pid], %{"reason" => "stopped_after_reminder"}}
           ] =
             watch_messages(ctx, conversation_id)

    assert_received {:telemetry, @stalled, _, %{phase: :idle_no_reply}}

    # The reminder reached a station whose Sessions of the Task ended: `gone`, and it left.
    Stations.answer(:not_station)

    log =
      capture_log(fn ->
        settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
      end)

    refute log =~ "stage=station_left"
    assert length(watch_messages(ctx, conversation_id)) == 2
    refute_received {:telemetry, @stalled, _, _}
  end

  test "a delegation older than stale_ms when the watch finds it is not reported", ctx do
    log =
      capture_log(fn ->
        {conversation_id, watch, worker_pid} =
          start_task(ctx, "stale-task", true,
            created_at: SystemsClock.system_time(:millisecond) - 120_000
          )

        assert %{pending: %{epoch: 1, stale: true, timer: nil}} = :sys.get_state(watch, :infinity)

        Stations.answer(
          {:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "archived"}}
        )

        settle_after(3_000)
        assert Stations.asked() == 0
        refute_received {:telemetry, _, _, _}

        # Answered after all: not measured, as the watch did not wait for it.
        assert {:ok, _reply} = station_post(ctx, conversation_id, worker_pid, "late", "all_done")
        settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
        refute_received {:telemetry, _, _, _}
      end)

    assert log =~ "station Task delegation older than stale_ms is not watched: epoch=1"
    refute log =~ "station Task delegation unanswered"
  end

  test "a standing that cannot be read is asked again, not taken for a stage", ctx do
    {_conversation_id, watch, _worker_pid} = start_task(ctx, "unread-standing-task")
    Stations.answer({:error, :workload_unavailable})

    log = capture_log(fn -> settle_after(1_000) end)
    assert log =~ "standing not read, checked again"
    refute log =~ "station Task delegation unanswered"
    refute_received {:telemetry, @stalled, _, _}
    assert Stations.asked() == 1
    assert %{pending: %{epoch: 1, reported: [], timer: timer}} = :sys.get_state(watch, :infinity)
    assert is_reference(timer)

    Stations.answer({:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "ready"}})
    settle_after(1_000)
    assert_received {:telemetry, @stalled, _, %{phase: :station_offline, kind: :cloud_vm}}
  end

  test "a delegation older than the Message window is still waited for", ctx do
    {conversation_id, watch, worker_pid} = start_task(ctx, "window-task")

    # Fifty Messages given to nobody push the delegation out of the window.
    for n <- 1..50 do
      assert {:ok, _} =
               ConversationServer.append_group_conversation_agent_message(
                 ctx.group_id,
                 conversation_id,
                 ctx.router_id,
                 %{
                   "content" => "note #{n}",
                   "client_request_id" => "window-task-note-#{n}",
                   "delivery_filter" => %{"participant_ids" => []}
                 }
               )
    end

    settle()
    assert %{pending: %{epoch: 1}} = :sys.get_state(watch, :infinity)
    Stations.answer({:ok, %{place: :cloud_vm, connected?: true, sent: 51, vm_status: "ready"}})
    settle_after(1_000)
    assert %{pending: %{epoch: 1, timer: timer}} = :sys.get_state(watch, :infinity)
    assert is_reference(timer)

    assert {:ok, _reply} = station_post(ctx, conversation_id, worker_pid, "done", "all_done")
    settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
    assert_received {:telemetry, @answered, %{duration: waited}, %{kind: :device}}
    assert waited >= 1_000
  end

  test "a failure inside the watch is logged and the check made again", ctx do
    {conversation_id, watch, _worker_pid} = start_task(ctx, "failing-task")
    assert {:ok, owner} = ConversationPlacement.ensure_started(ctx.group_id, conversation_id)
    Stations.answer(:raise)

    log = capture_log(fn -> settle_after(1_000) end)
    assert log =~ "station task watch #{conversation_id} failed and checks again"
    assert log =~ "the station port fell over"
    assert Process.alive?(watch) and Process.alive?(owner)
    assert Stations.asked() == 1
    assert %{pending: %{epoch: 1, timer: timer}} = :sys.get_state(watch, :infinity)
    assert is_reference(timer)

    Stations.answer({:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "ready"}})
    settle_after(1_000)
    assert_received {:telemetry, @stalled, _, %{phase: :station_offline, kind: :cloud_vm}}
  end

  test "a Task of a canary Group is marked canary in its events and metrics", ctx do
    SystemsRuntime.put_env(
      :salix_im,
      :station_task_watch,
      @thresholds ++ [canary_group_ids: ["grp1_other", ctx.group_id]]
    )

    assert SalixIM.StationTaskWatch.canary?(ctx.group_id)
    refute SalixIM.StationTaskWatch.canary?("grp1_other_group")

    {conversation_id, watch, worker_pid} = start_task(ctx, "canary-task")
    Stations.answer({:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "archived"}})

    log = capture_log(fn -> settle_after(1_000) end)

    assert log =~
             "station Task delegation unanswered: stage=vm_not_ready place=cloud_vm vm_status=archived epoch=1"

    assert log =~ "canary=true"

    assert_received {:telemetry, @stalled, %{count: 1},
                     %{phase: :vm_not_ready, kind: :cloud_vm, canary: true}}

    vm = SalixStore.RuntimeIds.cloud_vm_device_id(ctx.group_id)

    log =
      capture_log(fn ->
        assert {:ok, _reply} =
                 station_post(
                   %{ctx | device_id: vm},
                   conversation_id,
                   worker_pid,
                   "done",
                   "all_done"
                 )

        settle_until(fn -> :sys.get_state(watch, :infinity).pending == nil end)
      end)

    assert log =~
             "station Task delegation answered after a stall: stage=vm_not_ready place=cloud_vm epoch=1"

    assert log =~ "canary=true"
    assert_received {:telemetry, @answered, %{duration: _}, %{kind: :cloud_vm, canary: true}}
  end

  test "canary_group_ids of another shape keeps the default of no canary Group" do
    SystemsRuntime.put_env(:salix_im, :station_task_watch, canary_group_ids: "grp1_canary")
    refute SalixIM.StationTaskWatch.canary?("grp1_canary")
    assert SalixIM.StationTaskWatch.config()[:canary_group_ids] == []

    SystemsRuntime.put_env(:salix_im, :station_task_watch, canary_group_ids: ["grp1_canary", 7])
    refute SalixIM.StationTaskWatch.canary?("grp1_canary")
  end

  test "the metrics' labels are finite" do
    metrics = Salix.Telemetry.metrics()

    stalled = Enum.find(metrics, &(&1.name == [:salix, :station_tasks, :stalled, :total]))
    assert stalled.tags == [:phase, :kind, :canary]

    assert stalled.tag_values.(%{phase: :vm_not_ready, kind: :cloud_vm, canary: true}) ==
             %{phase: "vm_not_ready", kind: "cloud_vm", canary: "true"}

    for phase <- [:idle_no_reply, :cannot_start, :station_left, :given_no_reply] do
      assert stalled.tag_values.(%{phase: phase, kind: :device}).phase == Atom.to_string(phase)
    end

    assert stalled.tag_values.(%{phase: :bogus, kind: "dev-station-1", canary: "yes"}) ==
             %{phase: "other", kind: "other", canary: "false"}

    reply = Enum.find(metrics, &(&1.name == [:salix, :station_tasks, :first_reply, :seconds]))
    assert reply.tags == [:kind, :canary]

    assert Map.take(reply.tag_values.(%{kind: :device}), [:kind, :canary]) ==
             %{kind: "device", canary: "false"}

    assert reply.tag_values.(%{}).kind == "other"
  end

  # A Task of the Router's for the Worker, run on the station `ctx.device_id`
  # (or by a Salix Session of the Worker's), with its watch and the Worker's
  # participant id.
  defp start_task(ctx, request_id, station? \\ true, opts \\ []) do
    command = "Summarize the thread and report back."
    created_at = Keyword.get(opts, :created_at, SystemsClock.system_time(:millisecond))

    attrs =
      %{
        "content" => command,
        "client_request_id" => request_id,
        "schedule" => %{"schedule_id" => nil, "command" => command},
        "initial_message_attrs" => %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => ctx.router_id,
          "content" => command,
          "metadata" => %{"message_type" => "task_command"},
          "client_request_id" => "delegate-" <> request_id,
          "created_at" => created_at
        }
      }
      |> then(fn attrs ->
        if station?,
          do: Map.put(attrs, "runs_on", %{"kind" => "station", "device_id" => ctx.device_id}),
          else: attrs
      end)

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             TaskConversationInput.create_with_id(
               ctx.group_id,
               conversation_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group_id, conversation_id)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker_id))
    assert TaskConversationInput.station_worker?(worker) == station?

    assert {:ok, owner} = ConversationPlacement.ensure_started(ctx.group_id, conversation_id)
    assert {:ok, watch} = ConversationActor.station_task_watch(owner)

    if station?,
      do: settle_until(fn -> :sys.get_state(watch, :infinity).pending != nil end),
      else: settle()

    {conversation_id, watch, worker["participant_id"]}
  end

  defp now, do: SystemsClock.system_time(:millisecond)

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content),
    do: content |> Enum.map(&(&1["text"] || "")) |> Enum.join("\n")

  # The watch's Messages in the Task, oldest first: each one's type, who it
  # was delivered to, and what it recorded. With `all`, every Message that is
  # not the first delegation (watch Messages as `{type, targets, facts}`, the
  # rest as their actor type).
  defp watch_messages(ctx, conversation_id, all \\ false) do
    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(ctx.group_id, conversation_id,
               limit: 20
             )

    messages
    |> Enum.drop(1)
    |> Enum.flat_map(fn message ->
      case get_in(message, ["metadata", "message_type"]) do
        type when type in [@nudge, @notify] ->
          [
            {type, get_in(message, ["delivery_filter", "participant_ids"]),
             get_in(message, ["metadata", "task_worker_watch"])}
          ]

        _other ->
          if all, do: [message["actor_type"]], else: []
      end
    end)
  end

  defp messages_of_type(ctx, conversation_id, type) do
    with {:ok, messages} <-
           Conversations.list_group_conversation_messages(ctx.group_id, conversation_id,
             limit: 20
           ),
         do: {:ok, Enum.filter(messages, &(get_in(&1, ["metadata", "message_type"]) == type))}
  end

  defp router_participant(ctx, conversation_id) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group_id, conversation_id)

    Enum.find(participants, &(&1["agent_id"] == ctx.router_id))["participant_id"]
  end

  # The Router gives the Worker more to do.
  defp delegate(ctx, conversation_id, worker_pid, text) do
    ConversationServer.append_group_conversation_agent_message(
      ctx.group_id,
      conversation_id,
      ctx.router_id,
      %{
        "content" => text,
        "client_request_id" => "#{conversation_id}:#{text}",
        "delivery_filter" => %{"participant_ids" => [worker_pid]},
        "metadata" => %{"message_type" => "task_command"}
      }
    )
  end

  # What the station's Session posts into the Task as the Worker (`task.post`).
  defp station_post(ctx, conversation_id, worker_pid, text, declared) do
    metadata =
      %{"kind" => "station_task", "device_id" => ctx.device_id, "session" => "ember:c-1"}
      |> then(&if(declared, do: Map.put(&1, "declared", declared), else: &1))

    ConversationServer.append_group_conversation_agent_message(
      ctx.group_id,
      conversation_id,
      ctx.worker_id,
      %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => ctx.worker_id,
        "participant_id" => worker_pid,
        "content" => text,
        "client_request_id" => "station-task:#{conversation_id}:#{inspect(text)}",
        "metadata" => metadata
      }
    )
  end
end
