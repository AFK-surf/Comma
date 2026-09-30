defmodule SalixLlm.ConvertLegacyToolIdTest do
  use ExUnit.Case, async: true

  alias SalixLlm.{Convert, ConvertOpenAI}

  @messages [
    %{
      role: "assistant",
      content: "",
      tool_calls: [%{"id" => "t1", "name" => "echo", "args" => %{}}]
    },
    %{role: "tool", tool_use_id: "t1", content: "legacy result"}
  ]

  test "legacy tool_use_id-only tool results keep their call id at provider boundaries" do
    {_system, anthropic} = Convert.to_anthropic(@messages)
    [%{"type" => "tool_result", "tool_use_id" => "t1"}] = Enum.at(anthropic, 1)["content"]

    chat = ConvertOpenAI.to_chat(@messages)
    assert Enum.at(chat, 1)["tool_call_id"] == "t1"

    responses = ConvertOpenAI.to_responses(@messages)
    assert Enum.at(responses, 1)["call_id"] == "t1"
  end
end
