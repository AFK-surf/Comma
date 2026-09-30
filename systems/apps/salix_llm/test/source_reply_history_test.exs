defmodule SalixLlm.SourceReplyHistoryTest do
  use ExUnit.Case, async: true

  alias SalixLlm.{Convert, ConvertOpenAI}

  test "a historical removed reply alias and its canonical result replay by call ID on every provider" do
    history = [
      %{role: "user", content: "Say hello"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "reply-id", name: "reply", args: %{"text" => "Hello"}}]
      },
      %{
        role: "tool",
        tool_call_id: "reply-id",
        tool_name: "im_api.internal.send_message",
        content: "sent"
      }
    ]

    [_user, assistant, result] = ConvertOpenAI.to_chat(history)

    assert [%{"id" => "reply-id", "function" => %{"name" => "reply"}}] =
             assistant["tool_calls"]

    assert result == %{"role" => "tool", "tool_call_id" => "reply-id", "content" => "sent"}

    [_user, call, result] = ConvertOpenAI.to_responses(history)
    assert %{"type" => "function_call", "call_id" => "reply-id", "name" => "reply"} = call

    assert %{"type" => "function_call_output", "call_id" => "reply-id", "output" => "sent"} =
             result

    {_system, [_user, assistant, result]} = Convert.to_anthropic(history)

    assert [%{"type" => "tool_use", "id" => "reply-id", "name" => "reply"}] =
             assistant["content"]

    assert [%{"type" => "tool_result", "tool_use_id" => "reply-id", "content" => "sent"}] =
             result["content"]
  end
end
