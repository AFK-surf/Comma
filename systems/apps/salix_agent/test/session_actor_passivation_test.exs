defmodule SalixAgent.SessionActorPassivationTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{
    Control,
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore,
    Runtime
  }

  alias SalixAgent.LLM.Mock
  alias SalixStore.{Agent, Keys, S3}

  @pid_key {__MODULE__, :test_pid}

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case SystemsRuntime.PersistentTerm.get(
             {SalixAgent.SessionActorPassivationTest, :test_pid},
             nil
           ) do
        nil -> :ok
        pid -> SystemsRuntime.Proc.send(pid, {:session_actor_notifier, agent_id, event})
      end

      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_idle_ms = SystemsRuntime.get_env(:salix_agent, :session_actor_idle_ms)
    prev_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    if SystemsRuntime.Proc.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 20)
    SystemsRuntime.put_env(:salix_agent, :notifier, TestNotifier)
    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(@pid_key)
      put_or_delete_env(:salix_store, :s3_backend, prev_store)
      put_or_delete_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :session_actor_idle_ms, prev_idle_ms)
      put_or_delete_env(:salix_agent, :notifier, prev_notifier)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, agent_id: agent_id}
  end

  test "internal session actor stays resident until eviction and later wakes through delivery", %{
    agent_id: agent_id
  } do
    {:ok, pid} = InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910")
    ref = SystemsRuntime.Proc.monitor(pid)

    settle_refute_receive({:DOWN, ^ref, :process, ^pid, _}, 100)
    # A queued request from an old pressure episode cannot retire a now-warm
    # actor after the controller has reopened admission.
    SalixAgent.SessionResidency.second_chance(pid)
    SystemsRuntime.Proc.send(pid, :residency_evict)
    settle_refute_receive({:DOWN, ^ref, :process, ^pid, _}, 50)

    with_memory_pressure(fn ->
      assert eventually(fn ->
               SalixAgent.SessionResidency.second_chance(pid)
               SystemsRuntime.Proc.send(pid, :residency_evict)
               not SystemsRuntime.Proc.alive?(pid)
             end)
    end)

    settle_receive({:DOWN, ^ref, :process, ^pid, :normal})

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
             ) ==
               []
           end)

    Mock.script([{:final, "after passivation"}])

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: "wake the passivated session",
                 session_id: "ses1_0000000000000000910",
                 role: "user",
                 created_at: SystemsClock.system_time(:second)
               },
               source_message_id: "passivation:internal:wake"
             )

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910") do
               {:ok, session} ->
                 Enum.any?(
                   session.messages,
                   &(&1.role == "assistant" and &1.content == "after passivation")
                 )

               {:error, _reason} ->
                 false
             end
           end)
  end

  test "runtime fork is executed by the target internal session actor", %{agent_id: agent_id} do
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 1_000)

    {:ok, _source} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000910", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000910",
          "name" => "Main"
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000000910",
          "message_id" => 1,
          "source_message_id" => "fork-source",
          "role" => "user",
          "content" => "copy this message"
        }
      ])

    assert {:ok, forked} =
             Runtime.fork_session(agent_id, "ses1_0000000000000000910", %{
               "target_session_id" => "ses1_0000000000000000911",
               "fork_request_id" => "passivation-fork-1",
               "name" => "Forked"
             })

    forked_session_id = forked["session_id"]
    assert SalixStore.Ids.valid_session_id?(forked_session_id)
    assert forked["name"] == "Forked"

    assert {:ok, forked_state} =
             SalixAgent.TestSupport.SessionData.read(agent_id, forked_session_id)

    assert Enum.any?(forked_state.messages, &(&1.content == "copy this message"))

    assert [{pid, _}] =
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, forked_session_id)
             )

    assert SystemsRuntime.Proc.alive?(pid)

    settle_receive({:session_actor_notifier, ^agent_id, {:session_updated, ^forked_session_id}})

    settle_receive(
      {:session_actor_notifier, ^agent_id, {:session_activity_updated, ^forked_session_id}}
    )
  end

  test "agent fork prepares internal sessions without starting runtime actors" do
    source_id = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(source_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)
    target_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(source_id)

    {:ok, _source} =
      InternalSessionStore.prepare_commit(source_id, "ses1_0000000000000000910", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000910",
          "name" => "Source Main",
          "hidden" => true,
          "created_at" => 100
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "ses1_0000000000000000910",
          "message_id" => 1,
          "source_message_id" => "agent-fork-source",
          "role" => "user",
          "content" => "seed this transcript"
        }
      ])

    assert {:ok, target} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Fork Target",
                 "fork_from" => source_id
               },
               tenant_id,
               target_id
             )

    assert target["forked_from"] == source_id

    assert {:ok, [forked_session]} = InternalSessionStore.list(target_id)

    assert SalixStore.Ids.valid_session_id?(
             SalixAgent.InternalSession.get(forked_session, :session_id)
           )

    refute SalixAgent.InternalSession.get(forked_session, :session_id) ==
             "ses1_0000000000000000910"

    assert SalixAgent.InternalSession.get(forked_session, :source_agent_id) == source_id

    assert SalixAgent.InternalSession.get(forked_session, :source_session_id) ==
             "ses1_0000000000000000910"

    assert SalixAgent.InternalSession.get(forked_session, :name) == "Source Main"
    assert SalixAgent.InternalSession.get(forked_session, :hidden) == true

    assert Enum.any?(
             SalixAgent.InternalSession.get(forked_session, :messages),
             &(&1.content == "seed this transcript")
           )

    assert Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(
               target_id,
               SalixAgent.InternalSession.get(forked_session, :session_id)
             )
           ) == []

    forked_session_id = SalixAgent.InternalSession.get(forked_session, :session_id)

    settle_refute_receive(
      {:session_actor_notifier, ^target_id, {:session_updated, ^forked_session_id}},
      50
    )
  end

  test "internal session control delivery commits and notifies from the session actor", %{
    agent_id: agent_id
  } do
    {:ok, :created} =
      SalixAgent.deliver(
        agent_id,
        %{kind: "session_create", session_id: "ses1_0000000000000000910", name: "Original"},
        source_message_id: "session-control:create"
      )

    {:ok, :created} =
      SalixAgent.deliver(
        agent_id,
        %{kind: "session_update", session_id: "ses1_0000000000000000910", name: "Renamed"},
        source_message_id: "session-control:update"
      )

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910") do
               {:ok, session} -> session.name == "Renamed"
               {:error, _} -> false
             end
           end)

    settle_receive(
      {:session_actor_notifier, ^agent_id, {:session_updated, "ses1_0000000000000000910"}}
    )
  end

  test "session_log control preserves explicit dedupe key", %{agent_id: agent_id} do
    entry = fn content ->
      %{
        source_message_id: "session-log-source-#{content}",
        payload: %{
          kind: "session_log",
          session_id: "ses1_0000000000000000910",
          dedupe_key: "session-log-event-key",
          content: content
        }
      }
    end

    assert {:ok, :committed, []} = SalixAgent.AgentActor.stage_delivery(agent_id, entry.("first"))

    assert {:ok, :committed, []} =
             SalixAgent.AgentActor.stage_delivery(agent_id, entry.("duplicate"))

    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910")
    assert Enum.map(session.messages, & &1.content) == ["first"]
    assert Enum.map(session.messages, & &1.dedupe_key) == ["session-log-event-key"]
  end

  test "wait timeout wakes only the target internal session actor", %{agent_id: agent_id} do
    wait_a = SalixAgent.Waits.build("target wait", 20, "wait_for", %{"tool_call_id" => "a"})
    wait_b = SalixAgent.Waits.build("other wait", 20, "wait_for", %{"tool_call_id" => "b"})

    {:ok, _session_a} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000913", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000913",
          "name" => "Wait A"
        },
        SalixAgent.Waits.event("ses1_0000000000000000913", wait_a)
      ])

    {:ok, _session_b} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000914", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000914",
          "name" => "Wait B"
        },
        SalixAgent.Waits.event("ses1_0000000000000000914", wait_b)
      ])

    Mock.script([{:final, "handled target timeout"}])

    source_id = "wait-timeout:wait-a:#{wait_a["wait_id"]}"

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 kind: "wait_timeout",
                 session_id: "ses1_0000000000000000913",
                 wait_id: wait_a["wait_id"],
                 wait: wait_a,
                 content: SalixAgent.Waits.timeout_content(wait_a)
               },
               source_message_id: source_id
             )

    assert eventually(fn ->
             with {:ok, session} <-
                    SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000913") do
               session.wait == nil and
                 Enum.any?(
                   session.messages,
                   &(&1.role == "runtime" and &1.runtime_message_id == source_id)
                 )
             else
               _ -> false
             end
           end)

    assert {:ok, other} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000914")

    assert other.wait["wait_id"] == wait_b["wait_id"]

    refute Enum.any?(
             other.messages,
             &(&1.role == "runtime" and &1.runtime_message_id == source_id)
           )

    settle_receive(
      {:session_actor_notifier, ^agent_id, {:session_updated, "ses1_0000000000000000913"}}
    )

    settle_refute_receive(
      {:session_actor_notifier, ^agent_id, {:session_updated, "ses1_0000000000000000914"}},
      50
    )
  end

  test "expired internal wait without wait id uses stable non-unknown timeout identity", %{
    agent_id: agent_id
  } do
    wait = %{
      "reason" => "missing id wait",
      "deadline_ms" => SystemsClock.system_time(:millisecond) - 1,
      "timeout_seconds" => 1
    }

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000915", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000000915"},
        %{"type" => "wait_set", "session_id" => "ses1_0000000000000000915", "wait" => wait}
      ])

    Mock.script([{:final, "handled missing wait id timeout"}])

    {:ok, _pid} = InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000915")

    assert eventually(fn ->
             with {:ok, session} <-
                    SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000915"),
                  %{} = runtime <- Enum.find(session.messages, &(&1[:role] == "runtime")) do
               runtime.runtime_message_id =~
                 "wait-timeout:ses1_0000000000000000915:" and
                 runtime.type == "wait_expired" and
                 runtime.reason == "missing id wait"
             else
               _ -> false
             end
           end)
  end

  test "async tool completion wakes only the target internal session actor", %{agent_id: agent_id} do
    capability_a =
      SalixAgent.TestSupport.pending_capability_fields!(
        agent_id,
        "ses1_0000000000000000917",
        "tool-a"
      )

    capability_b =
      SalixAgent.TestSupport.pending_capability_fields!(
        agent_id,
        "ses1_0000000000000000918",
        "tool-b"
      )

    {:ok, _session_a} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000917", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000917",
          "name" => "Async A"
        },
        %{
          "type" => "async_tool_call_started",
          "session_id" => "ses1_0000000000000000917",
          "tool_call_id" => "tool-a",
          "tool_name" => "long_tool",
          "input" => %{},
          "status" => "running",
          "completion_mode" => "external_callback",
          "capability_request_id" => capability_a["capability_request_id"],
          "capability_deadline_ms" => capability_a["capability_deadline_ms"],
          "started_at" => SystemsClock.system_time(:millisecond)
        }
      ])

    {:ok, _session_b} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000918", [
        %{
          "type" => "session_created",
          "session_id" => "ses1_0000000000000000918",
          "name" => "Async B"
        },
        %{
          "type" => "async_tool_call_started",
          "session_id" => "ses1_0000000000000000918",
          "tool_call_id" => "tool-b",
          "tool_name" => "long_tool",
          "input" => %{},
          "status" => "running",
          "completion_mode" => "external_callback",
          "capability_request_id" => capability_b["capability_request_id"],
          "capability_deadline_ms" => capability_b["capability_deadline_ms"],
          "started_at" => SystemsClock.system_time(:millisecond)
        }
      ])

    Mock.script([{:final, "handled async result"}])

    assert {:ok, %{"status" => "completed", "tool_call_id" => "tool-a"}} =
             SalixAgent.complete_async_tool_call(
               agent_id,
               "ses1_0000000000000000917",
               "tool-a",
               %{name: "long_tool", content: "done", status: "completed"},
               %{"tool_name" => "long_tool"}
             )

    assert eventually(fn ->
             with {:ok, session} <-
                    SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000917"),
                  {:ok, %{"status" => "completed"}} <-
                    SalixAgent.TestSupport.SessionData.query(
                      session,
                      :lookup_async_call,
                      "tool-a"
                    ) do
               Enum.any?(
                 session.messages,
                 &(&1.role == "runtime" and &1.source_tool_call_id == "tool-a")
               ) and
                 Enum.any?(
                   session.messages,
                   &(&1.role == "assistant" and &1.content == "handled async result")
                 )
             else
               _ -> false
             end
           end)

    assert {:ok, other} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000918")

    assert other.async_tool_calls["tool-b"]["status"] == "running"

    refute Enum.any?(
             other.messages,
             &(&1.role == "runtime" and &1.source_tool_call_id == "tool-a")
           )

    settle_receive(
      {:session_actor_notifier, ^agent_id, {:session_updated, "ses1_0000000000000000917"}}
    )

    settle_refute_receive(
      {:session_actor_notifier, ^agent_id, {:session_updated, "ses1_0000000000000000918"}},
      50
    )
  end

  test "agent cancel stops live session actors", %{agent_id: agent_id} do
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 1_000)

    {:ok, internal_pid} =
      InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910",
        process_on_init: false
      )

    assert Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
           ) != []

    assert {:ok, _config} = SalixAgent.AgentActor.runtime_session_config(agent_id, %{})
    assert {:ok, record} = SalixAgent.Control.get_record(agent_id)
    assert {:ok, _role_actor} = SalixAgent.AgentActor.ensure_started(record)
    assert Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(agent_id)) != []

    assert SystemsRuntime.Proc.alive?(internal_pid)

    assert {:ok, agent} = Control.cancel(agent_id)
    assert agent["status"] == "cancelled"

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
             ) ==
               [] and
               Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(agent_id)) == []
           end)

    refute SystemsRuntime.Proc.alive?(internal_pid)

    assert Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
           ) == []

    Mock.script([{:final, "after cancel restart"}])

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: "ses1_0000000000000000910",
                 role: "user",
                 content: "restart after cancel"
               },
               source_message_id: "cancelled-agent:delivery"
             )

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910") do
               {:ok, session} ->
                 Enum.any?(
                   session.messages,
                   &(&1.role == "assistant" and &1.content == "after cancel restart")
                 )

               {:error, _reason} ->
                 false
             end
           end)
  end

  test "agent delete archives and blocks later delivery" do
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 1_000)
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, pid} =
      InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910",
        process_on_init: false
      )

    assert SystemsRuntime.Proc.alive?(pid)
    assert {:ok, _config} = SalixAgent.AgentActor.runtime_session_config(agent_id, %{})
    assert {:ok, record} = SalixAgent.Control.get_record(agent_id)
    assert {:ok, _role_actor} = SalixAgent.AgentActor.ensure_started(record)
    assert Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(agent_id)) != []

    assert {:ok, agent} = Control.delete(agent_id)
    assert agent["status"] == "cancelled"
    assert is_integer(agent["archived_at"])

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.deliver(
               agent_id,
               %{session_id: "ses1_0000000000000000910", role: "user", content: "do not restart"},
               source_message_id: "archived-agent:delivery"
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.Fleet.ensure_started(agent_id, create: false)

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.Placement.ensure_started(agent_id, create: false)

    assert {:error, {:bad_request, "agent is archived"}} = Control.wake(agent_id)

    assert {:error, {:bad_request, "agent is archived"}} =
             InternalSessionFleet.wake(agent_id, "ses1_0000000000000000910")

    assert {:error, {:bad_request, "agent is archived"}} =
             InternalSessionFleet.stage_delivery(agent_id, "ses1_0000000000000000910", %{
               source_message_id: "archived-agent:internal-delivery",
               payload: %{
                 session_id: "ses1_0000000000000000910",
                 role: "user",
                 content: "do not stage"
               }
             })

    assert {:error, {:bad_request, "agent is archived"}} =
             InternalSessionFleet.stage_control(agent_id, "ses1_0000000000000000910", %{
               source_message_id: "archived-agent:internal-control",
               payload: %{
                 kind: "session_update",
                 session_id: "ses1_0000000000000000910",
                 name: "Do not update"
               }
             })

    assert {:error, {:bad_request, "agent is archived"}} =
             InternalSessionFleet.fork_session(
               agent_id,
               "ses1_0000000000000000910",
               "ses1_0000000000000000911",
               %{}
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.execute_session_tool(
               agent_id,
               "ses1_0000000000000000910",
               "fs.read_file",
               %{"path" => "/x"}
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.complete_async_tool_call(
               agent_id,
               "ses1_0000000000000000910",
               "late-tool",
               %{name: "late_tool", content: "late", status: "completed"},
               %{"tool_name" => "late_tool"}
             )

    # Archive closes admission first; explicit stop can finish existing work later.
    assert {:ok, %{next_cursor: nil}} = Control.stop(agent_id, agent["tenant_id"])

    # Each actor has its own Registry monitor; one actor disappearing does not
    # fence asynchronous Registry cleanup for the server or the other sessions.
    stopped_keys = [
      agent_id,
      SalixAgent.AgentActor.key(agent_id),
      InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
    ]

    assert eventually(fn ->
             Enum.all?(stopped_keys, &(Registry.lookup(SalixAgent.Registry, &1) == []))
           end)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp with_memory_pressure(fun) do
    controller = SystemsRuntime.Proc.whereis(SalixAgent.SessionResidency)
    :sys.suspend(controller, :infinity)
    previous = :ets.lookup(SalixAgent.SessionResidency, :pressure)

    try do
      :ets.insert(SalixAgent.SessionResidency, {:pressure, :high})
      fun.()
    after
      :ets.delete(SalixAgent.SessionResidency, :pressure)
      :ets.insert(SalixAgent.SessionResidency, previous)
      :sys.resume(controller, :infinity)
    end
  end
end
