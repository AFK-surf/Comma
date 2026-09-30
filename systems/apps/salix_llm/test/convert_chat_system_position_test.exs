defmodule SalixLlm.ConvertChatSystemPositionTest do
  @moduledoc """
  Chat Completions implementations commonly reject a `system` message that is
  not the first one ("System message must be at the beginning."). Salix
  transcripts interleave system-authored roles (`summary`, `runtime`) with the
  conversation — the compaction summary and prompt snapshot lead, the end-turn
  reminder trails, runtime facts land mid-conversation — so the chat projection
  must keep exactly one leading `system` message and carry the rest as user
  turns.
  """
  use ExUnit.Case, async: true

  alias SalixLlm.ConvertOpenAI

  test "only the leading system run keeps the system role" do
    chat =
      ConvertOpenAI.to_chat([
        %{role: "system", content: "You are Salix."},
        %{role: "summary", content: "Prior compacted context."},
        %{role: "user", content: "start"},
        %{role: "assistant", content: "on it"},
        %{
          role: "runtime",
          kind: "runtime_message",
          runtime_message_id: "runtime-1",
          type: "wait_expired",
          summary: "wait timeout reached"
        },
        %{role: "user", content: "any update?"},
        %{role: "summary", content: "Re-evaluate every current request."}
      ])

    assert [%{"role" => "system", "content" => system} | rest] = chat
    assert system == "You are Salix.\n\nPrior compacted context."
    assert Enum.all?(rest, &(&1["role"] != "system"))

    assert [
             %{"role" => "user", "content" => "start"},
             %{"role" => "assistant", "content" => "on it"},
             %{"role" => "user", "content" => runtime},
             %{"role" => "user", "content" => "any update?"},
             %{"role" => "user", "content" => reminder}
           ] = rest

    assert runtime =~ "<system>"
    assert runtime =~ "summary: wait timeout reached"
    assert reminder == "<system>\nRe-evaluate every current request.\n</system>"
  end

  test "a leading system message survives the chat projection" do
    assert [
             %{"role" => "system", "content" => "You generate titles only."},
             %{"role" => "user", "content" => "draft the Q2 report"}
           ] =
             ConvertOpenAI.to_chat([
               %{role: "system", content: "You generate titles only."},
               %{role: "user", content: "draft the Q2 report"}
             ])
  end

  test "blank system-authored messages are dropped from both positions" do
    assert [%{"role" => "user", "content" => "start"}] =
             ConvertOpenAI.to_chat([
               %{role: "summary", content: "   "},
               %{role: "user", content: "start"},
               %{role: "summary", content: ""}
             ])
  end

  test "tool results stay adjacent to their assistant call across runtime context" do
    chat =
      ConvertOpenAI.to_chat([
        %{role: "user", content: "run it"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{"id" => "call-1", "name" => "shell", "args" => %{}}]
        },
        %{role: "tool", tool_call_id: "call-1", content: "done"},
        %{
          role: "runtime",
          kind: "runtime_message",
          runtime_message_id: "runtime-1",
          type: "tool_call_completed",
          summary: "Tool call completed in the background."
        }
      ])

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "tool_calls" => [%{"id" => "call-1"}]},
             %{"role" => "tool", "tool_call_id" => "call-1"},
             %{"role" => "user", "content" => runtime}
           ] = chat

    assert runtime =~ "<runtime-message>"
  end
end
