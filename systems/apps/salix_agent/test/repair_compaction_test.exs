defmodule SalixAgent.RepairCompactionTest.PendingCapStore do
  @moduledoc false
  # Capability-request store stub: reports the OAuth call's request as still
  # pending so repair leaves it running instead of failing it.
  @behaviour SalixAgent.CapabilityRequestStore

  @impl true
  def create_capability_request(_attrs), do: {:error, :not_implemented}

  @impl true
  def cancel_capability_request(_agent_id, _session_id, _tool_call_id, _reason),
    do: {:ok, :not_found}

  @impl true
  def pending_capability_request?(_agent_id, "ses1_0000000000000000601", id)
      when id in ["oauth-call", "tool-a"], do: true

  def pending_capability_request?(_agent_id, _session_id, _tool_call_id), do: false
  @impl true
  def reconcile_capability_request(agent_id, session_id, id, _result) do
    if pending_capability_request?(agent_id, session_id, id) do
      {:ok,
       %{
         "request_id" => "pending-" <> id,
         "status" => "pending",
         "expires_at" => SystemsClock.system_time(:second) + 600
       }}
    else
      {:ok, :not_found}
    end
  end
end

defmodule SalixAgent.RepairCompactionTest.RaisingCapStore do
  @moduledoc false
  @behaviour SalixAgent.CapabilityRequestStore

  @impl true
  def create_capability_request(_attrs), do: {:error, :not_implemented}

  @impl true
  def cancel_capability_request(_agent_id, _session_id, _tool_call_id, _reason),
    do: {:ok, :not_found}

  @impl true
  def pending_capability_request?(_agent_id, _session_id, _tool_call_id),
    do: raise("capability store unavailable")

  @impl true
  def reconcile_capability_request(_agent_id, _session_id, _id, _result),
    do: {:error, :store_unavailable}
end

defmodule SalixAgent.RepairCompactionTest.CrashOnceLLM do
  @moduledoc false
  @behaviour SalixAgent.LLM

  use Agent

  def start_link(_opts \\ []) do
    case Agent.start_link(fn -> {:crash, 1} end, name: __MODULE__) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def reset(crash_count \\ 1) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> {:crash, crash_count} end)
  end

  @impl true
  def complete(_messages, _tools), do: next_response()

  @impl true
  def complete_stream(messages, tools, on_delta) do
    case complete(messages, tools) do
      {:final, text} = response ->
        on_delta.(text)
        response

      response ->
        response
    end
  end

  defp next_response do
    ensure_started()

    case Agent.get_and_update(__MODULE__, fn
           {:crash, remaining} when remaining > 0 -> {:crash, {:crash, remaining - 1}}
           _ -> {{:final, "continued after llm task crash"}, {:crash, 0}}
         end) do
      :crash -> raise "simulated provider task crash"
      response -> response
    end
  end

  defp ensure_started do
    case SystemsRuntime.Proc.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end
end

