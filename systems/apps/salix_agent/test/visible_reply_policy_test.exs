defmodule SalixAgent.VisibleReplyPolicyTest do
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixAgent.SessionToolDispatch
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.Tools
  alias SalixAgent.VisibleReplyPolicy, as: Policy

  test "an unrelated successful read does not rewrite an IFC refusal as resolved" do
    call = %{
      id: "denied",
      name: "call",
      args: %{
        "tool" => "im_api.slack.post_message",
        "ifc" => %{"request" => "src:q-11", "sources" => ["src:q-11"]}
      }
    }

    denied = %{
      role: "tool",
      tool_call_id: "denied",
      status: "guidance",
      guidance_reason: "information_flow",
      diagnostic_visibility: "model_only",
      content: ~s({"status":"guidance","clause":"request_without_principal"})
    }

    assistant = %{role: "assistant", content: "", tool_calls: [call]}
    [kept_call, kept_result] = Policy.sanitize_context([assistant, denied], :clean)
    assert kept_result == denied
    assert kept_call.tool_calls == [call]
    refute kept_result.content =~ "resolved"
  end

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
      Process.sleep(100)
      {:ok, %{"late" => true}}
    end
  end

  defmodule NestedWriteIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

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
      send(:persistent_term.get({__MODULE__, :owner}), {:nested_visible_send, agent_id, args})
      {:ok, %{"ok" => true}}
    end
  end

  setup do
    previous_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    previous_tool_timeouts = Application.get_env(:salix_agent, :tool_timeouts)

    previous_capability_store =
      Application.get_env(:salix_agent, :capability_request_store_mod)

    Application.put_env(
      :salix_agent,
      :capability_request_store_mod,
      NoPendingCapabilityStore
    )

    on_exit(fn ->
      if previous_im_provider,
        do: Application.put_env(:salix_agent, :im_provider_mod, previous_im_provider),
        else: Application.delete_env(:salix_agent, :im_provider_mod)

      if previous_tool_timeouts,
        do: Application.put_env(:salix_agent, :tool_timeouts, previous_tool_timeouts),
        else: Application.delete_env(:salix_agent, :tool_timeouts)

      if previous_capability_store,
        do:
          Application.put_env(
            :salix_agent,
            :capability_request_store_mod,
            previous_capability_store
          ),
        else: Application.delete_env(:salix_agent, :capability_request_store_mod)
    end)

    :ok
  end

  describe "diagnostic provenance" do
    test "all closed guidance reasons are model-only" do
      disclosed_help = %{
        "name" => "help",
        "callable" => true,
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"tool" => %{"type" => "string"}},
          "required" => ["tool"]
        }
      }

      cases = [
        {
          "envelope_misuse",
          %{id: "missing-tool", name: "call", args: %{"params" => %{}}},
          envelope_ctx([disclosed_help])
        },
        {
          "invalid_params",
          %{id: "invalid-params", name: "call", args: %{"tool" => "help", "params" => %{}}},
          envelope_ctx([disclosed_help])
        },
        {
          "not_callable",
          %{
            id: "not-callable",
            name: "call",
            args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
          },
          envelope_ctx([Map.put(disclosed_help, "callable", false)])
        },
        {
          "not_disclosed",
          %{
            id: "not-disclosed",
            name: "call",
            args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
          },
          %{agent_id: "agt1_0000000000000000001", llm_tool_envelope: true}
        }
      ]

      for {reason, call, ctx} <- cases do
        [result] = Tools.execute([call], ctx)
        result = Policy.label_result(result)

        assert result.diagnostic_visibility == "model_only"
        assert result.guidance_reason == reason
        refute Map.has_key?(result, :public_summary)
      end
    end

    test "exception, crash, and timeout failures are model-only" do
      Application.put_env(:salix_agent, :im_provider_mod, FaultIMProvider)

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

      Application.put_env(:salix_agent, :tool_timeouts, %{"im_api.test.failure" => 1})
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

        [sanitized] =
          Policy.sanitize_context([Map.put(result, :role, "tool")], :clean)

        refute sanitized.content =~ "private"
      end
    end

    test "only an explicit public summary promotes a failure" do
      promoted =
        Policy.label_result(%{
          status: "error",
          error: true,
          error_class: "provider_unavailable",
          diagnostic_visibility: "user_reportable",
          public_summary: "Slack is temporarily unavailable.",
          content: "private provider response"
        })

      assert promoted.diagnostic_visibility == "user_reportable"
      assert promoted.public_summary == "Slack is temporarily unavailable."

      bounded =
        Policy.label_result(%{
          status: "error",
          error: true,
          diagnostic_visibility: "user_reportable",
          public_summary: String.duplicate("a", 513),
          content: "private provider response"
        })

      assert String.length(bounded.public_summary) == 512

      rejected =
        Policy.label_result(%{
          status: "error",
          error: true,
          diagnostic_visibility: "user_reportable",
          content: "private provider response"
        })

      assert rejected.diagnostic_visibility == "model_only"
    end

    test "external provider public failure contract survives dispatch structurally" do
      Application.put_env(:salix_agent, :im_provider_mod, PublicFailureIMProvider)

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

      [sanitized] = Policy.sanitize_context([Map.put(labeled, :role, "tool")], :clean)
      assert sanitized.content =~ "Slack is temporarily unavailable."
      refute sanitized.content =~ "private Slack response"
    end
  end

  describe "retained failure facts" do
    test "a coded provider failure keeps its closed facts after repair" do
      Application.put_env(:salix_agent, :im_provider_mod, CodedFailureIMProvider)

      ctx = %{
        agent_id: "agt1_0000000000000000001",
        session_id: "ses1_0000000000000000001",
        runtime_kind: :internal,
        visible_reply_phase: :clean,
        llm_tool_envelope: true,
        tool_disclosure: %{
          "tools" => [
            %{
              "name" => "im_api.imessage.send_message",
              "callable" => true,
              "safety" => "write",
              "input_schema" => %{
                "type" => "object",
                "properties" => %{
                  "connect_id" => %{"type" => "string"},
                  "text" => %{"type" => "string"}
                },
                "required" => ["connect_id", "text"]
              }
            }
          ]
        }
      }

      call = %{
        id: "unacknowledged-send",
        name: "call",
        args: %{
          "tool" => "im_api.imessage.send_message",
          "params" => %{"connect_id" => "imessage-1", "text" => "hello"}
        }
      }

      [result] = SessionToolDispatch.execute([call], ctx)
      assert result.error_class == "imessage_delivery_unknown"

      private = result |> Map.merge(%{role: "tool", tool_call_id: result.id})
      assert private.diagnostic_visibility == "model_only"
      assert Policy.transition(:clean, [private]) == {:required, 0}

      # A later unrelated success completes repair. The failed send must still
      # read as a failure whose effect may have happened.
      assistant = %{role: "assistant", content: "", tool_calls: [call]}
      [redacted, retained] = Policy.sanitize_context([assistant, private], :clean)

      assert [
               %{
                 args: %{"tool" => "im_api.imessage.send_message", "repair_context" => "redacted"}
               }
             ] =
               redacted.tool_calls

      assert %{
               "status" => "failed",
               "error_class" => "imessage_delivery_unknown",
               "effect" => "unknown",
               "retry" => "forbidden",
               "detail" => "redacted"
             } = Jason.decode!(retained.content)

      refute retained.content =~ "private relay detail"
      refute inspect(redacted) =~ "hello"
    end

    test "only identifiers survive, and results made during repair keep their state" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              "id" => "prose-call",
              "name" => "call",
              "args" => %{"tool" => "private text: not a tool", "params" => %{}}
            }
          ]
        },
        %{
          role: "tool",
          tool_call_id: "prose-call",
          status: "error",
          error: true,
          error_class: "Provider said: private detail",
          content: "private detail"
        },
        %{
          role: "tool",
          tool_call_id: "unlisted",
          status: "error",
          error: true,
          error_class: "vm_disk_full",
          content: "private disk path"
        },
        %{
          role: "tool",
          tool_call_id: "repair-send",
          status: "completed",
          visible_reply_origin: "repair",
          content: ~s({"ok":true,"echo":"private detail"})
        },
        %{
          role: "tool",
          tool_call_id: "repair-async",
          status: "async_running",
          visible_reply_origin: "repair",
          content: "private detail"
        }
      ]

      [assistant, prose, unlisted, repaired, pending] = Policy.sanitize_context(messages, :clean)

      assert get_in(assistant, [:tool_calls, Access.at(0), "args"]) == %{
               "repair_context" => "redacted"
             }

      assert Jason.decode!(prose.content) == %{"status" => "failed", "detail" => "redacted"}

      assert Jason.decode!(unlisted.content) == %{
               "status" => "failed",
               "error_class" => "vm_disk_full",
               "detail" => "redacted"
             }

      assert Jason.decode!(repaired.content) == %{"status" => "completed"}
      assert Jason.decode!(pending.content) == %{"status" => "running"}
      refute inspect([assistant, prose, unlisted, repaired, pending]) =~ "private"
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

    test "clean context hides the diagnostic but retains a real repair receipt" do
      private =
        Policy.label_result(%{
          role: "tool",
          tool_call_id: "failed-call",
          status: "error",
          error: true,
          error_class: "invalid_params",
          content: "private provider diagnostic"
        })

      repair_assistant = %{
        role: "assistant",
        content: "using the private diagnostic",
        visible_reply_phase: "repair",
        tool_calls: [
          %{
            "id" => "corrected-call",
            "name" => "call",
            "args" => %{
              "tool" => "im_api.slack.post_message",
              "params" => %{"text" => "corrected message"}
            }
          }
        ],
        provider_meta: %{"private" => true}
      }

      receipt = %{
        role: "tool",
        tool_call_id: "corrected-call",
        status: "completed",
        error: false,
        content: Jason.encode!(%{"ok" => true, "ts" => "123.456"}),
        diagnostic_visibility: "none"
      }

      [sanitized_private, sanitized_assistant, sanitized_receipt] =
        Policy.sanitize_context([private, repair_assistant, receipt], :clean)

      assert Jason.decode!(sanitized_private.content) == %{
               "status" => "failed",
               "error_class" => "invalid_params",
               "detail" => "redacted"
             }

      refute sanitized_private.content =~ "private provider diagnostic"
      assert sanitized_assistant.content == ""
      refute Map.has_key?(sanitized_assistant, :provider_meta)

      assert get_in(sanitized_assistant, [:tool_calls, Access.at(0), "args", "params", "text"]) ==
               "corrected message"

      assert Jason.decode!(sanitized_receipt.content) == %{"ok" => true, "ts" => "123.456"}
    end

    test "state work remains runnable while repair is required and resets on new user input" do
      session_id = "ses1_0000000000000000001"

      state =
        "agt1_0000000000000000001"
        |> SalixAgent.InternalSession.new(session_id)
        |> SalixAgent.InternalSession.apply_event(%{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "required",
          "attempts" => 0
        })
        |> SalixAgent.InternalSession.export()

      assert SessionData.query(state, :visible_reply_repair_required?)
      assert "visible_reply_repair" in SessionData.query(state, :work_reasons)
      assert SessionData.query(state, :has_unprocessed_stable_work?)

      exhausted =
        SessionData.apply_event(state, %{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "exhausted",
          "attempts" => Policy.repair_budget()
        })

      assert SessionData.query(exhausted, :visible_reply_repair_exhausted?)
      refute SessionData.query(exhausted, :has_unprocessed_stable_work?)
      assert SessionData.query(exhausted, :activity_status) == :failed

      still_exhausted =
        SessionData.apply_event(exhausted, %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 1,
          "source_message_id" => "runtime-message-1",
          "role" => "runtime",
          "content" => "late runtime completion"
        })

      assert SessionData.query(still_exhausted, :visible_reply_repair_exhausted?)
      refute "stable_input_pending" in SessionData.query(still_exhausted, :work_reasons)

      reset =
        SessionData.apply_event(still_exhausted, %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 2,
          "source_message_id" => "user-message-1",
          "role" => "user",
          "content" => "try again"
        })

      refute SessionData.query(reset, :visible_reply_repair_required?)
    end

    test "compaction is disabled while private repair context is live" do
      state =
        "agt1_0000000000000000001"
        |> SalixAgent.InternalSession.new("ses1_0000000000000000001")
        |> SalixAgent.InternalSession.apply_event(%{
          "type" => "visible_reply_repair",
          "session_id" => "ses1_0000000000000000001",
          "status" => "required",
          "attempts" => 0
        })
        |> SalixAgent.InternalSession.export()

      refute SalixAgent.Compaction.should_compact?(SalixAgent.InternalSession.open(state),
               threshold: 0
             )
    end

    test "async failures open repair before their runtime notification can drive egress" do
      session_id = "ses1_0000000000000000001"

      state =
        "agt1_0000000000000000001"
        |> SalixAgent.InternalSession.new(session_id)
        |> SalixAgent.InternalSession.export()

      result =
        Policy.label_result(%{
          id: "async-timeout",
          name: "test.tool",
          status: "error",
          error: true,
          error_class: "timeout",
          error_message: "private timeout detail",
          content: "private timeout detail",
          events: []
        })

      pending = %{
        session_id: session_id,
        tool_call_id: "async-timeout",
        tool_name: "test.tool"
      }

      events =
        pending
        |> SalixAgent.AsyncToolResults.internal_events(result)
        |> Policy.async_completion_events(SalixAgent.InternalSession.open(state), result)

      completion = Enum.find(events, &(&1["type"] == "async_tool_call_failed"))
      assert completion["diagnostic_visibility"] == "model_only"

      queue_event = Enum.find(events, &(&1["type"] == "queue_append"))
      assert get_in(queue_event, ["payload", "diagnostic_visibility"]) == "model_only"

      repair_event = Enum.find(events, &(&1["type"] == "visible_reply_repair"))
      assert repair_event["status"] == "required"

      state =
        [queue_event, repair_event]
        |> Enum.reduce(state, &SessionData.apply_event(&2, &1))

      {materialized, true, _hwm} =
        state
        |> SalixAgent.InternalSession.open()
        |> SalixAgent.InternalSession.materialize_pending_input_events()

      state = Enum.reduce(materialized, state, &SessionData.apply_event(&2, &1))
      assert Policy.phase(SalixAgent.InternalSession.open(state)) == {:repair_required, 0}

      [runtime] = Enum.filter(state.messages, &(&1.role == "runtime"))
      assert runtime.content =~ "private timeout detail"
      assert runtime.diagnostic_visibility == "model_only"

      completed =
        SessionData.apply_event(state, %{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "completed"
        })

      [sanitized] =
        completed
        |> SalixAgent.InternalSession.open()
        |> SalixAgent.Compaction.context()
        |> Enum.filter(&(&1.role == "runtime"))

      refute sanitized.content =~ "private timeout detail"
      refute Map.has_key?(sanitized, :source_refs)
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

    test "late async completion cannot reopen an exhausted repair" do
      session_id = "ses1_0000000000000000001"

      state =
        "agt1_0000000000000000001"
        |> SalixAgent.InternalSession.new(session_id)
        |> SalixAgent.InternalSession.apply_event(%{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "exhausted",
          "attempts" => Policy.repair_budget()
        })
        |> SalixAgent.InternalSession.export()

      result =
        Policy.label_result(%{
          id: "late-async-failure",
          status: "error",
          error: true,
          error_class: "timeout",
          content: "private late failure"
        })

      events =
        %{session_id: session_id, tool_call_id: "late-async-failure", tool_name: "test.tool"}
        |> SalixAgent.AsyncToolResults.internal_events(result)
        |> Policy.async_completion_events(SalixAgent.InternalSession.open(state), result)

      assert Enum.any?(events, &(&1["type"] == "async_tool_call_failed"))
      refute Enum.any?(events, &(&1["type"] == "queue_append"))
      refute Enum.any?(events, &(&1["type"] == "visible_reply_repair"))
    end

    test "crash recovery labels synthesized tool diagnostics and opens repair" do
      session_id = "ses1_0000000000000000001"

      session = %State{
        agent_id: "agt1_0000000000000000001",
        session_id: session_id,
        status: :idle,
        next_message_id: 2,
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

      tool_result = Enum.find(events, &(&1["type"] == "tool_result"))
      assert tool_result["diagnostic_visibility"] == "model_only"
      assert tool_result["error_class"] == "runtime_restarted"

      runtime = Enum.find(events, &(&1["type"] == "queue_append"))
      assert get_in(runtime, ["payload", "diagnostic_visibility"]) == "model_only"

      repair = Enum.find(events, &(&1["type"] == "visible_reply_repair"))
      assert repair["status"] == "required"
      assert repair["attempts"] == 0
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

    test "an interrupted LLM recovery exposes only its platform public summary" do
      session_id = "ses1_0000000000000000001"

      session = %State{
        agent_id: "agt1_0000000000000000001",
        session_id: session_id,
        status: :active,
        next_message_id: 2,
        messages: [%{id: 1, role: "user", content: "continue"}]
      }

      {events, 2} = SalixAgent.Repair.plan_session(SalixAgent.InternalSession.open(session))
      runtime = Enum.find(events, &(&1["type"] == "queue_append"))

      assert get_in(runtime, ["payload", "diagnostic_visibility"]) == "user_reportable"

      assert get_in(runtime, ["payload", "public_summary"]) ==
               "The previous response was interrupted. Please try again."

      state = SessionData.apply_event(session, runtime)

      {materialized, true, _hwm} =
        state
        |> SalixAgent.InternalSession.open()
        |> SalixAgent.InternalSession.materialize_pending_input_events()

      state = Enum.reduce(materialized, state, &SessionData.apply_event(&2, &1))

      [sanitized] =
        state
        |> SalixAgent.InternalSession.open()
        |> SalixAgent.Compaction.context()
        |> Enum.filter(&(&1.role == "runtime"))

      assert Jason.decode!(sanitized.content) == %{
               "public_summary" => "The previous response was interrupted. Please try again.",
               "status" => "error"
             }

      refute Map.has_key?(sanitized, :failed_llm_call)
      refute Map.has_key?(sanitized, :source_refs)
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
    test "redacts model-only diagnostics and repair-generation payloads" do
      messages = [
        %{id: 1, role: "user", content: "What does 'tool' is required mean?"},
        %{
          id: 2,
          role: "assistant",
          content: "private diagnostic copied here",
          visible_reply_phase: "repair",
          provider_meta: %{"raw" => "private diagnostic"},
          tool_calls: [
            %{
              "id" => "repair-1",
              "name" => "call",
              "args" => %{"private" => "'tool' is required"}
            }
          ]
        },
        %{
          id: 3,
          role: "tool",
          tool_call_id: "repair-1",
          content: "'tool' is required",
          error_message: "'tool' is required",
          input: "private args",
          diagnostic_visibility: "model_only"
        }
      ]

      [user, assistant, tool] = Policy.sanitize_context(messages, :clean)

      assert user.content == "What does 'tool' is required mean?"
      assert assistant.content == ""
      refute Map.has_key?(assistant, :provider_meta)

      assert get_in(assistant, [:tool_calls, Access.at(0), "args"]) == %{
               "repair_context" => "redacted"
             }

      refute tool.content =~ "'tool' is required"
      refute Map.has_key?(tool, :error_message)
      refute Map.has_key?(tool, :input)
    end

    test "redacts a successful tool value produced during repair by structural origin" do
      messages = [
        %{
          id: 1,
          role: "assistant",
          content: "checking status",
          tool_calls: [
            %{
              "id" => "repair-read",
              "name" => "call",
              "args" => %{
                "tool" => "tool_call.get_status",
                "params" => %{"tool_call_id" => "'tool' is required"}
              }
            }
          ]
        },
        %{
          id: 2,
          role: "tool",
          tool_call_id: "repair-read",
          tool_name: "tool_call.get_status",
          content: ~s({"status":"not_found","tool_call_id":"'tool' is required"}),
          status: "completed",
          diagnostic_visibility: "none",
          visible_reply_origin: "repair"
        }
      ]

      [assistant, tool] = Policy.sanitize_context(messages, :clean)

      assert assistant.content == ""

      assert get_in(assistant, [:tool_calls, Access.at(0), "args"]) == %{
               "tool" => "tool_call.get_status",
               "repair_context" => "redacted"
             }

      refute tool.content =~ "'tool' is required"
      assert Jason.decode!(tool.content) == %{"status" => "completed"}
    end

    test "removes tool arguments from repair-phase live activity" do
      calls = [
        %{
          id: "repair-activity",
          name: "env.exec",
          args: %{"description" => "'tool' is required", "command" => "true"}
        }
      ]

      assert [
               %{
                 "args" => %{},
                 :id => "repair-activity",
                 :name => "env.exec",
                 :args => %{}
               }
             ] = Policy.sanitize_activity_calls(calls, {:repair_required, 0})

      assert Policy.sanitize_activity_calls(calls, :clean) == calls
    end

    test "replaces a reportable provider failure with only its public summary" do
      [tool] =
        Policy.sanitize_context(
          [
            %{
              role: "tool",
              content: "private Slack response",
              error_message: "private Slack response",
              diagnostic_visibility: "user_reportable",
              public_summary: "Slack is temporarily unavailable."
            }
          ],
          :clean
        )

      assert Jason.decode!(tool.content) == %{
               "status" => "error",
               "public_summary" => "Slack is temporarily unavailable."
             }

      refute Map.has_key?(tool, :error_message)
    end

    test "replaces a reportable async runtime failure with only its public summary" do
      [runtime] =
        Policy.sanitize_context(
          [
            %{
              role: "runtime",
              summary: "private provider failure",
              content: "private provider response",
              source_refs: %{"error_message" => "private provider response"},
              diagnostic_visibility: "user_reportable",
              public_summary: "Slack is temporarily unavailable."
            }
          ],
          :clean
        )

      assert runtime.summary == "Slack is temporarily unavailable."

      assert Jason.decode!(runtime.content) == %{
               "status" => "error",
               "public_summary" => "Slack is temporarily unavailable."
             }

      refute Map.has_key?(runtime, :source_refs)
    end

    test "legacy unlabeled tool and runtime failures fail closed in clean context" do
      messages = [
        %{
          role: "assistant",
          content: "legacy repair text",
          tool_calls: [
            %{
              "id" => "legacy-tool",
              "name" => "call",
              "args" => %{"tool" => "help", "params" => %{}}
            }
          ]
        },
        %{
          role: "tool",
          tool_call_id: "legacy-tool",
          content: "'tool' is required",
          status: "guidance"
        },
        %{
          role: "runtime",
          type: "tool_call_failed",
          content: "private legacy timeout"
        },
        %{
          role: "tool",
          tool_call_id: "malformed-public",
          content: "private detail without a public summary",
          status: "error",
          diagnostic_visibility: "user_reportable"
        }
      ]

      [assistant, tool, runtime, malformed_public] =
        Policy.sanitize_context(messages, :clean)

      assert assistant.content == ""

      assert get_in(assistant, [:tool_calls, Access.at(0), "args"]) == %{
               "tool" => "help",
               "repair_context" => "redacted"
             }

      assert Jason.decode!(tool.content) == %{
               "status" => "failed",
               "effect" => "not_applied",
               "retry" => "after_change",
               "note" => "The effect did not happen. Do not repeat this call unchanged.",
               "detail" => "redacted"
             }

      assert Jason.decode!(runtime.content) == %{
               "status" => "failed",
               "type" => "tool_call_failed",
               "detail" => "redacted"
             }

      assert Jason.decode!(malformed_public.content) == %{
               "status" => "failed",
               "detail" => "redacted"
             }

      for message <- [tool, runtime, malformed_public] do
        assert message.diagnostic_visibility == "model_only"
        refute message.content =~ "private"
        refute message.content =~ "'tool' is required"
      end
    end
  end

  describe "nested script tool dispatch" do
    test "allows a nested visible send when every present reply authority is clean" do
      Application.put_env(:salix_agent, :im_provider_mod, NestedWriteIMProvider)
      NestedWriteIMProvider.set_owner(self())

      {{:ok, %{"ok" => true}}, _state} =
        SalixAgent.ScriptRun.host_call(
          "im_api.test.send",
          %{"connect_id" => "test-1", "text" => "clean visible reply"},
          SalixAgent.ScriptRun.new(
            nested_visible_write_ctx(%{
              visible_reply_guard: :clean,
              visible_reply_phase: :clean
            })
          )
        )

      assert_receive {:nested_visible_send, _, %{"params" => %{"text" => "clean visible reply"}}}
    end

    test "reply repair metadata does not gate nested provider calls" do
      Application.put_env(:salix_agent, :im_provider_mod, NestedWriteIMProvider)
      NestedWriteIMProvider.set_owner(self())

      reply_states = [
        %{},
        %{visible_reply_guard: nil, visible_reply_phase: :clean},
        %{visible_reply_guard: {:future_guard, 0}, visible_reply_phase: :clean},
        %{visible_reply_guard: :clean, visible_reply_phase: {:future_phase, 0}},
        %{
          "visible_reply_guard" => {:repair_required, 0, 0, 0},
          visible_reply_guard: :clean,
          visible_reply_phase: :clean
        },
        %{
          "visible_reply_phase" => {:future_phase, 0},
          visible_reply_guard: :clean,
          visible_reply_phase: :clean
        }
      ]

      reply_states
      |> Enum.with_index()
      |> Enum.each(fn {reply_state, index} ->
        text = "independent nested send #{index}"

        {{:ok, %{"ok" => true}}, _state} =
          SalixAgent.ScriptRun.host_call(
            "im_api.test.send",
            %{"connect_id" => "test-1", "text" => text},
            SalixAgent.ScriptRun.new(nested_visible_write_ctx(reply_state))
          )

        assert_receive {:nested_visible_send, _, %{"params" => %{"text" => ^text}}}
      end)
    end

    test "repair metadata does not stamp a successful read as private" do
      ctx =
        %{
          "visible_reply_phase" => {:repair_required, 0},
          visible_reply_guard: :clean,
          visible_reply_phase: :clean
        }
        |> nested_visible_write_ctx()
        |> Map.delete(:llm_tool_envelope)
        |> Map.put(:runtime_kind, :script)

      [result] =
        SessionToolDispatch.execute(
          [
            %{
              id: "nested-repair-read",
              name: "help",
              args: %{"tool" => "im_api.test.send"}
            }
          ],
          ctx
        )

      refute Map.has_key?(result, :visible_reply_origin)
      assert result.content =~ "im_api.test.send"

      [sanitized] =
        Policy.sanitize_context(
          [result |> Map.put(:role, "tool") |> Map.put(:tool_name, "help")],
          :clean
        )

      assert sanitized.content =~ "im_api.test.send"
    end

    test "a private diagnostic does not block a later nested send" do
      Application.put_env(:salix_agent, :im_provider_mod, NestedWriteIMProvider)
      NestedWriteIMProvider.set_owner(self())

      ctx =
        envelope_ctx([
          %{
            "name" => "help",
            "callable" => true,
            "input_schema" => %{
              "type" => "object",
              "properties" => %{"tool" => %{"type" => "string"}},
              "required" => ["tool"]
            }
          },
          %{
            "name" => "im_api.test.send",
            "callable" => true,
            "safety" => "write",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "connect_id" => %{"type" => "string"},
                "text" => %{"type" => "string"}
              },
              "required" => ["connect_id", "text"]
            }
          }
        ])
        |> Map.put(:visible_reply_phase, :clean)
        |> Map.put(:visible_reply_guard, :clean)

      {{:ok, _guidance}, state} =
        SalixAgent.ScriptRun.host_call("help", %{}, SalixAgent.ScriptRun.new(ctx))

      {{:ok, sent}, state} =
        SalixAgent.ScriptRun.host_call(
          "im_api.test.send",
          %{"connect_id" => "test-1", "text" => "'tool' is required"},
          state
        )

      assert sent == %{"ok" => true}
      assert_receive {:nested_visible_send, _, _}

      assert {:tool_failure, diagnostic, "invalid_params", "model_only", nil, [], observations} =
               SalixAgent.ScriptRun.finalize_result("script caught the error", state)

      assert Jason.decode!(diagnostic)["error"] == "missing required params: tool"
      assert observations != []
    end

    test "returns only an adapter-owned public summary to JavaScript" do
      Application.put_env(:salix_agent, :im_provider_mod, PublicFailureIMProvider)

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
      Application.put_env(:salix_agent, :im_provider_mod, FailedInternalSendIMProvider)

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

  defp nested_visible_write_ctx(reply_state) do
    envelope_ctx([
      %{
        "name" => "help",
        "callable" => true,
        "safety" => "read",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"tool" => %{"type" => "string"}},
          "required" => ["tool"]
        }
      },
      %{
        "name" => "im_api.test.send",
        "callable" => true,
        "helpable" => true,
        "safety" => "write",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "connect_id" => %{"type" => "string"},
            "text" => %{"type" => "string"}
          },
          "required" => ["connect_id", "text"]
        }
      }
    ])
    |> Map.merge(reply_state)
  end
end
