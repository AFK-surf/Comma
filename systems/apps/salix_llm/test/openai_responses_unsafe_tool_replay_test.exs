defmodule SalixLlm.OpenAIResponsesUnsafeToolReplayTest do
  use ExUnit.Case, async: true

  alias SalixLlm.ConvertOpenAI

  test "projects a provider-unsafe historical call and its output as system context" do
    input =
      ConvertOpenAI.to_responses([
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              "id" => "unsafe-1",
              "name" => "im_api.internal.read_conversation",
              "args" => %{"repair_context" => "redacted"}
            }
          ]
        },
        %{role: "tool", tool_call_id: "unsafe-1", content: ~s({"status":"resolved"})}
      ])

    assert [call_record, output_record] = input

    assert %{"role" => "system", "content" => call_content} = call_record
    assert call_content =~ "type: historical_provider_function_call"
    assert call_content =~ "im_api.internal.read_conversation"
    assert call_content =~ ~s(\\"repair_context\\":\\"redacted\\")

    assert %{"role" => "system", "content" => output_content} = output_record
    assert output_content =~ "type: historical_provider_function_call_output"
    assert output_content =~ "unsafe-1"
    assert output_content =~ ~s({\\"status\\":\\"resolved\\"})

    refute Enum.any?(input, &(&1["type"] in ["function_call", "function_call_output"]))
  end

  test "keeps valid sibling calls and outputs native and in order" do
    input =
      ConvertOpenAI.to_responses([
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{"id" => "unsafe-1", "name" => "fs.read_file", "args" => %{"path" => "/x"}},
            %{
              "id" => "safe-1",
              "name" => "call",
              "args" => %{"tool" => "fs.read_file", "params" => %{"path" => "/y"}}
            }
          ]
        },
        %{role: "tool", tool_call_id: "unsafe-1", content: "rejected"},
        %{role: "tool", tool_call_id: "safe-1", content: "accepted"}
      ])

    assert [unsafe_call, safe_call, unsafe_output, safe_output] = input
    assert unsafe_call["role"] == "system"
    assert unsafe_call["content"] =~ "fs.read_file"

    assert %{
             "type" => "function_call",
             "call_id" => "safe-1",
             "name" => "call"
           } = safe_call

    assert unsafe_output["role"] == "system"

    assert %{
             "type" => "function_call_output",
             "call_id" => "safe-1",
             "output" => "accepted"
           } = safe_output
  end

  test "projects unsafe raw Responses replay items without dropping adjacent provider context" do
    reasoning = %{"type" => "reasoning", "encrypted_content" => "opaque"}

    input =
      ConvertOpenAI.to_responses([
        %{
          role: "assistant",
          content: "",
          provider_meta: %{
            "responses_items" => [
              reasoning,
              %{
                "type" => "function_call",
                "call_id" => "unsafe-raw",
                "name" => "legacy.tool",
                "arguments" => ~s({"value":1})
              }
            ]
          }
        },
        %{role: "tool", tool_call_id: "unsafe-raw", content: "legacy result"}
      ])

    assert [^reasoning, call_record, output_record] = input
    assert call_record["role"] == "system"
    assert call_record["content"] =~ "legacy.tool"
    assert output_record["role"] == "system"
    assert output_record["content"] =~ "legacy result"
  end
end
