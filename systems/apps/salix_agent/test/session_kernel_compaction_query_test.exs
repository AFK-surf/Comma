defmodule SalixAgent.SessionKernelCompactionQueryTest do
  @moduledoc """
  Coverage for the compaction query catalog.

  The request window keeps the current activation's project knowledge in
  place, once, and drops project knowledge from earlier activations.
  """
  use SystemsClock.Case, async: true

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  defp ask(state, name, args \\ nil), do: Resident.query(Resident.open(state), name, args)

  defp base(attrs) do
    struct(State, Map.merge(%{agent_id: "agent-1", session_id: "session-1"}, attrs))
  end

  defp user_message(id, extra \\ %{}),
    do: Map.merge(%{id: id, role: "user", content: "hello #{id}"}, extra)

  defp assistant_message(id),
    do: %{id: id, role: "assistant", content: "reply #{id}", tool_calls: []}

  defp tool_message(id), do: %{id: id, role: "tool", content: ~s({"ok":true})}

  defp runtime_message(id, extra),
    do: Map.merge(%{id: id, role: "runtime", content: "note", type: "wait_expired"}, extra)

  test "live windows leave out duplicate project knowledge" do
    state =
      base(%{
        next_message_id: 8,
        messages: [
          user_message(1),
          runtime_message(2, %{type: "project_knowledge", content: "facts-a"}),
          assistant_message(3),
          tool_message(4),
          runtime_message(5, %{type: "project_knowledge", content: "facts-a"}),
          user_message(6, %{no_wake: true}),
          runtime_message(7, %{type: "project_knowledge", content: "facts-b"})
        ]
      })

    assert Enum.map(ask(state, :request_live_messages), & &1.id) == [1, 2, 3, 4, 6, 7]
    assert Enum.map(ask(state, :compaction_live_messages), & &1.id) == [1, 2, 3, 4, 6, 7]
  end

  test "the conversation tail is what people and Agents received and sent, not raw model text" do
    send = fn id, tool, params ->
      %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}
    end

    state =
      base(%{
        next_message_id: 9,
        compacted_through: 1,
        messages: [
          user_message(1, %{content: "compacted away"}),
          user_message(2, %{content: "Ship 2.4 on Friday."}),
          %{
            id: 3,
            role: "assistant",
            content: "private reasoning text",
            tool_calls: [
              send.("c1", "im_api.internal.send_message", %{
                "conversation_id" => "conv-1",
                "content" => [%{"type" => "text", "text" => "On it."}]
              }),
              send.("c2", "fs.read_file", %{"path" => "/plan.md"}),
              send.("c3", "im_api.internal.task.create", %{"content" => "Draft release notes."})
            ]
          },
          tool_message(4),
          runtime_message(5, %{content: "note"}),
          user_message(6, %{
            content: [%{"type" => "text", "text" => "Notes drafted."}],
            trusted_origin: %{"source_actor_type" => "agent"}
          }),
          user_message(7, %{content: [%{"type" => "image", "url" => "x"}]}),
          %{
            id: 8,
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                id: "c4",
                name: "end_turn",
                args: %{
                  "outcome" => "done",
                  "reply" => %{
                    "tool" => "im_api.slack.reply_message",
                    "params" => %{"text" => "Done: notes are ready."}
                  }
                }
              }
            ]
          }
        ]
      })

    assert ask(state, :request_conversation_tail, 16) == [
             %{"direction" => "in", "from" => "user", "text" => "Ship 2.4 on Friday."},
             %{
               "direction" => "out",
               "tool" => "im_api.internal.send_message",
               "text" => "On it."
             },
             %{
               "direction" => "out",
               "tool" => "im_api.internal.task.create",
               "text" => "Draft release notes."
             },
             %{"direction" => "in", "from" => "agent", "text" => "Notes drafted."},
             %{
               "direction" => "out",
               "tool" => "im_api.slack.reply_message",
               "text" => "Done: notes are ready."
             }
           ]

    assert [%{"text" => "Notes drafted."}, %{"text" => "Done: notes are ready."}] =
             ask(state, :request_conversation_tail, 2)

    assert ask(state, :request_conversation_tail, 0) == []
  end

  describe "handoff_window and zero-stall compaction_prepare" do
    test "partitions native and responses tool pairs without splitting and handles single-user-message Workers" do
      state =
        base(%{
          next_message_id: 10,
          last_ack_message_id: 9,
          messages: [
            user_message(1, %{content: "Run the multi-step worker task"}),
            %{
              id: 2,
              role: "assistant",
              content: "",
              tool_calls: [%{id: "tc_1", name: "fs.read_file", args: %{"path" => "/a"}}]
            },
            %{id: 3, role: "tool", tool_call_id: "tc_1", content: "file-a"},
            %{
              id: 4,
              role: "assistant",
              content: "",
              provider_meta: %{
                "responses_items" => [%{"type" => "function_call", "call_id" => "fc_2"}]
              }
            },
            %{
              id: 5,
              role: "tool",
              provider_meta: %{
                "responses_items" => [%{"type" => "function_call_output", "call_id" => "fc_2"}]
              },
              content: "resp-2"
            },
            %{
              id: 6,
              role: "assistant",
              content: "",
              tool_calls: [%{id: "tc_3", name: "fs.read_file", args: %{"path" => "/c"}}]
            },
            %{id: 7, role: "tool", tool_call_id: "tc_3", content: "file-c"},
            assistant_message(8)
          ]
        })

      win =
        ask(state, :handoff_window, %{
          covered: 0,
          max_bytes: 262_144,
          window_tokens: 128_000,
          ratio: 0.50
        })

      assert win.covered_from == 0
      assert is_binary(win.covered_prefix_digest) and byte_size(win.covered_prefix_digest) == 64
      assert win.through == 5
      assert Enum.map(win.messages, & &1.id) == [1, 2, 3, 4, 5]
      assert is_binary(win.prefix_digest) and byte_size(win.prefix_digest) == 64
      assert win.base_summary_sequence == 0
      assert win.base_compacted_through == 0
      assert win.has_provider_compaction == false

      win_eager =
        ask(state, :handoff_window, %{
          covered: 0,
          max_bytes: 262_144,
          window_tokens: 128_000,
          ratio: 0.85
        })

      assert win_eager.through == 7
      assert Enum.map(win_eager.messages, & &1.id) == [1, 2, 3, 4, 5, 6, 7]
    end

    test "multi-user Router hot-tail protects whole user+assistant turns without splitting" do
      state =
        base(%{
          next_message_id: 7,
          last_ack_message_id: 6,
          messages: [
            user_message(1, %{content: "Q1"}),
            assistant_message(2),
            user_message(3, %{content: "Q2"}),
            assistant_message(4),
            user_message(5, %{content: "Q3"}),
            assistant_message(6)
          ]
        })

      # Normal ratio (< 0.80): keeps last 2 full user+assistant turns ([3,4], [5,6])
      win_normal =
        ask(state, :handoff_window, %{
          covered: 0,
          max_bytes: 262_144,
          window_tokens: 128_000,
          ratio: 0.50
        })

      assert win_normal.through == 2
      assert Enum.map(win_normal.messages, & &1.id) == [1, 2]

      # Near-threshold ratio (>= 0.80): keeps last 1 full user+assistant turn ([5,6])
      win_eager =
        ask(state, :handoff_window, %{
          covered: 0,
          max_bytes: 262_144,
          window_tokens: 128_000,
          ratio: 0.85
        })

      assert win_eager.through == 4
      assert Enum.map(win_eager.messages, & &1.id) == [1, 2, 3, 4]
    end

    test "returns :group_too_large when first eligible tool-closed group exceeds max_bytes" do
      state =
        base(%{
          next_message_id: 5,
          last_ack_message_id: 4,
          messages: [
            user_message(1, %{content: String.duplicate("x", 500)}),
            assistant_message(2),
            user_message(3),
            assistant_message(4)
          ]
        })

      assert :group_too_large ==
               ask(state, :handoff_window, %{
                 covered: 0,
                 max_bytes: 100,
                 window_tokens: 128_000,
                 ratio: 0.85
               })
    end

    test "compaction_prepare admits eligible auto handoff even under matching-fingerprint backoff and rejects ineligible cases" do
      base_state =
        base(%{
          next_message_id: 9,
          last_ack_message_id: 8,
          messages: [
            user_message(1, %{content: String.duplicate("a", 300)}),
            %{
              id: 2,
              role: "assistant",
              content: "",
              tool_calls: [%{id: "tc_1", name: "fs.read_file", args: %{"path" => "/a"}}]
            },
            %{id: 3, role: "tool", tool_call_id: "tc_1", content: "ok"},
            assistant_message(4),
            user_message(5, %{content: "mid turn"}),
            assistant_message(6),
            user_message(7, %{content: "short tail"}),
            assistant_message(8)
          ]
        })

      # Probe real fingerprint from a non-handoff compaction_prepare
      probe_facts = %{
        "threshold" => 100,
        "context_tokens" => 4_096,
        "config" => %{
          "protocol" => "openai",
          "model" => "gpt-test",
          "context_tokens" => 4_096
        }
      }

      assert {:summarize, probe_plan} =
               ask(base_state, :compaction_prepare, {:maybe_compact, probe_facts})

      real_fp = probe_plan["fingerprint"]

      state = %{
        base_state
        | compaction_failure: %{
            "config_fingerprint" => real_fp,
            "retryable" => true,
            "next_retry_at" => 9_999_999_999
          }
      }

      # Without handoff, real matching fingerprint hits compaction_backoff
      assert {:done, %{"status" => "noop", "reason" => reason}, _} =
               ask(state, :compaction_prepare, {:maybe_compact, probe_facts})

      assert reason =~ "compaction_backoff"

      win =
        ask(state, :handoff_window, %{
          covered: 0,
          max_bytes: 262_144,
          window_tokens: 4_096,
          ratio: 0.50
        })

      assert win.through == 4

      valid_handoff = %{
        "summary" => "- Active goal: finish D7",
        "covered_message_id" => win.through,
        "base_summary_sequence" => 0,
        "base_compacted_through" => 0,
        "prefix_digest" => win.prefix_digest
      }

      facts = put_in(probe_facts, ["config", "handoff"], valid_handoff)

      # Eligible auto compaction bypasses real backoff and narrows plan["live"] to <= H
      assert {:summarize, plan} = ask(state, :compaction_prepare, {:maybe_compact, facts})
      assert plan["last_id"] == 4
      assert Enum.map(plan["live"], & &1.id) == [1, 2, 3, 4]

      assert plan["handoff"] ==
               "<compacted-context>\n- Active goal: finish D7\n</compacted-context>"

      # Explicit :compact NEVER uses handoff
      assert {:summarize, explicit_plan} = ask(base_state, :compaction_prepare, {:compact, facts})
      assert explicit_plan["last_id"] == 8
      refute Map.has_key?(explicit_plan, "handoff")

      # Mismatched prefix_digest falls back to normal compaction
      bad_digest_facts = put_in(facts, ["config", "handoff", "prefix_digest"], "deadbeef")

      assert {:summarize, fallback_plan} =
               ask(base_state, :compaction_prepare, {:maybe_compact, bad_digest_facts})

      assert fallback_plan["last_id"] == 8
      refute Map.has_key?(fallback_plan, "handoff")

      # Non-tool-closed boundary (id 2 splits tc_1 from tool result 3) is rejected
      bad_boundary_facts = put_in(facts, ["config", "handoff", "covered_message_id"], 2)

      assert {:summarize, boundary_fallback} =
               ask(base_state, :compaction_prepare, {:maybe_compact, bad_boundary_facts})

      refute Map.has_key?(boundary_fallback, "handoff")

      # provider_compaction present is ineligible
      provider_state = %{
        base_state
        | provider_compaction: %{
            "protocol" => "responses",
            "items" => [%{"type" => "compaction"}]
          }
      }

      assert {:summarize, provider_fallback} =
               ask(provider_state, :compaction_prepare, {:maybe_compact, facts})

      refute Map.has_key?(provider_fallback, "handoff")

      # Overflow recovery includes unfinished activation input (20 KiB) in 16 KiB tail cap
      unfinished_overflow_state = %{
        base_state
        | next_message_id: 10,
          last_ack_message_id: 8,
          messages:
            base_state.messages ++
              [user_message(9, %{content: String.duplicate("u", 20_000)})]
      }

      recovery_facts = Map.put(facts, "overflow_recovery", true)

      assert {:summarize, recovery_fallback} =
               ask(
                 unfinished_overflow_state,
                 :compaction_prepare,
                 {:maybe_compact, recovery_facts}
               )

      refute Map.has_key?(recovery_fallback, "handoff")

      # CompactionHost.commit rechecks surviving tail cap & tool closure on interleaved appends
      assert {:summarize, recovery_plan} =
               ask(base_state, :compaction_prepare, {:maybe_compact, recovery_facts})

      assert is_binary(recovery_plan["handoff"])
      assert recovery_plan["handoff_tail_cap"] == 16_384

      # Small harmless append after H commits cleanly
      small_append_state = %{
        base_state
        | next_message_id: 10,
          messages: base_state.messages ++ [user_message(9, %{content: "tiny follow-up"})]
      }

      assert {:ok, _events, %{"status" => "compacted"}, true} =
               ask(
                 small_append_state,
                 :compaction_commit,
                 {recovery_plan, {:summary, recovery_plan["handoff"]}, "prompt"}
               )

      # Large 20 KiB append after H exceeds 16 KiB overflow tail cap -> stale_compaction_snapshot
      large_append_state = %{
        base_state
        | next_message_id: 10,
          messages:
            base_state.messages ++
              [user_message(9, %{content: String.duplicate("x", 20_000)})]
      }

      assert {:error, {:stale_compaction_snapshot, %{reason: "handoff_tail_exceeded"}}} =
               ask(
                 large_append_state,
                 :compaction_commit,
                 {recovery_plan, {:summary, recovery_plan["handoff"]}, "prompt"}
               )

      # Interleaved tool result after H referencing a tool call inside <= H invalidates boundary
      crossing_tool_state = %{
        base_state
        | next_message_id: 10,
          messages:
            base_state.messages ++
              [%{id: 9, role: "tool", tool_call_id: "tc_1", content: "late crossing result"}]
      }

      assert {:error, {:stale_compaction_snapshot, %{reason: "handoff_boundary_invalidated"}}} =
               ask(
                 crossing_tool_state,
                 :compaction_commit,
                 {recovery_plan, {:summary, recovery_plan["handoff"]}, "prompt"}
               )
    end
  end
end
