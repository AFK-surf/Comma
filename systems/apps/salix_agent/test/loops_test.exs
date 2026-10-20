defmodule SalixAgent.LoopsTest do
  @moduledoc """
  Background Loop domain rules over the durable row, independent of the
  spinfoam child: quotas, the closed capability allowlist, the notification and
  restart budgets, incarnation fencing, archive pause and unarchive resume.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{AgentWorkspace, Loops}
  alias SalixAgent.Loops.Capabilities
  alias SalixStore.Loops, as: Store
  alias SalixStore.S3.Fake

  defmodule LoopHttpPlug do
    @moduledoc "A Bandit plug that delegates to the function it was started with."
    @behaviour Plug
    @impl true
    def init(fun), do: fun
    @impl true
    def call(conn, fun), do: fun.(conn)
  end

  defmodule OwnerProbe do
    @moduledoc "The Task owner port, forwarding each report to the test."
    @behaviour SalixAgent.Loops.TaskOwner

    @impl true
    def loop_wake(loop, _payload, source) do
      cond do
        String.ends_with?(source, ":duplicate") ->
          {:ok, :duplicate}

        String.ends_with?(source, ":gone") ->
          {:error, :not_found}

        true ->
          tell({:loop_woke, loop, %{"source_id" => source}})
          {:ok, :created}
      end
    end

    @impl true
    def loop_ended(loop, fact), do: tell({:loop_ended, loop, fact})

    defp tell(message) do
      SystemsRuntime.Proc.send(SystemsRuntime.PersistentTerm.get({__MODULE__, :test}), message)
      :ok
    end
  end

  defmodule DeliveryProbe do
    @moduledoc """
    The product delivery seam in place of a Session: the dedup key picks the
    ledger's answer.
    """
    def authorize(_row, _capability, _args), do: :ok
    def deliver(_row, _content, "duplicate", _origin), do: {:ok, :duplicate}
    def deliver(_row, _content, "gone", _origin), do: {:error, :not_found}
    def deliver(_row, _content, _dedup, _origin), do: {:ok, :created}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    put_probes!()
    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_agent_max = SystemsRuntime.get_env(:salix_agent, :loops_max_active_per_agent)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    if SystemsRuntime.Proc.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)
    SalixStore.Repo.query!("TRUNCATE agent_loops, agent_loop_acks")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, prev_store)
      restore(:salix_agent, :loops_max_active_per_agent, prev_agent_max)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "worker"})
    elf = <<0x7F, ?E, ?L, ?F, 1, 2, 3>>
    sha = :crypto.hash(:sha256, elf) |> Base.encode16(case: :lower)
    :ok = put_file!(agent_id, "/loops/main.elf", elf)

    {:ok,
     agent_id: agent_id,
     session_id: session_id,
     sha: sha,
     path: "/loops/main.elf",
     ctx: %{
       agent_id: agent_id,
       session_id: session_id,
       role: "worker",
       ifc_evidence: %{"requester" => "comma_user|u1", "sources_label" => ["public"]}
     }}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp put_file!(agent_id, path, content) do
    {:ok, event} = AgentWorkspace.prepare_write(agent_id, path, content)

    {:ok, _} =
      AgentWorkspace.seed_operation(
        agent_id,
        "loops-test:#{SystemsRuntime.Proc.unique_integer([:positive])}",
        %{},
        [event]
      )

    :ok
  end

  defp create!(ctx, _sha, attrs \\ %{}) do
    {:ok, loop} = Loops.create(ctx, Map.merge(%{"path" => "/loops/main.elf"}, attrs))
    loop
  end

  # A Worker round that a Message of Task `task_id` started, in the Worker's
  # own Session of that Task.
  defp in_task(ctx, task_id) do
    Map.merge(ctx, %{
      session_id: SalixStore.Ids.new_session_id(),
      trusted_origin: %{
        "provider" => "internal",
        "conversation_kind" => "agent_task",
        "conversation_id" => task_id,
        "agent_group_id" => group_id(ctx)
      }
    })
  end

  defp group_id(ctx) do
    {:ok, agent} = SalixAgent.Control.get(ctx.agent_id)
    agent["group_id"]
  end

  defp put_probes! do
    previous =
      Map.new(
        [:loop_task_owner_mod, :loop_authorization_adapter],
        &{&1, SystemsRuntime.get_env(:salix_agent, &1)}
      )

    SystemsRuntime.PersistentTerm.put({OwnerProbe, :test}, self())
    SystemsRuntime.put_env(:salix_agent, :loop_task_owner_mod, OwnerProbe)
    SystemsRuntime.put_env(:salix_agent, :loop_authorization_adapter, DeliveryProbe)

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase({OwnerProbe, :test})
      Enum.each(previous, fn {key, value} -> restore(:salix_agent, key, value) end)
    end)
  end

  test "a Worker round that works a Task binds its Loop to that Task, and the Task runs one Loop",
       %{ctx: ctx, sha: sha} do
    task_a = in_task(ctx, "cnv_a")
    a = create!(task_a, sha)
    assert a["task_conversation_id"] == "cnv_a"
    assert {:ok, %{"task_conversation_id" => "cnv_a"} = record} = Store.get(a["loop_id"])
    assert record["session_id"] == task_a.session_id

    a_id = a["loop_id"]

    assert {:error, {:task_loop_exists, ^a_id}} =
             Loops.create(task_a, %{"path" => "/loops/main.elf"})

    # A round without a Task Message still works its Task: one the Task's
    # Loop woke, or any round of the Task's Session.
    woken = %{
      task_a
      | session_id: SalixStore.Ids.new_session_id(),
        trusted_origin: SalixAgent.IFC.loop_origin(a_id, "comma_user|u1", ["public"])
    }

    assert {:ok, "cnv_a"} = Loops.round_task(woken)
    assert {:ok, "cnv_a"} = Loops.round_task(Map.delete(task_a, :trusted_origin))

    # Another Task's round binds its own Loop.
    assert create!(in_task(ctx, "cnv_b"), sha)["task_conversation_id"] == "cnv_b"

    # A Router round in the Task and a Worker round outside any Task work no
    # Task: their Loops stay unbound.
    refute Map.has_key?(create!(%{task_a | role: "router"}, sha), "task_conversation_id")
    refute Map.has_key?(create!(ctx, sha), "task_conversation_id")
  end

  test "the Task layer requests one Task's Loop, reads it in one batch, ends and deletes it",
       %{ctx: ctx, sha: sha} do
    group = group_id(ctx)

    request = fn task, trigger ->
      Loops.request_task_loop(%{
        "tenant_id" => "tenant",
        "group_id" => group,
        "agent_id" => ctx.agent_id,
        "task_conversation_id" => task,
        "trigger" => trigger,
        "max_runs" => 3
      })
    end

    assert {:ok, %{"status" => "pending", "loop_id" => a_id, "run_count" => 0}} =
             request.("cnv_a", %{"every_minutes" => 60})

    # A repeated request keeps the pending Loop; the Worker binds its program.
    assert {:ok, %{"loop_id" => ^a_id}} = request.("cnv_a", %{"every_minutes" => 30})

    assert %{"loop_id" => ^a_id, "trigger" => %{"every_minutes" => 60}} =
             create!(in_task(ctx, "cnv_a"), sha)

    assert {:error, {:task_loop_exists, ^a_id}} = request.("cnv_a", %{"every_minutes" => 60})

    incidental = create!(in_task(ctx, "cnv_b"), sha)
    free = create!(ctx, sha)

    assert {:ok,
            %{
              "cnv_a" => %{
                "status" => "active",
                "trigger" => %{"every_minutes" => 60},
                "max_runs" => 3
              },
              "cnv_b" => %{"status" => "active"}
            } = loops} = Loops.task_loops(group, ["cnv_a", "cnv_b", "cnv_none"])

    refute Map.has_key?(loops, "cnv_none")

    # Archive cancels the requested Loop and leaves the others; the Task's end
    # deletes a Loop it did not request.
    assert :ok = Loops.end_task_loops(group, "cnv_a", "archived")
    assert :ok = Loops.end_task_loops(group, "cnv_b", "archived")

    assert {:ok,
            %{"status" => "ended", "ended_reason" => "cancelled", "task_settle_pending" => false}} =
             Store.get(a_id)

    assert {:ok, %{"status" => "active"}} = Store.get(incidental["loop_id"])
    assert :ok = Loops.end_task_loops(group, "cnv_a", "completed")
    assert {:ok, %{"ended_reason" => "cancelled"}} = Store.get(a_id)
    assert :ok = Loops.end_task_loops(group, "cnv_b", "completed")
    assert {:error, :not_found} = Store.get(incidental["loop_id"])

    # An ended Loop gives way to a new request.
    assert {:ok, %{"status" => "pending", "loop_id" => new_id}} =
             request.("cnv_a", %{"events" => "new comments"})

    refute new_id == a_id
    assert {:error, :not_found} = Store.get(a_id)
    assert {:ok, 1} = Loops.delete_task_loops(group, "cnv_a")
    assert {:ok, 0} = Loops.delete_task_loops(group, "cnv_a")
    assert {:ok, _} = Store.get(free["loop_id"])
  end

  # A lifecycle notice wakes the Loop's Session through real delivery, which
  # places the Agent and lets the Reconciler load its Loops. Each test below
  # therefore drives incarnations by hand only before its one such notice.
  test "a Task Loop's wakes reach its Task, count as runs, and its stops reach its Worker there",
       %{ctx: ctx, sha: sha} do
    task = in_task(ctx, "cnv_watch")
    bound = create!(task, sha)
    id = bound["loop_id"]
    {:ok, %{"incarnation" => incarnation}} = Loops.begin_incarnation(id, "node@a", "s1")

    assert {:ok, %{"status" => "queued"}} = notify(bound, "comment-1")
    assert_received({:loop_woke, loop, %{"source_id" => source}})

    assert loop == %{
             "group_id" => group_id(ctx),
             "conversation_id" => "cnv_watch",
             "loop_id" => id,
             "agent_id" => ctx.agent_id,
             "session_id" => task.session_id
           }

    assert source == "loop:#{id}:comment-1"
    assert {:ok, %{"run_count" => 1}} = Store.get(id)

    # The same wake again is the same run.
    assert {:ok, %{"status" => "queued"}} = notify(bound, "comment-1")
    assert_received({:loop_woke, _loop, %{"source_id" => ^source}})
    assert {:ok, %{"run_count" => 1}} = Store.get(id)

    assert :ok = Loops.record_exit(id, incarnation, 0)
    settle_receive({:loop_woke, %{"loop_id" => ^id}, %{"source_id" => "loop:" <> _ = exited}})
    assert exited =~ "lifecycle:exited"
    assert {:ok, %{"status" => "paused", "paused_by" => "exited"}} = Store.get(id)
  end

  test "a Task Loop that cannot reach its Task pauses as undeliverable", %{ctx: ctx, sha: sha} do
    bound = create!(in_task(ctx, "cnv_watch"), sha)
    id = bound["loop_id"]
    {:ok, _} = Loops.begin_incarnation(id, "node@a", "s1")
    assert {:error, _} = notify(bound, "gone")

    assert {:ok, %{"status" => "paused", "paused_by" => "undeliverable", "run_count" => 0}} =
             Store.get(id)
  end

  defp notify(loop, dedup_key) do
    Capabilities.call(loop_ref(loop), "agent.notify", %{
      "content" => "PR #12 has a new comment",
      "dedup_key" => dedup_key
    })
  end

  test "create records the artifact's path and hash with the creator's authority", %{
    ctx: ctx,
    sha: sha
  } do
    loop =
      create!(ctx, sha, %{
        "name" => "watch",
        "config" => %{"interval_ms" => 500}
      })

    assert loop["status"] == "active"
    assert loop["artifact_sha256"] == sha
    assert loop["path"] == "/loops/main.elf"
    # No per-Loop grant list exists any more: the allowlist is the contract.
    refute Map.has_key?(loop, "capabilities")
    assert loop["incarnation"] == 0

    {:ok, record} = Store.get(loop["loop_id"])
    refute Map.has_key?(record, "elf")
    assert record["elf_path"] == "/loops/main.elf"
    assert {:ok, <<0x7F, ?E, ?L, ?F, 1, 2, 3>>} = Loops.artifact(record)
    assert record["ifc"] == %{"creator" => "comma_user|u1", "label" => ["public"]}
    assert record["session_id"] == ctx.session_id
  end

  test "a changed or deleted artifact file fails the load, never substitutes", %{
    ctx: ctx,
    sha: sha
  } do
    loop = create!(ctx, sha)
    {:ok, record} = Store.get(loop["loop_id"])

    :ok = put_file!(ctx.agent_id, "/loops/main.elf", <<0x7F, ?E, ?L, ?F, 9, 9, 9>>)
    assert {:error, :artifact_changed} = Loops.artifact(record)

    {:ok, _} =
      AgentWorkspace.seed_operation(ctx.agent_id, "loops-test:delete", %{}, [
        AgentWorkspace.prepare_delete("/loops/main.elf")
      ])

    assert {:error, :artifact_missing} = Loops.artifact(record)
  end

  test "the allowlist is closed and is what every loop is loaded with", %{ctx: ctx, sha: sha} do
    assert "fs.read_file" in Capabilities.allowed_names()
    refute Enum.any?(Capabilities.allowed_names(), &String.starts_with?(&1, "fs.write"))
    assert Enum.all?(Capabilities.builtin(), &(&1 in Capabilities.allowed_names()))

    # The external environment tools and the HTTP API request are callable;
    # other write tools are not.
    for name <-
          ~w(env.exec env.copy env.process_write env.computer_use device.get web.http_request ssh.open ssh.write ssh.exec ssh.upload ssh.download ssh.close ssh.known_hosts.remove),
        do: assert(name in Capabilities.allowed_names(), "#{name} must be callable")

    for name <-
          ~w(memory.write schedule.create agent.update loop.create script.run im_api.feishu.send_text),
        do: refute(name in Capabilities.allowed_names(), "#{name} must not be callable")

    # spinfoam is handed the whole allowlist, unconstrained, for every object.
    loaded = Capabilities.load_capabilities()
    assert Enum.map(loaded, & &1["name"]) == Capabilities.allowed_names()
    assert Enum.all?(loaded, &(&1["arguments"] == %{}))

    # A call outside the allowlist is refused by Salix before dispatch, whatever
    # the program asks for; there is no grant list on the row to consult.
    loop = create!(ctx, sha)
    ref = loop_ref(loop)

    assert {:error, "capability not available to loops: fs.write_file"} =
             Capabilities.call(ref, "fs.write_file", %{"path" => "/x", "content" => "y"})

    assert {:error, "capability not available to loops: im_api.feishu.send_text"} =
             Capabilities.call(ref, "im_api.feishu.send_text", %{})

    # `capabilities` on create is not an attribute any more; it is ignored, not
    # an error, so an older caller does not fail.
    assert {:ok, ignored} =
             Loops.create(ctx, %{"path" => "/loops/main.elf", "capabilities" => ["fs.write_file"]})

    refute Map.has_key?(ignored, "capabilities")
  end

  test "the per-agent quota is enforced at creation", %{ctx: ctx, sha: sha} do
    SystemsRuntime.put_env(:salix_agent, :loops_max_active_per_agent, 2)
    create!(ctx, sha)
    create!(ctx, sha)
    assert {:error, {:quota, :agent, 2}} = Loops.create(ctx, %{"path" => "/loops/main.elf"})
    {:ok, [a, _b]} = Loops.list(ctx.agent_id)
    assert {:ok, _} = Loops.pause(ctx.agent_id, a["loop_id"])
    assert {:ok, _} = Loops.create(ctx, %{"path" => "/loops/main.elf"})
  end

  test "incarnations fence checkpoints and object attachment", %{ctx: ctx, sha: sha} do
    loop = create!(ctx, sha)
    id = loop["loop_id"]

    assert {:ok, %{"incarnation" => 1, "object_id" => nil}} =
             Loops.begin_incarnation(id, "node@a", "s1")

    assert :ok = Loops.attach_object(id, 1, "o1")
    assert {:error, :stale_incarnation} = Loops.attach_object(id, 0, "o0")
    assert :ok = Loops.put_checkpoint(id, 1, %{"counter" => 1})
    assert {:error, :stale_incarnation} = Loops.put_checkpoint(id, 0, %{"counter" => 9})
    assert {:ok, %{"counter" => 1}} = Loops.get_checkpoint(id)
    assert Loops.current_incarnation?(id, 1)
    refute Loops.current_incarnation?(id, 0)
    assert :ok = Loops.end_incarnation(id, 1)
    assert {:ok, %{"object_id" => nil}} = Store.get(id)
    too_big = %{"blob" => String.duplicate("y", Loops.max_checkpoint_bytes())}
    assert {:error, :checkpoint_too_large} = Loops.put_checkpoint(id, 1, too_big)
    assert {:ok, _} = Loops.pause(ctx.agent_id, id)
    assert {:error, :not_active} = Loops.begin_incarnation(id, "node@a", "s1")
  end

  test "the notification budget rate-limits and then pauses a chatty loop", %{ctx: ctx, sha: sha} do
    loop = create!(ctx, sha)
    id = loop["loop_id"]
    {:ok, _} = Loops.begin_incarnation(id, "node@a", "s1")

    for _ <- 1..Loops.notify_window_limit(), do: assert(:ok = Loops.admit_notification(id, 1))
    assert {:error, :rate_limited} = Loops.admit_notification(id, 1)
    assert {:error, :stale_incarnation} = Loops.admit_notification(id, 2)

    # An hour of continuous limiting: age the limited-since stamp.
    {:ok, _} =
      Store.update(id, fn r ->
        {:ok,
         Map.put(r, "notify_limited_since_ms", r["notify_limited_since_ms"] - :timer.hours(2))}
      end)

    assert {:error, :budget_paused} = Loops.admit_notification(id, 1)
    assert {:ok, %{"status" => "paused", "paused_by" => "budget"}} = Store.get(id)
    assert {:error, :not_active} = Loops.admit_notification(id, 1)
  end

  test "exit pauses the loop once per incarnation", %{ctx: ctx, sha: sha} do
    loop = create!(ctx, sha)
    id = loop["loop_id"]
    {:ok, _} = Loops.begin_incarnation(id, "node@a", "s1")
    assert :ok = Loops.record_exit(id, 1, 7)

    assert {:ok, %{"status" => "paused", "paused_by" => "exited", "exit_code" => 7}} =
             Store.get(id)

    assert {:ok, %{"status" => "active", "incarnation" => 2}} = Loops.resume(ctx.agent_id, id)
    # A late exit notice from the retired incarnation changes nothing.
    assert :ok = Loops.record_exit(id, 1, 9)
    assert {:ok, %{"status" => "active", "exit_code" => 7}} = Store.get(id)
    assert {:error, :already_active} = Loops.resume(ctx.agent_id, id)
  end

  test "archive pauses every active loop and unarchive resumes exactly those", %{
    ctx: ctx,
    sha: sha
  } do
    a = create!(ctx, sha)
    b = create!(ctx, sha)
    {:ok, _} = Loops.pause(ctx.agent_id, b["loop_id"])

    assert {:ok, 1} = Loops.pause_for_archive(ctx.agent_id)
    assert {:ok, %{"status" => "paused", "paused_by" => "archive"}} = Store.get(a["loop_id"])
    assert {:ok, %{"paused_by" => "user"}} = Store.get(b["loop_id"])
    assert {:error, :agent_archived} = Loops.resume(ctx.agent_id, a["loop_id"])

    assert {:ok, 1} = Loops.resume_for_unarchive(ctx.agent_id)
    assert {:ok, %{"status" => "active", "paused_by" => nil}} = Store.get(a["loop_id"])
    assert {:ok, %{"status" => "paused", "paused_by" => "user"}} = Store.get(b["loop_id"])
  end

  test "archiving the agent through control pauses its loops", %{ctx: ctx, sha: sha} do
    loop = create!(ctx, sha)
    {:ok, agent} = SalixAgent.Control.get(ctx.agent_id)
    assert {:ok, _} = SalixAgent.Control.delete(ctx.agent_id, agent["tenant_id"])
    assert {:ok, %{"status" => "paused", "paused_by" => "archive"}} = Store.get(loop["loop_id"])
    assert {:ok, _} = SalixAgent.Control.unarchive(ctx.agent_id, agent["tenant_id"])
    assert {:ok, %{"status" => "active"}} = Store.get(loop["loop_id"])
  end

  test "the loop origin seals the creator's authority under the kernel's delegated wrapper" do
    origin = SalixAgent.IFC.loop_origin("lop1_1", "comma_user|u1", ["public"])
    assert origin["provider"] == "loop"
    assert origin["loop_id"] == "lop1_1"
    assert origin["ifc"]["principal"] == "schedule|loop:lop1_1|comma_user|u1"
    assert {:schedule, "loop:lop1_1", {:comma_user, "u1"}} = SalixAgent.IFC.principal(origin)
    assert SalixAgent.IFC.loop_origin("lop1_1", nil, nil) == nil
  end

  test "a capability call from a stale incarnation is refused at dispatch", %{ctx: ctx, sha: sha} do
    loop = create!(ctx, sha)
    loop_id = loop["loop_id"]
    {:ok, first} = Loops.begin_incarnation(loop_id, "node-a", "session-a")
    stale = %{loop_ref(loop) | incarnation: first["incarnation"]}

    {:ok, second} = Loops.begin_incarnation(loop_id, "node-b", "session-b")
    :ok = Loops.put_checkpoint(loop_id, second["incarnation"], %{"counter" => 2})
    current = %{stale | incarnation: second["incarnation"]}
    refute Loops.current_incarnation?(loop_id, stale.incarnation)

    assert {:error, message} = Capabilities.call(stale, "loop.state.get", %{})
    assert message =~ "no longer current"
    assert {:error, _} = Capabilities.call(stale, "loop.log", %{"message" => "stale"})

    assert {:ok, %{"state" => %{"counter" => 2}}} =
             Capabilities.call(current, "loop.state.get", %{})

    # a paused Loop's resident object is refused too
    assert {:ok, _} = Loops.pause(ctx.agent_id, loop_id)
    assert {:error, _} = Capabilities.call(current, "loop.state.get", %{})
  end

  defp loop_ref(loop) do
    {:ok, record} = Store.get(loop["loop_id"])

    %{
      loop_id: record["id"],
      incarnation: record["incarnation"],
      agent_id: record["agent_id"],
      session_id: record["session_id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      task_conversation_id: record["task_conversation_id"],
      name: record["name"],
      ifc: record["ifc"]
    }
  end
end
