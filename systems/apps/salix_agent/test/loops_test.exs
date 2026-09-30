defmodule SalixAgent.LoopsTest do
  @moduledoc """
  Background Loop domain rules over the durable row, independent of the
  spinfoam child: quotas, the closed capability allowlist, the notification and
  restart budgets, incarnation fencing, archive pause and unarchive resume.
  """
  use ExUnit.Case, async: false

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

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_agent_max = Application.get_env(:salix_agent, :loops_max_active_per_agent)
    Application.put_env(:salix_store, :s3_backend, Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    if Process.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)
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

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp put_file!(agent_id, path, content) do
    {:ok, event} = AgentWorkspace.prepare_write(agent_id, path, content)

    {:ok, _} =
      AgentWorkspace.seed_operation(
        agent_id,
        "loops-test:#{System.unique_integer([:positive])}",
        %{},
        [event]
      )

    :ok
  end

  defp create!(ctx, _sha, attrs \\ %{}) do
    {:ok, loop} = Loops.create(ctx, Map.merge(%{"path" => "/loops/main.elf"}, attrs))
    loop
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

  test "a missing or non-ELF file, an oversized config and a bad name are refused", %{
    ctx: ctx
  } do
    assert {:error, :artifact_not_found} = Loops.create(ctx, %{"path" => "/loops/nope.elf"})
    :ok = put_file!(ctx.agent_id, "/notes.md", "not an object")
    assert {:error, :invalid_artifact} = Loops.create(ctx, %{"path" => "/notes.md"})
    assert {:error, {:invalid, "path"}} = Loops.create(ctx, %{"path" => "loops/main.elf"})
    assert {:error, {:invalid, "path"}} = Loops.create(ctx, %{"path" => "/.runtime/x.elf"})
    big = %{"blob" => String.duplicate("x", Loops.max_config_bytes())}

    assert {:error, {:invalid, "config_too_large"}} =
             Loops.create(ctx, %{"path" => "/loops/main.elf", "config" => big})

    assert {:error, {:invalid, "name"}} =
             Loops.create(ctx, %{"path" => "/loops/main.elf", "name" => String.duplicate("n", 81)})

    assert {:error, {:missing, "path"}} = Loops.create(ctx, %{})
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

  test "env.exec runs the command through the tool dispatcher without a grant", %{
    ctx: ctx,
    sha: sha
  } do
    previous = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, SalixAgent.LoopEnvDispatchFixture)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :env_dispatch, previous),
        else: Application.delete_env(:salix_agent, :env_dispatch)
    end)

    SalixAgent.LoopEnvDispatchFixture.register()

    loop = create!(ctx, sha)

    {:ok, _} = Loops.begin_incarnation(loop["loop_id"], "node@a", "s1")
    ref = loop_ref(loop)

    args = %{
      "device_id" => "dev-1",
      "environment" => "env-1",
      "command" => "uptime",
      "description" => "loop probe",
      "timeout" => 5
    }

    assert {:ok, %{"tool" => "env.exec", "error" => false, "content" => content}} =
             Capabilities.call(ref, "env.exec", args)

    assert %{"exit_code" => 0, "stdout" => "ran: uptime"} = Jason.decode!(content)

    assert_receive {:loop_env_exec, agent_id, %{device_id: "dev-1", environment_id: "env-1"},
                    "uptime", %{"description" => "loop probe", "timeout" => 5}}

    assert agent_id == ctx.agent_id

    # A write outside the allowlist never reaches the environment dispatch.
    assert {:error, "capability not available to loops: memory.write"} =
             Capabilities.call(ref, "memory.write", %{"content" => "x"})

    refute_receive {:loop_env_exec, _, _, _, _}, 100
  end

  test "Loop decisions reject stale callers and return an error instead of truncated JSON", %{
    ctx: ctx,
    sha: sha
  } do
    SalixAgent.DecideFixture.start_provider()
    {:ok, _} = SalixAgent.InternalSessionStore.prepare_commit(ctx.agent_id, ctx.session_id, [])
    loop = create!(ctx, sha)
    ref = loop_ref(loop)
    args = SalixAgent.DecideFixture.args()

    assert {:error, _} =
             Capabilities.call(%{ref | incarnation: ref.incarnation + 1}, "decide", args)

    refute_receive {:decision_request, _, _, _}
    assert {:ok, full} = Capabilities.call(ref, "decide", args)
    assert_receive {:decision_request, "/v1/systemone", _, _}
    exact_budget = byte_size(Jason.encode!(full))
    assert {:ok, ^full} = Capabilities.call(ref, "decide", args, exact_budget)
    assert_receive {:decision_request, "/v1/systemone", _, _}
    assert {:ok, payload} = Capabilities.call(ref, "decide", args, 256)
    assert_receive {:decision_request, "/v1/systemone", _, _}
    assert Jason.decode!(payload["content"]) == %{"error" => %{"code" => "result_too_large"}}
    assert byte_size(Jason.encode!(payload)) <= 256
  end

  test "web.http_request runs the request through the tool dispatcher without a grant", %{
    ctx: ctx,
    sha: sha
  } do
    previous = Application.get_env(:salix_agent, :http_request_allow_private_hosts)
    Application.put_env(:salix_agent, :http_request_allow_private_hosts, true)

    on_exit(fn ->
      restore(:salix_agent, :http_request_allow_private_hosts, previous)
    end)

    owner = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(owner, {:loop_http, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"seen" => conn.method}))
    end

    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(make_ref(), 20000)

        case start_supervised({Bandit, plug: {LoopHttpPlug, plug}, port: p, startup_log: false},
               id: {:bandit, p}
             ) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    url = "http://127.0.0.1:#{port}/status"

    loop = create!(ctx, sha)

    {:ok, _} = Loops.begin_incarnation(loop["loop_id"], "node@a", "s1")
    ref = loop_ref(loop)

    assert {:ok, %{"tool" => "web.http_request", "error" => false, "content" => content}} =
             Capabilities.call(ref, "web.http_request", %{"url" => url, "method" => "GET"})

    assert %{"status" => 200, "ok" => true, "body" => %{"seen" => "GET"}} = Jason.decode!(content)
    assert_receive {:loop_http, "GET", "/status", ""}

    # The program chooses the endpoint and method; a second call to another
    # path with another method is the program's own decision and goes through.
    assert {:ok, %{"error" => false, "content" => second}} =
             Capabilities.call(ref, "web.http_request", %{
               "url" => "http://127.0.0.1:#{port}/other",
               "method" => "DELETE"
             })

    assert %{"status" => 200, "body" => %{"seen" => "DELETE"}} = Jason.decode!(second)
    assert_receive {:loop_http, "DELETE", "/other", ""}
  end

  test "the per-agent quota is enforced at creation", %{ctx: ctx, sha: sha} do
    Application.put_env(:salix_agent, :loops_max_active_per_agent, 2)
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

  test "the restart budget reloads a faulted loop three times an hour, then fails it", %{
    ctx: ctx,
    sha: sha
  } do
    loop = create!(ctx, sha)
    id = loop["loop_id"]
    {:ok, _} = Loops.begin_incarnation(id, "node@a", "s1")

    for _ <- 1..Loops.restart_limit(),
        do: assert({:ok, :restart} = Loops.record_failure(id, 1, "boom"))

    assert {:ok, :failed} = Loops.record_failure(id, 1, "boom again")
    assert {:ok, %{"status" => "failed", "failure" => "boom again"}} = Store.get(id)
    assert {:error, :stale_incarnation} = Loops.record_failure(id, 1, "late")

    assert {:ok, %{"status" => "active"}} = Loops.resume(ctx.agent_id, id)
    assert {:ok, %{"failure" => nil}} = Store.get(id)
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

  test "events are validated and acks are recorded", %{ctx: ctx, sha: sha} do
    loop = create!(ctx, sha)
    id = loop["loop_id"]

    assert {:error, {:invalid_event, "topic"}} =
             Loops.send_event(ctx.agent_id, id, %{"payload" => %{}})

    assert {:error, {:invalid_event, "payload_too_large"}} =
             Loops.send_event(ctx.agent_id, id, %{
               "topic" => "t",
               "payload" => String.duplicate("z", 17_000)
             })

    assert {:error, :not_found} =
             Loops.send_event(
               "agt1_0000000000000000001_0000000000000000002_0000000000000000003",
               id,
               %{"topic" => "t"}
             )

    {:ok, current} = Store.get(id)
    assert :ok = Loops.ack_event(id, current["incarnation"], "e1")
    assert Store.acked?(id, "e1")
    assert {:error, :invalid_event_id} = Loops.ack_event(id, current["incarnation"], "")
    assert :ok = Loops.delete(ctx.agent_id, id)
    refute Store.acked?(id, "e1")
  end

  test "the loop origin seals the creator's authority under the kernel's delegated wrapper" do
    origin = SalixAgent.IFC.loop_origin("lop1_1", "comma_user|u1", ["public"])
    assert origin["provider"] == "loop"
    assert origin["loop_id"] == "lop1_1"
    assert origin["ifc"]["principal"] == "schedule|loop:lop1_1|comma_user|u1"
    assert {:schedule, "loop:lop1_1", {:comma_user, "u1"}} = SalixAgent.IFC.principal(origin)
    assert SalixAgent.IFC.loop_origin("lop1_1", nil, nil) == nil
  end

  test "resume is admitted against the active quota like create", %{ctx: ctx, sha: sha} do
    Application.put_env(:salix_agent, :loops_max_active_per_agent, 1)
    a = create!(ctx, sha, %{"name" => "a"})
    assert {:ok, %{"status" => "paused"}} = Loops.pause(ctx.agent_id, a["loop_id"])
    b = create!(ctx, sha, %{"name" => "b"})

    assert {:error, {:quota, :agent, 1}} = Loops.resume(ctx.agent_id, a["loop_id"])

    assert {:ok, %{"status" => "paused", "paused_by" => "user"}} =
             Loops.get(ctx.agent_id, a["loop_id"])

    assert {:error, {:quota, :agent, 1}} = Loops.create(ctx, %{"path" => "/loops/main.elf"})

    assert {:ok, %{"status" => "paused"}} = Loops.pause(ctx.agent_id, b["loop_id"])
    assert {:ok, %{"status" => "active"}} = Loops.resume(ctx.agent_id, a["loop_id"])

    assert {:ok, {1, 1}} =
             Store.active_counts(ctx.agent_id, elem(Store.get(a["loop_id"]), 1)["group_id"])
  end

  test "unarchive restores only what the quota admits and parks the rest", %{ctx: ctx, sha: sha} do
    Application.put_env(:salix_agent, :loops_max_active_per_agent, 1)
    a = create!(ctx, sha, %{"name" => "a"})
    assert {:ok, 1} = Loops.pause_for_archive(ctx.agent_id)
    b = create!(ctx, sha, %{"name" => "b"})

    assert {:ok, 0} = Loops.resume_for_unarchive(ctx.agent_id)

    assert {:ok, %{"status" => "paused", "paused_by" => "quota"}} =
             Loops.get(ctx.agent_id, a["loop_id"])

    assert {:ok, %{"status" => "active"}} = Loops.get(ctx.agent_id, b["loop_id"])

    assert {:ok, %{"status" => "paused"}} = Loops.pause(ctx.agent_id, b["loop_id"])
    assert {:ok, %{"status" => "active"}} = Loops.resume(ctx.agent_id, a["loop_id"])
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

  test "recovery walks past an unserviceable first page to a stranded tail", %{
    ctx: ctx,
    sha: sha
  } do
    prev_page = Application.get_env(:salix_agent, :loops_recovery_page)
    prev_capacity = Application.get_env(:salix_agent, :spinfoam_max_objects)
    Application.put_env(:salix_agent, :loops_recovery_page, 2)
    # Keep these rows stranded even when the suite has a live spinfoam Host.
    Application.put_env(:salix_agent, :spinfoam_max_objects, 0)

    on_exit(fn ->
      restore(:salix_agent, :loops_recovery_page, prev_page)
      restore(:salix_agent, :spinfoam_max_objects, prev_capacity)
    end)

    # A is served here: its two stranded rows fill the first page and are
    # skipped by recovery (adoption owns them); B's Server is not running.
    {:ok, _} = SalixAgent.Fleet.ensure_started(ctx.agent_id, create: false)
    :ok = SalixAgent.Fleet.await_ownership_installed(ctx.agent_id)
    a1 = create!(ctx, sha, %{"name" => "a1"})
    a2 = create!(ctx, sha, %{"name" => "a2"})

    b = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(b, %{"role" => "worker"})
    :ok = put_file!(b, "/loops/main.elf", <<0x7F, ?E, ?L, ?F, 1, 2, 3>>)
    b_session = SalixStore.Ids.new_session_id()

    {:ok, b_loop} =
      Loops.create(%{ctx | agent_id: b, session_id: b_session}, %{"path" => "/loops/main.elf"})

    :ok = SalixAgent.Fleet.stop_existing(b)

    later = System.system_time(:millisecond) + 10

    for id <- [a1["loop_id"], a2["loop_id"]],
        do:
          {:ok, _} =
            Store.update(
              id,
              &{:ok, Map.merge(&1, %{"object_id" => nil, "updated_at" => later - 5})}
            )

    {:ok, _} =
      Store.update(
        b_loop["loop_id"],
        &{:ok, Map.merge(&1, %{"object_id" => nil, "updated_at" => later})}
      )

    assert Registry.lookup(SalixAgent.Registry, b) == []

    :sys.replace_state(SalixAgent.Loops.Reconciler, &%{&1 | recovery_cursor: nil})
    live_nodes = Enum.map([node() | Node.list()], &Atom.to_string/1)
    assert {:ok, first_page} = Store.list_active_stranded(live_nodes, 2, nil)
    assert MapSet.new(first_page, & &1["id"]) == MapSet.new([a1["loop_id"], a2["loop_id"]])

    sweep = fn ->
      send(SalixAgent.Loops.Reconciler, :sweep)
      # the release call is a barrier behind the sweep message
      :ok = SalixAgent.Loops.Reconciler.release("agt1_none")
    end

    sweep.()
    assert Registry.lookup(SalixAgent.Registry, b) == [], "the first page must not reach B"
    sweep.()
    assert [{_pid, _}] = Registry.lookup(SalixAgent.Registry, b)
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
      name: record["name"],
      ifc: record["ifc"]
    }
  end
end
