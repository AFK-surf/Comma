defmodule SalixAgent.SessionActorPassivationTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    Control,
    ExternalSessionActor,
    ExternalSessionFleet,
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore,
    Runtime
  }

  alias SalixAgent.LLM.Mock
  alias SalixStore.{Agent, Keys, RuntimeIds, S3}

  @pid_key {__MODULE__, :test_pid}
  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case :persistent_term.get({SalixAgent.SessionActorPassivationTest, :test_pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:session_actor_notifier, agent_id, event})
      end

      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_external_runtime = Application.get_env(:salix_agent, :external_runtime_driver)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_idle_ms = Application.get_env(:salix_agent, :session_actor_idle_ms)
    prev_notifier = Application.get_env(:salix_agent, :notifier)

    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :external_runtime_driver, SalixAgent.ExternalRuntime.None)
    Application.put_env(:salix_agent, :session_actor_idle_ms, 20)
    Application.put_env(:salix_agent, :notifier, TestNotifier)
    :persistent_term.put(@pid_key, self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase(@pid_key)
      put_or_delete_env(:salix_store, :s3_backend, prev_store)
      put_or_delete_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :external_runtime_driver, prev_external_runtime)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :session_actor_idle_ms, prev_idle_ms)
      put_or_delete_env(:salix_agent, :notifier, prev_notifier)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, agent_id: agent_id}
  end

  test "pressure denies absent sessions but preserves warm admission", %{agent_id: agent_id} do
    session = "ses1_0000000000000000910"

    assert {:ok, pid} =
             InternalSessionFleet.ensure_started(agent_id, session, process_on_init: false)

    controller = Process.whereis(SalixAgent.SessionResidency)
    :sys.suspend(controller)
    previous = :ets.lookup(SalixAgent.SessionResidency, :pressure)

    try do
      :ets.insert(SalixAgent.SessionResidency, {:pressure, :high})

      assert {:ok, ^pid} =
               InternalSessionFleet.ensure_started(agent_id, session, process_on_init: false)

      assert {:error, :session_memory_pressure} =
               SalixAgent.Fleet.start_session_actor(InternalSessionActor,
                 agent_id: agent_id,
                 session_id: "ses1_0000000000000000999",
                 process_on_init: false
               )

      assert Process.alive?(pid)
    after
      :ets.delete(SalixAgent.SessionResidency, :pressure)
      :ets.insert(SalixAgent.SessionResidency, previous)
      :sys.resume(controller)
    end
  end

  test "internal session actor stays resident until eviction and later wakes through delivery", %{
    agent_id: agent_id
  } do
    {:ok, pid} = InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910")
    ref = Process.monitor(pid)

    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
    # A queued request from an old pressure episode cannot retire a now-warm
    # actor after the controller has reopened admission.
    SalixAgent.SessionResidency.second_chance(pid)
    send(pid, :residency_evict)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50

    with_memory_pressure(fn ->
      assert eventually(fn ->
               SalixAgent.SessionResidency.second_chance(pid)
               send(pid, :residency_evict)
               not Process.alive?(pid)
             end)
    end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

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
                 created_at: System.system_time(:second)
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
    Application.put_env(:salix_agent, :session_actor_idle_ms, 1_000)

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

    assert Process.alive?(pid)

    assert_receive {:session_actor_notifier, ^agent_id, {:session_updated, ^forked_session_id}}

    assert_receive {:session_actor_notifier, ^agent_id,
                    {:session_activity_updated, ^forked_session_id}}
  end

  test "internal fork and seed calls reject a non-target session actor", %{agent_id: agent_id} do
    Application.put_env(:salix_agent, :session_actor_idle_ms, 1_000)

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

    assert {:ok, source_state} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910")

    wrong_owner_session_id = "ses1_0000000000000000920"
    target_seed_session_id = "ses1_0000000000000000921"

    assert {:ok, wrong_pid} =
             InternalSessionFleet.ensure_started(agent_id, wrong_owner_session_id)

    assert {:error,
            {:session_actor_target_mismatch, ^wrong_owner_session_id, "ses1_0000000000000000912"}} =
             InternalSessionActor.fork_session(
               wrong_pid,
               "ses1_0000000000000000910",
               "ses1_0000000000000000912",
               %{"name" => "Target Fork"}
             )

    assert {:error, :not_found} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000912")

    assert {:error,
            {:session_actor_target_mismatch, ^wrong_owner_session_id, ^target_seed_session_id}} =
             InternalSessionActor.seed_session(
               wrong_pid,
               source_state,
               target_seed_session_id,
               %{"name" => "Target Seed"}
             )

    assert {:error, :not_found} =
             SalixAgent.TestSupport.SessionData.read(agent_id, target_seed_session_id)

    assert {:ok, forked} =
             Runtime.fork_session(agent_id, "ses1_0000000000000000910", %{
               "target_session_id" => "ses1_0000000000000000912",
               "fork_request_id" => "passivation-fork-2",
               "name" => "Target Fork"
             })

    forked_session_id = forked["session_id"]
    assert SalixStore.Ids.valid_session_id?(forked_session_id)

    assert {:ok, _forked_state} =
             SalixAgent.TestSupport.SessionData.read(agent_id, forked_session_id)
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

    refute_receive {:session_actor_notifier, ^target_id, {:session_updated, ^forked_session_id}},
                   50
  end

  test "agent fork does not publish a control record when workspace clone fails" do
    source_id = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(source_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)
    target_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(source_id)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               source_id,
               "bad-workspace-ref",
               %{},
               [
                 %{
                   "type" => "vfs_write",
                   "path" => "/memory/missing.txt",
                   "ref" => %{
                     "kind" => "blob",
                     "uuid" => "missing-blob",
                     "size" => 7,
                     "hash" => "missing-hash"
                   },
                   "size" => 7,
                   "hash" => "missing-hash"
                 }
               ]
             )

    assert {:error, :not_found} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Bad Workspace Fork Target",
                 "fork_from" => source_id
               },
               tenant_id,
               target_id
             )

    assert {:error, :not_found} = S3.get(Keys.ctl_agent(target_id))
    assert {:error, :not_found} = Agent.peek(target_id)

    assert {:ok, replacement_write} =
             SalixAgent.AgentWorkspace.prepare_write(
               source_id,
               "/memory/missing.txt",
               "replacement"
             )

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               source_id,
               "fix-bad-workspace-ref",
               %{},
               [replacement_write]
             )

    assert {:ok, retry} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Retried Workspace Fork Target",
                 "fork_from" => source_id
               },
               tenant_id,
               target_id
             )

    assert retry["agent_id"] == target_id

    assert {:ok, "replacement"} =
             SalixAgent.AgentWorkspace.read(target_id, "/memory/missing.txt")
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

    assert_receive {:session_actor_notifier, ^agent_id,
                    {:session_updated, "ses1_0000000000000000910"}}
  end

  test "session_log control rejects user and runtime roles", %{agent_id: agent_id} do
    for role <- ["user", "runtime"] do
      assert {:error, {:invalid_session_log_role, ^role}} =
               SalixAgent.AgentActor.stage_delivery(agent_id, %{
                 source_message_id: "bad-session-log-role-#{role}",
                 payload: %{
                   kind: "session_log",
                   session_id: "ses1_0000000000000000910",
                   role: role,
                   content: "must not bypass the pending input queue"
                 }
               })
    end

    assert {:error, :not_found} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910")
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

  test "internal in-owner helper rejects calls outside the target session actor", %{
    agent_id: agent_id
  } do
    entry = %{
      source_message_id: "internal-in-owner-direct",
      payload: %{
        session_id: "ses1_0000000000000000910",
        content: "direct helper call must not commit",
        role: "user",
        created_at: System.system_time(:second)
      }
    }

    assert {:error, :not_session_owner} =
             InternalSessionActor.stage_delivery_in_owner(
               agent_id,
               "ses1_0000000000000000910",
               entry
             )

    assert {:error, :not_found} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910")

    assert {:ok, :committed} =
             InternalSessionFleet.stage_delivery(agent_id, "ses1_0000000000000000910", entry)

    assert {:ok, session} =
             SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910")

    # The fleet path owns the commit. Depending on actor scheduling, the input
    # may still be queued or may already be materialized into the transcript.
    assert session_contains_content?(session, "direct helper call must not commit")
  end

  test "internal control starts the target session actor passively", %{agent_id: agent_id} do
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000910", [
        %{
          "type" => "queue_append",
          "session_id" => "ses1_0000000000000000910",
          "kind" => "user_message",
          "dedupe_key" => "passive-control-source",
          "payload" => %{
            "source_message_id" => "passive-control-source",
            "role" => "user",
            "content" => "this queued input must not run during metadata update"
          }
        }
      ])

    Mock.script([{:final, "should not run from passive control"}])

    assert {:ok, :committed} =
             InternalSessionFleet.stage_control(agent_id, "ses1_0000000000000000910", %{
               payload: %{
                 kind: "session_update",
                 session_id: "ses1_0000000000000000910",
                 name: "Renamed"
               }
             })

    Process.sleep(50)

    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000910")
    assert session.name == "Renamed"
    refute Enum.any?(session.messages, &(&1[:role] == "assistant"))
    assert session.status == :idle
    assert SalixAgent.TestSupport.SessionData.query(session, :derived_state) == :queued
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

    assert_receive {:session_actor_notifier, ^agent_id,
                    {:session_updated, "ses1_0000000000000000913"}}

    refute_receive {:session_actor_notifier, ^agent_id,
                    {:session_updated, "ses1_0000000000000000914"}},
                   50
  end

  test "expired internal wait without wait id uses stable non-unknown timeout identity", %{
    agent_id: agent_id
  } do
    wait = %{
      "reason" => "missing id wait",
      "deadline_ms" => System.system_time(:millisecond) - 1,
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

  test "inbound wait timeout without source id derives stable runtime queue identity", %{
    agent_id: agent_id
  } do
    wait = %{
      "wait_id" => "wait-without-source",
      "reason" => "timer without source id",
      "deadline_ms" => System.system_time(:millisecond) + 60_000,
      "timeout_seconds" => 1
    }

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, "ses1_0000000000000000916", [
        %{"type" => "session_created", "session_id" => "ses1_0000000000000000916"},
        %{"type" => "wait_set", "session_id" => "ses1_0000000000000000916", "wait" => wait}
      ])

    assert {:ok, :committed} =
             InternalSessionFleet.stage_wait_timeout(agent_id, "ses1_0000000000000000916", %{
               payload: %{
                 session_id: "ses1_0000000000000000916",
                 kind: "wait_timeout",
                 wait_id: "wait-without-source",
                 wait: wait
               }
             })

    source_id = "wait-timeout:ses1_0000000000000000916:wait-without-source"

    assert eventually(fn ->
             with {:ok, session} <-
                    SalixAgent.TestSupport.SessionData.read(agent_id, "ses1_0000000000000000916") do
               queued? =
                 Enum.any?(session.input_queue, fn item ->
                   item["kind"] == "runtime_message" and
                     item["dedupe_key"] == source_id and
                     item["payload"]["runtime_message_id"] == source_id and
                     item["payload"]["type"] == "wait_expired"
                 end)

               materialized? =
                 Enum.any?(session.messages, fn message ->
                   message.role == "runtime" and
                     message.runtime_message_id == source_id and
                     message.type == "wait_expired"
                 end)

               queued? or materialized?
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
          "started_at" => System.system_time(:millisecond)
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
          "started_at" => System.system_time(:millisecond)
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

    assert_receive {:session_actor_notifier, ^agent_id,
                    {:session_updated, "ses1_0000000000000000917"}}

    refute_receive {:session_actor_notifier, ^agent_id,
                    {:session_updated, "ses1_0000000000000000918"}},
                   50
  end

  test "agent cancel stops live internal and external session actors", %{agent_id: agent_id} do
    Application.put_env(:salix_agent, :session_actor_idle_ms, 1_000)

    {:ok, internal_pid} =
      InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910",
        process_on_init: false
      )

    {:ok, external_pid} =
      ExternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000919",
        process_on_init: false
      )

    assert Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
           ) != []

    assert Registry.lookup(
             SalixAgent.Registry,
             ExternalSessionActor.key(agent_id, "ses1_0000000000000000919")
           ) != []

    assert {:ok, _config} = SalixAgent.AgentActor.runtime_session_config(agent_id, %{})
    assert {:ok, record} = SalixAgent.Control.get_record(agent_id)
    assert {:ok, _role_actor} = SalixAgent.AgentActor.ensure_started(record)
    assert Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(agent_id)) != []

    assert Process.alive?(internal_pid)
    assert Process.alive?(external_pid)

    assert {:ok, agent} = Control.cancel(agent_id)
    assert agent["status"] == "cancelled"

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
             ) ==
               [] and
               Registry.lookup(
                 SalixAgent.Registry,
                 ExternalSessionActor.key(agent_id, "ses1_0000000000000000919")
               ) == [] and
               Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(agent_id)) == []
           end)

    refute Process.alive?(internal_pid)
    refute Process.alive?(external_pid)

    assert Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, "ses1_0000000000000000910")
           ) == []

    assert Registry.lookup(
             SalixAgent.Registry,
             ExternalSessionActor.key(agent_id, "ses1_0000000000000000919")
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
    Application.put_env(:salix_agent, :session_actor_idle_ms, 1_000)
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, pid} =
      InternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910",
        process_on_init: false
      )

    assert Process.alive?(pid)
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
             ExternalSessionFleet.wake(agent_id, "ses1_0000000000000000919")

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

    assert {:error, {:bad_request, "agent is archived"}} =
             ExternalSessionFleet.accept_session(agent_id, "ses1_0000000000000000919", %{})

    assert {:error, {:bad_request, "agent is archived"}} =
             ExternalSessionFleet.stage_delivery(agent_id, "ses1_0000000000000000919", %{
               source_message_id: "archived-agent:external-delivery",
               payload: %{
                 "session_id" => "ses1_0000000000000000919",
                 "role" => "user",
                 "content" => "do not stage"
               }
             })

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.begin_session(
               agent_id,
               "ses1_0000000000000000919",
               "tenant-test",
               %{"device_runtime_id" => @device_runtime_id}
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.begin_session(
               agent_id,
               "ses1_0000000000000000919",
               "tenant-test",
               %{"device_runtime_id" => @device_runtime_id}
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.stage_delivery(agent_id, %{
               source_message_id: "archived-agent:external-runtime-delivery",
               payload: %{
                 "session_id" => "ses1_0000000000000000919",
                 "role" => "user",
                 "content" => "do not stage"
               }
             })

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.update_session(
               agent_id,
               "ses1_0000000000000000919",
               %{
                 "status" => "running"
               }
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.accept_session(
               agent_id,
               "ses1_0000000000000000919",
               %{}
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.complete_session(
               agent_id,
               "ses1_0000000000000000919"
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.fail_session(
               agent_id,
               "ses1_0000000000000000919",
               :disconnected
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.append_event(agent_id, "ses1_0000000000000000919", %{
               "token_hash" => "token",
               "event" => %{"method" => "turn/completed"}
             })

    assert {:error, {:bad_request, "agent is archived"}} =
             SalixAgent.ExternalAgentRuntime.commit_session_events(
               agent_id,
               "ses1_0000000000000000919",
               [
                 %{"type" => "async_tool_call_started", "tool_call_id" => "late"}
               ]
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             ExternalSessionFleet.stage_wait_timeout(agent_id, "ses1_0000000000000000919", %{
               source_message_id: "archived-agent:external-wait",
               payload: %{"session_id" => "ses1_0000000000000000919", "wait_id" => "wait-1"}
             })

    assert {:error, {:bad_request, "agent is archived"}} =
             ExternalSessionFleet.fail_session(
               agent_id,
               "ses1_0000000000000000919",
               :disconnected
             )

    assert {:error, {:bad_request, "agent is archived"}} =
             ExternalSessionFleet.commit_connector_event(
               %{"agent_id" => agent_id, "session_id" => "ses1_0000000000000000919"},
               %{"method" => "turn/completed"}
             )

    # Archive closes admission first; explicit stop can finish existing work later.
    assert {:ok, %{next_cursor: nil}} = Control.stop(agent_id, agent["tenant_id"])

    # Each actor has its own Registry monitor; one actor disappearing does not
    # fence asynchronous Registry cleanup for the server or the other sessions.
    stopped_keys = [
      agent_id,
      SalixAgent.AgentActor.key(agent_id),
      InternalSessionActor.key(agent_id, "ses1_0000000000000000910"),
      ExternalSessionActor.key(agent_id, "ses1_0000000000000000919")
    ]

    assert eventually(fn ->
             Enum.all?(stopped_keys, &(Registry.lookup(SalixAgent.Registry, &1) == []))
           end)
  end

  test "external session actor passivates when idle and can be started again by wake", %{
    agent_id: agent_id
  } do
    {:ok, pid} = ExternalSessionFleet.ensure_started(agent_id, "ses1_0000000000000000910")
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               ExternalSessionActor.key(agent_id, "ses1_0000000000000000910")
             ) ==
               []
           end)

    assert :ok = ExternalSessionFleet.wake(agent_id, "ses1_0000000000000000910")

    assert [{new_pid, _}] =
             Registry.lookup(
               SalixAgent.Registry,
               ExternalSessionActor.key(agent_id, "ses1_0000000000000000910")
             )

    refute new_pid == pid
    assert Process.alive?(new_pid)
  end

  defp eventually(fun, retries \\ 100) do
    case fun.() do
      true ->
        true

      _ when retries <= 0 ->
        false

      _ ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end

  defp session_contains_content?(session, content) do
    queued? =
      Enum.any?(
        session.input_queue,
        &(&1["payload"]["content"] == content)
      )

    materialized? =
      Enum.any?(
        session.messages,
        &((&1[:content] || &1["content"]) == content)
      )

    queued? or materialized?
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)

  defp with_memory_pressure(fun) do
    controller = Process.whereis(SalixAgent.SessionResidency)
    :sys.suspend(controller)
    previous = :ets.lookup(SalixAgent.SessionResidency, :pressure)

    try do
      :ets.insert(SalixAgent.SessionResidency, {:pressure, :high})
      fun.()
    after
      :ets.delete(SalixAgent.SessionResidency, :pressure)
      :ets.insert(SalixAgent.SessionResidency, previous)
      :sys.resume(controller)
    end
  end
end
