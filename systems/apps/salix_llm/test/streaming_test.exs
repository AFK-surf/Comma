defmodule SalixLlm.StreamingTest do
  @moduledoc """
  `SalixLlm.Streaming.complete_stream/4` against a mock SSE
  server: text deltas fire `on_delta` incrementally and in order across
  chunk-split lines, and the final reassembled result equals what
  `SalixLlm.Stream.decode/1` produces for the full body.
  """
  use ExUnit.Case, async: false

  alias SalixLlm.{MockSSEServer, Stream, Streaming}

  # No cluster-wide config: the provider config arrives per call via
  # opts[:llm] (the agent's template-resolved llm_opts).
  setup do
    start_supervised!(MockSSEServer)
    # Randomized port avoids collisions with stray listeners across runs.
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockSSEServer, port: p} end)

    llm_opts = %{
      "protocol" => "anthropic",
      "model" => "claude-opus-4-8",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test-key"
    }

    {:ok, llm_opts: llm_opts}
  end

  defp recorder do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    on_delta = fn text -> Agent.update(rec, &[text | &1]) end
    {rec, on_delta}
  end

  defp deltas(rec), do: rec |> Agent.get(& &1) |> Enum.reverse()

  test "a kernel-built round request preserves the stored prompt and streamed output", %{
    llm_opts: opts
  } do
    previous = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, SalixLlm.Provider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :llm, previous),
        else: Application.delete_env(:salix_agent, :llm)
    end)

    session =
      SalixVerifiedKernel.Session.new("agent", "session")
      |> SalixVerifiedKernel.Session.export()
      |> Map.put(:messages, [%{id: 1, role: "user", content: "resident 雪"}])
      |> Map.put(:system_prompt, "stored prompt")
      |> SalixVerifiedKernel.Session.open()

    # As a round does: the kernel builds the request from the stored session
    # for the dispatch's provider configuration.
    {protocol, cfg, _images?} = SalixAgent.LLM.request_config(opts)

    config = %{
      "role" => "worker",
      "canonical_router" => false,
      "disclosure" => %{},
      "protocol" => protocol,
      "cfg" => cfg,
      "tools" => [echo_tool_spec()],
      "mode" => "stream"
    }

    {:ok, body, _facts} =
      SalixVerifiedKernel.Session.query(session, :round_request, config, fn _read -> nil end)

    request = {:encoded_provider_request, protocol, body}
    {rec, on_delta} = recorder()

    assert {:assistant, "Hello there", [_]} =
             SalixAgent.LLM.complete_stream(request, [echo_tool_spec()], on_delta, opts)

    assert deltas(rec) == ["Hello ", "there"]
    body = MockSSEServer.last_request()
    assert body["model"] == opts["model"]
    assert body["stream"] == true
    assert hd(body["system"])["text"] == "stored prompt"
    assert hd(hd(body["messages"])["content"])["text"] == "resident 雪"
  end

  test "HTTP error bodies cannot emit assistant deltas", %{llm_opts: llm_opts} do
    MockSSEServer.set_chunks(
      [
        ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"not an answer"}}\n)
      ],
      500
    )

    {rec, on_delta} = recorder()

    assert {:error, %{"status" => 500, "retryable" => true}} =
             Streaming.complete_stream([%{role: "user", content: "hi"}], [], on_delta,
               llm: llm_opts
             )

    assert deltas(rec) == []
  end

  test "text + tool_use stream: deltas fire in order, final result matches Stream.decode",
       %{llm_opts: llm_opts} do
    body = MockSSEServer.default_body()
    # 7-byte chunks split every `data:` line across multiple chunks.
    MockSSEServer.set_body(body, 7)
    {rec, on_delta} = recorder()

    result =
      Streaming.complete_stream(
        [%{role: "user", content: "use echo"}],
        [echo_tool_spec()],
        on_delta,
        llm: llm_opts
      )

    assert {:assistant, "Hello there", [%{id: "t1", name: "echo", args: %{"text" => "hi"}}]} =
             result

    assert result == Stream.decode(body)
    assert deltas(rec) == ["Hello ", "there"]

    # The outgoing request was the standard Messages body plus "stream": true.
    req = MockSSEServer.last_request()
    assert req["stream"] == true
    assert req["model"] == "claude-opus-4-8"
    # The conversation tail carries the rolling cache breakpoint, which promotes
    # the string turn to block form (see SalixLlm.CacheBreakpoints).
    assert [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "use echo", "cache_control" => _}]
             }
           ] = req["messages"]

    assert [%{"name" => "echo", "input_schema" => _}] = req["tools"]
  end

  test "text-only stream returns {:final, _} and deltas concatenate to the final text",
       %{llm_opts: llm_opts} do
    body = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_2"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"streamed "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"reply, "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"in pieces"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    event: message_stop
    data: {"type":"message_stop"}
    """

    MockSSEServer.set_body(body, 11)
    {rec, on_delta} = recorder()

    result =
      Streaming.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm: llm_opts)

    assert {:final, "streamed reply, in pieces"} = result
    assert result == Stream.decode(body)
    fired = deltas(rec)
    assert fired == ["streamed ", "reply, ", "in pieces"]
    assert IO.iodata_to_binary(fired) == "streamed reply, in pieces"
  end

  # Extended-thinking blocks are private raw reasoning. They still cross the
  # typed provider callback in order, but carry no public activity authority.
  test "thinking deltas are classified private and stay separate from text deltas",
       %{llm_opts: llm_opts} do
    body = """
    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think about this."}}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}

    event: message_stop
    data: {"type":"message_stop"}
    """

    MockSSEServer.set_body(body, 11)
    {rec, on_delta} = recorder()
    {reasoning_rec, on_reasoning} = recorder()

    result =
      Streaming.complete_stream([%{role: "user", content: "hi"}], [], on_delta,
        llm: Map.put(llm_opts, :on_reasoning_delta, on_reasoning)
      )

    # The reassembled turn keeps the thinking block for replay; only the text
    # is the assistant's answer.
    assert {:final, "Hello", provider_meta, _trace} = result
    assert deltas(rec) == ["Hello"]

    assert provider_meta["anthropic_thinking"] == [
             %{
               "type" => "thinking",
               "thinking" => "Let me think about this.",
               "signature" => ""
             }
           ]

    assert deltas(reasoning_rec) == [
             SalixAgent.LLM.ReasoningDelta.private_reasoning("Let me "),
             SalixAgent.LLM.ReasoningDelta.private_reasoning("think about this.")
           ]
  end

  test "a final data line without a trailing newline still fires and decodes",
       %{llm_opts: llm_opts} do
    body =
      "data:{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" <>
        "data:{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"tail\"}}"

    MockSSEServer.set_body(body, 9)
    {rec, on_delta} = recorder()

    result =
      Streaming.complete_stream([%{role: "user", content: "hi"}], [], on_delta, llm: llm_opts)

    assert {:final, "tail"} = result
    assert result == Stream.decode(body)
    assert deltas(rec) == ["tail"]
  end

  test "tool_use args stream through on_tool and reconstruct the complete call",
       %{llm_opts: llm_opts} do
    args =
      Jason.encode!(%{
        "tool" => "im_api.internal.send_message",
        "params" => %{"conversation_id" => "c1", "content" => "Hello world"}
      })

    fragments = for <<piece::binary-size(7) <- args>>, do: piece

    fragments =
      fragments ++
        [binary_part(args, length(fragments) * 7, byte_size(args) - length(fragments) * 7)]

    start =
      "data: " <>
        Jason.encode!(%{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "call"
          }
        }) <> "\n\n"

    deltas =
      Enum.map(fragments, fn f ->
        "data: " <>
          Jason.encode!(%{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => f}
          }) <> "\n\n"
      end)

    MockSSEServer.set_chunks([start | deltas] ++ ["data: {\"type\":\"message_stop\"}\n\n"])

    {:ok, rec} = Agent.start_link(fn -> {nil, ""} end)

    on_tool = fn frag ->
      Agent.update(rec, fn {name, fragments} ->
        {name || frag.name, fragments <> (frag.fragment || "")}
      end)
    end

    llm = Map.put(llm_opts, :on_tool_delta, on_tool)

    Streaming.complete_stream(
      [%{role: "user", content: "hi"}],
      [call_tool_spec()],
      fn _ -> :ok end,
      llm: llm
    )

    {name, reconstructed} = Agent.get(rec, & &1)
    assert name == "call"
    assert get_in(Jason.decode!(reconstructed), ["params", "content"]) == "Hello world"
  end

  defp echo_tool_spec do
    %{
      "name" => "echo",
      "description" => "echo text",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    }
  end

  defp call_tool_spec do
    %{
      "name" => "call",
      "description" => "call tool",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "tool" => %{"type" => "string"},
          "params" => %{"type" => "object"}
        },
        "required" => ["tool", "params"]
      }
    }
  end

  # Bind Bandit on a random port, retrying on collisions across suites.
  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      p = 40000 + :erlang.phash2(make_ref(), 20000)

      case ExUnit.Callbacks.start_supervised(spec_fun.(p), id: {:bandit_retry, p}) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
