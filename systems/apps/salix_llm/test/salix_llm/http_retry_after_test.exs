defmodule SalixLlm.HttpRetryAfterTest do
  use ExUnit.Case, async: true

  alias SalixLlm.Http

  test "delay-seconds form reads as milliseconds" do
    assert Http.retry_after_ms(%{"retry-after" => ["7"]}) == 7_000
    assert Http.retry_after_ms(%{"retry-after" => [" 0 "]}) == 0
  end

  test "HTTP-date form reads as the distance from now, never negative" do
    future = DateTime.add(DateTime.utc_now(), 90, :second)
    value = Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")
    ms = Http.retry_after_ms(%{"retry-after" => [value]})
    assert ms > 85_000 and ms <= 90_000

    assert Http.retry_after_ms(%{"retry-after" => ["Sun, 06 Nov 1994 08:49:37 GMT"]}) == 0
  end

  test "missing, malformed and negative values read as nil" do
    assert Http.retry_after_ms(%{}) == nil
    assert Http.retry_after_ms(%{"retry-after" => ["soon"]}) == nil
    assert Http.retry_after_ms(%{"retry-after" => ["-5"]}) == nil
    assert Http.retry_after_ms(%{"retry-after" => []}) == nil
    assert Http.retry_after_ms([]) == nil
  end

  test "list-form headers match case-insensitively" do
    assert Http.retry_after_ms([{"Retry-After", "12"}]) == 12_000
    assert Http.retry_after_ms([{"content-type", "text/plain"}]) == nil
  end
end
