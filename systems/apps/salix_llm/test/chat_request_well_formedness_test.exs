defmodule SalixLlm.ChatRequestWellFormednessTest do
  @moduledoc """
  Structural rules the strict OpenAI-compatible providers validate — DeepSeek,
  Alibaba Model Studio (Qwen) and OpenRouter — checked against transcript shapes
  Salix actually produces:

    * one system message, first (both reject a later one; Qwen's chat template
      also breaks on several leading ones)
    * "an assistant message with `tool_calls` must be followed by tool messages
      responding to each `tool_call_id`" — no interleaving, none missing, none
      unclaimed
    * DeepSeek thinking mode wants `reasoning_content` on every assistant
      message once the request carries tools
    * OpenRouter replays reasoning blocks as a consecutive sequence, so streamed
      text/summary fragments merge only until the next block-type transition
  """
  use ExUnit.Case, async: true

  alias SalixLlm.ConvertOpenAI

  defp assistant(content, calls, extra \\ %{}) do
    Map.merge(%{role: "assistant", content: content, tool_calls: calls}, extra)
  end

  defp call(id, name), do: %{"id" => id, "name" => name, "args" => %{}}

  # Every rule the providers validate about tool sequencing, in one pass.
  defp assert_tool_sequencing!(chat) do
    answered =
      chat
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"role" => "assistant", "tool_calls" => calls}, index} when is_list(calls) ->
          for {c, offset} <- Enum.with_index(calls, 1), do: {c["id"], index + offset}

        _ ->
          []
      end)

    for {id, position} <- answered do
      assert %{"role" => "tool", "tool_call_id" => ^id} = Enum.at(chat, position),
             "tool result for #{id} must sit immediately after its call"
    end

    positions = MapSet.new(answered, fn {_id, position} -> position end)

    for {message, index} <- Enum.with_index(chat), message["role"] == "tool" do
      assert MapSet.member?(positions, index),
             "tool message at #{index} answers no preceding tool_call"
    end

    chat
  end

  describe "tool-call sequencing" do
    test "runtime context between a call and its result does not split them" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "run it"},
          assistant("", [call("c1", "shell")]),
          %{
            role: "runtime",
            kind: "runtime_message",
            runtime_message_id: "r1",
            type: "tool_call_completed",
            summary: "Tool call completed in the background."
          },
          %{role: "tool", tool_call_id: "c1", content: "done"}
        ])
        |> assert_tool_sequencing!()

      assert [
               %{"role" => "user", "content" => "run it"},
               %{"role" => "assistant"},
               %{"role" => "tool", "tool_call_id" => "c1", "content" => "done"},
               %{"role" => "user", "content" => runtime}
             ] = chat

      assert runtime =~ "<runtime-message>"
    end

    test "a call with no recorded result still gets one" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "run both"},
          assistant("", [call("c1", "shell"), call("c2", "search")]),
          %{role: "tool", tool_call_id: "c2", content: "found"}
        ])
        |> assert_tool_sequencing!()

      assert [
               %{"role" => "user"},
               %{"role" => "assistant"},
               %{"role" => "tool", "tool_call_id" => "c1", "content" => missing},
               %{"role" => "tool", "tool_call_id" => "c2", "content" => "found"}
             ] = chat

      assert Jason.decode!(missing) == %{"status" => "no_result_recorded"}
    end

    test "a result whose call is gone rides as system context" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "hi"},
          %{role: "tool", tool_call_id: "c9", content: "orphaned output"},
          %{role: "user", content: "still there?"}
        ])
        |> assert_tool_sequencing!()

      assert [
               %{"role" => "user", "content" => "hi"},
               %{"role" => "user", "content" => carried},
               %{"role" => "user", "content" => "still there?"}
             ] = chat

      assert carried =~ ~s(<unclaimed-tool-result call_id="c9">)
      assert carried =~ "orphaned output"
    end

    test "a duplicated result is sent once" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "run it"},
          assistant("", [call("c1", "shell")]),
          %{role: "tool", tool_call_id: "c1", content: "done"},
          %{role: "tool", tool_call_id: "c1", content: "done"}
        ])
        |> assert_tool_sequencing!()

      assert Enum.count(chat, &(&1["role"] == "tool")) == 1
    end

    test "a legacy result with no call id does not ride as a tool message" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "hi"},
          %{role: "tool", content: "result with no id"}
        ])
        |> assert_tool_sequencing!()

      refute Enum.any?(chat, &(&1["role"] == "tool"))
    end
  end

  describe "DeepSeek reasoning_content" do
    test "every assistant message carries the field once the turn uses it" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "go"},
          # A sanitized/legacy turn: no reasoning was kept for it.
          assistant("earlier answer", []),
          %{role: "user", content: "again"},
          assistant("", [call("c1", "shell")], %{
            provider_meta: %{"chat_message_extra" => %{"reasoning_content" => "thinking"}}
          }),
          %{role: "tool", tool_call_id: "c1", content: "done"}
        ])

      assistants = Enum.filter(chat, &(&1["role"] == "assistant"))
      assert length(assistants) == 2
      assert Enum.all?(assistants, &Map.has_key?(&1, "reasoning_content"))
      assert Enum.map(assistants, & &1["reasoning_content"]) == [nil, "thinking"]
    end

    test "assistants stay untouched when no turn reasoned" do
      chat =
        ConvertOpenAI.to_chat([
          %{role: "user", content: "go"},
          assistant("answer", [])
        ])

      refute chat
             |> Enum.filter(&(&1["role"] == "assistant"))
             |> Enum.any?(&Map.has_key?(&1, "reasoning_content"))
    end
  end

  describe "OpenRouter reasoning_details" do
    test "consecutive text fragments merge by type rather than provider index" do
      deltas = [
        %{
          "reasoning_details" => [
            %{
              "type" => "reasoning.text",
              "index" => 0,
              "format" => "anthropic-claude-v1",
              "text" => "First I "
            }
          ]
        },
        %{
          "reasoning_details" => [
            %{
              "type" => "reasoning.text",
              "index" => 42,
              "text" => "check the date.",
              "signature" => "SIG"
            }
          ]
        },
        %{
          "reasoning_details" => [
            %{"type" => "reasoning.encrypted", "index" => 1, "data" => "OPAQUE"}
          ]
        }
      ]

      assert %{"chat_message_extra" => %{"reasoning_details" => details}} =
               ConvertOpenAI.chat_provider_meta_from_deltas(deltas)

      assert details == [
               %{
                 "type" => "reasoning.text",
                 "index" => 0,
                 "format" => "anthropic-claude-v1",
                 "text" => "First I check the date.",
                 "signature" => "SIG"
               },
               %{"type" => "reasoning.encrypted", "index" => 1, "data" => "OPAQUE"}
             ]
    end
  end

  describe "tool specs" do
    test "a spec without a description omits the key rather than sending null" do
      [tool] =
        ConvertOpenAI.chat_tools([
          %{
            "name" => "get_date",
            "input_schema" => %{"type" => "object", "properties" => %{}, "required" => []}
          }
        ])

      refute Map.has_key?(tool["function"], "description")
      assert tool["function"]["name"] == "get_date"
    end
  end
end
