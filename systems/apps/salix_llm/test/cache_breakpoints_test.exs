defmodule SalixLlm.CacheBreakpointsTest do
  @moduledoc """
  Automatic `cache_control` placement.

  The properties that matter are structural: the frozen prefix (tools + system)
  always gets exactly one breakpoint, the conversation tail gets a rolling one
  the next round can read back, long tails get intermediates inside the API's
  20-content-block lookback window, and the request never exceeds the 4
  breakpoints the API allows.
  """
  use ExUnit.Case, async: true

  alias SalixLlm.CacheBreakpoints

  @ephemeral %{"type" => "ephemeral"}

  defp user(text), do: %{"role" => "user", "content" => text}

  defp blocks_message(role, n) do
    %{
      "role" => role,
      "content" => for(i <- 1..n, do: %{"type" => "text", "text" => "block #{i}"})
    }
  end

  defp breakpoint_count(value), do: value |> flatten_maps() |> Enum.count(& &1["cache_control"])

  defp flatten_maps(%{} = map) do
    [map | map |> Map.values() |> Enum.flat_map(&flatten_maps/1)]
  end

  defp flatten_maps(list) when is_list(list), do: Enum.flat_map(list, &flatten_maps/1)
  defp flatten_maps(_other), do: []

  defp total_breakpoints(system, tools, messages),
    do: breakpoint_count(system) + breakpoint_count(tools) + breakpoint_count(messages)

  # Content blocks between consecutive marked positions. The run before the
  # first mark is dropped: that breakpoint looks back to the frozen-prefix
  # entry, not to another tail entry.
  defp gaps_between_breakpoints(messages) do
    messages
    |> Enum.reduce({[], 0}, fn message, {gaps, since} ->
      since = since + block_count(message)
      if breakpoint_count(message) > 0, do: {[since | gaps], 0}, else: {gaps, since}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.drop(1)
  end

  defp block_count(%{"content" => content}) when is_list(content), do: length(content)
  defp block_count(_message), do: 1

  describe "frozen prefix" do
    test "the system prompt becomes a marked text block, caching tools with it" do
      {system, tools, _messages} =
        CacheBreakpoints.place("you are a bot", [%{"name" => "echo"}], [user("hi")])

      assert system == [
               %{"type" => "text", "text" => "you are a bot", "cache_control" => @ephemeral}
             ]

      # Tools render before system, so the system marker already covers them.
      assert tools == [%{"name" => "echo"}]
    end

    test "with no system prompt the marker falls to the last tool definition" do
      {system, tools, _messages} =
        CacheBreakpoints.place(nil, [%{"name" => "a"}, %{"name" => "b"}], [user("hi")])

      assert system == nil
      assert [%{"name" => "a"}, %{"name" => "b", "cache_control" => @ephemeral}] = tools
    end

    test "with neither system nor tools there is no prefix to mark" do
      {system, tools, _messages} = CacheBreakpoints.place(nil, nil, [user("hi")])
      assert system == nil
      assert tools == nil
    end

    test "an empty system string is not a cacheable block" do
      {system, tools, _messages} = CacheBreakpoints.place("", [%{"name" => "a"}], [user("hi")])
      assert system == ""
      assert [%{"name" => "a", "cache_control" => @ephemeral}] = tools
    end
  end

  describe "conversation tail" do
    test "the last turn carries the rolling breakpoint the next round reads back" do
      {_system, _tools, messages} =
        CacheBreakpoints.place("sys", nil, [user("first"), user("second")])

      assert [
               %{"content" => "first"},
               %{"content" => [%{"type" => "text", "text" => "second", "cache_control" => _}]}
             ] = messages
    end

    test "a block-list turn is marked on its last block only" do
      message = %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "a"},
          %{"type" => "tool_result", "tool_use_id" => "t2", "content" => "b"}
        ]
      }

      {_system, _tools, [marked]} = CacheBreakpoints.place("sys", nil, [message])

      assert [%{"tool_use_id" => "t1"} = first, %{"tool_use_id" => "t2"} = last] =
               marked["content"]

      refute Map.has_key?(first, "cache_control")
      assert last["cache_control"] == @ephemeral
    end

    test "an unmarkable final turn passes the breakpoint to the nearest one that fits" do
      {_system, _tools, messages} =
        CacheBreakpoints.place("sys", nil, [user("real"), user("")])

      assert [%{"content" => [%{"text" => "real", "cache_control" => _}]}, %{"content" => ""}] =
               messages
    end

    test "a long tail gets an intermediate inside the 20-block lookback window" do
      # One round can append more than 20 content blocks; without an
      # intermediate, the next round's breakpoint cannot see this round's entry.
      messages = [user("start"), blocks_message("assistant", 18), blocks_message("user", 18)]

      {_system, _tools, marked} = CacheBreakpoints.place("sys", nil, messages)

      assert breakpoint_count(marked) == 2
      assert Enum.all?(gaps_between_breakpoints(marked), &(&1 <= 20))
    end

    test "the tail never spends more than the API's remaining breakpoints" do
      messages = for i <- 1..40, do: blocks_message("user", 5) |> Map.put("i", i)

      {system, tools, marked} = CacheBreakpoints.place("sys", [%{"name" => "a"}], messages)

      assert breakpoint_count(marked) == 3
      assert total_breakpoints(system, tools, marked) == 4
      assert Enum.all?(gaps_between_breakpoints(marked), &(&1 <= 20))
    end

    test "an empty conversation is left alone" do
      assert {_system, _tools, []} = CacheBreakpoints.place("sys", nil, [])
    end
  end

  describe "disabled" do
    test "everything passes through untouched" do
      system = "sys"
      tools = [%{"name" => "a"}]
      messages = [user("hi")]

      assert {^system, ^tools, ^messages} =
               CacheBreakpoints.place(system, tools, messages, false)
    end
  end

  test "placement is deterministic — the same request marks the same positions" do
    messages = [user("a"), blocks_message("assistant", 20), user("b")]

    assert CacheBreakpoints.place("sys", nil, messages) ==
             CacheBreakpoints.place("sys", nil, messages)
  end

  test "an appended round keeps the previous tail bytes intact ahead of the new marker" do
    # The next round's prefix must still contain the bytes the previous round
    # cached, or there is nothing to read back.
    round_1 = [user("hi")]

    round_2 =
      round_1 ++ [%{"role" => "assistant", "content" => [%{"type" => "text", "text" => "a"}]}]

    {_s1, _t1, [marked_1]} = CacheBreakpoints.place("sys", nil, round_1)
    {_s2, _t2, [carried, _new_tail]} = CacheBreakpoints.place("sys", nil, round_2)

    # Round 2 no longer marks the first turn, but its content is byte-identical
    # apart from the marker, which is metadata rather than cached content.
    assert [%{"type" => "text", "text" => "hi"}] = marked_1["content"] |> strip_markers()
    assert carried["content"] == "hi"
  end

  defp strip_markers(blocks) when is_list(blocks),
    do: Enum.map(blocks, &Map.delete(&1, "cache_control"))
end
