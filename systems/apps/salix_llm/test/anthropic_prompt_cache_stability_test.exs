defmodule SalixLlm.AnthropicPromptCacheStabilityTest do
  @moduledoc """
  Anthropic prompt caching is a prefix match: an entry is read back only when
  the bytes ahead of a breakpoint are identical to the bytes that wrote it.

  `SalixAgent.Round` builds every request as the prompt snapshot, then the
  conversation, then whatever context the round derived — mid-conversation
  runtime facts, the activation delta, the end-of-turn reminders. Folding all of
  those into `system` (which renders ahead of every message) rewrote the prefix
  of the entire request on every round, so each call wrote a fresh entry and
  read none back: `cache_read_input_tokens` pinned at 0 while
  `cache_creation_input_tokens` stayed full. These tests pin the two properties
  that fix restores.
  """
  use ExUnit.Case, async: true

  alias SalixLlm.{CacheBreakpoints, Convert}

  @ephemeral %{"type" => "ephemeral"}

  defp reminder(text), do: %{role: "summary", content: text}

  defp runtime_fact(id) do
    %{
      role: "runtime",
      kind: "runtime_message",
      runtime_message_id: id,
      type: "tool_call_completed",
      summary: "background tool call #{id} finished"
    }
  end

  defp project_knowledge do
    %{
      role: "runtime",
      kind: "runtime_message",
      runtime_message_id: "project-knowledge:atlas",
      type: "project_knowledge",
      summary: "Resolved project knowledge for this question",
      content: ~s({"facts":[{"content":"The Atlas launch codename is ORBITAL-TEAL-47."}]})
    }
  end

  defp round(conversation, trailing) do
    [%{role: "summary", content: "You are Salix."} | conversation] ++ trailing
  end

  # The prefix a breakpoint's cache entry is keyed on: every message up to and
  # including the marked one, as rendered.
  defp cached_prefix(messages) do
    index = Enum.find_index(messages, &(breakpoints(&1) > 0))
    messages |> Enum.take(index + 1) |> rendered()
  end

  # The key is the rendered prompt, and a plain-string turn renders as a single
  # text block — which is what lets `mark_last_block/1` promote a marked turn
  # without moving cached bytes. Compare what the API sees, not the shape.
  defp rendered(messages) do
    messages
    |> strip_markers()
    |> Enum.map(fn
      %{"content" => content} = message when is_binary(content) ->
        %{message | "content" => [%{"type" => "text", "text" => content}]}

      message ->
        message
    end)
  end

  defp request(messages) do
    {system, msgs, trailing} = Convert.to_anthropic_parts(messages, "claude-opus-5")
    CacheBreakpoints.place(system, [%{"name" => "echo"}], msgs, true, trailing)
  end

  defp marked_messages(messages),
    do: Enum.filter(messages, &(breakpoints(&1) > 0))

  defp breakpoints(%{"content" => content}) when is_list(content),
    do: Enum.count(content, & &1["cache_control"])

  defp breakpoints(_message), do: 0

  defp strip_markers(%{} = map),
    do: map |> Map.delete("cache_control") |> Map.new(fn {k, v} -> {k, strip_markers(v)} end)

  defp strip_markers(list) when is_list(list), do: Enum.map(list, &strip_markers/1)
  defp strip_markers(other), do: other

  describe "the frozen prefix survives the next round" do
    test "trailing reminders and runtime facts do not rewrite the system block" do
      first =
        round(
          [%{role: "user", content: "book the room"}],
          [reminder("Reply before ending the turn.")]
        )

      second =
        round(
          [
            %{role: "user", content: "book the room"},
            %{role: "assistant", content: "done"},
            runtime_fact("runtime-1"),
            %{role: "user", content: "thanks"}
          ],
          [reminder("Unresolved external reply obligations (2 total).")]
        )

      {system_a, tools_a, _} = request(first)
      {system_b, tools_b, _} = request(second)

      assert system_a == [
               %{"type" => "text", "text" => "You are Salix.", "cache_control" => @ephemeral}
             ]

      assert system_a == system_b
      assert tools_a == tools_b
    end

    test "new time readings preserve the cached prefix containing an adopted reading" do
      reading = %{
        role: "runtime",
        type: "time_context",
        content_kind: "model_context",
        runtime_message_id: "time-1",
        summary: "current time context",
        content: "sampled_at: 2026-09-10T00:00:00Z"
      }

      history = [%{role: "user", content: "yesterday?"}, reading]
      {system_a, tools_a, first} = request(round(history, [reminder("reply now")]))

      later = %{
        reading
        | runtime_message_id: "time-2",
          content: "sampled_at: 2026-09-11T00:00:00Z"
      }

      {system_b, tools_b, second} =
        request(round(history ++ [%{role: "assistant", content: "September 9"}, later], []))

      assert system_a == system_b
      assert tools_a == tools_b
      prefix = cached_prefix(first)
      assert inspect(prefix) =~ "2026-09-10T00:00:00Z"
      assert prefix == second |> rendered() |> Enum.take(length(prefix))
    end

    test "a mid-conversation runtime fact leaves the earlier turns byte-identical" do
      base = [
        %{role: "user", content: "start"},
        %{role: "assistant", content: "working"}
      ]

      {_, _, before_msgs} = request(round(base, []))
      {_, _, after_msgs} = request(round(base ++ [runtime_fact("runtime-9")], []))

      # `cache_control` is a marker, not prompt content: what has to stay
      # identical is the rendered bytes the next round hashes.
      assert strip_markers(Enum.take(after_msgs, 2)) == strip_markers(before_msgs)
    end
  end

  describe "the conversation tail breakpoint" do
    test "sits on the last durable turn, not on a re-derived reminder" do
      {_system, _tools, messages} =
        request(
          round(
            [
              %{role: "user", content: "start"},
              %{role: "assistant", content: "on it"},
              %{role: "user", content: "any update?"}
            ],
            [reminder("Re-evaluate every current request."), reminder("Reply before end_turn.")]
          )
        )

      assert [%{"content" => [%{"type" => "text", "text" => "any update?"}]}] =
               marked_messages(messages)

      assert List.last(messages)["content"] =~ "Reply before end_turn."
      assert breakpoints(List.last(messages)) == 0
    end

    test "a trailing runtime fact carries it — the round commits that fact" do
      # The activation delta lands after the conversation like the reminders do,
      # but it is journaled with the round, so the next request still has it in
      # the same place and can read the entry back.
      {_system, _tools, messages} =
        request(round([%{role: "user", content: "start"}, runtime_fact("runtime-2")], []))

      assert [marked] = marked_messages(messages)
      assert Map.delete(marked, "content") == Map.delete(List.last(messages), "content")
      assert hd(marked["content"])["text"] =~ "runtime_message_id: runtime-2"
    end

    test "only the trailing reminder run is skipped, not context further back" do
      {_system, _tools, messages} =
        request(
          round(
            [
              %{role: "user", content: "start"},
              reminder("A reminder this round already committed."),
              %{role: "user", content: "any update?"}
            ],
            [reminder("Reply before ending the turn.")]
          )
        )

      assert [%{"content" => [%{"text" => "any update?"}]}] = marked_messages(messages)
      assert length(messages) == 4
    end

    test "a runtime fact between a tool call and its result does not split them" do
      # The Messages API 400s on a `tool_use` whose `tool_result` is not in the
      # next message, and the transcript is resent verbatim on every wake, so
      # the context turn moves rather than the results.
      {_system, messages, _trailing} =
        Convert.to_anthropic_parts(
          [
            %{role: "user", content: "run it"},
            %{
              role: "assistant",
              content: "",
              tool_calls: [%{"id" => "call-1", "name" => "shell", "args" => %{}}]
            },
            runtime_fact("runtime-4"),
            %{role: "tool", tool_call_id: "call-1", content: "done"},
            %{role: "user", content: "thanks"}
          ],
          nil
        )

      assert [
               %{"content" => "run it"},
               %{"role" => "assistant", "content" => [%{"type" => "tool_use"}]},
               %{"content" => [%{"type" => "tool_result", "tool_use_id" => "call-1"}]},
               %{"content" => "<system>\n<runtime-message>" <> _},
               %{"content" => "thanks"}
             ] = messages
    end

    test "an unanswered tool call leaves the transcript order alone" do
      # Nothing to pull up, so the repair path — not this reordering — owns the
      # inconsistency: a later call's result must not jump to the earlier one.
      {_system, messages, _trailing} =
        Convert.to_anthropic_parts(
          [
            %{
              role: "assistant",
              content: "",
              tool_calls: [%{"id" => "call-1", "name" => "shell", "args" => %{}}]
            },
            %{role: "user", content: "still there?"},
            %{
              role: "assistant",
              content: "",
              tool_calls: [%{"id" => "call-2", "name" => "shell", "args" => %{}}]
            },
            %{role: "tool", tool_call_id: "call-2", content: "done"}
          ],
          nil
        )

      assert [
               %{"role" => "assistant", "content" => [%{"id" => "call-1"}]},
               %{"content" => "still there?"},
               %{"role" => "assistant", "content" => [%{"id" => "call-2"}]},
               %{"content" => [%{"type" => "tool_result", "tool_use_id" => "call-2"}]}
             ] = messages
    end

    test "project knowledge cannot carry it — the next request has dropped it" do
      # The kernel's `request_live_messages` keeps a `project_knowledge` fact
      # only while the activation that retrieved it is current: the next user
      # input drops it from every later rebuild, so a breakpoint on it writes
      # up to 32 KiB of prefix that is never readable again. Request N marks
      # the last turn that request N+1 still has.
      {_system, _tools, first} =
        request(
          round(
            [%{role: "user", content: "what is the codename?"}, project_knowledge()],
            [reminder("Reply before ending the turn.")]
          )
        )

      assert [%{"content" => [%{"text" => "what is the codename?"}]}] = marked_messages(first)

      knowledge_turn = Enum.at(first, 1)
      assert knowledge_turn["content"] =~ "ORBITAL-TEAL-47"
      assert breakpoints(knowledge_turn) == 0

      # Request N+1: project knowledge is gone, the conversation moved on.
      {_system, _tools, second} =
        request(
          round(
            [
              %{role: "user", content: "what is the codename?"},
              %{role: "assistant", content: "ORBITAL-TEAL-47"},
              %{role: "user", content: "thanks"}
            ],
            [reminder("Reply before ending the turn.")]
          )
        )

      prefix = cached_prefix(first)
      assert prefix == second |> rendered() |> Enum.take(length(prefix))
    end

    test "the trailing-context count only covers the re-derived tail" do
      messages =
        round(
          [%{role: "user", content: "start"}, runtime_fact("runtime-3")],
          [reminder("first"), reminder("second")]
        )

      assert {"You are Salix.", projected, 2} = Convert.to_anthropic_parts(messages, nil)
      assert length(projected) == 4
    end
  end
end
