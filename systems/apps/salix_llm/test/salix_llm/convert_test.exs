defmodule SalixLlm.ConvertTest do
  @moduledoc """
  Anthropic Messages serialization must stay replayable after tool turns: the
  API rejects blank text blocks with HTTP 400, so a tool-use-only assistant turn
  (no meaningful accompanying text — the common shape when the model retries
  after a tool error) must not serialize an empty or whitespace-only text block.
  A 400 on replay wedges the session permanently because the same transcript is
  resent verbatim on every wake.
  """
  use SystemsClock.Case, async: true

  alias SalixLlm.Convert

  test "tool-use-only assistant turn omits the empty text block" do
    {_system, messages} =
      Convert.to_anthropic([
        %{role: "user", content: "list files"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{"id" => "tc_1", "name" => "call", "args" => %{"tool" => "fs.list"}}]
        },
        %{role: "tool", tool_call_id: "tc_1", content: "error: workspace not provisioned"}
      ])

    assert [_user, %{"role" => "assistant", "content" => blocks}, tool_result] = messages
    assert [%{"type" => "tool_use", "id" => "tc_1", "name" => "call"}] = blocks
    refute Enum.any?(blocks, &(&1["type"] == "text"))

    assert %{
             "role" => "user",
             "content" => [%{"type" => "tool_result", "tool_use_id" => "tc_1"}]
           } = tool_result
  end

  test "assistant turn with text keeps the text block ahead of tool_use blocks" do
    {_system, [message]} =
      Convert.to_anthropic([
        %{
          role: "assistant",
          content: "checking the workspace",
          tool_calls: [%{"id" => "tc_2", "name" => "call", "args" => %{}}]
        }
      ])

    assert %{"role" => "assistant", "content" => blocks} = message

    assert [
             %{"type" => "text", "text" => "checking the workspace"},
             %{"type" => "tool_use", "id" => "tc_2"}
           ] = blocks
  end

  for {name, content} <- [
        {"assistant turn with neither text nor tool calls is dropped", ""},
        {"assistant turn with only whitespace and no tool calls is dropped", " \n\t"}
      ] do
    test name do
      {_system, messages} =
        Convert.to_anthropic([
          %{role: "user", content: "hi"},
          %{role: "assistant", content: unquote(content), tool_calls: []},
          %{role: "user", content: "still there?"}
        ])

      assert Enum.map(messages, & &1["role"]) == ["user", "user"]
    end
  end

  test "plain final assistant text is unchanged (prompt-cache stability)" do
    {_system, [message]} =
      Convert.to_anthropic([%{role: "assistant", content: "  done\n", tool_calls: []}])

    assert message == %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "  done\n"}]
           }
  end

  describe "a transcript with no conversation turn" do
    # The round right after a compaction: the live context is the compaction
    # summary, and the prompt snapshot and the end-of-turn reminder are
    # system-authored too, so the leading run is the whole transcript. Hoisting
    # all of it left `messages: []` and the API answered
    # "messages: at least one message is required" (HTTP 400). A placeholder
    # user turn opens the conversation instead of a system tag in a user turn.
    @placeholder %{"role" => "user", "content" => "[No new user message.]"}

    test "keeps all context in system and adds a placeholder user turn" do
      {system, messages} =
        Convert.to_anthropic([
          %{role: "summary", content: "ROUTER PROMPT"},
          %{role: "summary", content: "<compacted-context>what happened</compacted-context>"},
          %{role: "system", content: "<end-of-turn>settle this round</end-of-turn>"}
        ])

      assert system ==
               "ROUTER PROMPT\n\n<compacted-context>what happened</compacted-context>\n\n<end-of-turn>settle this round</end-of-turn>"

      assert messages == [@placeholder]
    end

    test "a runtime fact stays in system with its wrapper intact" do
      {system, messages} =
        Convert.to_anthropic([
          %{role: "summary", content: "ROUTER PROMPT"},
          %{
            role: "runtime",
            kind: "runtime_message",
            runtime_message_id: "r1",
            type: "wait_timeout",
            reason: "waiting on the worker"
          }
        ])

      assert system =~ "ROUTER PROMPT"
      assert system =~ "<runtime-message>"
      assert system =~ "type: wait_timeout"
      assert messages == [@placeholder]
    end

    # An assistant turn with neither text nor tool calls is dropped, so a
    # transcript whose only conversation turn is that one is empty too.
    test "a dropped assistant turn still leaves a message behind" do
      {system, messages} =
        Convert.to_anthropic([
          %{role: "summary", content: "ROUTER PROMPT"},
          %{role: "system", content: "reminder"},
          %{role: "assistant", content: "", tool_calls: []}
        ])

      assert system == "ROUTER PROMPT\n\nreminder"
      assert messages == [@placeholder]
    end

    test "a lone system message stays in system" do
      assert {"ROUTER PROMPT", [@placeholder]} =
               Convert.to_anthropic([%{role: "summary", content: "ROUTER PROMPT"}])
    end

    test "a transcript with nothing to say is left alone" do
      assert {nil, []} = Convert.to_anthropic([%{role: "system", content: "  "}])
    end
  end

  test "a leading run above a real turn is still hoisted whole" do
    {system, messages} =
      Convert.to_anthropic([
        %{role: "summary", content: "ROUTER PROMPT"},
        %{role: "system", content: "reminder"},
        %{role: "user", content: "hi"}
      ])

    assert system == "ROUTER PROMPT\n\nreminder"
    assert messages == [%{"role" => "user", "content" => "hi"}]
  end
end
