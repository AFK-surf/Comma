defmodule SalixAgent.LLMErrorClassificationTest do
  @moduledoc """
  HTTP failure classification at the LLM seam: overflow phrasings must map to
  `context_overflow` (the category the auto-compaction recovery consumes) —
  a provider whose wording isn't recognized leaves its session permanently
  wedged over the context limit.
  """
  use SystemsClock.Case, async: true

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
      {"bedrock", %{"message" => "Input is too long for requested model."}},
      # Volces Ark (OpenAI-compatible) oversized-request phrasing.
      {"openai_chat",
       %{
         "error" => %{
           "code" => "InvalidParameter",
           "message" => "Total tokens of image and text exceed max message tokens.",
           "type" => "BadRequest"
         }
       }}
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

  test "an exhausted provider account is recognized and stops retries" do
    for {provider, status, body} <- [
          {"anthropic", 400,
           %{
             "type" => "error",
             "error" => %{
               "type" => "invalid_request_error",
               "message" =>
                 "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."
             }
           }},
          {"anthropic", 400, %{"type" => "billing_error", "message" => "billing issue"}},
          {"openai_chat", 429,
           %{
             "error" => %{
               "message" =>
                 "You exceeded your current quota, please check your plan and billing details.",
               "type" => "insufficient_quota",
               "code" => "insufficient_quota"
             }
           }},
          {"openai_chat", 402, %{"error" => %{"message" => "Payment required"}}}
        ] do
      assert {:error, meta} = Error.http(provider, status, body)
      assert Error.provider_quota_exhausted?(meta)

      assert {:error,
              %{
                "error_class" => "billing_unavailable",
                "reason" => "provider_quota_exhausted",
                "retryable" => false
              }} = Error.provider_quota({:error, meta})
    end
  end
end
