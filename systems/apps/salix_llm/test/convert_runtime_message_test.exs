defmodule SalixLlm.ConvertRuntimeMessageTest do
  use SystemsClock.Case, async: true

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

  @placeholder %{"role" => "user", "content" => "[No new user message.]"}

  # A transcript of only system-authored context keeps it in `system` and opens
  # the conversation with a placeholder user turn, because the Messages API
  # rejects `messages: []`. These cases assert the rendered runtime text.
  defp anthropic_context(messages) do
    {system, [@placeholder]} = Convert.to_anthropic(messages)

    system
  end

  defp shell_call(id), do: %{"id" => id, "name" => "shell", "args" => %{}}

  defp payload(json), do: Jason.decode!(json)

  test "anthropic sends a runtime message with tool output as user text" do
    {system, messages} = Convert.to_anthropic(@messages)

    # `system` renders ahead of every message, so folding a mid-conversation
    # runtime fact into it would rewrite the cached prefix of the whole request
    # each time one arrives. It rides in position instead. Tool output must not
    # get operator authority, so it is user text, not a system message.
    assert system == nil

    assert [
             %{"role" => "user", "content" => "before"},
             %{"role" => "user", "content" => text},
             %{"role" => "user", "content" => "after"}
           ] = messages

    assert text =~ "<runtime-message>"
    assert text =~ "runtime_message_id: runtime-1"
    assert text =~ "type: tool_call_completed"
    assert text =~ ~s("conversation_id":"conv-123")
  end

  test "anthropic sends a runtime-authored message as a system message after a user turn" do
    {system, messages} =
      Convert.to_anthropic([
        %{role: "summary", content: "PROMPT"},
        %{role: "user", content: "start"},
        %{role: "assistant", content: "ok"},
        hd(@generic_runtime_messages),
        %{role: "user", content: "next"}
      ])

    assert system == "PROMPT"

    # A system message must follow a user turn and precede an assistant turn.
    assert [
             %{"role" => "user", "content" => "start"},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "ok"}]},
             @placeholder,
             %{"role" => "system", "content" => text},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "[Noted.]"}]},
             %{"role" => "user", "content" => "next"}
           ] = messages

    assert text =~ "runtime_message_id: runtime-generic"
    assert text =~ "summary: Runtime session recovered."
  end

  test "openai chat carries a mid-conversation runtime message as a synthetic call" do
    assert [
             %{"role" => "user", "content" => "before"},
             %{
               "role" => "assistant",
               "content" => "",
               "reasoning_content" => "",
               "tool_calls" => [call]
             },
             %{"role" => "tool", "tool_call_id" => id, "content" => result},
             %{"role" => "user", "content" => "after"}
           ] = ConvertOpenAI.to_chat(@messages)

    assert %{"id" => ^id, "type" => "function", "function" => function} = call
    assert function["name"] == "get_runtime_message"
    assert Jason.decode!(function["arguments"]) == %{"runtime_message_id" => "runtime-1"}

    assert %{"type" => "tool_call_completed", "content" => %{"status" => "completed"}} =
             payload(result)
  end

  test "openai responses carries a mid-conversation runtime message as a synthetic call" do
    assert {[
              %{"role" => "user", "content" => "before"},
              %{"type" => "function_call", "call_id" => id, "name" => "get_runtime_message"},
              %{"type" => "function_call_output", "call_id" => id, "output" => output},
              %{"role" => "user", "content" => "after"}
            ], nil} = ConvertOpenAI.to_responses_parts(@messages)

    text = if is_binary(output), do: output, else: Enum.map_join(output, & &1["text"])
    assert %{"runtime_message_id" => "runtime-1"} = payload(text)
  end

  test "the synthetic call ID is stable and keyed by the runtime message" do
    [_, %{"tool_calls" => [first]} | _] = ConvertOpenAI.to_chat(@messages)

    [_, %{"tool_calls" => [again]} | _] =
      ConvertOpenAI.to_chat(@messages ++ [%{role: "user", content: "more"}])

    assert first["id"] == again["id"]

    other = put_in(Enum.at(@messages, 1)[:runtime_message_id], "runtime-2")

    [_, %{"tool_calls" => [changed]} | _] =
      ConvertOpenAI.to_chat(List.replace_at(@messages, 1, other))

    refute changed["id"] == first["id"]
  end

  # A later system reminder is a runtime message too, never XML in a user turn.
  # Identical reminders still get distinct call IDs.
  test "anthropic carries later system reminders as system messages" do
    {system, messages} =
      Convert.to_anthropic([
        %{role: "summary", content: "PROMPT"},
        %{role: "user", content: "start"},
        %{role: "system", content: "  check again  "},
        %{role: "assistant", content: "ok"},
        %{role: "system", content: "check again"}
      ])

    assert system == "PROMPT"

    assert [
             %{"role" => "user", "content" => "start"},
             %{"role" => "system", "content" => "check again"},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "ok"}]},
             @placeholder,
             %{"role" => "system", "content" => "check again"}
           ] = messages
  end

  test "an IFC source marker becomes the result's ref and JSON content stays structured" do
    marked = Map.put(Enum.at(@messages, 1), :content, "[src:a-42]\n" <> @bounded_async_result)

    [_, _, %{"content" => result}, _] =
      ConvertOpenAI.to_chat(List.replace_at(@messages, 1, marked))

    assert %{"ref" => "src:a-42", "content" => %{"tool_call_id" => "call-1"}} = payload(result)
  end

  test "a runtime message inside a pending tool batch follows the batch results" do
    chat =
      ConvertOpenAI.to_chat([
        %{role: "user", content: "run it"},
        %{role: "assistant", content: "", tool_calls: [shell_call("c1"), shell_call("c2")]},
        %{role: "tool", tool_call_id: "c1", content: "one"},
        Enum.at(@messages, 1),
        %{role: "tool", tool_call_id: "c2", content: "two"}
      ])

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "tool_calls" => [%{"id" => "c1"}, %{"id" => "c2"}]},
             %{"role" => "tool", "tool_call_id" => "c1"},
             %{"role" => "tool", "tool_call_id" => "c2"},
             %{"role" => "assistant", "tool_calls" => [%{"id" => "rtm_" <> _ = id}]},
             %{"role" => "tool", "tool_call_id" => id}
           ] = chat
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

    assert [%{"role" => "system", "content" => chat_context}, @placeholder] =
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

    assert [%{"role" => "system", "content" => chat_context}, @placeholder] =
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

    assert [%{"role" => "system", "content" => chat_context}, @placeholder] =
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

    assert [%{"role" => "system", "content" => chat_context}, @placeholder] =
             ConvertOpenAI.to_chat(messages)

    assert chat_context =~ "deadline_ms: 123000"
    assert chat_context =~ "elapsed_ms: 121000"
    assert chat_context =~ "overdue_ms: 1000"
  end
end
