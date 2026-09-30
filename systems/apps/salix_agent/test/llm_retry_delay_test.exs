defmodule SalixAgent.LLMRetryDelayTest do
  @moduledoc """
  Round's provider retry backoff: ordinary failures back off in milliseconds,
  rate limits back off on the provider's clock and never below its Retry-After.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.Round

  setup do
    previous = Application.get_env(:salix_agent, :llm_rate_limit_retry_base_ms)
    Application.delete_env(:salix_agent, :llm_rate_limit_retry_base_ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :llm_rate_limit_retry_base_ms, previous),
        else: Application.delete_env(:salix_agent, :llm_rate_limit_retry_base_ms)
    end)

    :ok
  end

  test "ordinary retryable errors keep the millisecond backoff" do
    error = {:error, %{"status" => 503, "retryable" => true}}
    assert Enum.map(1..5, &Round.llm_retry_delay_ms(&1, error)) == [250, 500, 1_000, 2_000, 4_000]
    assert Round.llm_retry_delay_ms(1, %RuntimeError{message: "boom"}) == 250
    assert Round.llm_retry_delay_ms(1, {:exit, :timeout}) == 250
  end

  test "a 429 or 529 backs off from five seconds and caps at one minute" do
    for status <- [429, 529] do
      error = {:error, %{"status" => status, "retryable" => true}}

      assert Enum.map(1..5, &Round.llm_retry_delay_ms(&1, error)) ==
               [5_000, 10_000, 20_000, 40_000, 60_000]
    end
  end

  test "the provider's Retry-After is a floor, not a replacement, and is never cut short" do
    error = {:error, %{"status" => 429, "retryable" => true, "retry_after_ms" => 25_000}}
    assert Round.llm_retry_delay_ms(1, error) == 25_000
    assert Round.llm_retry_delay_ms(4, error) == 40_000

    # Only the local backoff is capped at a minute; a provider wait above it
    # is honored in full.
    long = {:error, %{"status" => 429, "retryable" => true, "retry_after_ms" => 120_000}}
    assert Round.llm_retry_delay_ms(1, long) == 120_000
    assert Round.llm_retry_delay_ms(5, long) == 120_000

    ordinary = {:error, %{"status" => 503, "retryable" => true, "retry_after_ms" => 3_000}}
    assert Round.llm_retry_delay_ms(1, ordinary) == 3_000
  end

  test "a wait the request deadline cannot hold abandons the retry" do
    assert Round.retry_within_budget?(120_000, 300_000)
    refute Round.retry_within_budget?(120_000, 120_000)
    refute Round.retry_within_budget?(120_000, 0)
    assert Round.retry_within_budget?(600_000, :infinity)
  end

  test "the rate-limit base is configurable for operators" do
    Application.put_env(:salix_agent, :llm_rate_limit_retry_base_ms, 10)
    error = {:error, %{"status" => 429, "retryable" => true}}
    assert Round.llm_retry_delay_ms(3, error) == 40

    Application.put_env(:salix_agent, :llm_rate_limit_retry_base_ms, "fast")
    assert Round.llm_retry_delay_ms(1, error) == 5_000
  end
end
