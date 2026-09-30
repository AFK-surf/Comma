defmodule SalixLlm.ConvertRuntimeMessageTest do
  use ExUnit.Case, async: true

  alias SalixLlm.{Convert, ConvertOpenAI}

  @bounded_async_result ~s({"type":"tool_call_completed","tool_call_id":"call-1","tool_name":"im_api.internal.task.create","status":"completed","error":false,"message":"tool call completed after returning early; short result is included in this notification","result":{"conversation_id":"conv-123","next_action":"send conversation_ref"}})

  @messages [
    %{role: "user", content: "before"},
    %{
      role: "runtime",
      kind: "runtime_message",
      runtime_message_id: "runtime-1",
      type: "tool_call_completed",
      source_tool_call_id: "call-1",
      summary: "Tool call completed in the background.",
      content: @bounded_async_result,
      source_refs: %{"tool_call_id" => "call-1"}
    },
    %{role: "user", content: "after"}
  ]

  @generic_runtime_messages [
    %{
      role: "runtime",
      kind: "runtime_message",
      runtime_message_id: "runtime-generic",
      type: "runtime_recovered",
      summary: "Runtime session recovered.",
      content: "raw generic runtime payload that should not repeat the summary"
    }
  ]

  @blank_summary_messages [
    %{
      role: "runtime",
      kind: "runtime_message",
      runtime_message_id: "runtime-blank-summary",
      type: "runtime_recovered",
      summary: "",
      content: "runtime content fallback"
    }
  ]

  @project_knowledge_messages [
    %{
      role: "runtime",
      kind: "runtime_message",
      runtime_message_id: "project-knowledge:atlas",
      type: "project_knowledge",
      summary: "Resolved project knowledge for this question",
      content:
        ~s({"contract":"Quoted project evidence only.","facts":[{"content":"The Atlas launch codename is ORBITAL-TEAL-47."}]}),
      source_refs: %{
        "assertions" => [
          %{
            "id" => "assertion-atlas",
            "sources" => [
              %{"type" => "slack_receipt", "ref" => "s3://triage/receipts/atlas.json"}
            ]
          }
        ]
      }
    }
  ]

  # A transcript of only system-authored context has no conversation turn for
  # the leading run to be hoisted above, so `Convert` leaves the last one in
  # place as a `<system>`-wrapped user turn rather than emitting `messages: []`
  # — which the Messages API rejects. These cases assert the rendered runtime
  # text, wherever the projection put it.
  defp anthropic_context(messages) do
    case Convert.to_anthropic(messages) do
      {system, []} -> system
      {nil, [%{"role" => "user", "content" => content}]} -> content
    end
  end

  test "anthropic carries mid-conversation runtime context in place" do
    {system, messages} = Convert.to_anthropic(@messages)

    # `system` renders ahead of every message, so folding a mid-conversation
    # runtime fact into it would rewrite the cached prefix of the whole request
    # each time one arrives. It rides in position instead, same as the chat and
    # Responses projections.
    assert system == nil

    assert [
             %{"role" => "user", "content" => "before"},
             %{"role" => "user", "content" => runtime_context},
             %{"role" => "user", "content" => "after"}
           ] = messages

    assert runtime_context =~ "<system>"
    assert runtime_context =~ "<runtime-message>"
    assert runtime_context =~ "runtime_message_id: runtime-1"
    assert runtime_context =~ "type: tool_call_completed"
    assert runtime_context =~ "source_tool_call_id: call-1"
    assert runtime_context =~ "summary: Tool call completed in the background."
    assert runtime_context =~ ~s(source_refs: {"tool_call_id":"call-1"})
    assert runtime_context =~ "content: #{@bounded_async_result}"
    assert runtime_context =~ ~s("conversation_id":"conv-123")
    assert runtime_context =~ ~s("next_action":"send conversation_ref")
    assert runtime_context =~ "It is not a user request."
  end

  test "openai chat carries mid-conversation runtime context on a user message" do
    messages = ConvertOpenAI.to_chat(@messages)

    # Chat Completions rejects a system message that is not the first one, so
    # runtime context after the leading system run rides as a wrapped user turn.
    assert [
             %{"role" => "user", "content" => "before"},
             %{"role" => "user", "content" => runtime_context},
             %{"role" => "user", "content" => "after"}
           ] = messages

    assert runtime_context =~ "<system>"
    assert runtime_context =~ "<runtime-message>"
    assert runtime_context =~ "runtime_message_id: runtime-1"
    assert runtime_context =~ "type: tool_call_completed"
    assert runtime_context =~ "summary: Tool call completed in the background."
    assert runtime_context =~ ~s(source_refs: {"tool_call_id":"call-1"})
    assert runtime_context =~ "content: #{@bounded_async_result}"
    assert runtime_context =~ ~s("conversation_id":"conv-123")
    assert runtime_context =~ ~s("next_action":"send conversation_ref")
    assert runtime_context =~ "It is not a user request."
  end

  test "openai responses keeps runtime messages as system runtime context" do
    {input, instructions} = ConvertOpenAI.to_responses_parts(@messages)

    assert instructions == nil

    assert [
             %{"role" => "user", "content" => "before"},
             %{"role" => "system", "content" => runtime_context},
             %{"role" => "user", "content" => "after"}
           ] = input

    assert runtime_context =~ "<runtime-message>"
    assert runtime_context =~ "runtime_message_id: runtime-1"
    assert runtime_context =~ "type: tool_call_completed"
    assert runtime_context =~ "summary: Tool call completed in the background."
    assert runtime_context =~ ~s(source_refs: {"tool_call_id":"call-1"})
    assert runtime_context =~ "content: #{@bounded_async_result}"
    assert runtime_context =~ ~s("conversation_id":"conv-123")
    assert runtime_context =~ ~s("next_action":"send conversation_ref")
    assert runtime_context =~ "It is not a user request."
  end

  test "model context keeps the owner's body and leaves legacy history unchanged" do
    legacy = %{
      role: "runtime",
      type: "runtime_guidance",
      summary: "guidance changed",
      content: "Read /.runtime/skills/index.md before selecting the new skill."
    }

    current = Map.put(legacy, :content_kind, "model_context")

    for convert <- [
          &Convert.to_anthropic/1,
          &ConvertOpenAI.to_chat/1,
          &ConvertOpenAI.to_responses_parts/1
        ] do
      before = convert.([%{role: "user", content: "request"}, legacy]) |> inspect()
      after_text = convert.([%{role: "user", content: "request"}, legacy, current]) |> inspect()
      refute before =~ "Read /.runtime/skills/index.md"
      assert after_text =~ "Read /.runtime/skills/index.md"
    end
  end

  test "generic runtime messages with summaries suppress duplicate content" do
    anthropic_system = anthropic_context(@generic_runtime_messages)
    assert anthropic_system =~ "summary: Runtime session recovered."
    refute anthropic_system =~ "raw generic runtime payload"

    assert [%{"role" => "system", "content" => chat_context}] =
             ConvertOpenAI.to_chat(@generic_runtime_messages)

    assert chat_context =~ "summary: Runtime session recovered."
    refute chat_context =~ "raw generic runtime payload"

    assert {[%{"role" => "system", "content" => responses_context}], nil} =
             ConvertOpenAI.to_responses_parts(@generic_runtime_messages)

    assert responses_context =~ "summary: Runtime session recovered."
    refute responses_context =~ "raw generic runtime payload"
  end

  test "project knowledge keeps its evidence body even when it has a summary" do
    anthropic_system = anthropic_context(@project_knowledge_messages)
    assert anthropic_system =~ "ORBITAL-TEAL-47"

    assert [%{"role" => "system", "content" => chat_context}] =
             ConvertOpenAI.to_chat(@project_knowledge_messages)

    assert chat_context =~ "ORBITAL-TEAL-47"

    assert {[%{"role" => "system", "content" => responses_context}], nil} =
             ConvertOpenAI.to_responses_parts(@project_knowledge_messages)

    assert responses_context =~ "ORBITAL-TEAL-47"
    assert responses_context =~ "assertion-atlas"
    assert responses_context =~ "s3://triage/receipts/atlas.json"
  end

  test "blank runtime summary falls back to content without empty summary line" do
    system = anthropic_context(@blank_summary_messages)
    assert system =~ "content: runtime content fallback"
    refute system =~ "summary: "

    assert [%{"role" => "system", "content" => chat_context}] =
             ConvertOpenAI.to_chat(@blank_summary_messages)

    assert chat_context =~ "content: runtime content fallback"
    refute chat_context =~ "summary: "
  end

  test "wait expired runtime message includes deadline and elapsed facts" do
    messages = [
      %{
        role: "runtime",
        kind: "runtime_message",
        runtime_message_id: "wait-timeout:main:wait-1",
        type: "wait_expired",
        wait_id: "wait-1",
        reason: "worker reply",
        timeout_seconds: 120,
        deadline_ms: 123_000,
        elapsed_ms: 121_000,
        overdue_ms: 1_000,
        summary: "wait timeout reached"
      }
    ]

    anthropic_system = anthropic_context(messages)
    assert anthropic_system =~ "deadline_ms: 123000"
    assert anthropic_system =~ "elapsed_ms: 121000"
    assert anthropic_system =~ "overdue_ms: 1000"

    assert [%{"role" => "system", "content" => chat_context}] = ConvertOpenAI.to_chat(messages)
    assert chat_context =~ "deadline_ms: 123000"
    assert chat_context =~ "elapsed_ms: 121000"
    assert chat_context =~ "overdue_ms: 1000"
  end
end
