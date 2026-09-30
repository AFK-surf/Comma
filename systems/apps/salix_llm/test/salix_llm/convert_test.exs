defmodule SalixLlm.ConvertTest do
  @moduledoc """
  Anthropic Messages serialization must stay replayable after tool turns: the
  API rejects blank text blocks with HTTP 400, so a tool-use-only assistant turn
  (no meaningful accompanying text — the common shape when the model retries
  after a tool error) must not serialize an empty or whitespace-only text block.
  A 400 on replay wedges the session permanently because the same transcript is
  resent verbatim on every wake.
  """
  use ExUnit.Case, async: true

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

  test "assistant turn with neither text nor tool calls is dropped" do
    {_system, messages} =
      Convert.to_anthropic([
        %{role: "user", content: "hi"},
        %{role: "assistant", content: "", tool_calls: []},
        %{role: "user", content: "still there?"}
      ])

    assert Enum.map(messages, & &1["role"]) == ["user", "user"]
  end

  test "assistant turn with only whitespace and no tool calls is dropped" do
    {_system, messages} =
      Convert.to_anthropic([
        %{role: "user", content: "hi"},
        %{role: "assistant", content: " \n\t", tool_calls: []},
        %{role: "user", content: "still there?"}
      ])

    assert Enum.map(messages, & &1["role"]) == ["user", "user"]
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
    # "messages: at least one message is required" (HTTP 400).
    test "keeps the prompt snapshot in system and demotes the last reminder" do
      {system, messages} =
        Convert.to_anthropic([
          %{role: "summary", content: "ROUTER PROMPT"},
          %{role: "summary", content: "<compacted-context>what happened</compacted-context>"},
          %{role: "system", content: "<end-of-turn>settle this round</end-of-turn>"}
        ])

      assert system == "ROUTER PROMPT\n\n<compacted-context>what happened</compacted-context>"

      assert messages == [
               %{
                 "role" => "user",
                 "content" => "<system>\n<end-of-turn>settle this round</end-of-turn>\n</system>"
               }
             ]
    end

    test "a runtime fact is demoted with its wrapper intact" do
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

      assert system == "ROUTER PROMPT"
      assert [%{"role" => "user", "content" => content}] = messages
      assert content =~ "<runtime-message>"
      assert content =~ "type: wait_timeout"
    end

    # Demotion walks past a message the projection drops rather than stopping
    # on it: a blank one contributes no turn either.
    test "blank system-authored messages are skipped while demoting" do
      {system, messages} =
        Convert.to_anthropic([
          %{role: "summary", content: "ROUTER PROMPT"},
          %{role: "system", content: "still here?"},
          %{role: "system", content: "   "}
        ])

      assert system == "ROUTER PROMPT"
      assert messages == [%{"role" => "user", "content" => "<system>\nstill here?\n</system>"}]
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

      assert system == "ROUTER PROMPT"
      assert messages == [%{"role" => "user", "content" => "<system>\nreminder\n</system>"}]
    end

    # The last resort: with a single system-authored message there is nothing
    # to hoist it above, so it becomes the conversation instead of leaving the
    # request with no messages at all.
    test "a lone system message becomes the conversation" do
      {system, messages} = Convert.to_anthropic([%{role: "summary", content: "ROUTER PROMPT"}])

      assert system == nil
      assert messages == [%{"role" => "user", "content" => "<system>\nROUTER PROMPT\n</system>"}]
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
