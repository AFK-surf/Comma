defmodule SalixLlm.AnthropicThinkingReplayTest do
  @moduledoc """
  Extended-thinking round trip: an assistant turn's `thinking` /
  `redacted_thinking` blocks are journaled verbatim on the way in and replayed
  unchanged on the way out.

  The API requires them back unmodified on the turn that made a tool call —
  dropping or editing them breaks the turn, and stripping them can trigger
  ordering/signature 400s — so a signature that survives capture but not replay
  is the same defect as not capturing it.
  """
  use ExUnit.Case, async: true

  alias SalixLlm.{Convert, Stream}

  @model "claude-opus-4-8"

  defp thinking_block(text \\ "step one", signature \\ "sig-abc") do
    %{"type" => "thinking", "thinking" => text, "signature" => signature}
  end

  describe "capture" do
    test "a blocking tool_use turn journals its thinking blocks verbatim" do
      resp = %{
        "content" => [
          thinking_block(),
          %{"type" => "redacted_thinking", "data" => "encrypted-blob"},
          %{"type" => "text", "text" => "calling echo"},
          %{"type" => "tool_use", "id" => "t1", "name" => "echo", "input" => %{"text" => "hi"}}
        ],
        "stop_reason" => "tool_use"
      }

      assert {:assistant, "calling echo", [%{id: "t1"}], provider_meta} =
               Convert.parse_response(resp)

      assert provider_meta["anthropic_thinking"] == [
               thinking_block(),
               %{"type" => "redacted_thinking", "data" => "encrypted-blob"}
             ]
    end

    test "a final turn journals its thinking too — the round replays it next" do
      resp = %{
        "content" => [thinking_block(), %{"type" => "text", "text" => "done"}],
        "stop_reason" => "end_turn"
      }

      assert {:final, "done", provider_meta, %{}} = Convert.parse_response(resp)
      assert provider_meta["anthropic_thinking"] == [thinking_block()]
    end

    test "a turn without thinking keeps the plain result shapes" do
      assert {:final, "done"} =
               Convert.parse_response(%{
                 "content" => [%{"type" => "text", "text" => "done"}],
                 "stop_reason" => "end_turn"
               })

      assert {:assistant, "", [%{id: "t1"}]} =
               Convert.parse_response(%{
                 "content" => [
                   %{"type" => "tool_use", "id" => "t1", "name" => "e", "input" => %{}}
                 ],
                 "stop_reason" => "tool_use"
               })
    end

    test "a streamed turn accumulates thinking text and its signature" do
      body = """
      data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"step "}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"one"}}

      data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}

      data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"encrypted-blob"}}

      data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

      data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"done"}}

      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
      """

      assert {:final, "done", provider_meta, %{}} = Stream.decode(body)

      assert provider_meta["anthropic_thinking"] == [
               thinking_block(),
               %{"type" => "redacted_thinking", "data" => "encrypted-blob"}
             ]
    end

    test "a delta for a block that never started is dropped, not raised" do
      body =
        ~s(data: {"type":"content_block_delta","index":7,) <>
          ~s("delta":{"type":"signature_delta","signature":"orphan"}}\n)

      assert {:final, ""} = Stream.decode(body)
    end
  end

  describe "replay" do
    defp journaled_turn(extra \\ %{}) do
      {meta, extra} = Map.pop(extra, :provider_meta)

      Map.merge(
        %{
          role: "assistant",
          content: "calling echo",
          model: @model,
          tool_calls: [%{"id" => "t1", "name" => "echo", "args" => %{"text" => "hi"}}],
          provider_meta:
            meta ||
              %{
                "anthropic_thinking" => [thinking_block()],
                "anthropic_thinking_model" => @model
              }
        },
        extra
      )
    end

    test "thinking replays unchanged, ahead of the text and tool_use blocks" do
      {_system, [assistant]} = Convert.to_anthropic([journaled_turn()], @model)

      assert %{"role" => "assistant", "content" => blocks} = assistant

      assert [
               %{"type" => "thinking", "thinking" => "step one", "signature" => "sig-abc"},
               %{"type" => "text", "text" => "calling echo"},
               %{"type" => "tool_use", "id" => "t1", "name" => "echo"}
             ] = blocks
    end

    test "a turn from another model replays without its thinking" do
      {_system, [assistant]} = Convert.to_anthropic([journaled_turn()], "claude-sonnet-5")

      assert %{"content" => blocks} = assistant
      refute Enum.any?(blocks, &(&1["type"] == "thinking"))
      assert [%{"type" => "text"}, %{"type" => "tool_use"}] = blocks
    end

    test "an alias request keeps its thinking even though the response resolved it" do
      # Aliases resolve to a concrete snapshot id server-side, so the response
      # reports a different model string than the request sent. Comparing that
      # against the next request's configured alias would strip the signed
      # blocks on every round — the exact breakage this journaling prevents.
      alias_id = "claude-opus-4-5"
      resolved = "claude-opus-4-5-20251101"

      resp = %{
        "model" => resolved,
        "content" => [
          thinking_block(),
          %{"type" => "tool_use", "id" => "t1", "name" => "echo", "input" => %{"text" => "hi"}}
        ],
        "stop_reason" => "tool_use"
      }

      {:assistant, text, calls, provider_meta} = Convert.parse_response(resp, alias_id)
      assert provider_meta["anthropic_thinking_model"] == alias_id

      # The round persists the provider-reported model on the message; replay
      # must not be decided by it.
      journaled = %{
        role: "assistant",
        content: text,
        model: resolved,
        tool_calls: Enum.map(calls, &%{"id" => &1.id, "name" => &1.name, "args" => &1.args}),
        provider_meta: provider_meta
      }

      {_system, [assistant]} = Convert.to_anthropic([journaled], alias_id)

      assert [
               %{"type" => "thinking", "signature" => "sig-abc"},
               %{"type" => "tool_use", "id" => "t1"}
             ] = assistant["content"]
    end

    test "a journal without a recorded request model replays permissively" do
      # A wrongly withheld block fails the turn; a genuinely foreign one is
      # dropped server-side. With no evidence of a switch, replay.
      turn = journaled_turn(%{provider_meta: %{"anthropic_thinking" => [thinking_block()]}})

      {_system, [assistant]} = Convert.to_anthropic([turn], @model)
      assert [%{"type" => "thinking"} | _] = assistant["content"]
    end

    test "a request with no configured model replays journaled thinking" do
      {_system, [assistant]} = Convert.to_anthropic([journaled_turn()], nil)
      assert [%{"type" => "thinking"} | _] = assistant["content"]
    end

    test "a compaction-pruned tool call takes its tool_use block with it" do
      # Compaction drops tool calls whose results are gone. Because the turn is
      # rebuilt from `tool_calls` rather than replayed whole, the pruning holds
      # and no orphaned tool_use survives to 400 the request.
      turn = journaled_turn(%{tool_calls: []})

      {_system, [assistant]} = Convert.to_anthropic([turn], @model)

      assert [%{"type" => "thinking"}, %{"type" => "text", "text" => "calling echo"}] =
               assistant["content"]
    end

    test "a turn with only thinking and no answer is still dropped" do
      turn = journaled_turn(%{content: "", tool_calls: []})

      assert {_system, []} = Convert.to_anthropic([turn], @model)
    end

    test "non-block junk in the journal never reaches the request" do
      turn =
        journaled_turn(%{provider_meta: %{"anthropic_thinking" => ["nope", %{"type" => "x"}]}})

      {_system, [assistant]} = Convert.to_anthropic([turn], @model)
      assert [%{"type" => "text"}, %{"type" => "tool_use"}] = assistant["content"]
    end

    test "a full round trip survives capture and replay byte-for-byte" do
      resp = %{
        "content" => [
          thinking_block(),
          %{"type" => "text", "text" => "calling echo"},
          %{"type" => "tool_use", "id" => "t1", "name" => "echo", "input" => %{"text" => "hi"}}
        ],
        "stop_reason" => "tool_use"
      }

      {:assistant, text, calls, provider_meta} = Convert.parse_response(resp, @model)

      journaled = %{
        role: "assistant",
        content: text,
        model: @model,
        tool_calls: Enum.map(calls, &%{"id" => &1.id, "name" => &1.name, "args" => &1.args}),
        provider_meta: provider_meta
      }

      {_system, [assistant]} = Convert.to_anthropic([journaled], @model)

      assert assistant["content"] == resp["content"]
    end
  end
end
