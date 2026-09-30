import { describe, expect, test } from "bun:test";

import { isHttpNotFound, mean, measure, ratio, type Timing } from "@evalens/utils";

function expectValidTiming(timing: Timing) {
  expect(timing.startedAt).toBeInstanceOf(Date);
  expect(timing.finishedAt).toBeInstanceOf(Date);
  expect(timing.durationMs).toBe(
    Math.max(0, timing.finishedAt.getTime() - timing.startedAt.getTime())
  );
}

describe("measure", () => {
  test("returns a fulfilled result with Date-based timing", async () => {
    const measured = await measure(async () => "value");

    expect(measured.status).toBe("fulfilled");
    if (measured.status !== "fulfilled") throw measured.reason;
    expect(measured.value).toBe("value");
    expectValidTiming(measured.timing);
  });

  test("returns a rejected result with Date-based timing", async () => {
    const failure = new Error("failed");
    const measured = await measure(() => {
      throw failure;
    });

    expect(measured.status).toBe("rejected");
    if (measured.status !== "rejected") throw new Error("expected rejection");
    expect(measured.reason).toBe(failure);
    expectValidTiming(measured.timing);
  });
});

describe("math", () => {
  test("uses the evaluation identities for empty and populated collections", () => {
    expect(ratio([])).toBe(1);
    expect(ratio([true, false, true])).toBe(2 / 3);
    expect(mean([])).toBe(0);
    expect(mean([1, 2, 3])).toBe(2);
  });
});

describe("HTTP errors", () => {
  test("matches only a structured 404 status", () => {
    expect(isHttpNotFound({ status: 404 })).toBe(true);
    expect(isHttpNotFound({ status: 401 })).toBe(false);
    expect(isHttpNotFound(new Error("404"))).toBe(false);
  });
});
