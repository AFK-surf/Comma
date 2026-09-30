defmodule SalixLlm.OpenAIResponsesStreamToolTest do
  @moduledoc """
  Responses streaming surfaces `response.function_call_arguments.delta` fragments
  through `on_tool_delta` (name recorded from `response.output_item.added`). The
  callback carries decoded argument fragments, including safe prefixes decoded
  from a still-open SSE data line.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.ReasoningDelta
  alias SalixLlm.{MockSSEServer, OpenAIResponses}

  setup do
    start_supervised!(MockSSEServer)
    port = start_bandit_retry!(fn p -> {Bandit, plug: MockSSEServer, port: p} end)

    llm_opts = %{
      "protocol" => "responses",
      "model" => "gpt-test",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test-key"
    }

    {:ok, llm_opts: llm_opts}
  end

  test "function-call argument deltas reach on_tool and reconstruct the complete call",
       %{llm_opts: llm_opts} do
    args =
      Jason.encode!(%{
        "tool" => "im_api.internal.send_message",
        "params" => %{"conversation_id" => "c1", "content" => "Hello world"}
      })

    n7 = div(byte_size(args), 7)

    fragments =
      for(<<piece::binary-size(7) <- args>>, do: piece) ++
        [binary_part(args, n7 * 7, byte_size(args) - n7 * 7)]

    added =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "call",
            "arguments" => ""
          }
        }) <> "\n\n"

    deltas =
      Enum.map(fragments, fn f ->
        "data: " <>
          Jason.encode!(%{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "fc_1",
            "output_index" => 0,
            "delta" => f
          }) <> "\n\n"
      end)

    completed =
      "data: " <>
        Jason.encode!(%{"type" => "response.completed", "response" => %{"output" => []}}) <>
        "\n\n"

    MockSSEServer.set_chunks([added | deltas] ++ [completed])

    {:ok, rec} = Agent.start_link(fn -> {nil, ""} end)

    on_tool = fn frag ->
      Agent.update(rec, fn {name, fragments} ->
        {name || frag.name, fragments <> (frag.fragment || "")}
      end)
    end

    opts = Map.put(llm_opts, :on_tool_delta, on_tool)

    OpenAIResponses.complete_stream([%{role: "user", content: "hi"}], [], fn _ -> :ok end, opts)

    {name, reconstructed} = Agent.get(rec, & &1)
    assert name == "call"
    assert get_in(Jason.decode!(reconstructed), ["params", "content"]) == "Hello world"
  end

  test "the canonical IM call streams text before the HTTP response finishes",
       %{llm_opts: llm_opts} do
    alias SalixAgent.SendMessageDraftStream

    {:ok, scope} =
      SalixAgent.TestSupport.PresentationScope.with_identity(%{
        "provider" => "internal",
        "conversation_kind" => "user_chat",
        "source_actor_type" => "user",
        "agent_group_id" => "group",
        "conversation_id" => "source-conversation",
        "participant_id" => "participant",
        "source_message_ids" => ["source"],
        "source_messages" => [%{"source_message_id" => "source", "message_id" => "message"}]
      })

    args =
      ~s({"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":"source-conversation","content":[{"type":"text","text":"第一句，第二句。"}]}})

    item = Map.put(function_call_item(args), "name", "call")
    encode = fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end

    {prefix, suffix} =
      :erlang.split_binary(args, elem(:binary.match(args, "第一句"), 0) + byte_size("第一句"))

    added =
      encode.(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{item | "arguments" => ""}
      })

    delta = fn text ->
      encode.(%{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_1",
        "output_index" => 0,
        "delta" => text
      })
    end

    completed =
      encode.(%{"type" => "response.completed", "response" => %{"output" => [item]}})

    parent = self()

    MockSSEServer.set_chunks([
      added,
      {:barrier, delta.(prefix), parent, :reply_prefix},
      delta.(suffix),
      completed
    ])

    {:ok, recorder} = Agent.start_link(fn -> SendMessageDraftStream.new() end)

    on_tool = fn fragment ->
      action =
        Agent.get_and_update(recorder, fn state ->
          {next, action} = SendMessageDraftStream.consume(state, fragment, scope)
          {action, next}
        end)

      if match?({:publish, _}, action), do: send(parent, action)
    end

    request =
      Task.async(fn ->
        OpenAIResponses.complete_stream(
          [%{role: "user", content: "hi"}],
          [],
          fn _ -> :ok end,
          Map.put(llm_opts, :on_tool_delta, on_tool)
        )
      end)

    assert_receive {:mock_sse_barrier, :reply_prefix, server}, 1_000
    assert_receive {:publish, "第一句"}, 1_000
    assert Task.yield(request, 0) == nil
    send(server, {:release_mock_sse_barrier, :reply_prefix})
    _response = Task.await(request, 5_000)
    assert_receive {:publish, "第一句，第二句。"}, 1_000
  end

  test "one unfinished SSE data line streams its decoded tool argument prefix",
       %{llm_opts: llm_opts} do
    args =
      Jason.encode!(%{
        "tool" => "im_api.internal.send_message",
        "params" => %{
          "conversation_id" => "c1",
          "content" =>
            String.duplicate("leading-", 1_024) <>
              "stream-prefix-✓ " <> String.duplicate("still-streaming-", 160)
        }
      })

    item = function_call_item(args)

    added =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{item | "arguments" => ""}
        }) <> "\n\n"

    # Match the provider's wire order. The adapter can safely expose an open
    # `delta` string only after the event type and tool identity have already
    # arrived and been validated.
    unfinished_line =
      ~s(data: {"type":"response.function_call_arguments.delta","sequence_number":2,"output_index":0,"item_id":"fc_1","delta":) <>
        Jason.encode!(args) <> "}\n\n"

    {marker_start, marker_size} = :binary.match(unfinished_line, "stream-prefix-")
    {head, tail} = :erlang.split_binary(unfinished_line, marker_start + marker_size)

    completed =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{"output" => [item]}
        }) <> "\n\n"

    parent = self()

    MockSSEServer.set_chunks(
      [added, {:barrier, head, parent, :unfinished_tool_delta}] ++
        chunk_binary(tail, 16) ++ [completed]
    )

    {:ok, recorder} = Agent.start_link(fn -> "" end)

    on_tool = fn fragment ->
      cumulative =
        Agent.get_and_update(recorder, fn current ->
          next = current <> fragment.fragment
          {next, next}
        end)

      send(parent, {:partial_tool_arguments, cumulative})
    end

    opts = Map.put(llm_opts, :on_tool_delta, on_tool)

    request =
      Task.async(fn ->
        OpenAIResponses.complete_stream(
          [%{role: "user", content: "hi"}],
          [],
          fn _ -> :ok end,
          opts
        )
      end)

    assert_receive {:mock_sse_barrier, :unfinished_tool_delta, server}, 1_000
    assert_receive {:partial_tool_arguments, partial}, 1_000
    assert partial != args
    assert String.starts_with?(args, partial)
    assert Task.yield(request, 0) == nil
    send(server, {:release_mock_sse_barrier, :unfinished_tool_delta})

    _response = Task.await(request, 5_000)
    assert Agent.get(recorder, & &1) == args
  end

  # Reasoning summaries stream as `response.reasoning_summary_text.delta`
  # events; they fire `on_reasoning_delta` in order, separate from the visible
  # output-text deltas.
  test "reasoning summary deltas reach on_reasoning_delta", %{llm_opts: llm_opts} do
    events = [
      %{"type" => "response.reasoning_summary_text.delta", "delta" => "Let me "},
      %{"type" => "response.reasoning_summary_text.delta", "delta" => "think about this."},
      %{"type" => "response.output_text.delta", "delta" => "Hello"},
      %{"type" => "response.completed", "response" => %{"output" => []}}
    ]

    MockSSEServer.set_chunks(Enum.map(events, &("data: " <> Jason.encode!(&1) <> "\n\n")))

    {:ok, content_rec} = Agent.start_link(fn -> [] end)
    {:ok, reasoning_rec} = Agent.start_link(fn -> [] end)

    on_delta = fn text -> Agent.update(content_rec, &(&1 ++ [text])) end
    on_reasoning = fn text -> Agent.update(reasoning_rec, &(&1 ++ [text])) end

    opts = Map.put(llm_opts, :on_reasoning_delta, on_reasoning)

    OpenAIResponses.complete_stream([%{role: "user", content: "hi"}], [], on_delta, opts)

    assert Agent.get(reasoning_rec, & &1) == [
             ReasoningDelta.public_summary("Let me "),
             ReasoningDelta.public_summary("think about this.")
           ]

    assert Agent.get(content_rec, & &1) == ["Hello"]
  end

  defp function_call_item(arguments) do
    %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_1",
      "name" => "call",
      "arguments" => arguments
    }
  end

  defp chunk_binary("", _size), do: []

  defp chunk_binary(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_binary(binary, size) do
    <<chunk::binary-size(^size), rest::binary>> = binary
    [chunk | chunk_binary(rest, size)]
  end

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
