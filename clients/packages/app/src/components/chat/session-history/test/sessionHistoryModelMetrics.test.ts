import { expect, it } from "vitest";
import { sessionModelMetrics } from "../model/sessionHistoryModelMetrics";

it("uses total normalized input as the cache denominator, including cache writes", () => {
  const metrics = sessionModelMetrics({
    id: "1",
    kind: "assistant",
    content: {
      model: "test-model",
      input_tokens: 12000,
      output_tokens: 600,
      cache_read_input_tokens: 9000,
      cache_write_input_tokens: 1000,
    },
    execution: {
      id: "request",
      lane: "model",
      started_at_ms: 1000,
      first_token_at_ms: 1200,
      observed_at_ms: 1500,
      completed_at_ms: 1500,
      duration_ms: 500,
    },
  });
  expect(metrics).toEqual({
    model: "test-model",
    input: 12000,
    output: 600,
    cacheRead: 9000,
    cacheWrite: 1000,
    cacheRate: 0.75,
    ttft: 200,
  });
});

it("distinguishes unavailable usage from a reported zero cache hit rate", () => {
  const record = { id: "1", kind: "assistant", content: { input_tokens: 100 } };
  expect(sessionModelMetrics(record).cacheRate).toBeUndefined();
  expect(
    sessionModelMetrics({
      ...record,
      content: { input_tokens: 100, cache_read_input_tokens: 0 },
    }).cacheRate
  ).toBe(0);
  expect(
    sessionModelMetrics({
      ...record,
      content: { input_tokens: 0, cache_read_input_tokens: 0 },
    }).cacheRate
  ).toBeUndefined();
  expect(sessionModelMetrics(record).output).toBeUndefined();
  expect(sessionModelMetrics(record).ttft).toBeUndefined();
});
