defmodule SalixVerifiedKernel.LoopHostTest do
  # The loop's host data: the kernel builds tool-batch events, records, reply
  # scopes and call operations, so a host answers each loop effect with one
  # query and its own I/O facts.
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.{AgentLoop, Session}

  @origin %{
    "provider" => "internal",
    "source_actor_type" => "user",
    "conversation_kind" => "user_chat",
    "conversation_id" => "alice",
    "source_message_id" => "m1"
  }

  defp session(patch \\ %{}) do
    Session.new("agent", "ses1_0000000000000000001")
    |> Session.export()
    |> Map.merge(%{
      status: :active,
      next_message_id: 2,
      last_seq: 1,
      messages: [
        %{
          id: 1,
          seq: 1,
          role: "user",
          content: "hi",
          source_message_id: "m1",
          trusted_origin: @origin
        }
      ]
    })
    |> Map.merge(patch)
    |> Session.open()
  end

  defp slack_reply(status \\ "completed") do
    %{
      id: "c1",
      name: "im_api.slack.reply_message",
      status: status,
      content: "ok",
      input: ~s({"connect_id":"conn","channel":"C1","thread_ts":"1.0","text":"x"})
    }
  end

  describe "tool_batch_events" do
    test "results take consecutive ids from the next message id" do
      results = [
        %{id: "c1", name: "fs.list", status: "completed", content: "a", output: "a"},
        %{
          id: "c2",
          name: "fs.read",
          status: "error",
          content: "b",
          started_at: 1_790_000_000_000,
          duration_ms: 5
        }
      ]

      assert {:ok, events, 3} =
               Session.query(session(), :tool_batch_events, {%{}, results, %{turn_id: "turn-1"}})

      [first, second | _] = Enum.filter(events, &(&1["type"] == "tool_result"))
      assert {first["message_id"], second["message_id"]} == {2, 3}
      assert first["error"] == false and first["output"] == nil and first["turn_id"] == "turn-1"

      assert second["execution_timing"]["completed_at_ms"] == 1_790_000_000_005
      assert second["completed_at"] == 1_790_000_000_005
    end

    test "a side-effect event that retires input fails the batch" do
      result = %{
        id: "c1",
        name: "x",
        status: "completed",
        content: "",
        events: [%{"type" => "queue_ack"}]
      }

      assert {:error, {:invalid_tool_side_effect_event, "queue_ack"}} =
               Session.query(session(), :tool_batch_events, {%{}, [result], %{}})
    end

    test "a successful Slack reply resolves its exact obligation target" do
      {:ok, events, _hwm} =
        Session.query(session(), :tool_batch_events, {%{}, [slack_reply()], %{}})

      [resolved] = Enum.filter(events, &(&1["type"] == "provider_reply_obligation_resolved"))

      target = %{
        "provider" => "slack",
        "connect_id" => "conn",
        "channel" => "C1",
        "thread_ts" => "1.0"
      }

      assert resolved["obligation_key"] ==
               Session.query(session(), :normalize_obligation, target)["key"]

      {:ok, failed, _hwm} =
        Session.query(session(), :tool_batch_events, {%{}, [slack_reply("error")], %{}})

      refute Enum.any?(failed, &(&1["type"] == "provider_reply_obligation_resolved"))
    end

    test "a Task creation adds a card candidate unless it is a Triage delegation" do
      create = fn params ->
        %{
          id: "c1",
          name: "im_api.internal.task.create",
          status: "completed",
          content: ~s({"conversation_id":" task-1 "}),
          args: params
        }
      end

      {:ok, events, _hwm} =
        Session.query(session(), :tool_batch_events, {%{}, [create.(%{})], %{}})

      assert [%{"conversation_id" => "task-1", "limit" => 1000}] =
               Enum.filter(events, &(&1["type"] == "provider_card_obligation_added"))

      {:ok, triage, _hwm} =
        Session.query(session(), :tool_batch_events, {
          %{},
          [create.(%{"triage_delegation_ref" => "t"})],
          %{}
        })

      refute Enum.any?(triage, &(&1["type"] == "provider_card_obligation_added"))
    end
  end

  describe "loop_record" do
    defp spec(mode, calls, extra \\ %{}) do
      Map.merge(
        %{
          "mode" => mode,
          "content" => "",
          "calls" => calls,
          "provider_meta" => nil,
          "trace_meta" => %{"model" => "m", "usage" => %{"input_tokens" => 7}},
          "replaced_calls" => false,
          "vphase" => :clean
        },
        extra
      )
    end

    defp facts(extra \\ %{}),
      do:
        Map.merge(
          %{"role" => "router", "canonical_router" => true, "source_ids" => ["m1"]},
          extra
        )

    defp call(name, args), do: %{id: "c-#{name}", name: name, args: args}

    test "the assistant follows the activation's runtime messages" do
      leading = [%{"type" => "context", "content" => "note", "created_at" => 5}]
      calls = [call("call", %{"tool" => "fs.list", "params" => %{}})]

      %{"record" => record, "scope" => scope} =
        Session.query(
          session(),
          :loop_record,
          {spec("tools", calls), facts(%{"leading" => leading})}
        )

      assert record["base"] == 2 and record["aid"] == 3
      [runtime, assistant, activity] = record["intent"]
      assert runtime["message_id"] == 2 and runtime["created_at"] == 5 and runtime["no_wake"]
      assert assistant["message_id"] == 3 and assistant["input_tokens"] == 7
      assert activity["activity_status"] == "execution"
      assert scope["assistant_id"] == 3 and scope["eligible"] == true
      assert record["admission"] == nil and record["speculative"] == false
    end

    test "a batch of sends only is messaging" do
      send = %{"tool" => "im_api.internal.send_message", "params" => %{}}

      phase = fn calls ->
        %{"record" => %{"intent" => intent}} =
          Session.query(session(), :loop_record, {spec("tools", calls), facts()})

        List.last(intent)["activity_status"]
      end

      assert phase.([call("call", send)]) == "messaging"
      assert phase.([call("im_api.internal.send_message", %{})]) == "messaging"
      assert phase.([call(" im_api.internal.send_message ", %{})]) == "messaging"

      assert phase.([call("im_api.internal.send_message", %{}), call("fs.read", %{})]) ==
               "execution"

      assert phase.([call("reply", %{"text" => "retired"})]) == "execution"
    end

    test "a settled end_turn gets its output item in Jason key order" do
      items = [%{"type" => "function_call", "call_id" => "e1", "name" => "end_turn"}]

      %{"record" => record} =
        Session.query(session(), :loop_record, {
          spec("final", [], %{
            "provider_meta" => %{"responses_items" => items},
            "terminal_call" => %{id: "e1"},
            "terminal_result" => %{"status" => "settled", "outcome" => "done"}
          }),
          facts()
        })

      assert record["aid"] == 2

      assert [_, %{"type" => "function_call_output", "call_id" => "e1", "output" => output}] =
               record["assistant"]["provider_meta"]["responses_items"]

      assert output == ~s({"outcome":"done","status":"settled"})
    end

    test "replaced calls adopt the canonical calls and settle the dropped one" do
      items = [
        %{"type" => "function_call", "call_id" => "keep", "name" => "old", "arguments" => "{}"},
        %{"type" => "function_call_output", "call_id" => "keep", "output" => "stale"},
        %{"type" => "function_call", "call_id" => "drop", "name" => "gone", "arguments" => "{}"}
      ]

      calls = [
        %{id: "keep", name: "call", args: %{"tool" => "t", "params" => %{"b" => 1, "a" => 2}}},
        %{id: "new", name: "call", args: %{}}
      ]

      %{"record" => record} =
        Session.query(session(), :loop_record, {
          spec("tools", calls, %{
            "replaced_calls" => true,
            "provider_meta" => %{"responses_items" => items}
          }),
          facts()
        })

      assistant = Enum.find(record["intent"], &(&1["type"] == "assistant"))

      assert [kept, drop, dropped, added] = assistant["provider_meta"]["responses_items"]

      assert kept["name"] == "call" and
               kept["arguments"] == ~s({"params":{"a":2,"b":1},"tool":"t"})

      assert drop["call_id"] == "drop"
      assert dropped["output"] == ~s({"reason":"repair_required","status":"not_settled"})
      assert added["call_id"] == "new"
    end
  end

  describe "call envelope" do
    test "decodes one operation and keeps the reply intent" do
      args = %{"tool" => " fs.read ", "params" => %{"path" => "a"}, "reply_mode" => "final"}

      assert {:ok, "fs.read", %{"path" => "a"}, nil, %{"reply_mode" => "final"}} =
               AgentLoop.call_envelope(args)
    end

    test "accepts one repeated params wrapper and rejects a nested envelope" do
      wrapped = %{"params" => %{"tool" => "fs.read", "params" => %{}}}
      assert {:ok, "fs.read", %{}, nil, %{}} = AgentLoop.call_envelope(wrapped)

      assert {:error, _reason, "call"} =
               AgentLoop.call_envelope(%{"tool" => "call", "params" => %{}})

      assert {:error, _reason, "fs.read"} = AgentLoop.call_envelope(%{"tool" => "fs.read"})
      assert {:error, _reason, ""} = AgentLoop.call_envelope("not a map")
    end
  end

  describe "call_envelopes" do
    test "a call becomes its target; a direct tool and a call of wait_for become guidance" do
      send = %{
        "tool" => "im_api.internal.send_message",
        "params" => %{"connect_id" => "internal", "conversation_id" => "alice", "content" => []}
      }

      calls = [
        %{id: "c1", name: "call", args: send},
        %{id: "c2", name: "fs.read", args: %{}},
        %{id: "c3", name: "call", args: %{"tool" => "wait_for", "params" => %{}}}
      ]

      [target, direct, wait] = Session.query(session(), :call_envelopes, {calls, true})

      assert target[:name] == "im_api.internal.send_message" and target[:args] == send["params"]
      assert direct[:name] == "call" and direct[:guidance_error] =~ "call envelope"
      assert direct[:guidance_reason] == "envelope_misuse" and direct[:guidance_tool] == "fs.read"

      assert wait[:guidance_tool] == "wait_for" and
               wait[:guidance_error] =~ "call wait_for directly"
    end
  end

  describe "conversation header" do
    test "an internal origin that asks for it shows its conversation in each request" do
      shown = Map.put(@origin, "show_conversation", true)
      [message] = Session.export(session()).messages
      state = session(%{status: :idle, messages: [%{message | trusted_origin: shown}]})

      config = %{
        "role" => "router",
        "canonical_router" => true,
        "nonce" => 1,
        "protocol" => :neutral
      }

      {:ok, messages, _facts} = Session.query(state, :round_request, config)
      assert Enum.count(messages, &(&1[:content] == "[conversation alice] hi")) == 1

      {:ok, plain, _facts} = Session.query(session(%{status: :idle}), :round_request, config)
      assert Enum.any?(plain, &(&1[:content] == "hi"))
    end
  end

  describe "round_request" do
    test "the request and the facts the model response carries" do
      config = %{
        "role" => "router",
        "canonical_router" => true,
        "nonce" => 9,
        "protocol" => :neutral
      }

      {:ok, messages, facts} = Session.query(session(%{status: :idle}), :round_request, config)

      assert Enum.any?(messages, &(&1[:content] == "hi"))
      assert facts["id_snapshot"] == 2 and facts["source_ids"] == ["m1"] and facts["nonce"] == 9
      assert facts["vphase"] == :clean and facts["guard"] == :clean

      assert facts["trace"] == %{
               "request_summary_sequence" => 0,
               "request_compacted_through" => 0,
               "request_input_through" => 1
             }
    end
  end
end
