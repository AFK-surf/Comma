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
         "expires_at" => System.system_time(:second) + 600
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
    case Process.whereis(__MODULE__) do
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
  use ExUnit.Case, async: false

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
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
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
    test "actor repair preserves a staged terminal across a workspace read failure", %{agent: a} do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "actor-staged-read-failure"

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 %{
                   id: tool_call_id,
                   name: "env.exec",
                   status: "error",
                   content: "exact staged failure",
                   error: true,
                   error_class: "tool_error",
                   error_message: "exact staged failure",
                   diagnostic_visibility: "model_only",
                   events: []
                 },
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      assert {:ok, _} =
               InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => session_id,
                   "tool_call_id" => tool_call_id,
                   "tool_name" => "env.exec",
                   "status" => "running",
                   "completion_owner" => "direct_poll"
                 }
               ])

      assert {:ok, _} = InternalSessionFleet.ensure_started(a, session_id, process_on_init: false)

      [{pid, _}] =
        Registry.lookup(SalixAgent.Registry, SalixAgent.InternalSessionActor.key(a, session_id))

      assert {:ok, before} = read_state(a, session_id)

      SalixStore.S3.Fake.set_fault_for(
        pid,
        {:fail, 503, :get, SalixStore.Keys.agent_workspace_state(a)}
      )

      assert :ok = SalixAgent.InternalSessionActor.wake(a, session_id)
      # The first synchronous probe follows the wake cast. The second follows
      # the :process message that the wake handler enqueues to itself. Direct
      # GenServer.call makes a timeout fail instead of busy?/2 swallowing it.
      GenServer.call(pid, :busy?, 5_000)
      GenServer.call(pid, :busy?, 5_000)

      assert Process.alive?(pid)
      assert {:ok, unchanged} = read_state(a, session_id)

      assert SalixAgent.InternalSession.export(unchanged) ==
               SalixAgent.InternalSession.export(before)

      assert {:ok, %{"status" => "running"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(unchanged), tool_call_id)

      # The fault is one-shot. Recovery is explicitly woken, not an assertion
      # that generic repair errors automatically allocate a retry timer.
      assert :ok = SalixAgent.InternalSessionActor.wake(a, session_id)
      GenServer.call(pid, :busy?, 5_000)
      GenServer.call(pid, :busy?, 5_000)

      assert {:ok, recovered} = read_state(a, session_id)

      assert {:ok, terminal} =
               SalixAgent.InternalSession.lookup_async_call(handle(recovered), tool_call_id)

      assert terminal["status"] == "failed"
      assert terminal["result"]["content"] == "exact staged failure"
      refute terminal["error_class"] == "runtime_restarted"
      assert SalixAgent.InternalSession.get(recovered, :input_queue) == []
      assert SalixAgent.InternalSession.get(recovered, :visible_reply_repair) == nil
    end

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

    test "reconstructs deterministic envelope guidance instead of a false restart", %{agent: a} do
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
              "content" => "calling",
              "tool_calls" => [
                %{
                  "id" => "malformed-call",
                  "name" => "call",
                  "args" => %{"params" => %{"command" => "echo alive"}}
                }
              ]
            }
          ],
          hwm: 1
        )

      {events, _next} = Repair.plan_session(session)

      assert %{
               "tool_call_id" => "malformed-call",
               "tool_name" => "call",
               "status" => "guidance",
               "error" => false,
               "error_class" => nil,
               "guidance_reason" => "envelope_misuse",
               "diagnostic_visibility" => "model_only"
             } = Enum.find(events, &(&1["type"] == "tool_result"))

      result = Enum.find(events, &(&1["type"] == "tool_result"))
      assert Jason.decode!(result["content"])["error"] == "'tool' is required"

      refute Enum.any?(events, fn event ->
               event["type"] == "queue_append" and
                 get_in(event, ["payload", "failed_tool_calls"]) != nil
             end)
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

    test "restart terminalizes an unstaged direct poll-owned call without model work", %{
      agent: a
    } do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "direct-restart"

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "env.exec",
            "input" => "{}",
            "status" => "running",
            "completion_owner" => "direct_poll",
            "started_at" => 1,
            "auto_wait_seconds" => 20
          },
          SalixAgent.Waits.event(
            session_id,
            SalixAgent.Waits.build("direct tool is running", 20, "auto_wait", %{
              "tool_call_id" => tool_call_id
            })
          )
        ])

      assert SalixAgent.InternalSession.get(session, :async_tool_calls)[tool_call_id][
               "completion_owner"
             ] == "direct_poll"

      SalixStore.S3.Fake.set_fault_for(
        self(),
        {:fail, 503, :get, SalixStore.Keys.agent_workspace_state(a)}
      )

      assert {:error, {:staged_async_result_read_failed, ^tool_call_id, {:http, 503}}} =
               Repair.plan_session(session)

      assert {:ok, unchanged} = read_state(a, session_id)

      assert {:ok, %{"status" => "running"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(unchanged), tool_call_id)

      {events, 1} = Repair.plan_session(unchanged)

      assert Enum.map(events, & &1["type"]) == ["async_tool_call_failed", "wait_clear"]

      assert [
               %{
                 "tool_call_id" => ^tool_call_id,
                 "error_class" => "runtime_restarted",
                 "result" => %{
                   "error_class" => "runtime_restarted",
                   "diagnostic_visibility" => "model_only"
                 }
               },
               %{"type" => "wait_clear"}
             ] = events

      refute Enum.any?(events, &(&1["type"] in ["queue_append", "visible_reply_repair"]))

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, session_id, events)

      assert {:ok,
              %{
                "status" => "failed",
                "error_class" => "runtime_restarted",
                "tool_call_id" => ^tool_call_id
              }} = SalixAgent.InternalSession.lookup_async_call(handle(repaired), tool_call_id)

      assert SalixAgent.InternalSession.get(repaired, :wait) == nil
      assert SalixAgent.InternalSession.get(repaired, :input_queue) == []
      assert SalixAgent.InternalSession.get(repaired, :visible_reply_repair) == nil
      assert SalixAgent.InternalSession.work_reasons(handle(repaired)) == []
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
        self(),
        {:fail, 503, :get, SalixStore.Keys.agent_workspace_state(a)}
      )

      assert {:error, {:staged_async_result_read_failed, ^tool_call_id, {:http, 503}}} =
               Repair.plan_session(session)

      assert {:ok, unchanged} = read_state(a, session_id)

      assert {:ok, %{"status" => "running"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(unchanged), tool_call_id)

      SalixStore.S3.Fake.set_fault_for(
        self(),
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

    test "restart replays a staged direct poll-owned callback handoff without terminalizing it",
         %{agent: a} do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "direct-staged-handoff"

      callback_wait =
        SalixAgent.Waits.build("waiting for callback", 120, "auto_wait", %{
          "tool_call_id" => tool_call_id
        })

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 %{
                   id: tool_call_id,
                   name: "permission.request",
                   status: "async_running",
                   content: Jason.encode!(%{"status" => "running", "request_id" => "req-1"}),
                   error: false,
                   events: [
                     %{
                       "type" => "async_tool_call_started",
                       "session_id" => session_id,
                       "tool_call_id" => tool_call_id,
                       "tool_name" => "permission.request",
                       "status" => "running",
                       "completion_mode" => "external_callback",
                       "started_at" => 2
                     },
                     SalixAgent.Waits.event(session_id, callback_wait)
                   ]
                 },
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => tool_call_id,
            "tool_name" => "permission.request",
            "status" => "running",
            "completion_owner" => "direct_poll",
            "started_at" => 1
          },
          SalixAgent.Waits.event(
            session_id,
            SalixAgent.Waits.build("setup is running", 20, "auto_wait", %{
              "tool_call_id" => tool_call_id
            })
          )
        ])

      {events, 1} = Repair.plan_session(session)

      assert Enum.map(events, & &1["type"]) == ["async_tool_call_started", "wait_set"]

      assert %{
               "completion_mode" => "external_callback",
               "completion_owner" => "direct_poll",
               "tool_call_id" => ^tool_call_id
             } = List.first(events)

      refute Enum.any?(events, fn event ->
               event["type"] in [
                 "async_tool_call_completed",
                 "async_tool_call_failed",
                 "queue_append",
                 "visible_reply_repair",
                 "wait_clear"
               ]
             end)

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, session_id, events)

      assert {:ok,
              %{
                "status" => "running",
                "completion_mode" => "external_callback",
                "completion_owner" => "direct_poll",
                "tool_call_id" => ^tool_call_id
              }} = SalixAgent.InternalSession.lookup_async_call(handle(repaired), tool_call_id)

      assert SalixAgent.InternalSession.get(repaired, :wait)["tool_call_id"] == tool_call_id
      assert SalixAgent.InternalSession.get(repaired, :input_queue) == []
      assert SalixAgent.InternalSession.get(repaired, :visible_reply_repair) == nil

      assert "external_callback_tool_call" in SalixAgent.InternalSession.work_reasons(
               handle(repaired)
             )
    end

    test "a direct restart casualty does not hide simultaneous active LLM recovery", %{agent: a} do
      session_id = "ses1_0000000000000000601"
      tool_call_id = "direct-during-active-llm"

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{"type" => "status", "session_id" => session_id, "status" => "active"},
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

      {events, 1} = Repair.plan_session(session)

      assert Enum.map(events, & &1["type"]) == [
               "async_tool_call_failed",
               "wait_clear",
               "status",
               "queue_append"
             ]

      [llm_recovery] = Enum.filter(events, &(&1["type"] == "queue_append"))
      assert llm_recovery["payload"]["failed_llm_call"] == %{"reason" => "runtime_restarted"}
      refute llm_recovery["payload"]["source_tool_call_id"] == tool_call_id

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, session_id, events)
      assert SalixAgent.InternalSession.get(repaired, :status) == :idle
      assert SalixAgent.InternalSession.get(repaired, :wait) == nil

      assert {:ok, %{"status" => "failed", "tool_call_id" => ^tool_call_id}} =
               SalixAgent.InternalSession.lookup_async_call(handle(repaired), tool_call_id)

      assert Enum.any?(SalixAgent.InternalSession.get(repaired, :input_queue), fn item ->
               get_in(item, ["payload", "failed_llm_call", "reason"]) == "runtime_restarted"
             end)

      refute Enum.any?(SalixAgent.InternalSession.get(repaired, :input_queue), fn item ->
               get_in(item, ["payload", "source_tool_call_id"]) == tool_call_id
             end)
    end

    test "a direct poll terminal clears only its own current auto-wait after another result archives" do
      session_id = "ses1_0000000000000000601"

      session =
        SalixAgent.InternalSession.new("agt1_0000000000000000601", session_id)
        |> SalixAgent.InternalSession.apply_events([
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => "direct-a",
            "tool_name" => "env.exec",
            "completion_owner" => "direct_poll"
          },
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => "direct-b",
            "tool_name" => "env.exec",
            "completion_owner" => "direct_poll"
          },
          SalixAgent.Waits.event(
            session_id,
            SalixAgent.Waits.build("direct B is running", 20, "auto_wait", %{
              "tool_call_id" => "direct-b"
            })
          )
        ])

      events_a =
        AsyncToolResults.internal_poll_events(
          %{session_id: session_id, tool_call_id: "direct-a", tool_name: "env.exec"},
          %{error: true, error_class: "tool_error", error_message: "A failed"}
        )

      assert List.last(events_a) == %{
               "type" => "wait_clear",
               "session_id" => session_id,
               "tool_call_id" => "direct-a"
             }

      after_a = SalixAgent.InternalSession.apply_events(session, events_a)
      assert SalixAgent.InternalSession.wait(after_a)["tool_call_id"] == "direct-b"

      archived_seq =
        SalixAgent.InternalSession.get(after_a, :async_result_refs)["direct-a"]

      after_a =
        after_a
        |> SalixAgent.InternalSession.export()
        |> Map.put(:compacted_seq, archived_seq)
        |> handle()
        |> SalixAgent.InternalSession.apply_events([
          %{
            "type" => "archive_advance",
            "session_id" => session_id,
            "archived_through" => archived_seq,
            "segments" => []
          }
        ])

      # The terminal pointer has no remaining wait, queue item, or transcript
      # projection after archival, so the bounded live-reference index retires
      # it without disturbing direct-b's independent wait.
      assert :not_found = SalixAgent.InternalSession.lookup_async_call(after_a, "direct-a")

      events_b =
        AsyncToolResults.internal_poll_events(
          %{session_id: session_id, tool_call_id: "direct-b", tool_name: "env.exec"},
          %{error: false, content: "B completed"}
        )

      after_b = SalixAgent.InternalSession.apply_events(after_a, events_b)
      assert SalixAgent.InternalSession.wait(after_b) == nil
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

    test "recovers a staged repair-origin async success without laundering its provenance",
         %{
           agent: a
         } do
      operation_id =
        WorkspaceEvents.operation_id(
          AsyncToolResults.operation_source(:internal),
          a,
          "ses1_0000000000000000601",
          "copy-1"
        )

      assert {:ok, _} =
               AgentWorkspace.seed_operation(
                 a,
                 operation_id,
                 %{
                   "tool_call_id" => "copy-1",
                   "tool_name" => "env.copy",
                   "status" => "completed",
                   "content" => "copied",
                   "error" => false,
                   "visible_reply_origin" => "repair",
                   "session_events" => []
                 },
                 []
               )

      {:ok, session} =
        InternalSessionStore.prepare_commit(
          a,
          "ses1_0000000000000000601",
          [
            %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
            %{
              "type" => "async_tool_call_started",
              "session_id" => "ses1_0000000000000000601",
              "tool_call_id" => "copy-1",
              "tool_name" => "env.copy",
              "status" => "running",
              "visible_reply_origin" => "repair"
            },
            %{
              "type" => "status",
              "session_id" => "ses1_0000000000000000601",
              "status" => "active"
            }
          ]
        )

      {events, _next_id} = Repair.plan_session(session)

      completion =
        Enum.find(
          events,
          &(&1["type"] == "async_tool_call_completed" and &1["tool_call_id"] == "copy-1")
        )

      assert completion["visible_reply_origin"] == "repair"
      assert get_in(completion, ["result", "visible_reply_origin"]) == "repair"

      notification =
        Enum.find(
          events,
          &(&1["type"] == "queue_append" and &1["kind"] == "runtime_message" and
              get_in(&1, ["payload", "type"]) == "tool_call_completed")
        )

      assert get_in(notification, ["payload", "visible_reply_origin"]) == "repair"

      refute Enum.any?(events, fn
               %{"type" => "async_tool_call_failed", "tool_call_id" => "copy-1"} -> true
               _ -> false
             end)

      refute Enum.any?(events, fn
               %{"type" => "queue_append", "payload" => %{"type" => "runtime_recovered"}} -> true
               _ -> false
             end)

      assert Enum.any?(
               events,
               &(&1["type"] == "visible_reply_repair" and &1["status"] == "required")
             )

      assert Enum.any?(events, &(&1["type"] == "status" and &1["status"] == "idle"))

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events)

      assert {:ok, %{"status" => "completed", "visible_reply_origin" => "repair"}} =
               SalixAgent.InternalSession.lookup_async_call(handle(repaired), "copy-1")

      assert SalixAgent.InternalSession.visible_reply_repair_required?(handle(repaired))
      assert [queued] = SalixAgent.InternalSession.get(repaired, :input_queue)
      assert queued["kind"] == "runtime_message"
      assert get_in(queued, ["payload", "visible_reply_origin"]) == "repair"

      {materialized, true, _hwm} =
        SalixAgent.InternalSession.materialize_pending_input_events(handle(repaired))

      runtime_event = Enum.find(materialized, &(&1["type"] == "runtime_message"))
      assert runtime_event["visible_reply_origin"] == "repair"

      materialized = SalixAgent.InternalSession.apply_events(handle(repaired), materialized)

      completed =
        SalixAgent.InternalSession.apply_events(materialized, [
          %{
            "type" => "visible_reply_repair",
            "session_id" => SalixAgent.InternalSession.session_id(materialized),
            "status" => "completed"
          }
        ])

      [runtime] =
        completed
        |> Compaction.context()
        |> Enum.filter(&(&1.role == "runtime"))

      assert runtime.visible_reply_origin == "repair"
      refute runtime.content =~ "copied"
    end

    test "replayed staged async failure preserves provenance and opens repair", %{agent: a} do
      session_id = "ses1_0000000000000000601"

      staged = %{
        id: "copy-failure",
        name: "env.copy",
        status: "error",
        content: "private connector timeout",
        error: true,
        error_class: "timeout",
        error_message: "private connector timeout",
        diagnostic_visibility: "model_only",
        events: []
      }

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 staged,
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => "copy-failure",
            "tool_name" => "env.copy",
            "status" => "running"
          }
        ])

      {events, _next_id} = Repair.plan_session(session)

      runtime = Enum.find(events, &(&1["type"] == "queue_append"))
      assert get_in(runtime, ["payload", "diagnostic_visibility"]) == "model_only"
      assert get_in(runtime, ["payload", "content"]) =~ "private connector timeout"

      assert Enum.any?(
               events,
               &(&1["type"] == "visible_reply_repair" and &1["status"] == "required")
             )

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, session_id, events)
      assert SalixAgent.InternalSession.visible_reply_repair_required?(handle(repaired))
    end

    test "a staged successful async repair completion clears the repair", %{agent: a} do
      session_id = "ses1_0000000000000000601"
      attempts = SalixAgent.VisibleReplyPolicy.repair_budget() - 1

      assert {:ok, _} =
               WorkspaceEvents.commit_result(
                 a,
                 session_id,
                 %{
                   id: "copy-existing-repair",
                   name: "env.copy",
                   status: "completed",
                   content: "copied",
                   error: false,
                   visible_reply_origin: "repair",
                   events: []
                 },
                 AsyncToolResults.operation_source(:internal),
                 store_result: true
               )

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, session_id, [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "visible_reply_repair",
            "session_id" => session_id,
            "status" => "required",
            "attempts" => attempts,
            "revision" => 7,
            "diagnostic_hwm" => 3
          },
          %{
            "type" => "async_tool_call_started",
            "session_id" => session_id,
            "tool_call_id" => "copy-existing-repair",
            "tool_name" => "env.copy",
            "status" => "running",
            "visible_reply_origin" => "repair"
          },
          %{"type" => "status", "session_id" => session_id, "status" => "active"}
        ])

      {events, _next_id} = Repair.plan_session(session)

      refute Enum.any?(
               events,
               &(&1["type"] == "visible_reply_repair" and &1["status"] == "exhausted")
             )

      assert %{"status" => "completed"} =
               Enum.find(events, &(&1["type"] == "visible_reply_repair"))

      refute Enum.any?(
               events,
               &(&1["type"] == "visible_reply_repair" and &1["status"] == "required")
             )

      assert Enum.any?(
               events,
               &(&1["type"] == "queue_append" and
                   get_in(&1, ["payload", "visible_reply_origin"]) == "repair")
             )
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

    test "repair treats active session ending in tool result as transcript continuation", %{
      agent: a
    } do
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
              "content" => "",
              "tool_calls" => [
                %{
                  "id" => "call-1",
                  "name" => "call",
                  "args" => %{
                    "tool" => "help",
                    "params" => %{"tool" => "fs.read_file"}
                  }
                }
              ]
            },
            %{
              "type" => "tool_result",
              "session_id" => "ses1_0000000000000000601",
              "message_id" => 2,
              "tool_call_id" => "call-1",
              "content" => "done"
            },
            %{
              "type" => "status",
              "session_id" => "ses1_0000000000000000601",
              "status" => "active"
            }
          ],
          hwm: 2
        )

      {events, next_id} = Repair.plan_session(session)

      assert events == [
               %{
                 "type" => "status",
                 "session_id" => "ses1_0000000000000000601",
                 "status" => "idle"
               }
             ]

      assert next_id == 3

      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events,
          hwm: next_id - 1
        )

      assert SalixAgent.InternalSession.get(repaired, :status) == :idle
      assert SalixAgent.InternalSession.needs_transcript_continuation?(handle(repaired))

      refute Enum.any?(
               SalixAgent.InternalSession.get(repaired, :input_queue),
               &(&1["kind"] == "runtime_message")
             )
    end

    test "InternalSessionActor resumes after repairing active in-flight LLM", %{agent: a} do
      {:ok, _session} =
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

      Mock.script([{:final, "continued after llm recovery"}])
      :ok = InternalSessionFleet.wake(a, "ses1_0000000000000000601")

      assert eventually(fn ->
               {:ok, session} = read_state(a, "ses1_0000000000000000601")

               Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "runtime" and &1.type == "runtime_recovered")
               ) and
                 Enum.any?(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1[:content] == "continued after llm recovery")
                 )
             end)
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

    for staged <- [false, true] do
      @staged_handoff staged
      @tag :expired_callback
      test "expired location callback releases a parked session with staged handoff #{@staged_handoff}",
           %{agent: a} do
        use_capability_store(SalixAgent.CapabilityRequests)
        session_id = "ses1_0000000000000000601"
        origin = %{"provider" => "internal", "source_message_id" => "old-location-source"}

        assert {:ok, _request} =
                 SalixAgent.CapabilityRequests.create_capability_request(%{
                   "source_agent_id" => a,
                   "source_session_id" => session_id,
                   "tool_call_id" => "expired-location",
                   "request_type" => "location",
                   "request_payload" => %{"location" => %{"reason" => "weather"}},
                   "expires_at" => System.system_time(:second) - 1
                 })

        {:ok, session} =
          InternalSessionStore.prepare_commit(a, session_id, [
            %{"type" => "session_created", "session_id" => session_id},
            %{
              "type" => "delivery",
              "from_queue" => true,
              "session_id" => session_id,
              "message_id" => 1,
              "role" => "user",
              "source_message_id" => "telegram-source",
              "content" => "Please answer",
              "trusted_origin" => %{
                "provider" => "telegram",
                "source_actor_type" => "provider_user",
                "source_message_id" => "telegram-source"
              }
            },
            %{
              "type" => "async_tool_call_started",
              "session_id" => session_id,
              "tool_call_id" => "expired-location",
              "tool_name" => "location.request",
              "input" => "{}",
              "status" => "running",
              "completion_mode" => "external_callback",
              "trusted_origin" => origin,
              "trusted_origins" => [origin],
              "trusted_origin_source_message_ids" => ["old-location-source"],
              "started_at" => 1
            }
          ])

        if @staged_handoff do
          assert {:ok, _} =
                   WorkspaceEvents.commit_result(
                     a,
                     session_id,
                     %{
                       id: "expired-location",
                       name: "location.request",
                       status: "async_running",
                       content: Jason.encode!(%{"status" => "pending"}),
                       error: false,
                       events: [
                         %{
                           "type" => "async_tool_call_started",
                           "session_id" => session_id,
                           "tool_call_id" => "expired-location",
                           "tool_name" => "location.request",
                           "status" => "running",
                           "completion_mode" => "external_callback"
                         }
                       ]
                     },
                     AsyncToolResults.operation_source(:internal),
                     store_result: true
                   )
        end

        session =
          session
          |> InternalSession.export()
          |> Map.put(:repeated_tool_result_streak, %{
            "count" => 5,
            "fingerprint" => "blocked-reply",
            "tool_name" => "im_api.telegram.send_message"
          })
          |> handle()

        assert InternalSession.repeated_tool_results_exhausted?(session)
        assert InternalSession.query(session, :terminal_reply_running?)

        {events, _} = Repair.plan_session(session)
        repaired = InternalSession.apply_events(session, events)

        assert {:ok, %{"status" => "failed"} = terminal} =
                 InternalSession.lookup_async_call(repaired, "expired-location")

        assert terminal["trusted_origin_source_message_ids"] == ["old-location-source"]
        refute InternalSession.query(repaired, :terminal_reply_running?)
        refute InternalSession.repeated_tool_results_exhausted?(repaired)
      end
    end

    test "active session waiting for external callback is not treated as an LLM crash", %{
      agent: a
    } do
      use_capability_store(SalixAgent.RepairCompactionTest.PendingCapStore)

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{"type" => "status", "session_id" => "ses1_0000000000000000601", "status" => "active"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "tool-a",
            "tool_name" => "permission.request",
            "input" => "{}",
            "status" => "running",
            "completion_mode" => "external_callback",
            "started_at" => 1,
            "auto_wait_seconds" => 120
          }
        ])

      {events, next_id} = Repair.plan_session(session)
      contract_events = assert_capability_sync(events)

      assert next_id == 1

      assert [
               %{"type" => "status", "status" => "idle"},
               %{"type" => "queue_append", "kind" => "runtime_message"} = delivery
             ] = contract_events

      assert delivery["payload"]["type"] == "runtime_recovered"
      assert delivery["payload"]["source_refs"]["failed_tool_calls"] == []

      assert [
               %{
                 "tool_call_id" => "tool-a",
                 "tool_name" => "permission.request",
                 "reason" => "external_callback_pending"
               }
             ] = delivery["payload"]["source_refs"]["pending_external_callback_tool_calls"]

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events)
      assert SalixAgent.InternalSession.get(repaired, :status) == :idle

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["tool-a"]["status"] ==
               "running"

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["tool-a"][
               "completion_mode"
             ] == "external_callback"
    end

    test "idle session waiting for external callback is not reported as runtime recovery", %{
      agent: a
    } do
      use_capability_store(SalixAgent.RepairCompactionTest.PendingCapStore)

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{
            "type" => "wait_set",
            "session_id" => "ses1_0000000000000000601",
            "wait" => %{"reason" => "approval"}
          },
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "tool-a",
            "tool_name" => "permission.request",
            "input" => "{}",
            "status" => "running",
            "completion_mode" => "external_callback",
            "started_at" => 1,
            "auto_wait_seconds" => 120
          }
        ])

      assert SalixAgent.InternalSession.get(session, :status) == :idle
      assert SalixAgent.InternalSession.get(session, :wait)["reason"] == "approval"

      assert {events, 1} = Repair.plan_session(session)
      assert [] = assert_capability_sync(events)
      repaired = InternalSession.apply_events(handle(session), events)
      assert InternalSession.get(repaired, :status) == :idle
    end

    test "idle session with only external callback pending is not reported as runtime recovery",
         %{agent: a} do
      use_capability_store(SalixAgent.RepairCompactionTest.PendingCapStore)

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "tool-a",
            "tool_name" => "permission.request",
            "input" => "{}",
            "status" => "running",
            "completion_mode" => "external_callback",
            "started_at" => 1,
            "auto_wait_seconds" => 120
          }
        ])

      assert SalixAgent.InternalSession.get(session, :status) == :idle
      assert SalixAgent.InternalSession.get(session, :wait) == nil

      assert {events, 1} = Repair.plan_session(session)
      assert [] = assert_capability_sync(events)
      repaired = InternalSession.apply_events(handle(session), events)
      assert InternalSession.get(repaired, :status) == :idle
    end

    test "active session waiting for pending capability is not treated as an LLM crash", %{
      agent: a
    } do
      use_capability_store(SalixAgent.RepairCompactionTest.PendingCapStore)

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{"type" => "status", "session_id" => "ses1_0000000000000000601", "status" => "active"},
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
          }
        ])

      {events, next_id} = Repair.plan_session(session)
      contract_events = assert_capability_sync(events)

      assert next_id == 1

      assert [
               %{"type" => "status", "status" => "idle"},
               %{"type" => "queue_append", "kind" => "runtime_message"} = delivery
             ] = contract_events

      assert delivery["payload"]["type"] == "runtime_recovered"
      assert delivery["payload"]["source_refs"]["failed_tool_calls"] == []

      assert [
               %{
                 "tool_call_id" => "oauth-call",
                 "tool_name" => "oauth.request_authorization",
                 "reason" => "external_callback_pending"
               }
             ] = delivery["payload"]["source_refs"]["pending_external_callback_tool_calls"]

      {:ok, repaired} = InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events)
      assert SalixAgent.InternalSession.get(repaired, :status) == :idle

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["oauth-call"]["status"] ==
               "running"
    end

    test "repairs missing external-callback early result without failing pending capability", %{
      agent: a
    } do
      use_capability_store(SalixAgent.RepairCompactionTest.PendingCapStore)

      {:ok, session} =
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
              "content" => "need permission",
              "tool_calls" => [
                %{
                  "id" => "oauth-call",
                  "name" => "call",
                  "args" => %{
                    "tool" => "oauth.request_authorization",
                    "params" => %{"provider" => "github"}
                  }
                }
              ]
            }
          ],
          hwm: 1
        )

      {events, next_id} = Repair.plan_session(session)
      contract_events = assert_capability_sync(events)

      refute Enum.any?(events, &(&1["type"] == "async_tool_call_failed"))

      assert [
               %{
                 "type" => "async_tool_call_started",
                 "tool_call_id" => "oauth-call",
                 "completion_mode" => "external_callback"
               },
               %{
                 "type" => "tool_result",
                 "tool_call_id" => "oauth-call",
                 "content" => content,
                 "error" => false
               },
               %{"type" => "status", "status" => "idle"},
               %{"type" => "queue_append", "kind" => "runtime_message"} = delivery
             ] = contract_events

      assert Jason.decode!(content)["status"] == "async_running"
      assert delivery["payload"]["type"] == "runtime_recovered"

      assert [
               %{
                 "tool_call_id" => "oauth-call",
                 "tool_name" => "oauth.request_authorization",
                 "reason" => "external_callback_pending"
               }
             ] = delivery["payload"]["source_refs"]["pending_external_callback_tool_calls"]

      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events,
          hwm: next_id - 1
        )

      assert SalixAgent.InternalSession.get(repaired, :status) == :idle

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["oauth-call"][
               "completion_mode"
             ] == "external_callback"

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["oauth-call"]["status"] ==
               "running"
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

    test "loads a cold capability store before deciding whether its callback exists", %{agent: a} do
      store = SalixAgent.TestSupport.ColdPendingCapabilityStore
      use_capability_store(store)
      on_exit(fn -> Code.ensure_loaded!(store) end)

      Code.ensure_loaded!(store)
      :code.delete(store)
      :code.purge(store)
      assert :code.is_loaded(store) == false

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000601",
            "tool_call_id" => "cold-oauth-call",
            "tool_name" => "oauth.request_authorization",
            "completion_mode" => "external_callback",
            "status" => "running"
          }
        ])

      assert {events, 1} = Repair.plan_session(session)
      assert [] = assert_capability_sync(events)
      repaired = InternalSession.apply_events(handle(session), events)
      assert InternalSession.get(repaired, :status) == :idle
      assert :code.is_loaded(store) != false

      Application.put_env(
        :salix_agent,
        :capability_request_store_mod,
        SalixAgent.TestSupport.MissingCapabilityStore
      )

      assert {events, 1} = Repair.plan_session(session)
      assert [] = assert_capability_sync(events)
      repaired = InternalSession.apply_events(handle(session), events)
      assert InternalSession.get(repaired, :status) == :idle
    end

    test "preserves running async call when capability pending lookup is unavailable", %{agent: a} do
      use_capability_store(SalixAgent.RepairCompactionTest.RaisingCapStore)

      {:ok, session} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000601"},
          %{"type" => "status", "session_id" => "ses1_0000000000000000601", "status" => "active"},
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
          }
        ])

      {events, next_id} = Repair.plan_session(session)
      contract_events = assert_capability_sync(events)

      refute Enum.any?(events, &(&1["type"] == "async_tool_call_failed"))

      assert [%{"type" => "status", "status" => "idle"}] = contract_events
      refute Enum.any?(events, &(&1["type"] == "queue_append"))

      {:ok, repaired} =
        InternalSessionStore.prepare_commit(a, "ses1_0000000000000000601", events,
          hwm: next_id - 1
        )

      assert SalixAgent.InternalSession.get(repaired, :status) == :idle

      assert SalixAgent.InternalSession.get(repaired, :async_tool_calls)["oauth-call"]["status"] ==
               "running"
    end
  end

  describe "durable capability reconciliation" do
    test "a terminal request recovers its canonical result when the async start was lost", %{
      agent: a
    } do
      use_capability_store(SalixAgent.CapabilityRequests)
      sid = "ses1_0000000000000000601"
      request = create_location_request!(a, sid, "lost-start")
      canonical = %{"status" => "completed", "content" => "canonical location", "error" => false}

      assert {:ok, %{"result" => ^canonical}} =
               SalixAgent.CapabilityRequests.reconcile_capability_request(
                 a,
                 sid,
                 "lost-start",
                 canonical
               )

      {:ok, session} =
        InternalSessionStore.prepare_commit(
          a,
          sid,
          [
            %{"type" => "session_created", "session_id" => sid},
            %{
              "type" => "assistant",
              "session_id" => sid,
              "message_id" => 1,
              "content" => "need location",
              "tool_calls" => [
                %{
                  "id" => "lost-start",
                  "name" => "call",
                  "args" => %{"tool" => "location.request", "params" => %{}}
                }
              ]
            }
          ],
          hwm: 1
        )

      {events, _} = Repair.plan_session(session)
      repaired = InternalSession.apply_events(handle(session), events)
      assert {:ok, terminal} = InternalSession.lookup_async_call(repaired, "lost-start")
      assert terminal["status"] == "completed"
      assert terminal["result"]["content"] == canonical["content"]

      assert {:ok, %{"result" => ^canonical}} =
               SalixAgent.CapabilityRequests.get(
                 request["group_id"],
                 request["request_id"],
                 request["tenant_id"]
               )
    end

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
        "completed_at" => System.system_time(:millisecond)
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

    test "idle callback recovery persists the original request deadline across restart", %{
      agent: a
    } do
      use_capability_store(SalixAgent.CapabilityRequests)
      sid = "ses1_0000000000000000601"
      request = create_location_request!(a, sid, "waiting")
      session = callback_session!(a, sid, "waiting")
      {events, _} = Repair.plan_session(session)
      {:ok, repaired} = InternalSessionStore.prepare_commit(a, sid, events)
      {:ok, reopened} = InternalSessionStore.read(a, sid)
      deadline = request["expires_at"] * 1_000
      assert InternalSession.get(repaired, :status) == :idle
      assert InternalSession.query(handle(reopened), :recovery_wait)["deadline_ms"] == deadline

      assert {:ok, %{"status" => "running", "capability_deadline_ms" => ^deadline}} =
               InternalSession.lookup_async_call(handle(reopened), "waiting")

      {again, _} = Repair.plan_session(handle(reopened))
      again = InternalSession.apply_events(handle(reopened), again)
      assert InternalSession.query(again, :recovery_wait)["deadline_ms"] == deadline
    end

    test "transient request lookup persists a retry and exhausted lookup stops automatic retries",
         %{agent: a} do
      use_capability_store(SalixAgent.RepairCompactionTest.RaisingCapStore)
      sid = "ses1_0000000000000000601"
      session = callback_session!(a, sid, "unavailable")
      before = System.system_time(:millisecond)
      {events, _} = Repair.plan_session(session)
      {:ok, repaired} = InternalSessionStore.prepare_commit(a, sid, events)
      assert {:ok, running} = InternalSession.lookup_async_call(handle(repaired), "unavailable")
      assert running["status"] == "running"
      assert running["capability_error_since_ms"] >= before
      assert running["capability_retry_at_ms"] >= before + 5_000

      assert InternalSession.query(handle(repaired), :recovery_wait)["deadline_ms"] ==
               running["capability_retry_at_ms"]

      {:ok, overdue} =
        InternalSessionStore.prepare_commit(a, sid, [
          %{
            "type" => "capability_request_sync",
            "session_id" => sid,
            "tool_call_id" => "unavailable",
            "capability_error_since_ms" => before - 30_001,
            "capability_retry_at_ms" => before
          }
        ])

      {events, _} = Repair.plan_session(overdue)
      {:ok, settled} = InternalSessionStore.prepare_commit(a, sid, events)
      assert {:ok, terminal} = InternalSession.lookup_async_call(handle(settled), "unavailable")
      assert terminal["status"] == "failed"
      assert terminal["error_class"] == "capability_request_unavailable"

      assert InternalSession.get(settled, :async_tool_calls)["unavailable"][
               "capability_sync_failed"
             ]

      refute is_integer(
               (InternalSession.query(handle(settled), :recovery_wait) || %{})["deadline_ms"]
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
        "expires_at" => System.system_time(:second) + 600
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

    test "should_compact? respects the threshold", %{agent: _a} do
      s =
        InternalSession.normalize(
          handle(%InternalSession.State{
            agent_id: "agent",
            session_id: "ses1_0000000000000000601",
            messages: [%{id: 1, role: "user", content: String.duplicate("z", 500)}]
          })
        )

      assert Compaction.should_compact?(s, threshold: 100)
      refute Compaction.should_compact?(s, threshold: 100_000)
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
    previous = Application.fetch_env(:salix_agent, :capability_request_store_mod)
    Application.put_env(:salix_agent, :capability_request_store_mod, store)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:salix_agent, :capability_request_store_mod, value)
        :error -> Application.delete_env(:salix_agent, :capability_request_store_mod)
      end
    end)
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = read_state(agent_id, session_id)
    session
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp handle(session) when SalixAgent.InternalSession.is_session(session), do: session
  defp handle(state), do: SalixAgent.InternalSession.open(state)

  defp read_state(agent_id, session_id) do
    SalixAgent.InternalSessionStore.read(agent_id, session_id)
  end
end
