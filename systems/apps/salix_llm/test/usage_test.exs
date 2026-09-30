defmodule SalixLlm.UsageTest do
  use ExUnit.Case, async: true

  test "chat usage normalizes cache fields like Willow" do
    assert_usage(
      SalixLlm.Usage.openai(%{
        "prompt_tokens" => 100,
        "completion_tokens" => 5,
        "total_tokens" => 105,
        "prompt_tokens_details" => %{"cached_tokens" => 80}
      }),
      100,
      5,
      105,
      80,
      0
    )

    assert_usage(
      SalixLlm.Usage.openai(%{
        "prompt_tokens" => 194,
        "completion_tokens" => 2,
        "total_tokens" => 196,
        "prompt_tokens_details" => %{"cached_tokens" => 50, "cache_write_tokens" => 30}
      }),
      194,
      2,
      196,
      50,
      30
    )

    assert_usage(
      SalixLlm.Usage.openai(%{
        "input_tokens" => 21,
        "cache_read_input_tokens" => 80,
        "cache_creation_input_tokens" => 7,
        "output_tokens" => 5
      }),
      108,
      5,
      113,
      80,
      7
    )

    assert_usage(
      SalixLlm.Usage.openai(%{
        "uncached_input_tokens" => 21,
        "cache_read_input_tokens" => 80,
        "cache_creation" => %{
          "ephemeral_5m_input_tokens" => 4,
          "ephemeral_1h_input_tokens" => 3
        },
        "output_tokens" => 5
      }),
      108,
      5,
      113,
      80,
      7
    )
  end

  test "responses usage reads input token details cache counters" do
    assert_usage(
      SalixLlm.Usage.responses(%{
        "input_tokens" => 100,
        "input_tokens_details" => %{"cached_tokens" => 80, "cache_write_tokens" => 7},
        "output_tokens" => 5,
        "total_tokens" => 105
      }),
      100,
      5,
      105,
      80,
      7
    )
  end

  test "chat response usage merges Gemini-style usage metadata" do
    assert_usage(
      SalixLlm.Usage.openai_chat(%{
        "choices" => [%{"message" => %{"content" => "ok"}}],
        "usageMetadata" => %{
          "promptTokenCount" => 696_219,
          "cachedContentTokenCount" => 696_190,
          "candidatesTokenCount" => 214,
          "totalTokenCount" => 696_433
        }
      }),
      696_219,
      214,
      696_433,
      696_190,
      0
    )

    assert_usage(
      SalixLlm.Usage.openai_chat(%{
        "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 4, "total_tokens" => 34},
        "usageMetadata" => %{"cachedContentTokenCount" => 20}
      }),
      30,
      4,
      34,
      20,
      0
    )
  end

  test "Responses distinguishes missing counters from explicit zero" do
    missing = SalixLlm.Usage.responses(%{})
    assert missing["usage_reported"]
    refute missing["prompt_tokens_reported"]
    refute missing["completion_tokens_reported"]
    refute missing["cache_read_tokens_reported"]
    assert missing["cache_read_input_tokens"] == 0
    assert missing["reasoning_tokens"] == nil

    usage =
      SalixLlm.Usage.responses(%{
        "input_tokens" => 100,
        "output_tokens" => 40,
        "input_tokens_details" => %{"cached_tokens" => 0},
        "output_tokens_details" => %{"reasoning_tokens" => 30}
      })

    assert usage["cache_read_tokens_reported"]
    assert usage["cache_read_input_tokens"] == 0
    assert usage["reasoning_tokens"] == 30
    assert usage["completion_tokens"] == 40
  end

  defp assert_usage(usage, prompt, completion, total, cache_read, cache_write) do
    assert usage["prompt_tokens"] == prompt
    assert usage["completion_tokens"] == completion
    assert usage["total_tokens"] == total
    assert usage["cache_read_input_tokens"] == cache_read
    assert usage["cache_write_input_tokens"] == cache_write
  end
end
