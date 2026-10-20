defmodule SalixAgent.VisibleReplyPolicyTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.InternalSession.State
  alias SalixAgent.SessionToolDispatch
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.Tools
  alias SalixAgent.VisibleReplyPolicy, as: Policy

  defmodule PublicFailureIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "slack-1", "provider" => "slack"}]}

    @impl true
    def provider_manual("slack") do
      {:ok,
       %{
         "provider" => "slack",
         "apis" => [
           %{
             "name" => "slack.get_thread_replies",
             "safety" => "read",
             "required_params" => ["channel", "ts"],
             "parameters" => %{"channel" => "channel", "ts" => "thread"}
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(_agent_id, "slack", "slack.get_thread_replies", _args) do
      {:error,
       %{
         "error_class" => "provider_unavailable",
         "message" => "private Slack response body and request id",
         "public_summary" => "Slack is temporarily unavailable."
       }}
    end
  end

  defmodule FailedInternalSendIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal"}]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "required_params" => ["conversation_id", "content"],
             "parameters" => %{
               "conversation_id" => "target conversation",
               "content" => "visible content"
             }
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(_agent_id, "internal", "internal.send_message", _args) do
      {:error,
       %{
         "error_class" => "provider_unavailable",
         "message" => "private failed send detail",
         "public_summary" => "The message was not sent."
       }}
    end
  end

  # Mirrors `SalixIM.ImessageRelay`: an unacknowledged send is a coded
  # failure without a public summary.
  defmodule CodedFailureIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "imessage-1", "provider" => "imessage"}]}

    @impl true
    def provider_manual("imessage") do
      {:ok,
       %{
         "provider" => "imessage",
         "apis" => [
           %{
             "name" => "imessage.send_message",
             "safety" => "write",
             "required_params" => ["text"],
             "parameters" => %{"text" => "message text"}
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(_agent_id, "imessage", "imessage.send_message", _args) do
      {:error,
       %{
         "code" => "imessage_delivery_unknown",
         "retryable" => false,
         "message" => "private relay detail: the message may already have been sent"
       }}
    end
  end

  defmodule NoPendingCapabilityStore do
    @behaviour SalixAgent.CapabilityRequestStore

    @impl true
    def create_capability_request(_attrs), do: {:error, :not_implemented}

    @impl true
    def pending_capability_request?(_agent_id, _session_id, _tool_call_id), do: false

    @impl true
    def reconcile_capability_request(_agent_id, _session_id, _tool_call_id, _result),
      do: {:ok, :not_found}

    @impl true
    def cancel_capability_request(_agent_id, _session_id, _tool_call_id, _reason),
      do: {:ok, :not_found}
  end

  defmodule FaultIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "test-1", "provider" => "test"}]}

    @impl true
    def provider_manual("test") do
      {:ok,
       %{
         "provider" => "test",
         "apis" => [
           %{
             "name" => "test.failure",
             "safety" => "read",
             "required_params" => ["mode"],
             "parameters" => %{"mode" => "failure mode"}
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(_agent_id, "test", "test.failure", %{"params" => %{"mode" => "exception"}}),
      do: raise(ArgumentError, "private provider exception")

    def call_api(_agent_id, "test", "test.failure", %{"params" => %{"mode" => "timeout"}}) do
      SystemsClock.sleep(100)
      {:ok, %{"late" => true}}
    end
  end

  defmodule NestedWriteIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "test-1", "provider" => "test"}]}

    @impl true
    def provider_manual("test") do
      {:ok,
       %{
         "provider" => "test",
         "apis" => [
           %{
             "name" => "test.send",
             "safety" => "write",
             "required_params" => ["text"],
             "parameters" => %{"text" => "visible text"}
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, "test", "test.send", args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:nested_visible_send, agent_id, args}
      )

      {:ok, %{"ok" => true}}
    end
  end

  setup do
    previous_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    previous_tool_timeouts = SystemsRuntime.get_env(:salix_agent, :tool_timeouts)

    previous_capability_store =
      SystemsRuntime.get_env(:salix_agent, :capability_request_store_mod)

    SystemsRuntime.put_env(
      :salix_agent,
      :capability_request_store_mod,
      NoPendingCapabilityStore
    )

    on_exit(fn ->
      if previous_im_provider,
        do: SystemsRuntime.put_env(:salix_agent, :im_provider_mod, previous_im_provider),
        else: SystemsRuntime.delete_env(:salix_agent, :im_provider_mod)

      if previous_tool_timeouts,
        do: SystemsRuntime.put_env(:salix_agent, :tool_timeouts, previous_tool_timeouts),
        else: SystemsRuntime.delete_env(:salix_agent, :tool_timeouts)

      if previous_capability_store,
        do:
          SystemsRuntime.put_env(
            :salix_agent,
            :capability_request_store_mod,
            previous_capability_store
          ),
        else: SystemsRuntime.delete_env(:salix_agent, :capability_request_store_mod)
    end)

    :ok
  end

  describe "diagnostic provenance" do
    test "exception, crash, and timeout failures are model-only" do
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FaultIMProvider)

      ctx =
        envelope_ctx([
          %{
            "name" => "im_api.test.failure",
            "callable" => true,
            "safety" => "read",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "connect_id" => %{"type" => "string"},
                "mode" => %{"type" => "string"}
              },
              "required" => ["connect_id", "mode"]
            }
          }
        ])

      call = fn id, mode ->
        %{
          id: id,
          name: "call",
          args: %{
            "tool" => "im_api.test.failure",
            "params" => %{"connect_id" => "test-1", "mode" => mode}
          }
        }
      end

      ctx =
        Map.merge(ctx, %{
          runtime_kind: :internal,
          session_id: "ses1_0000000000000000001",
          visible_reply_phase: :clean
        })

      [exception] = SessionToolDispatch.execute([call.("exception-1", "exception")], ctx)
      assert exception.error_class == "exception"
      exception = Policy.label_result(exception)
      assert exception.diagnostic_visibility == "model_only"

      SystemsRuntime.put_env(:salix_agent, :tool_timeouts, %{"im_api.test.failure" => 1})
      [timeout] = SessionToolDispatch.execute([call.("timeout-1", "timeout")], ctx)
      assert timeout.error_class == "timeout"
      timeout = Policy.label_result(timeout)
      assert timeout.diagnostic_visibility == "model_only"

      [crashed] =
        SalixAgent.Round.tool_error_results(
          [%{id: "crashed-1", name: "test.tool", args: %{}}],
          :private_crash,
          "crashed"
        )

      crashed = Policy.label_result(crashed)
      assert crashed.diagnostic_visibility == "model_only"

      for result <- [exception, timeout, crashed] do
        assert Policy.transition(:clean, [result]) == {:required, 0}
      end
    end

    test "external provider public failure contract survives dispatch structurally" do
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, PublicFailureIMProvider)

      ctx = %{
        agent_id: "agt1_0000000000000000001",
        session_id: "ses1_0000000000000000001",
        runtime_kind: :internal,
        visible_reply_phase: :clean,
        llm_tool_envelope: true,
        tool_disclosure: %{
          "tools" => [
            %{
              "name" => "im_api.slack.get_thread_replies",
              "callable" => true,
              "safety" => "read",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{
                  "connect_id" => %{"type" => "string"},
                  "channel" => %{"type" => "string"},
                  "ts" => %{"type" => "string"}
                },
                "required" => ["connect_id", "channel", "ts"]
              }
            }
          ]
        }
      }

      [result] =
        SessionToolDispatch.execute(
          [
            %{
              id: "provider-public-failure",
              name: "call",
              args: %{
                "tool" => "im_api.slack.get_thread_replies",
                "params" => %{
                  "connect_id" => "slack-1",
                  "channel" => "C1",
                  "ts" => "1.0"
                }
              }
            }
          ],
          ctx
        )

      labeled = Policy.label_result(result)
      assert labeled.error_class == "provider_unavailable"
      assert labeled.diagnostic_visibility == "user_reportable"
      assert labeled.public_summary == "Slack is temporarily unavailable."
      assert labeled.content =~ "private Slack response"

      [sanitized] = Policy.sanitize_context([Map.put(labeled, :role, "tool")])
      assert sanitized.content =~ "Slack is temporarily unavailable."
      refute sanitized.content =~ "private Slack response"
    end
  end

  describe "repair state" do
    test "opens, completes on a real success, and exhausts a bounded repair" do
      private_failure =
        Policy.label_result(%{status: "error", error: true, content: "private"})

      success = Policy.label_result(%{status: "completed", error: false, content: "ok"})

      assert Policy.transition(:clean, [private_failure]) == {:required, 0}
      assert Policy.transition({:repair_required, 0}, [success]) == :completed
      assert Policy.transition({:repair_required, 0}, [private_failure]) == {:required, 1}

      budget = Policy.repair_budget()

      assert Policy.no_tool_transition({:repair_required, budget - 1}) ==
               {:exhausted, budget}

      events =
        Policy.transition_events(
          {:exhausted, budget},
          "ses1_0000000000000000001",
          7
        )

      assert Enum.any?(
               events,
               &(&1["type"] == "session_event" and
                   get_in(&1, ["event", "message"]) == Policy.safe_failure_summary())
             )

      refute Enum.any?(events, &(inspect(&1) =~ "private"))
    end

    test "async result reads inherit private or reportable provenance" do
      assert SalixAgent.AsyncToolResults.result_diagnostic_contract(%{
               "status" => "failed",
               "error" => true,
               "error_class" => "timeout",
               "result" => %{
                 "content" => "private timeout detail",
                 "diagnostic_visibility" => "model_only"
               }
             }) == {:model_only, "timeout"}

      assert SalixAgent.AsyncToolResults.result_diagnostic_contract(%{
               "status" => "failed",
               "error" => true,
               "error_class" => "provider_unavailable",
               "diagnostic_visibility" => "user_reportable",
               "public_summary" => "Slack is temporarily unavailable.",
               "result" => %{"content" => "private provider failure"}
             }) ==
               {:user_reportable, "provider_unavailable", "Slack is temporarily unavailable."}

      assert SalixAgent.AsyncToolResults.result_diagnostic_contract(%{
               "status" => "failed",
               "error" => true,
               "result" => %{"content" => "legacy private failure"}
             }) == {:model_only, "async_tool_failure"}

      assert SalixAgent.AsyncToolResults.result_diagnostic_contract(%{
               "status" => "completed",
               "result" => %{"content" => "safe result"}
             }) == :none

      assert SalixAgent.AsyncToolResults.result_diagnostic_contract(%{
               "status" => "completed",
               "visible_reply_origin" => "repair",
               "result" => %{
                 "content" => "private repair-origin success",
                 "visible_reply_origin" => "repair"
               }
             }) == {:model_only, "repair_context"}
    end

    test "async failures preserve repair budget and a later real success completes repair" do
      session_id = "ses1_0000000000000000001"

      state =
        "agt1_0000000000000000001"
        |> SalixAgent.InternalSession.new(session_id)
        |> SalixAgent.InternalSession.apply_event(%{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "required",
          "attempts" => Policy.repair_budget() - 1
        })
        |> SalixAgent.InternalSession.export()

      result =
        Policy.label_result(%{
          id: "async-crash",
          status: "error",
          error: true,
          error_class: "crashed",
          content: "private crash detail"
        })

      events =
        [
          %{
            "type" => "queue_append",
            "kind" => "runtime_message",
            "payload" => %{"content" => "private crash detail"}
          }
        ]
        |> Policy.async_completion_events(SalixAgent.InternalSession.open(state), result)

      assert Enum.any?(events, &(&1["type"] == "queue_append"))

      repair_event = Enum.find(events, &(&1["type"] == "visible_reply_repair"))
      assert repair_event["status"] == "required"
      assert repair_event["attempts"] == Policy.repair_budget() - 1
      assert repair_event["revision"] == 1
      refute Enum.any?(events, &(&1["type"] == "session_event"))

      next_state = SessionData.apply_event(state, repair_event)

      refute Policy.guard(SalixAgent.InternalSession.open(next_state)) ==
               Policy.guard(SalixAgent.InternalSession.open(state))

      success =
        Policy.label_result(%{
          id: "unrelated-async-success",
          status: "completed",
          error: false,
          content: "safe result"
        })

      next_events =
        Policy.async_completion_events([], SalixAgent.InternalSession.open(next_state), success)

      next_repair = Enum.find(next_events, &(&1["type"] == "visible_reply_repair"))
      assert next_repair["status"] == "completed"
    end

    test "crash recovery preserves the existing model repair budget" do
      session_id = "ses1_0000000000000000001"

      session = %State{
        agent_id: "agt1_0000000000000000001",
        session_id: session_id,
        status: :idle,
        next_message_id: 2,
        visible_reply_repair: %{
          "status" => "required",
          "attempts" => Policy.repair_budget() - 1
        },
        messages: [
          %{
            id: 1,
            role: "assistant",
            content: "calling",
            tool_calls: [
              %{
                "id" => "orphan-tool",
                "name" => "call",
                "args" => %{
                  "tool" => "help",
                  "params" => %{"tool" => "fs.read_file"}
                }
              }
            ]
          }
        ]
      }

      {events, 3} = SalixAgent.Repair.plan_session(SalixAgent.InternalSession.open(session))

      runtime = Enum.find(events, &(&1["type"] == "queue_append"))
      assert get_in(runtime, ["payload", "diagnostic_visibility"]) == "model_only"

      repair = Enum.find(events, &(&1["type"] == "visible_reply_repair"))
      assert repair["status"] == "required"
      assert repair["attempts"] == Policy.repair_budget() - 1
      assert repair["revision"] == 1
      assert repair["diagnostic_hwm"] == 2

      refute Enum.any?(events, &(&1["type"] == "session_event"))
    end
  end

  describe "scheduled Task failure admission" do
    test "requires the exact runtime-minted window identity" do
      conversation_id = "cnv1_0000000000000000001"
      request_id = "scheduled-task-safe-failure:sch1_0000000000000000001:1788256680000"

      origin = %{
        "provider" => "internal",
        "conversation_id" => conversation_id,
        "conversation_kind" => "agent_task",
        "source_actor_type" => "system",
        "task_schedule" => %{
          "schedule_id" => "sch1_0000000000000000001",
          "scheduled_for" => 1_788_256_680_000
        }
      }

      ctx =
        envelope_ctx([
          %{
            "name" => "im_api.internal.send_message",
            "callable" => true,
            "safety" => "write",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "connect_id" => %{"type" => "string"},
                "conversation_id" => %{"type" => "string"},
                "content" => %{"type" => "array"},
                "request_id" => %{"type" => "string"}
              },
              "required" => ["connect_id", "conversation_id", "content"]
            }
          }
        ])
        |> Map.put(:trusted_origins, [origin])
        |> Map.put(:visible_reply_phase, :clean)

      ordinary =
        call_tool("business-result", "im_api.internal.send_message", %{
          "connect_id" => "internal",
          "conversation_id" => conversation_id,
          "content" => [%{"type" => "text", "text" => "inspection passed"}],
          "request_id" => "business-result-request"
        })

      assert Policy.sanitize_scheduled_task_failure_call(ordinary, ctx) ==
               :not_scheduled_task_failure

      canonical =
        call_tool(request_id, "im_api.internal.send_message", %{
          "connect_id" => "internal",
          "conversation_id" => conversation_id,
          "content" => [%{"type" => "text", "text" => "private provider diagnostic"}],
          "request_id" => request_id
        })

      assert Policy.sanitize_scheduled_task_failure_call(canonical, ctx) ==
               :not_scheduled_task_failure

      repair_ctx = Map.put(ctx, :visible_reply_phase, {:repair_required, 0})

      assert {:ok, sanitized} =
               Policy.sanitize_scheduled_task_failure_call(canonical, repair_ctx)

      assert sanitized.args["params"]["request_id"] == request_id
      assert sanitized.args["params"]["conversation_id"] == conversation_id
      refute sanitized.args["params"]["content"] == canonical.args["params"]["content"]
    end
  end

  describe "clean model context" do
  end

  describe "nested script tool dispatch" do

    test "returns only an adapter-owned public summary to JavaScript" do
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, PublicFailureIMProvider)

      ctx =
        envelope_ctx([
          %{
            "name" => "im_api.slack.get_thread_replies",
            "callable" => true,
            "safety" => "read",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "connect_id" => %{"type" => "string"},
                "channel" => %{"type" => "string"},
                "ts" => %{"type" => "string"}
              },
              "required" => ["connect_id", "channel", "ts"]
            }
          }
        ])
        |> Map.put(:visible_reply_phase, :clean)

      {{:error, "Slack is temporarily unavailable."}, state} =
        SalixAgent.ScriptRun.host_call(
          "im_api.slack.get_thread_replies",
          %{"connect_id" => "slack-1", "channel" => "C1", "ts" => "1.0"},
          SalixAgent.ScriptRun.new(ctx)
        )

      assert {:tool_failure, diagnostic, "provider_unavailable", "user_reportable",
              "Slack is temporarily unavailable.", [], _observations} =
               SalixAgent.ScriptRun.finalize_result("script caught the error", state)

      assert diagnostic =~ "private Slack response body"
    end

    test "a failed nested internal send does not record visible reply ownership" do
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FailedInternalSendIMProvider)

      ctx =
        envelope_ctx([
          %{
            "name" => "im_api.internal.send_message",
            "callable" => true,
            "safety" => "write",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "connect_id" => %{"type" => "string"},
                "conversation_id" => %{"type" => "string"},
                "content" => %{"type" => "array"}
              },
              "required" => ["connect_id", "conversation_id", "content"]
            }
          }
        ])
        |> Map.merge(%{
          group_id: "group-source",
          session_id: "session-source",
          source_message_id: "source-1",
          source_message_ids: ["source-1"],
          tool_call_id: "outer-js-call",
          visible_reply_phase: :clean,
          visible_reply_guard: :clean
        })

      {{:error, "The message was not sent."}, state} =
        SalixAgent.ScriptRun.host_call(
          "im_api.internal.send_message",
          %{
            "connect_id" => "internal",
            "conversation_id" => "conversation-source",
            "content" => [%{"type" => "text", "text" => "not delivered"}]
          },
          SalixAgent.ScriptRun.new(ctx)
        )

      assert {:tool_failure, _diagnostic, "provider_unavailable", "user_reportable",
              "The message was not sent.", events, _observations} =
               SalixAgent.ScriptRun.finalize_result("script handled failure", state)

      refute Enum.any?(events, &(&1["kind"] == "visible_reply_egress"))
    end
  end

  defp envelope_ctx(tools) do
    %{
      agent_id: "agt1_0000000000000000001",
      llm_tool_envelope: true,
      tool_disclosure: %{"tools" => tools}
    }
  end

  defp call_tool(id, tool, params) do
    %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}
  end
end
