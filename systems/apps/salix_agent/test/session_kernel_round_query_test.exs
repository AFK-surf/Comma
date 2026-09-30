defmodule SalixAgent.SessionKernelRoundQueryTest do
  @moduledoc """
  Coverage for the round/actor query catalog in
  `runtime/VerifiedKernel/Session/Query/Round.lean`.

  Each case asserts the kernel's answer for a fixture state that exercises
  activation provenance, Telegram and Slack welcome source scopes, async call
  lookup, queue admission, waits, and the delivery stamps phase telemetry
  reads. The terminal reply assertions protect the separation between the
  human reply identity and execution provenance.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session, as: Resident

  defp ask(state, name, args \\ nil), do: Resident.query(Resident.open(state), name, args)

  ## Provider request tail ---------------------------------------------------

  test "the request tail keeps full reminders for a pre-catalog prompt and flags for a catalog prompt" do
    catalog = ask(base(), :provider_request_part, {:turn_reminder_catalog})
    args = {nil, false, %{}, %{"tools" => []}, true, :neutral, nil, [], "stream"}

    cases = [
      {"telegram request", "final_reply=on"},
      {"channel onboarding", "onboarding=on"}
    ]

    for {label, flag} <- cases do
      [_, rule] = Regex.run(~r/^- #{Regex.escape(flag)}: (.+)$/m, catalog)
      state = fixture(label)

      legacy =
        ask(%{state | system_prompt: "prompt from before the catalog"}, :provider_dispatch, args)

      assert %{role: "summary", content: legacy_tail} = List.last(legacy), label
      assert legacy_tail =~ rule, label
      refute Enum.any?(legacy, &(is_binary(&1[:content]) and &1[:content] =~ ~r/^turn: /)), label

      modern = ask(%{state | system_prompt: "prompt\n\n" <> catalog}, :provider_dispatch, args)
      assert %{role: "summary", content: modern_tail} = List.last(modern), label
      assert modern_tail =~ ~r/^turn: /, label
      assert modern_tail =~ flag, label
      # The rule text appears once, in the stored prompt, never as a tail block.
      assert Enum.count(modern, &(is_binary(&1[:content]) and &1[:content] =~ rule)) ==
               1,
             label

      assert hd(modern).content =~ rule, label

      # Both catalog flags and full terminal/onboarding reminders retain their
      # control text at the Responses transport boundary without becoming users.
      for {prompt, tail} <- [
            {"prompt from before the catalog", legacy_tail},
            {"prompt\n\n" <> catalog, modern_tail}
          ] do
        encoded_args =
          {nil, false, %{}, %{"tools" => []}, true, "responses", %{model: "test"}, [], "stream"}

        body =
          ask(%{state | system_prompt: prompt}, :provider_dispatch, encoded_args)
          |> Jason.decode!()

        assert List.last(body["input"]) == %{
                 "role" => "developer",
                 "content" => "<system>\n" <> tail <> "\n</system>"
               }

        assert Enum.any?(body["input"], &(&1["role"] == "user"))
      end
    end
  end

  ## Fixtures ---------------------------------------------------------------

  defp base(attrs \\ %{}) do
    struct(State, Map.merge(%{agent_id: "agent-1", session_id: "session-1"}, attrs))
  end

  defp telegram_origin(source \\ "tg-1") do
    %{
      "provider" => "telegram",
      "source_actor_type" => "provider_user",
      "source_message_id" => source,
      "provider_context" => %{"connect_id" => "c-1", "chat_id" => "42"}
    }
  end

  defp onboarding_origin(source \\ "im_provider:slack:c-1:channel_joined:C9:E7") do
    %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "source_message_id" => source,
      "provider_context" => %{
        "event_type" => "member_joined_channel",
        "connect_id" => "c-1",
        "channel_id" => "C9",
        "event_id" => "E7"
      }
    }
  end

  defp user_message(id, extra) do
    Map.merge(%{id: id, role: "user", content: "hello #{id}"}, extra)
  end

  defp runtime_message(id, extra) do
    Map.merge(%{id: id, role: "runtime", content: "note", type: "tool_call_completed"}, extra)
  end

  defp telegram_session(extra \\ %{}) do
    base(
      Map.merge(
        %{
          next_message_id: 3,
          messages: [
            user_message(2, %{
              source_message_id: "tg-1",
              trusted_origin: telegram_origin(),
              delivered_at_ms: 1_700_000_000_000
            })
          ]
        },
        extra
      )
    )
  end

  defp fixtures do
    [
      {"empty", base()},
      {"telegram request", telegram_session()},
      {"telegram request acked", telegram_session(%{last_ack_message_id: 2})},
      {"two human requests",
       telegram_session(%{
         next_message_id: 4,
         messages: [
           user_message(2, %{source_message_id: "tg-1", trusted_origin: telegram_origin()}),
           user_message(3, %{
             source_message_id: "tg-2",
             trusted_origin: telegram_origin("tg-2")
           })
         ]
       })},
      {"mismatched origin source id",
       telegram_session(%{
         messages: [
           user_message(2, %{
             source_message_id: "tg-other",
             trusted_origin: telegram_origin()
           })
         ]
       })},
      {"channel onboarding",
       base(%{
         next_message_id: 3,
         messages: [
           user_message(2, %{
             source_message_id: "im_provider:slack:c-1:channel_joined:C9:E7",
             trusted_origin: onboarding_origin()
           })
         ]
       })},
      {"channel onboarding bad event id",
       base(%{
         next_message_id: 3,
         messages: [
           user_message(2, %{
             source_message_id: "im_provider:slack:c-1:channel_joined:C9:OTHER",
             trusted_origin: onboarding_origin("im_provider:slack:c-1:channel_joined:C9:OTHER")
           })
         ]
       })},
      {"onboarding with completed send",
       base(%{
         next_message_id: 5,
         messages: [
           user_message(2, %{
             source_message_id: "im_provider:slack:c-1:channel_joined:C9:E7",
             trusted_origin: onboarding_origin()
           }),
           %{id: 3, role: "assistant", content: "", tool_calls: [%{"id" => "call-1"}]},
           %{
             id: 4,
             role: "tool",
             tool_call_id: "call-1",
             tool_name: "im_api.slack.post_message",
             status: "completed",
             content: "ok"
           }
         ]
       })},
      {"onboarding with running send",
       base(%{
         next_message_id: 4,
         messages: [
           user_message(2, %{
             source_message_id: "im_provider:slack:c-1:channel_joined:C9:E7",
             trusted_origin: onboarding_origin()
           }),
           %{
             id: 3,
             role: "tool",
             tool_call_id: "call-1",
             tool_name: "im_api.slack.post_message",
             status: "async_running",
             content: "started"
           }
         ]
       })},
      {"runtime continuation",
       base(%{
         next_message_id: 5,
         messages: [
           user_message(2, %{source_message_id: "tg-1", trusted_origin: telegram_origin()}),
           runtime_message(3, %{
             trusted_origin: telegram_origin(),
             trusted_origins: [telegram_origin()],
             trusted_origin_source_message_ids: ["tg-1"],
             source_tool_call_id: "call-1"
           }),
           runtime_message(4, %{
             trusted_origin: %{
               "provider" => "slack",
               "source_actor_type" => "provider_user",
               "source_message_id" => "other"
             },
             trusted_origin_source_message_ids: ["other"]
           })
         ]
       })},
      {"no-wake user context",
       base(%{
         next_message_id: 4,
         messages: [
           user_message(2, %{
             source_message_id: "tg-1",
             no_wake: true,
             trusted_origin: telegram_origin()
           }),
           user_message(3, %{source_message_id: "tg-2", trusted_origin: telegram_origin("tg-2")})
         ]
       })},
      {"assistant after input",
       base(%{
         next_message_id: 4,
         messages: [
           user_message(2, %{
             source_message_id: "tg-1",
             trusted_origin: telegram_origin(),
             delivered_at_ms: 1_700_000_000_000
           }),
           %{id: 3, role: "assistant", content: "hi", tool_calls: []}
         ]
       })},
      {"two stamped inputs",
       base(%{
         next_message_id: 4,
         messages: [
           user_message(2, %{
             source_message_id: "tg-1",
             trusted_origin: telegram_origin(),
             delivered_at_ms: 1_700_000_000_500
           }),
           user_message(3, %{
             source_message_id: "tg-2",
             trusted_origin: telegram_origin("tg-2"),
             delivered_at_ms: 1_700_000_000_100
           })
         ]
       })},
      {"no-wake stamped context",
       base(%{
         next_message_id: 4,
         messages: [
           user_message(2, %{
             source_message_id: "tg-1",
             no_wake: true,
             trusted_origin: telegram_origin(),
             delivered_at_ms: 1_700_000_000_100
           }),
           user_message(3, %{
             source_message_id: "tg-2",
             trusted_origin: telegram_origin("tg-2"),
             delivered_at_ms: 1_700_000_000_500
           })
         ]
       })},
      {"queue and dedupe",
       base(%{
         next_queue_id: 4,
         input_dedupe: MapSet.new(["tg-1", "tg-2"]),
         input_queue: [
           %{"queue_id" => 1, "kind" => "user_message", "payload" => %{"content" => "a"}},
           %{"queue_id" => 2, "kind" => "user_message", "payload" => %{"content" => "b"}}
         ]
       })},
      {"async calls",
       base(%{
         async_tool_calls: %{
           "run-1" => %{"status" => "running", "tool_name" => "search"},
           "done-1" => %{"status" => "completed", "tool_name" => "search"},
           "cancel-1" => %{"status" => "cancelled"},
           "bare-1" => %{"tool_name" => "search"}
         },
         async_results: [
           %{"seq" => 4, "tool_call_id" => "done-1", "result" => %{"ok" => true}},
           %{"seq" => 7, "tool_call_id" => "other", "result" => %{"ok" => false}}
         ]
       })},
      {"wait expired",
       base(%{
         wait: %{
           "wait_id" => "wait-1",
           "source" => "wait_for",
           "reason" => "tool",
           "timeout_seconds" => 1,
           "deadline_ms" => 1_000
         }
       })},
      {"wait pending",
       base(%{
         wait: %{
           "wait_id" => "wait-2",
           "source" => "wait_for",
           "reason" => "tool",
           "timeout_seconds" => 600,
           "deadline_ms" => 4_000_000_000_000
         }
       })},
      {"wait without deadline",
       base(%{wait: %{"wait_id" => "wait-3", "source" => "wait_for", "reason" => "tool"}})}
    ]
  end

  defp fixture(label) do
    {^label, state} = Enum.find(fixtures(), fn {name, _} -> name == label end)
    state
  end

  ## Round ------------------------------------------------------------------

  test "current_source_ids includes inherited continuations" do
    # The second runtime message inherits a foreign source, which stays in the
    # activation's provenance set even though it is not a declared source id.
    assert ask(fixture("runtime continuation"), :current_source_ids) == ["tg-1", "other"]
  end

  test "current_turn_source resolves the declared source and its origin" do
    assert ask(fixture("telegram request"), :current_turn_source, ["tg-1"]) ==
             {"tg-1", telegram_origin()}

    # A no-wake carrier cannot own the wakeable source, but its declared origin
    # still supplies this turn's provenance.
    assert ask(fixture("no-wake user context"), :current_turn_source, ["tg-1"]) ==
             {"tg-1", telegram_origin()}
  end

  test "async_result_by_seq finds a stored result" do
    assert ask(fixture("async calls"), :async_result_by_seq, 4)["tool_call_id"] == "done-1"
  end

  ## Phase telemetry --------------------------------------------------------

  test "earliest_delivered_at_ms reports the oldest wakeable stamp" do
    assert ask(fixture("two stamped inputs"), :earliest_delivered_at_ms, ["tg-1", "tg-2"]) ==
             1_700_000_000_100

    assert ask(fixture("assistant after input"), :earliest_delivered_at_ms, ["tg-1"]) == nil

    # A no_wake delivery schedules no round, so it never reports a wait of
    # its own even when it carries the oldest stamp of the set.
    assert ask(fixture("no-wake stamped context"), :earliest_delivered_at_ms, ["tg-1", "tg-2"]) ==
             1_700_000_000_500

    assert ask(fixture("no-wake stamped context"), :earliest_delivered_at_ms, ["tg-1"]) == nil
  end

  ## Actor ------------------------------------------------------------------

  test "input_queue_length counts queued input" do
    assert ask(fixture("queue and dedupe"), :input_queue_length) == 2
  end

  test "duplicate_delivery? reports known and unknown source ids" do
    assert ask(fixture("queue and dedupe"), :duplicate_delivery?, "tg-1") == true
    assert ask(fixture("queue and dedupe"), :duplicate_delivery?, "tg-9") == false
  end

  test "wait_expired? follows the wall clock" do
    assert ask(fixture("wait expired"), :wait_expired?) == true
    assert ask(fixture("wait pending"), :wait_expired?) == false
    assert ask(fixture("wait without deadline"), :wait_expired?) == false
  end

  test "completion_target classifies running, settled and unknown calls" do
    state = fixture("async calls")
    assert {:running, %{"status" => "running"}} = ask(state, :completion_target, "run-1")
    assert ask(state, :completion_target, "done-1") == :already_resolved
    assert ask(state, :completion_target, "cancel-1") == :already_resolved
    assert {:running, %{"tool_name" => "search"}} = ask(state, :completion_target, "bare-1")
    assert ask(state, :completion_target, "missing") == :unknown
  end

  ## Terminal reply ---------------------------------------------------------

  test "terminal_reply_source_scope for every carrier shape" do
    assert ask(fixture("telegram request"), :terminal_reply_source_scope) == %{
             "source_message_id" => "tg-1",
             "context_source_message_ids" => ["tg-1"],
             "trusted_origin" => telegram_origin()
           }

    assert ask(fixture("two human requests"), :terminal_reply_source_scope) == nil
    assert ask(fixture("mismatched origin source id"), :terminal_reply_source_scope) == nil
    assert ask(fixture("channel onboarding bad event id"), :terminal_reply_source_scope) == nil

    assert %{"source_message_id" => "im_provider:slack:c-1:channel_joined:C9:E7"} =
             ask(fixture("channel onboarding"), :terminal_reply_source_scope)
  end

  test "runtime provenance changes execution sources without changing the human reply identity" do
    state = fixture("runtime continuation")
    scope = ask(state, :terminal_reply_source_scope)
    assert scope["source_message_id"] == "tg-1"
    assert scope["trusted_origin"] == telegram_origin()
    assert scope["context_source_message_ids"] == ["tg-1", "other"]
    assert ask(state, :current_source_ids) == ["tg-1", "other"]

    binding = %{
      "kind" => "telegram",
      "agent_id" => "agent-1",
      "session_id" => "session-1",
      "last_ack_message_id" => 0,
      "source_message_id" => "tg-1",
      "trusted_origin" => telegram_origin(),
      "connect_id" => "c-1",
      "chat_id" => "42",
      "message_thread_id" => "",
      "context_source_message_ids" => ["tg-1", "other"],
      "assistant_id" => 5,
      "tool_call_id" => "reply-1"
    }

    assert ask(state, :terminal_reply_matches?, binding)
    refute ask(state, :terminal_reply_matches?, Map.put(binding, "chat_id", "other"))
    refute ask(state, :terminal_reply_matches?, Map.put(binding, "assistant_id", 3))

    refute ask(
             state,
             :terminal_reply_matches?,
             Map.put(binding, "context_source_message_ids", ["tg-1"])
           )

    refute ask(fixture("two human requests"), :terminal_reply_matches?, binding)
  end

  test "terminal_reply_reminder_active? follows the unacked request" do
    assert ask(fixture("telegram request"), :terminal_reply_reminder_active?) == true
    assert ask(fixture("telegram request acked"), :terminal_reply_reminder_active?) == false
    assert ask(fixture("channel onboarding"), :terminal_reply_reminder_active?) == false
  end

  test "terminal_reply_running? reports running async calls" do
    assert ask(fixture("async calls"), :terminal_reply_running?) == true
    assert ask(fixture("empty"), :terminal_reply_running?) == false
  end

  test "terminal_reply_matches? accepts a held binding and rejects another agent" do
    binding = %{
      "agent_id" => "agent-1",
      "session_id" => "session-1",
      "last_ack_message_id" => 0,
      "kind" => "telegram",
      "trusted_origin" => telegram_origin(),
      "connect_id" => "c-1",
      "chat_id" => "42",
      "message_thread_id" => "",
      "source_message_id" => "tg-1",
      "context_source_message_ids" => ["tg-1"],
      "assistant_id" => 3,
      "tool_call_id" => "call-1"
    }

    assert ask(fixture("telegram request"), :terminal_reply_matches?, binding) == true

    assert ask(
             fixture("telegram request"),
             :terminal_reply_matches?,
             Map.put(binding, "agent_id", "other")
           ) == false
  end

  test "onboarding settlement reads" do
    assert ask(fixture("onboarding with completed send"), :onboarding_send_completed?, 2) == true
    assert ask(fixture("onboarding with running send"), :onboarding_send_completed?, 2) == false
    assert ask(fixture("telegram request"), :onboarding_source_message_id, "tg-1") == 2
    assert ask(fixture("telegram request"), :onboarding_source_message_id, "missing") == nil
  end
end
