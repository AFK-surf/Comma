defmodule SalixLlm.OpenAIChatStreamToolTest do
  @moduledoc """
  Chat-completions streaming surfaces tool-call argument fragments through the
  `on_tool_delta` callback (threaded via `llm_opts`). These are raw transport
  fragments: the test reconstructs the complete JSON only to verify the adapter;
  it does not treat partial arguments as a user-visible draft.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.ReasoningDelta
  alias SalixLlm.{MockSSEServer, OpenAIChat}

  setup do
    start_supervised!(MockSSEServer)

    bandit =
      start_supervised!(
        {Bandit, plug: MockSSEServer, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    llm_opts = %{
      "protocol" => "",
      "model" => "gpt-test",
      "base_url" => "http://127.0.0.1:#{port}",
      "api_key" => "test-key"
    }

    {:ok, llm_opts: llm_opts}
  end

  test "structured content format reaches the provider without adding executable tools", %{
    llm_opts: opts
  } do
    format = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "content",
        "strict" => true,
        "schema" => %{
          "type" => "object",
          "properties" => %{"title" => %{"type" => "string"}},
          "required" => ["title"],
          "additionalProperties" => false
        }
      }
    }

    MockSSEServer.set_chunks([
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{"content" => ~s({"title":"Hello"})}}]}) <>
        "\n\n",
      "data: [DONE]\n\n"
    ])

    assert {:final, ~s({"title":"Hello"})} =
             OpenAIChat.complete_stream(
               [%{role: "user", content: "Write JSON"}],
               [],
               fn _ -> :ok end,
               Map.put(opts, "response_format", format)
             )

    assert MockSSEServer.last_request()["response_format"] == format
    refute Map.has_key?(MockSSEServer.last_request(), "tools")
  end

  test "surfaces tool-call argument fragments that reconstruct the complete call",
       %{llm_opts: llm_opts} do
    args =
      Jason.encode!(%{
        "tool" => "im_api.internal.send_message",
        "params" => %{"conversation_id" => "c1", "content" => "Hello world"}
      })

    {first, second} = String.split_at(args, div(byte_size(args), 2))

    MockSSEServer.set_chunks([
      "data: " <>
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{"name" => "call", "arguments" => ""}
                  }
                ]
              }
            }
          ]
        }) <> "\n\n",
      "data: " <>
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => first}}]
              }
            }
          ]
        }) <> "\n\n",
      "data: " <>
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => second}}]
              }
            }
          ]
        }) <> "\n\n",
      ~s(data: [DONE]\n\n)
    ])

    {:ok, content_rec} = Agent.start_link(fn -> [] end)
    {:ok, tool_rec} = Agent.start_link(fn -> {nil, ""} end)

    on_delta = fn text -> Agent.update(content_rec, &[text | &1]) end

    on_tool = fn frag ->
      Agent.update(tool_rec, fn {name, fragments} ->
        {name || frag.name, fragments <> (frag.fragment || "")}
      end)
    end

    opts = Map.put(llm_opts, :on_tool_delta, on_tool)

    assert {:assistant, "", [%{id: "call_1", name: "call"}]} =
             OpenAIChat.complete_stream([%{role: "user", content: "hi"}], [], on_delta, opts)

    # Tool-only turn: no assistant text content streamed.
    assert Agent.get(content_rec, & &1) == []

    {name, reconstructed} = Agent.get(tool_rec, & &1)
    assert name == "call"
    assert get_in(Jason.decode!(reconstructed), ["params", "content"]) == "Hello world"
  end

  test "rejects malformed final arguments instead of executing an empty call or its valid sibling",
       %{llm_opts: opts} do
    for malformed <- ["{\"tool\":", "[]"] do
      MockSSEServer.set_chunks([
        "data: " <>
          Jason.encode!(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "valid",
                      "function" => %{"name" => "call", "arguments" => "{}"}
                    },
                    %{
                      "index" => 1,
                      "id" => "broken",
                      "function" => %{"name" => "call", "arguments" => malformed}
                    }
                  ]
                }
              }
            ]
          }) <> "\n\n",
        "data: [DONE]\n\n"
      ])

      assert {:error, error} =
               OpenAIChat.complete_stream(
                 [%{role: "user", content: "hi"}],
                 [],
                 fn _ -> :ok end,
                 opts
               )

      assert error["reason"] == "invalid_tool_arguments"
    end
  end

  test "HTTP success without stream completion rejects partial and complete tool arguments",
       %{llm_opts: opts} do
    for args <- [~s({"command":"curl), ~s({"command":"curl"})] do
      MockSSEServer.set_chunks([tool_chunk(args)])
      assert {:error, error} = stream_result(opts)
      assert error["category"] == "transport_error"
      assert error["reason"] == "incomplete_stream"
      assert error["retryable"] == true

      assert {"transport_error", nil, "incomplete_stream"} =
               SalixAgent.AttemptTelemetry.classify(error)
    end
  end

  test "an empty HTTP success does not complete the model response", %{llm_opts: opts} do
    MockSSEServer.set_chunks([])
    assert {:error, %{"reason" => "incomplete_stream"}} = stream_result(opts)
  end

  test "output token exhaustion takes precedence over malformed arguments", %{llm_opts: opts} do
    MockSSEServer.set_chunks([
      tool_chunk(~s({"command":"curl)),
      finish_chunk("length"),
      "data: [DONE]\n\n"
    ])

    assert {:error, error} = stream_result(opts)
    assert error["reason"] == "output_token_limit"
    assert error["retryable"] == false
  end

  test "a broken SSE event cannot be hidden by a completion marker", %{llm_opts: opts} do
    MockSSEServer.set_chunks([
      tool_chunk(~s({"command":"curl"})),
      "data: {\"choices\":[\n\n",
      "data: [DONE]\n\n"
    ])

    assert {:error, error} = stream_result(opts)
    assert error["reason"] == "incomplete_stream"
  end

  test "finish reason completes a stream without a DONE sentinel", %{llm_opts: opts} do
    MockSSEServer.set_chunks([tool_chunk(~s({"command":"curl"})), finish_chunk("tool_calls")])
    assert {:assistant, "", [%{args: %{"command" => "curl"}}]} = stream_result(opts)
  end

  defp stream_result(opts),
    do: OpenAIChat.complete_stream([%{role: "user", content: "hi"}], [], fn _ -> :ok end, opts)

  defp tool_chunk(args) do
    "data: " <>
      Jason.encode!(%{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "probe",
                  "function" => %{"name" => "call", "arguments" => args}
                }
              ]
            }
          }
        ]
      }) <> "\n\n"
  end

  defp finish_chunk(reason),
    do:
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}) <> "\n\n"

  # Chat-compatible reasoning fields are raw provider reasoning. The adapter
  # must classify them as private instead of granting activity-text authority.
  test "classifies chat reasoning deltas as private", %{llm_opts: llm_opts} do
    MockSSEServer.set_chunks([
      "data: " <>
        Jason.encode!(%{
          "choices" => [%{"delta" => %{"role" => "assistant", "reasoning_content" => "Let me "}}]
        }) <> "\n\n",
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{"reasoning" => "think about this."}}]}) <>
        "\n\n",
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Hello"}}]}) <> "\n\n",
      ~s(data: [DONE]\n\n)
    ])

    {:ok, content_rec} = Agent.start_link(fn -> [] end)
    {:ok, reasoning_rec} = Agent.start_link(fn -> [] end)

    on_delta = fn text -> Agent.update(content_rec, &(&1 ++ [text])) end
    on_reasoning = fn text -> Agent.update(reasoning_rec, &(&1 ++ [text])) end

    opts = Map.put(llm_opts, :on_reasoning_delta, on_reasoning)

    result = OpenAIChat.complete_stream([%{role: "user", content: "hi"}], [], on_delta, opts)

    assert Agent.get(reasoning_rec, & &1) == [
             ReasoningDelta.private_reasoning("Let me "),
             ReasoningDelta.private_reasoning("think about this.")
           ]

    assert Agent.get(content_rec, & &1) == ["Hello"]

    # The text turn does not settle the session, so its reasoning is kept for
    # replay on the next round.
    assert {:final, "Hello", provider_meta, %{}} = result

    assert provider_meta["chat_message_extra"] == %{
             "reasoning_content" => "Let me ",
             "reasoning" => "think about this."
           }
  end
end
