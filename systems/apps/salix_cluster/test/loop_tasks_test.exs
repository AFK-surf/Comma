defmodule SalixCluster.LoopTasksTest do
  @moduledoc """
  Loop Tasks end to end (`SalixIM.TaskLoop`): the Router's
  `im_api.internal.task.create` with `loop`, through the product's Task
  create, writes the Task's Background Loop (`SalixAgent.Loops`), which the
  Worker gives its program and which alone holds the cadence, the limits and
  the runs. Lives in salix_cluster, which sees the Task create, the Loop
  runtime and the cron math behind `loop.next_run`.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixCluster"]

  alias SalixAgent.{AgentWorkspace, Loops}
  alias SalixIM.{ConversationServer, Conversations, Provider}
  alias SalixStore.{Ids, Keys}
  alias SalixStore.Loops, as: Store

  @elf_path "/loops/task.elf"

  defmodule NoopAgentDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      if pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test}, nil) do
        send(pid, {:loop_delivery, agent_id, payload, opts[:source_message_id]})
      end

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_found}
  end

  defmodule UnavailableOwner do
    @behaviour SalixAgent.Loops.TaskOwner
    alias Salix.Bindings.TaskLoopOwner
    defdelegate loop_wake(loop, payload, source), to: TaskLoopOwner

    def loop_ended(loop, fact) do
      if SystemsRuntime.get_env(:salix_agent, :test_unavailable_loop_report) == :ended,
        do: {:error, :task_owner_unavailable},
        else: TaskLoopOwner.loop_ended(loop, fact)
    end
  end

  defmodule StationsFake do
    @moduledoc "The stations a Task runs on (`SalixIM.Ports.TaskStations`): what they are asked."
    @behaviour SalixIM.Ports.TaskStations

    defp tell(message) do
      if pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test}, nil),
        do: SystemsRuntime.Proc.send(pid, message)

      :ok
    end

    @impl true
    def invite(invitation) do
      tell({:station_invite, invitation})
      {:ok, "ember:c-1"}
    end

    @impl true
    def joined(row), do: tell({:station_joined, row})

    @impl true
    def appended(group_id, conversation_id),
      do: tell({:station_appended, group_id, conversation_id})

    @impl true
    def standing(_group_id, _conversation_id), do: :not_station
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixStore.Repo.query!("TRUNCATE agent_loops, agent_loop_acks, schedules, schedule_runs")

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_im, :task_create_mod, Salix.Bindings.AgentConversations},
      {:salix_im, :agent_delivery_mod, NoopAgentDelivery},
      {:salix_im, :task_loops_mod, SalixAgent.Loops},
      {:salix_agent, :loop_task_owner_mod, Salix.Bindings.TaskLoopOwner},
      {:salix_agent, :schedules_mod, SalixCluster.Schedules},
      {:salix_im, :task_stations_mod, StationsFake},
      {:salix_env, :transfer_port, 0},
      {:salix_agent, :test_unavailable_loop_report, nil}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)
    SalixAgent.TestSupport.configure_control_fixtures!()
    SystemsRuntime.PersistentTerm.put({StationsFake, :test}, SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put({NoopAgentDelivery, :test}, self())
    {:ok, _started} = Application.ensure_all_started(:salix_cluster)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        SystemsRuntime.PersistentTerm.erase({StationsFake, :test})
        SystemsRuntime.PersistentTerm.erase({NoopAgentDelivery, :test})

        Enum.each(previous, fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, value} -> SystemsRuntime.put_env(app, key, value)
        end)
      end
    end)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Loop Tasks"})

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

    source = "#include <spinfoam.h>\nSF_MAIN sf_i64 main(void) { for (;;) sf_sleep_ms(60000); }"

    {:ok, %{"state" => "succeeded"}, event} =
      Loops.build(%{agent_id: worker["agent_id"]}, %{"main.c" => source}, "main.c", @elf_path)

    {:ok, _} = AgentWorkspace.seed_operation(worker["agent_id"], "loop-tasks-test", %{}, [event])

    {:ok,
     tenant_id: tenant_id,
     group_id: group_id,
     router: router["agent_id"],
     worker: worker["agent_id"]}
  end

  # A desktop station of `meta`, connected and taking Tasks.
  defp connect_station!(ctx, meta) do
    device_id = "device-station-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      SalixEnv.Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant_id,
          "group_id" => ctx.group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Laptop"
        },
        transport_id: transport_id
      )

    {:ok, _} =
      SalixEnv.Registry.update_meta(
        record["connector_run_id"],
        &(&1
          |> Map.merge(meta)
          |> Map.put("capabilities", %{"tasks" => 2, "task_models" => %{"codex" => ["gpt-5.5"]}}))
      )

    device_id
  end

  defp task_create(ctx, params) do
    Provider.call_api(ctx.router, "internal", "internal.task.create", %{
      "connect_id" => "internal",
      "params" =>
        Map.merge(
          %{"agent_id" => ctx.worker, "content" => "Check PR #12 and summarize new comments."},
          params
        )
    })
  end

  defp task(ctx, id) do
    {:ok, task} = Conversations.get_group_conversation(ctx.group_id, id)
    task
  end

  # A Worker round that a Message of the Task started.
  defp worker_round(ctx, id) do
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, id)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker))

    %{
      agent_id: ctx.worker,
      session_id: worker["payload"]["session_id"],
      role: "worker",
      ifc_evidence: %{"requester" => "comma_user|u1", "sources_label" => ["public"]},
      trusted_origin: %{
        "provider" => "internal",
        "conversation_kind" => "agent_task",
        "conversation_id" => id,
        "agent_group_id" => ctx.group_id
      }
    }
  end

  defp loop_of(ctx, id) do
    {:ok, [loop]} = Store.list_by_tasks(ctx.group_id, [id])
    loop
  end

  # The Worker gives the Task's Loop its program; the ref the Reconciler
  # loaded it with, read after adoption settled its incarnation.
  defp bind!(ctx, id) do
    assert {:ok, %{"status" => "active"}} =
             Loops.create(worker_round(ctx, id), %{"path" => @elf_path})

    settle()
    Loops.Reconciler.loop_ref(loop_of(ctx, id))
  end

  defp notify(ref, key),
    do:
      Loops.Capabilities.call(ref, "agent.notify", %{
        "content" => "Run " <> key,
        "dedup_key" => key
      })

  defp notices(ctx, id) do
    {:ok, messages} = Conversations.list_group_conversation_messages(ctx.group_id, id, limit: 50)
    Enum.filter(messages, &(get_in(&1, ["metadata", "message_type"]) == "task_loop"))
  end

  test "the Router's task.create writes the Task's pending Loop with its cadence and limits",
       ctx do
    future =
      SystemsClock.system_time(:second)
      |> DateTime.from_unix!()
      |> DateTime.add(7, :day)
      |> DateTime.to_iso8601()

    for {loop, extra, refusal} <- [
          {%{"cadence" => %{"every_minutes" => 2}}, %{}, "from 5 to 1440"},
          {%{"cadence" => %{"every_minutes" => 60, "events" => "x"}}, %{}, "exactly one of"},
          {%{"cadence" => %{"cron" => "0 9 * * *"}}, %{}, "timezone is required with cron"},
          {%{"cadence" => %{"cron" => "0 99 * * *", "timezone" => "UTC"}}, %{}, "cron"},
          {%{"cadence" => %{"events" => String.duplicate("e", 33)}}, %{}, "1 to 32 characters"},
          {%{"cadence" => %{"every_minutes" => 60}, "ends_at" => "2020-01-01T00:00:00Z"}, %{},
           "in the future"},
          {%{"cadence" => %{"every_minutes" => 60}, "max_runs" => 0}, %{}, "from 1 to 1000"},
          {%{"cadence" => %{"every_minutes" => 60}}, %{"schedule" => %{"interval_minutes" => 60}},
           "not both"}
        ] do
      assert {:error, message} = task_create(ctx, Map.put(extra, "loop", loop))
      assert message =~ refusal
    end

    assert {:ok, []} = Store.list_by_agent(ctx.worker)

    assert {:ok, created} =
             task_create(ctx, %{
               "loop" => %{
                 "cadence" => %{"cron" => "0 9 * * *", "timezone" => "Asia/Shanghai"},
                 "max_runs" => 10,
                 "ends_at" => future,
                 "until" => "PR #12 is merged"
               }
             })

    id = created["conversation_id"]
    {:ok, ends_at, _offset} = DateTime.from_iso8601(future)
    ends_at = DateTime.to_unix(ends_at, :millisecond)

    assert created["loop"] == %{
             "cadence" => %{"cron" => "0 9 * * *", "timezone" => "Asia/Shanghai"},
             "runs" => 0,
             "max_runs" => 10,
             "ends_at" => ends_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
             "until" => "PR #12 is merged"
           }

    # The Loop holds the request; the Task holds none of it.
    worker = ctx.worker

    assert %{
             "status" => "pending",
             "agent_id" => ^worker,
             "trigger" => %{"cron" => "0 9 * * *", "timezone" => "Asia/Shanghai"},
             "max_runs" => 10,
             "ends_at" => ^ends_at,
             "stop_condition" => "PR #12 is merged",
             "run_count" => 0
           } = loop_of(ctx, id)

    refute Map.has_key?(task(ctx, id), "loop")

    # The Router's list shows the same compact summary.
    assert {:ok, %{"tasks" => tasks}} =
             Provider.call_api(ctx.router, "internal", "internal.task.list", %{
               "connect_id" => "internal",
               "params" => %{}
             })

    assert Enum.find(tasks, &(&1["task_id"] == id))["loop"] == created["loop"]

    # A Loop Task runs on its Loop, so it takes no Schedule.
    assert {:error, refused} =
             Provider.call_api(ctx.router, "internal", "internal.task.update", %{
               "connect_id" => "internal",
               "params" => %{"conversation_id" => id, "schedule" => %{"interval_minutes" => 60}}
             })

    assert refused =~ "Loop Task"
    assert task(ctx, id)["schedule"]["schedule_id"] == nil
  end

  test "the Worker binds its program to the Task's Loop, and the Task's end ends the Loop", ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{"loop" => %{"cadence" => %{"every_minutes" => 60}}})

    pending = loop_of(ctx, id)
    round = worker_round(ctx, id)

    # The cadence is the Task's: a trigger of the Worker's own is refused.
    assert {:error, {:invalid, "trigger"}} =
             Loops.create(round, %{"path" => @elf_path, "every_minutes" => 30})

    assert {:ok, loop} = Loops.create(round, %{"path" => @elf_path})
    assert loop["loop_id"] == pending["id"]
    assert loop["trigger"] == %{"every_minutes" => 60}
    assert {:error, {:task_loop_exists, _}} = Loops.create(round, %{"path" => @elf_path})

    # The Task's status does not drive the Loop while the Task runs.
    update = &ConversationServer.update_group_conversation(ctx.group_id, id, &1)
    assert {:ok, _} = update.(%{"status" => "escalated"})
    assert %{"status" => "active"} = loop_of(ctx, id)

    assert {:ok, _} = update.(%{"status" => "active"})
    assert {:error, refused} = update.(%{"status" => "ready_for_review"})
    assert inspect(refused) =~ "one report is one run"

    # Ending the Task ends its Loop for good; the row stays to show it.
    assert {:ok, %{"status" => "completed"}} =
             update.(%{"status" => "completed", router_agent_id: ctx.router})

    settle()

    assert %{"status" => "ended", "ended_reason" => "completed", "task_settle_pending" => false} =
             loop_of(ctx, id)

    assert {:error, {:not_active, "ended"}} = Loops.resume(ctx.worker, pending["id"])
  end

  test "archiving a waiting Loop Task cancels its Loop; restoring does not run it again", ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{"loop" => %{"cadence" => %{"events" => "new comments"}}})

    _ref = bind!(ctx, id)

    assert {:ok, %{"updated_at" => version}} =
             ConversationServer.update_group_conversation(ctx.group_id, id, %{
               "status" => "escalated"
             })

    assert %{"status" => "active"} = loop_of(ctx, id)

    assert {:ok, archived} =
             ConversationServer.set_task_archived(ctx.group_id, id, :archive, version)

    settle()
    assert %{"status" => "ended", "ended_reason" => "cancelled"} = loop_of(ctx, id)

    assert {:ok, %{"status" => "escalated"}} =
             ConversationServer.set_task_archived(
               ctx.group_id,
               id,
               :unarchive,
               archived["updated_at"]
             )

    settle()
    assert %{"status" => "ended", "ended_reason" => "cancelled"} = loop_of(ctx, id)
  end

  test "a delivered wake is one run; the run that reaches max_runs ends the Loop and completes the Task",
       ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{
               "loop" => %{"cadence" => %{"events" => "new comments"}, "max_runs" => 2}
             })

    ref = bind!(ctx, id)
    assert {:ok, %{"status" => "queued"}} = notify(ref, "one")
    # The guest repeating the same wake counts it once.
    assert {:ok, %{"status" => "duplicate"}} = notify(ref, "one")
    assert %{"run_count" => 1, "status" => "active"} = loop_of(ctx, id)

    assert {:ok, %{"status" => "queued"}} = notify(ref, "two")

    assert %{"run_count" => 2, "status" => "ended", "ended_reason" => "max_runs"} =
             loop_of(ctx, id)

    assert {:error, _closed} = notify(ref, "three")

    # The Task takes the end once, with one notice to its Router.
    SalixAgent.Loops.TaskOwner.reconcile_settles(nil)
    settle()
    assert task(ctx, id)["status"] == "completed"
    assert %{"task_settle_pending" => false} = loop_of(ctx, id)
    assert [notice] = notices(ctx, id)
    assert notice["metadata"]["task_loop"] == %{"event" => "ended", "reason" => "max_runs"}

    # Both runs reached the Worker as input in its Task.
    worker = ctx.worker
    session = worker_round(ctx, id).session_id
    loop_id = ref.loop_id

    for key <- ["one", "two"] do
      source = "loop:#{loop_id}:#{key}"

      settle_receive(
        {:loop_delivery, ^worker,
         %{session_id: ^session, trusted_origin: %{"provider" => "loop", "loop_id" => ^loop_id}},
         ^source}
      )
    end
  end

  test "an end the Task could not take is retried until it lands", ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{
               "loop" => %{"cadence" => %{"events" => "new comments"}, "max_runs" => 1}
             })

    ref = bind!(ctx, id)
    SystemsRuntime.put_env(:salix_agent, :loop_task_owner_mod, UnavailableOwner)
    SystemsRuntime.put_env(:salix_agent, :test_unavailable_loop_report, :ended)
    assert {:ok, %{"status" => "queued"}} = notify(ref, "only")
    settle()
    SalixAgent.Loops.TaskOwner.reconcile_settles(nil)
    assert %{"status" => "ended", "task_settle_pending" => true} = loop_of(ctx, id)
    assert task(ctx, id)["status"] == "active"

    SystemsRuntime.put_env(:salix_agent, :test_unavailable_loop_report, nil)
    SalixAgent.Loops.TaskOwner.reconcile_settles(nil)
    assert %{"task_settle_pending" => false} = loop_of(ctx, id)
    assert task(ctx, id)["status"] == "completed"
    assert [_notice] = notices(ctx, id)
  end

  test "loop.next_run answers the trigger's next time, once for missed runs, and ends at ends_at",
       ctx do
    now = SystemsClock.system_time(:millisecond)
    finish = now + :timer.hours(30)
    ends_at = finish |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{
               "loop" => %{
                 "cadence" => %{"cron" => "0 9 * * *", "timezone" => "Asia/Shanghai"},
                 "ends_at" => ends_at
               }
             })

    ref = bind!(ctx, id)

    next =
      &Loops.Capabilities.call(ref, "loop.next_run", if(&1, do: %{"after_ms" => &1}, else: %{}))

    # 09:00 in Shanghai is 01:00 UTC.
    assert {:ok, %{"next_run_at" => first}} = next.(nil)
    assert first > now and first - now <= :timer.hours(24)
    assert %{hour: 1, minute: 0} = DateTime.from_unix!(first, :millisecond)
    assert %{"next_run_at" => ^first} = loop_of(ctx, id)

    # A Loop that was down for days runs once: the latest missed time.
    assert {:ok, %{"next_run_at" => missed}} = next.(first - :timer.hours(24 * 5))
    assert missed == first - :timer.hours(24)

    # The run after `first` would be past ends_at: the Loop ends.
    assert {:ok, %{"ended" => true}} = next.(first)
    assert %{"status" => "ended", "ended_reason" => "ends_at"} = loop_of(ctx, id)
  end

  test "a Loop past its ends_at ends at the Reconciler's sweep without another wake", ctx do
    finish = SystemsClock.system_time(:millisecond) + :timer.minutes(1)
    ends_at = finish |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{
               "loop" => %{"cadence" => %{"events" => "new comments"}, "ends_at" => ends_at}
             })

    ref = bind!(ctx, id)
    SystemsClock.advance(:timer.minutes(2))
    assert :ok = Loops.end_past_due()

    assert %{"status" => "ended", "ended_reason" => "ends_at", "run_count" => 0} =
             loop_of(ctx, id)

    assert {:error, _} = notify(ref, "late")

    SalixAgent.Loops.TaskOwner.reconcile_settles(nil)
    settle()
    assert task(ctx, id)["status"] == "completed"
    assert [notice] = notices(ctx, id)
    assert notice["metadata"]["task_loop"]["reason"] == "ends_at"
  end

  test "a Loop that stops on its own keeps its Task active and tells its Worker in the Task",
       ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{"loop" => %{"cadence" => %{"every_minutes" => 60}}})

    ref = bind!(ctx, id)
    assert :ok = Loops.record_exit(ref.loop_id, ref.incarnation, 3)
    assert %{"status" => "paused", "paused_by" => "exited"} = loop_of(ctx, id)
    assert task(ctx, id)["status"] == "active"
    assert notices(ctx, id) == []

    worker = ctx.worker
    loop_id = ref.loop_id
    source = "loop:#{loop_id}:lifecycle:exited:#{ref.incarnation}"

    settle_receive(
      {:loop_delivery, ^worker, %{trusted_origin: %{"conversation_id" => ^id}}, ^source}
    )

    # The Worker resumes its own Loop.
    assert {:ok, scope} = Loops.scope(worker_round(ctx, id))
    assert {:ok, %{"status" => "active"}} = Loops.resume(scope, loop_id)
  end

  test "a later human request gives an ended Loop Task a new Loop once", ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{
               "loop" => %{"cadence" => %{"events" => "old comments"}, "until" => "old PR merged"}
             })

    old_ref = bind!(ctx, id)
    assert {:ok, %{"status" => "queued"}} = notify(old_ref, "old")

    assert {:ok, _} =
             ConversationServer.update_group_conversation(ctx.group_id, id, %{
               "status" => "completed"
             })

    settle()
    SystemsClock.advance(1)
    source = "new-human-request"

    args = %{
      "connect_id" => "internal",
      "params" => %{
        "conversation_id" => id,
        "command" => "Check the new PR.",
        "loop" => %{"cadence" => %{"every_minutes" => 180}, "max_runs" => 2}
      },
      "tool_context" => %{
        source_message_id: source,
        trusted_origin: %{
          "source_message_id" => source,
          "source_actor_type" => "user",
          "agent_group_id" => ctx.group_id,
          "source_sent_at_ms" => SystemsClock.system_time(:millisecond)
        }
      }
    }

    # Only a human request restarts it.
    assert {:error, _} =
             Provider.call_api(
               ctx.router,
               "internal",
               "internal.task.update",
               Map.delete(args, "tool_context")
             )

    assert {:ok, %{"updated" => true, "status" => "active"}} =
             Provider.call_api(ctx.router, "internal", "internal.task.update", args)

    # A new Loop: a new id, the new request, no runs; the old Loop is gone.
    assert %{
             "status" => "pending",
             "trigger" => %{"every_minutes" => 180},
             "max_runs" => 2,
             "run_count" => 0
           } = new = loop_of(ctx, id)

    refute new["id"] == old_ref.loop_id
    refute new["stop_condition"]
    assert {:error, :not_found} = Store.get(old_ref.loop_id)
    assert task(ctx, id)["status"] == "active"

    # The old program reaches nothing.
    assert {:error, _} = notify(old_ref, "late")

    # Repeating the same request keeps the same Loop and command.
    assert {:ok, _} = Provider.call_api(ctx.router, "internal", "internal.task.update", args)
    assert loop_of(ctx, id)["id"] == new["id"]

    new_ref = bind!(ctx, id)
    assert new_ref.loop_id == new["id"]
    assert {:ok, %{"status" => "queued"}} = notify(new_ref, "new-1")
    assert loop_of(ctx, id)["run_count"] == 1
  end

  test "a wake after the Worker leaves its Task pauses the Loop as undeliverable", ctx do
    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{"loop" => %{"cadence" => %{"every_minutes" => 60}}})

    ref = bind!(ctx, id)

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(ctx.group_id, id)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker))

    assert {:ok, _} =
             ConversationServer.deactivate_group_conversation_participant(
               ctx.group_id,
               id,
               worker["participant_id"]
             )

    assert {:error, _} = notify(ref, "late")

    assert %{"status" => "paused", "paused_by" => "undeliverable", "run_count" => 0} =
             loop_of(ctx, id)

    assert task(ctx, id)["status"] == "active"
  end

  test "a Loop Task is refused a person's own computer; a one-shot Task still runs there", ctx do
    personal = connect_station!(ctx, %{"owner_user_id" => "user-1"})
    loop = %{"cadence" => %{"every_minutes" => 60}}

    assert {:error, explicit} =
             task_create(ctx, %{
               "loop" => loop,
               "runs_on" => %{"kind" => "station", "device_id" => personal}
             })

    assert explicit =~ "cannot run a Loop Task. Omit runs_on to run the Loop inside Salix"

    bound =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        ctx.tenant_id,
        ctx.group_id,
        %{
          "name" => "Desktop Worker",
          "role" => "worker",
          "station_binding" => %{
            "runs_on" => %{"kind" => "station", "device_id" => personal},
            "model" => %{"kind" => "runtime", "provider" => "codex"}
          }
        }
      )

    assert {:error, from_binding} =
             task_create(ctx, %{"agent_id" => bound["agent_id"], "loop" => loop})

    assert from_binding =~ "Give agent_id of a Worker that runs inside Salix"
    refute_received {:station_invite, _invitation}

    assert {:ok, %{"conversation_id" => id}} =
             task_create(ctx, %{
               "agent_id" => bound["agent_id"],
               "content" => "Run the benchmark once."
             })

    assert_received {:station_invite, %{device_id: ^personal, conversation_id: ^id}}
  end

  test "a Loop Task is refused the Group's default place when it is a person's own computer",
       ctx do
    personal = connect_station!(ctx, %{"owner_user_id" => "user-1"})
    loop = %{"cadence" => %{"every_minutes" => 60}}

    assert {:ok, _place} =
             SalixAgent.TaskPlace.put(ctx.tenant_id, ctx.group_id, %{
               "kind" => "station",
               "device_id" => personal
             })

    assert {:error, refused} = task_create(ctx, %{"loop" => loop})
    assert refused =~ "default place to run Tasks is a person's own computer"
    assert refused =~ "cannot run a Loop Task"
    refute_received {:station_invite, _invitation}

    # runs_on {kind: salix} runs the Loop inside Salix whatever the default is.
    assert {:ok, %{"conversation_id" => _id}} =
             task_create(ctx, %{"loop" => loop, "runs_on" => %{"kind" => "salix"}})

    refute_received {:station_invite, _invitation}
  end
end