defmodule SalixAgent.RepairCompactionTest do
  @moduledoc """
  Crash-recovery repair and compaction on the storage kernel, against the Fake
  backend.
  """
  require SalixAgent.InternalSession
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{
    AgentWorkspace,
    AsyncToolResults,
    Compaction,
    InternalSession,
    InternalSessionFleet,
    InternalSessionStore,
    Repair,
    WorkspaceEvents
  }

  alias SalixAgent.LLM.Mock

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      SystemsRuntime.put_env(:salix_agent, :llm, prev_llm)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant_id,
      group_id: group_id,
      role: "worker",
      name: "Repair Compaction",
      system_prompt: "",
      router_system_prompt: ""
    })

    {:ok, agent: agent}
  end

  describe "repair" do
    test "a durable source reply is never rebound or executed after a restart", %{agent: a} do
      session_id = "ses1_0000000000000000601"

      {:ok, session} =
        InternalSessionStore.prepare_commit(
          a,
          session_id,
          [
            %{"type" => "session_created", "session_id" => session_id},
            %{
              "type" => "assistant",
              "session_id" => session_id,
              "message_id" => 1,
              "content" => "",
              "tool_calls" => [
                %{"id" => "bound-reply", "name" => "reply", "args" => %{"text" => "answer"}}
              ]
            }
          ],
          hwm: 1
        )

      {events, _} = Repair.plan_session(session)
      assert [result] = Enum.filter(events, &(&1["type"] == "tool_result"))
      assert result["tool_call_id"] == "bound-reply"
      assert result["error_class"] == "runtime_restarted"
      assert result["error"] == true
      refute Enum.any?(events, &(&1["type"] in ["assistant", "async_tool_call_started"]))

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, session_id, events, hwm: 2)
      assert {[], _} = Repair.plan_session(repaired)
    end

    test "synthesizes results for tool calls left unanswered by a crash", %{agent: a} do
      # Simulate a crash: an assistant turn with tool calls is committed, but the
      # tool_results were never persisted (separate-commit scenario).
      {:ok, session} =
        InternalSessionStore.prepare_commit(
          a,
          "ses1_0000000000000000601",
          [
            %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
            %{
              "type" => "assistant",
              "session_id" => "ses1_0000000000000000601",
              "message_id" => 1,
              "content" => "calling",
              "tool_calls" => [
                %{
                  "id" => "t1",
                  "name" => "call",
                  "args" => %{
                    "tool" => "help",
                    "params" => %{"tool" => "fs.read_file"}
                  }
                },
                %{
                  "id" => "t2",
                  "name" => "call",
                  "args" => %{
                    "tool" => "help",
                    "params" => %{"tool" => "fs.read_file"}
                  }
                }
              ]
            }
          ],
          hwm: 1
        )

      # Repair plans the two missing results for the target internal session
      # and records a runtime recovery fact. The recovery fact is not a user
      # message; it tells the next activation what happened after restart.
      {events, _next} = Repair.plan_session(session)
      tool_events = Enum.filter(events, &(&1["type"] == "tool_result"))
      recovery_events = Enum.filter(events, &(&1["type"] == "queue_append"))

      assert length(tool_events) == 2
      assert Enum.map(tool_events, & &1["tool_call_id"]) == ["t1", "t2"]
      assert Enum.all?(tool_events, & &1["error"])

      assert [
               %{
                 "kind" => "runtime_message",
                 "payload" => %{
                   "type" => "runtime_recovered",
                   "source_refs" => %{
                     "failed_tool_calls" => failed_tool_calls
                   }
                 }
               }
             ] = recovery_events

      assert Enum.map(failed_tool_calls, & &1["tool_call_id"]) == ["t1", "t2"]

      assert Enum.all?(
               failed_tool_calls,
               &(&1["reason"] == "runtime_restarted")
             )

      # Applying them yields a complete result set; re-planning finds nothing.
      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events, hwm: 3)

      assert SalixAgent.InternalSession.derived_state(handle(repaired)) == :queued
      assert {[], _} = Repair.plan_session(repaired)
    end

    test "treats legacy tool_use_id tool results as answered" do
      session = %InternalSession.State{
        agent_id: "agent-legacy",
        session_id: "ses1_0000000000000000601",
        messages: [
          %{
            id: 1,
            role: "assistant",
            content: "calling",
            tool_calls: [
              %{
                "id" => "t1",
                "name" => "call",
                "args" => %{
                  "tool" => "help",
                  "params" => %{"tool" => "fs.read_file"}
                }
              }
            ]
          },
          %{id: 2, role: "tool", tool_use_id: "t1", content: "legacy result"}
        ],
        next_message_id: 3
      }

      assert {[], _next_id} = Repair.plan_session(InternalSession.open(session))
    end

    test "InternalSessionActor repairs its target session on wake", %{agent: a} do
      {:ok, _session} =
        InternalSessionStore.prepare_commit(
          a,
          "ses1_0000000000000000601",
          [
            %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
            %{
              "type" => "status",
              "session_id" => "ses1_0000000000000000601",
              "status" => "active"
            },
            %{
              "type" => "assistant",
              "session_id" => "ses1_0000000000000000601",
              "message_id" => 1,
              "content" => "x",
              "tool_calls" => [
                %{
                  "id" => "orphan",
                  "name" => "call",
                  "args" => %{
                    "tool" => "help",
                    "params" => %{"tool" => "fs.read_file"}
                  }
                }
              ]
            }
          ],
          hwm: 1
        )

      Mock.script([
        {:assistant, "running a corrected tool call after repair",
         [
           %{
             id: "repair-tool-call",
             name: "call",
             args: %{
               "tool" => "help",
               "params" => %{"tool" => "fs.read_file"}
             }
           }
         ]},
        {:final, "continued after repair"}
      ])

      :ok = InternalSessionFleet.wake(a, "ses1_0000000000000000601")

      assert eventually(fn ->
               {:ok, session} = read_state(a, "ses1_0000000000000000601")

               tool_msgs =
                 Enum.filter(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1[:role] == "tool")
                 )

               assistant_msgs =
                 Enum.filter(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1[:role] == "assistant")
                 )

               Enum.any?(tool_msgs, &(&1[:tool_call_id] == "orphan")) and
                 Enum.any?(assistant_msgs, &(&1[:content] == "continued after repair"))
             end)

      {:ok, session} = read_state(a, "ses1_0000000000000000601")
      assert SalixAgent.InternalSession.get(session, :status) == :idle
      refute SalixAgent.InternalSession.visible_reply_repair_required?(handle(session))

      assert %{content: content, diagnostic_visibility: "model_only"} =
               Enum.find(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1[:tool_call_id] == "orphan")
               )

      assert content =~ "did not complete"

      # The zero-wait tool window may commit either the fast completion or its
      # async placeholder. Repair owns the diagnostic tag, not that scheduling.
      assert %{diagnostic_visibility: "none"} =
               repair_call =
               Enum.find(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1[:tool_call_id] == "repair-tool-call")
               )

      refute Map.has_key?(repair_call, :repair_outcome)

      assert Enum.any?(
               SalixAgent.InternalSession.get(session, :events),
               &(&1["kind"] == "visible_reply_repair" and &1["status"] == "completed")
             )
    end

    test "marks running async tool calls failed and emits runtime_recovered", %{agent: a} do
      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "tool-a",
            "tool_name" => "env.exec",
            "input" => "{}",
            "status" => "running",
            "started_at" => 1,
            "auto_wait_seconds" => 20
          }
        ])

      {events, next_id} = Repair.plan_session(session)

      assert next_id == 1

      assert Enum.any?(events, &(&1["type"] == "async_tool_call_failed"))
      delivery = Enum.find(events, &(&1["type"] == "queue_append"))

      assert delivery["dedupe_key"] ==
               "runtime-recovered:async:ses1_0000000000000000601:failed:tool-a:pending:"

      assert delivery["payload"]["type"] == "runtime_recovered"
      assert delivery["payload"]["diagnostic_visibility"] == "model_only"

      assert Enum.any?(
               events,
               &(&1["type"] == "visible_reply_repair" and &1["status"] == "required")
             )

      assert [
               %{
                 "tool_call_id" => "tool-a",
                 "tool_name" => "env.exec",
                 "reason" => "runtime_restarted"
               }
             ] =
               delivery["payload"]["source_refs"]["failed_tool_calls"]

      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events,
          hwm: next_id - 1
        )

      assert {:ok, %{"status" => "failed", "error_class" => "runtime_restarted"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(repaired), "tool-a")

      assert SalixAgent.InternalSession.visible_reply_repair_required?(handle(repaired))
    end

    test "restart replays a staged direct poll-owned terminal without model work", %{agent: a} do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "direct-staged-failure"

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 %{
                   id: tool_call_id,
                   name: "env.exec",
                   status: "error",
                   content: "private remote failure",
                   error: true,
                   error_class: "tool_error",
                   error_message: "private remote failure",
                   diagnostic_visibility: "model_only",
                   events: []
                 },
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      # Staging the result started the agent's Server. Its first cycle wakes
      # every indexed session with work; let it finish before the session
      # exists, or that session actor replays the staged terminal under this
      # test, which injects the read faults only for its own process.
      settle()

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "env.exec",
            "status" => "running",
            "completion_owner" => "direct_poll"
          },
          SalixAgent.Waits.event(
            session_id,
            SalixAgent.Waits.build("direct tool is running", 20, "auto_wait", %{
              "tool_call_id" => tool_call_id
            })
          )
        ])

      SalixStore.S3.Fake.set_fault_for(
        SystemsRuntime.Proc.self(),
        {:fail, 503, :get, SalixStore.Keys.agent_workspace_state(a)}
      )

      assert {:error, {:staged_async_result_read_failed, ^tool_call_id, {:http, 503}}} =
               Repair.plan_session(session)

      assert {:ok, unchanged} = read_state(a, session_id)

      assert {:ok, %{"status" => "running"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(unchanged), tool_call_id)

      SalixStore.S3.Fake.set_fault_for(
        SystemsRuntime.Proc.self(),
        {:fail, 503, :get, SalixStore.Keys.agent_workspace_state(a)}
      )

      assert {:ok, %{"sessions" => [%{"session_id" => ^session_id, "error" => error}]}} =
               SalixAgent.AgentControl.force_recover(a,
                 session_id: session_id,
                 wake: false,
                 timeout: 1_000
               )

      assert error ==
               inspect({:staged_async_result_read_failed, tool_call_id, {:http, 503}})

      assert {:ok, after_failed_recovery} = read_state(a, session_id)

      assert SalixAgent.InternalSession.export(after_failed_recovery) ==
               SalixAgent.InternalSession.export(unchanged)

      {events, 1} = Repair.plan_session(handle(after_failed_recovery))

      assert Enum.map(events, & &1["type"]) == ["async_tool_call_failed", "wait_clear"]
      assert get_in(List.first(events), ["result", "content"]) == "private remote failure"
      refute Enum.any?(events, &(&1["type"] in ["queue_append", "visible_reply_repair"]))

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, session_id, events)

      assert {:ok,
              %{
                "status" => "failed",
                "error_class" => "tool_error",
                "tool_call_id" => ^tool_call_id
              }} = SalixAgent.InternalSession.lookup_async_call(handle(repaired), tool_call_id)

      assert SalixAgent.InternalSession.get(repaired, :wait) == nil
      assert SalixAgent.InternalSession.get(repaired, :input_queue) == []
      assert SalixAgent.InternalSession.get(repaired, :visible_reply_repair) == nil
      assert SalixAgent.InternalSession.work_reasons(handle(repaired)) == []
    end

    test "force_recover without a running Server neither wakes nor repairs the session",
         %{agent: a} do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "direct-staged-failure"

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 %{
                   id: tool_call_id,
                   name: "env.exec",
                   status: "error",
                   content: "private remote failure",
                   error: true,
                   error_class: "tool_error",
                   error_message: "private remote failure",
                   diagnostic_visibility: "model_only",
                   events: []
                 },
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      # The node restarts: no Server and no session actor run for the agent.
      settle()
      SalixAgent.TestSupport.stop_all_agents()

      {:ok, _} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "env.exec",
            "status" => "running",
            "completion_owner" => "direct_poll"
          },
          SalixAgent.Waits.event(
            session_id,
            SalixAgent.Waits.build("direct tool is running", 20, "auto_wait", %{
              "tool_call_id" => tool_call_id
            })
          )
        ])

      assert {:ok, unchanged} = read_state(a, session_id)

      SalixStore.S3.Fake.set_fault_for(
        SystemsRuntime.Proc.self(),
        {:fail, 503, :get, SalixStore.Keys.agent_workspace_state(a)}
      )

      assert {:ok, %{"sessions" => [%{"session_id" => ^session_id, "error" => _}]}} =
               SalixAgent.AgentControl.force_recover(a,
                 session_id: session_id,
                 wake: false,
                 timeout: 1_000
               )

      settle()

      assert [] =
               SystemsRuntime.Registry.lookup(
                 SalixAgent.Registry,
                 SalixAgent.InternalSessionActor.key(a, session_id)
               )

      assert {:ok, after_recovery} = read_state(a, session_id)

      assert SalixAgent.InternalSession.export(after_recovery) ==
               SalixAgent.InternalSession.export(unchanged)
    end

    test "force_recover stops a running Server before the session actors it can wake",
         %{agent: a} do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "direct-staged-failure"

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 %{
                   id: tool_call_id,
                   name: "env.exec",
                   status: "error",
                   content: "private remote failure",
                   error: true,
                   error_class: "tool_error",
                   error_message: "private remote failure",
                   diagnostic_visibility: "model_only",
                   events: []
                 },
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      # The Server that staging started finishes its first cycle and parks.
      settle()

      {:ok, _} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "env.exec",
            "status" => "running",
            "completion_owner" => "direct_poll"
          },
          SalixAgent.Waits.event(
            session_id,
            SalixAgent.Waits.build("direct tool is running", 20, "auto_wait", %{
              "tool_call_id" => tool_call_id
            })
          )
        ])

      # Hold the woken Server in its cycle, before it wakes the indexed
      # session: at its owner check, which reads the agent root.
      SalixStore.S3.Fake.set_fault({:pause, :get, SalixStore.Keys.agent_state(a)})
      assert {:ok, _} = SalixAgent.AgentControl.wake(a)
      :ok = SalixStore.S3.Fake.await_pause()

      recovery =
        SystemsRuntime.Task.async(fn ->
          SalixAgent.AgentControl.force_recover(a, session_id: session_id, wake: false)
        end)

      # force_recover now waits for the held Server to stop.
      settle()
      assert SystemsRuntime.Task.yield(recovery, 0) == nil

      # The Server completes its cycle, which wakes the session, and stops.
      SalixStore.S3.Fake.release_pause()
      assert {:ok, %{"sessions" => [%{"session_id" => ^session_id}]}} = settled_await(recovery)

      assert [] =
               SystemsRuntime.Registry.lookup(
                 SalixAgent.Registry,
                 SalixAgent.InternalSessionActor.key(a, session_id)
               )
    end

    test "does not fail process-local async tool calls still tracked by the live session actor",
         %{agent: a} do
      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "tool-a",
            "tool_name" => "env.copy",
            "input" => "{}",
            "status" => "running",
            "completion_mode" => "local_background",
            "started_at" => 1,
            "auto_wait_seconds" => 20
          }
        ])

      assert {[], 1} = Repair.plan_session(session, live_process_tool_call_ids: ["tool-a"])

      {events, _next_id} = Repair.plan_session(session)
      assert Enum.any?(events, &(&1["type"] == "async_tool_call_failed"))
    end

    test "restart rejects staged side effects that retire accepted work", %{agent: a} do
      session_id = "ses1_0000000000000000601"
      call_id = "unsafe-staged-result"

      operation_id =
        WorkspaceEvents.operation_id(
          AsyncToolResults.operation_source(:internal),
          a,
          session_id,
          call_id
        )

      stored_result = %{
        "tool_call_id" => call_id,
        "tool_name" => "env.copy",
        "status" => "completed",
        "content" => "copied",
        "error" => false,
        "session_events" => [%{"type" => "queue_consume", "queue_id" => 1}]
      }

      assert {:ok, _} = AgentWorkspace.seed_operation(a, operation_id, stored_result, [])

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => call_id,
            "tool_name" => "env.copy",
            "status" => "running"
          },
          %{
            "type" => "queue_append",
            "kind" => "user_message",
            "dedupe_key" => "accepted-before-restart",
            "wake" => false,
            "payload" => %{"content" => "preserve across restart"}
          }
        ])

      assert {:error,
              {:staged_async_result_read_failed, ^call_id,
               {:invalid_tool_side_effect_event, "queue_consume"}}} = Repair.plan_session(session)

      {:ok, durable} = read_state(a, session_id)

      assert SalixAgent.InternalSession.get(durable, :input_queue) ==
               SalixAgent.InternalSession.get(session, :input_queue)

      assert {:ok, ^stored_result} = AgentWorkspace.operation_result(a, operation_id)
    end

    test "recovers an active in-flight LLM call after restart", %{agent: a} do
      {:ok, session} =
        InternalSessionStore.prepare_commit(
          a,
          "ses1_0000000000000000601",
          [
            %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
            %{
              "type" => "delivery",
              "from_queue" => true,
              "session_id" => "ses1_0000000000000000601",
              "message_id" => 1,
              "content" => "go"
            },
            %{
              "type" => "status",
              "session_id" => "ses1_0000000000000000601",
              "status" => "active"
            }
          ],
          hwm: 1
        )

      {events, next_id} = Repair.plan_session(session)

      assert next_id == 2

      assert [
               %{"type" => "status", "status" => "idle"},
               %{"type" => "queue_append", "kind" => "runtime_message"} = delivery
             ] = events

      assert delivery["dedupe_key"] ==
               "runtime-recovered:llm:ses1_0000000000000000601:message-1"

      assert delivery["payload"]["type"] == "runtime_recovered"
      assert delivery["payload"]["diagnostic_visibility"] == "user_reportable"

      assert delivery["payload"]["public_summary"] ==
               "The previous response was interrupted. Please try again."

      assert delivery["payload"]["source_refs"]["failed_llm_call"]["reason"] ==
               "runtime_restarted"

      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events,
          hwm: next_id - 1
        )

      assert SalixAgent.InternalSession.get(repaired, :status) == :idle
      assert SalixAgent.InternalSession.derived_state(handle(repaired)) == :queued
    end

    test "exhausted visible-reply repair parks runtime wakes until new user input", %{agent: a} do
      session_id = "ses1_0000000000000000601"

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "visible_reply_repair",
            "session_id" => session_id,
            "status" => "exhausted",
            "attempts" => 2,
            "public_summary" => "I couldn't complete that reply safely. Please try again."
          },
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "runtime_message",
            "dedupe_key" => "late-runtime",
            "wake" => true,
            "payload" => %{
              "runtime_message_id" => "late-runtime",
              "type" => "tool_call_failed",
              "content" => "private late runtime detail",
              "diagnostic_visibility" => "model_only"
            }
          }
        ])

      Mock.script([{:final, "resumed only after user input"}])
      :ok = InternalSessionFleet.wake(a, session_id)

      assert eventually(fn ->
               session = read_session!(a, session_id)

               SalixAgent.InternalSession.get(session, :queue_ack_id) > 0 and
                 SalixAgent.InternalSession.get(session, :status) == :idle
             end)

      parked = read_session!(a, session_id)
      assert SalixAgent.InternalSession.visible_reply_repair_exhausted?(handle(parked))

      refute Enum.any?(
               SalixAgent.InternalSession.get(parked, :messages),
               &(&1.role == "assistant")
             )

      {:ok, _session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{
            "type" => "queue_append",
            "session_id" => session_id,
            "kind" => "user_message",
            "dedupe_key" => "retry-after-safe-failure",
            "wake" => true,
            "payload" => %{
              "source_message_id" => "retry-after-safe-failure",
              "content" => "try again"
            }
          }
        ])

      :ok = InternalSessionFleet.wake(a, session_id)

      assert eventually(fn ->
               session = read_session!(a, session_id)

               not SalixAgent.InternalSession.visible_reply_repair_exhausted?(handle(session)) and
                 Enum.any?(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1.role == "assistant" and &1.content == "resumed only after user input")
                 )
             end)
    end

    test "leaves running async calls backed by a pending capability request running", %{agent: a} do
      use_capability_store(SalixAgent.RepairCompactionTest.PendingCapStore)

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          # User-interaction call awaiting an external OAuth callback: pending
          # capability request ⇒ not a restart casualty.
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "oauth-call",
            "tool_name" => "oauth.request_authorization",
            "input" => "{}",
            "status" => "running",
            "completion_mode" => "external_callback",
            "started_at" => 1,
            "auto_wait_seconds" => 120
          },
          # Background Exec with no capability request ⇒ genuine restart casualty.
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "exec-call",
            "tool_name" => "env.exec",
            "input" => "{}",
            "status" => "running",
            "started_at" => 1,
            "auto_wait_seconds" => 20
          }
        ])

      {events, next_id} = Repair.plan_session(session)
      _contract_events = assert_capability_sync(events)

      # Only the Exec call is failed; the OAuth call is left running.
      failed = Enum.filter(events, &(&1["type"] == "async_tool_call_failed"))
      assert [%{"tool_call_id" => "exec-call"}] = failed

      [delivery] = Enum.filter(events, &(&1["type"] == "queue_append"))

      assert delivery["kind"] == "runtime_message"
      assert delivery["payload"]["type"] == "runtime_recovered"

      assert [%{"tool_call_id" => "exec-call"}] =
               delivery["payload"]["source_refs"]["failed_tool_calls"]

      assert [%{"tool_call_id" => "oauth-call"}] =
               delivery["payload"]["source_refs"]["pending_external_callback_tool_calls"]

      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events,
          hwm: next_id - 1
        )

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["oauth-call"]["status"] ==
               "running"

      assert {:ok, %{"status" => "failed"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(repaired), "exec-call")
    end
  end

  describe "durable capability reconciliation" do
    test "a terminal session callback settles the pending request and clears its residual", %{
      agent: a
    } do
      use_capability_store(SalixAgent.CapabilityRequests)
      sid = "ses1_0000000000000000601"
      create_location_request!(a, sid, "terminal-first")
      _session = callback_session!(a, sid, "terminal-first")

      terminal_event = %{
        "type" => "async_tool_call_completed",
        "session_id" => sid,
        "tool_call_id" => "terminal-first",
        "result" => %{"content" => "winner"},
        "completed_at" => SystemsClock.system_time(:millisecond)
      }

      {:ok, session} = InternalSessionStore.prepare_commit(a, sid, [terminal_event])
      assert Map.has_key?(InternalSession.get(session, :async_tool_calls), "terminal-first")
      {events, _} = Repair.plan_session(session)
      {:ok, repaired} = InternalSessionStore.prepare_commit(a, sid, events)
      refute Map.has_key?(InternalSession.get(repaired, :async_tool_calls), "terminal-first")

      assert {:ok, %{"status" => "completed", "result" => %{"content" => "winner"}}} =
               SalixAgent.CapabilityRequests.reconcile_capability_request(
                 a,
                 sid,
                 "terminal-first"
               )

      late = %{terminal_event | "result" => %{"content" => "late duplicate"}}
      after_late = InternalSession.apply_events(handle(repaired), [late])

      assert {:ok, %{"result" => %{"content" => "winner"}}} =
               InternalSession.lookup_async_call(after_late, "terminal-first")

      assert {:ok, %{"result" => %{"content" => "winner"}}} =
               SalixAgent.CapabilityRequests.reconcile_capability_request(
                 a,
                 sid,
                 "terminal-first",
                 %{"status" => "completed", "content" => "late duplicate"}
               )
    end
  end

  defp create_location_request!(agent_id, sid, id) do
    {:ok, request} =
      SalixAgent.CapabilityRequests.create_capability_request(%{
        "source_agent_id" => agent_id,
        "source_session_id" => sid,
        "tool_call_id" => id,
        "request_type" => "location",
        "request_payload" => %{"location" => %{"reason" => "weather"}},
        "expires_at" => SystemsClock.system_time(:second) + 600
      })

    request
  end

  defp callback_session!(agent_id, sid, id) do
    {:ok, session} =
      InternalSessionStore.prepare_commit(agent_id, sid, [
        %{"type" => "session_created", "session_id" => sid},
        %{
          "type" => "async_tool_call_started",
          "session_id" => sid,
          "tool_call_id" => id,
          "tool_name" => "location.request",
          "input" => "{}",
          "status" => "running",
          "completion_mode" => "external_callback",
          "started_at" => 1
        }
      ])

    session
  end

  describe "compaction" do
    test "summarizes over budget without deleting, and bounds the context", %{agent: a} do
      # Seed several user/assistant messages.
      {:ok, _session} =
        InternalSessionStore.prepare_commit(
          a,
          "ses1_0000000000000000601",
          [%{"type" => "session_created", "session_id" => "ses1_0000000000000000601"}] ++
            for i <- 1..6 do
              %{
                "type" => "assistant",
                "session_id" => "ses1_0000000000000000601",
                "message_id" => i,
                "content" => String.duplicate("x", 100)
              }
            end ++
            [
              %{
                "type" => "ack",
                "session_id" => "ses1_0000000000000000601",
                "last_ack_message_id" => 6
              }
            ]
        )

      # Force compaction with a tiny threshold.
      {:ok, _o, %{"status" => "compacted"}} =
        Compaction.compact(
          %{agent_id: a, session_id: "ses1_0000000000000000601"},
          "ses1_0000000000000000601",
          threshold: 1
        )

      session = read_session!(a, "ses1_0000000000000000601")

      # The transcript remains readable after the compacted prefix is archived.
      assert SalixAgent.InternalSession.get(session, :messages) == []

      assert {:ok, %{messages: messages}} =
               InternalSessionStore.transcript(a, handle(session), {:tail, 6})

      assert Enum.map(messages, &(&1[:id] || &1["id"])) == [1, 2, 3, 4, 5, 6]
      assert SalixAgent.InternalSession.get(session, :compacted_through) == 6
      assert SalixAgent.InternalSession.get(session, :summary) =~ "summary of"
      assert SalixAgent.InternalSession.get(session, :summary_sequence) == 1

      # Context after compaction = summary only (all messages are <= watermark).
      ctx = Compaction.context(handle(session))
      assert [%{role: "summary"}] = ctx

      # Durable storage reproduces the compaction state.
      assert SalixAgent.InternalSession.get(
               read_session!(a, "ses1_0000000000000000601"),
               :compacted_through
             ) == 6

      assert SalixAgent.InternalSession.get(
               read_session!(a, "ses1_0000000000000000601"),
               :summary
             ) =~ "summary of"
    end
  end

  defp assert_capability_sync(events) do
    syncs = Enum.filter(events, &(&1["type"] == "capability_request_sync"))
    assert syncs != []

    for sync <- syncs do
      assert is_integer(sync["capability_deadline_ms"]) or
               is_integer(sync["capability_retry_at_ms"]) or sync["settled"] == true
    end

    Enum.reject(events, &(&1["type"] == "capability_request_sync"))
  end

  defp use_capability_store(store) do
    previous = SystemsRuntime.fetch_env(:salix_agent, :capability_request_store_mod)
    SystemsRuntime.put_env(:salix_agent, :capability_request_store_mod, store)

    on_exit(fn ->
      case previous do
        {:ok, value} -> SystemsRuntime.put_env(:salix_agent, :capability_request_store_mod, value)
        :error -> SystemsRuntime.delete_env(:salix_agent, :capability_request_store_mod)
      end
    end)
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = read_state(agent_id, session_id)
    session
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp handle(session) when SalixAgent.InternalSession.is_session(session), do: session
  defp handle(state), do: SalixAgent.InternalSession.open(state)

  defp read_state(agent_id, session_id) do
    SalixAgent.InternalSessionStore.read(agent_id, session_id)
  end
end
