defmodule SalixAgent.LLMErrorClassificationTest do
  @moduledoc """
  HTTP failure classification at the LLM seam: overflow phrasings must map to
  `context_overflow` (the category the auto-compaction recovery consumes) —
  a provider whose wording isn't recognized leaves its session permanently
  wedged over the context limit.
  """
  use ExUnit.Case, async: true

  alias SalixAgent.LLM.Error

  test "structured and JSON provider error envelopes classify before diagnostic truncation" do
    cases = [
      {"openai_chat",
       %{"error" => %{"code" => "context_length_exceeded", "message" => "request rejected"}}},
      {"openai_responses", %{"error" => %{"code" => "model_context_window_exceeded"}}},
      {"anthropic",
       %{
         "type" => "error",
         "error" => %{
           "type" => "invalid_request_error",
           "message" => "prompt is too long: 210000 tokens > 200000 maximum"
         }
       }},
      {"gemini",
       %{
         "error" => %{
           "status" => "INVALID_ARGUMENT",
           "message" =>
             "The input token count (210000) exceeds the maximum number of tokens allowed (200000)."
         }
       }},
      {"bedrock", %{"message" => "Input is too long for requested model."}}
    ]

    for {provider, body} <- cases, value <- [body, Jason.encode!(body)] do
      assert {:error, %{"category" => "context_overflow", "retryable" => false}} =
               Error.http(provider, 400, value)
    end

    body = %{
      "padding" => String.duplicate("x", 5000),
      "error" => %{"code" => "context_length_exceeded"}
    }

    assert {:error, %{"category" => "context_overflow"} = meta} =
             Error.http("openai_chat", 400, body)

    assert byte_size(meta["body"]) <= 4096
  end

  test "failed and incomplete response envelopes retain context error classification" do
    for status <- ["failed", "incomplete"],
        details <- [
          %{"error" => %{"code" => "context_length_exceeded"}},
          %{"incomplete_details" => %{"reason" => "model_context_window_exceeded"}}
        ] do
      assert {:error, %{"category" => "context_overflow"}} =
               Error.provider_state("openai_responses", status, details)
    end
  end

  test "rate, output, byte-size and unrelated validation limits are not context overflow" do
    for {status, message} <- [
          {429, "token limit exceeded per minute"},
          {400, "max_output_tokens exceeds the output token limit"},
          {413, "request body exceeds maximum size of 32 MB"},
          {400, "invalid context window configuration"},
          {400, "tool schema contains too many tokens in its name"}
        ] do
      assert {:error, meta} =
               Error.http("openai_chat", status, %{"error" => %{"message" => message}})

      refute meta["category"] == "context_overflow"
    end
  end

  test "Volces Ark oversized-request phrasing classifies as context overflow" do
    body =
      ~s({"error":{"code":"InvalidParameter","message":"Total tokens of image and text exceed max message tokens.","type":"BadRequest"}})

    assert {:error, meta} = Error.http("openai_chat", 400, body)
    assert meta["category"] == "context_overflow"
    refute Error.retryable?(meta)
  end

  test "an unrelated 400 stays a permanent, non-retryable provider error" do
    assert {:error, meta} =
             Error.http("openai_chat", 400, ~s({"error":{"message":"bad tool schema"}}))

    assert meta["category"] == "permanent_provider_error"
    refute Error.retryable?(meta)
  end

  test "throttling and server failures stay retryable" do
    assert {:error, meta_429} = Error.http("openai_chat", 429, "slow down")
    assert Error.retryable?(meta_429)

    assert {:error, meta_500} = Error.http("openai_chat", 500, "boom")
    assert Error.retryable?(meta_500)
  end
end
