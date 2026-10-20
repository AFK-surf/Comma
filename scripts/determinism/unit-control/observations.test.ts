import assert from "node:assert/strict";
import { afterEach, expect, test, vi } from "vitest";

const value = Number(process.env.DETERMINISM_CONTROL_VALUE);

test("a positive number", () => expect(value).toBeGreaterThan(0));
test.fails("an expected failure", () => {
  expect(value).toBeGreaterThan(0);
  expect(value).toBe(0);
});
test("a resolved number", async () => {
  await expect(Promise.resolve(value)).resolves.toBeGreaterThan(0);
});
test("a mock call", () => {
  const send = vi.fn();
  send({ value });
  expect(send).toHaveBeenCalledWith({ value: expect.any(Number) });
  send.mockClear();
});
test("a custom matcher", () => {
  expect.extend({
    toBePositive(actual: number) {
      return { pass: actual > 0, message: () => "expected a positive number" };
    },
  });
  (expect(value) as unknown as { toBePositive(): void }).toBePositive();
});
test("a long value", () => {
  expect("a".repeat(12_000) + value).toContain("a");
});
test("a cleanup observation", () => {});
test("a finished observation", ({ onTestFinished }) => {
  onTestFinished(() => {
    expect(value).toBeGreaterThan(0);
    if (process.env.DETERMINISM_CONTROL_FAIL) throw new Error("finish failed");
  });
});
test("a soft assertion", () => {
  expect
    .soft(value)
    .toBeGreaterThan(process.env.DETERMINISM_CONTROL_FAIL ? 1 : 0);
});
afterEach(({ task }) => {
  if (task.name !== "a cleanup observation") return;
  expect(value).toBeGreaterThan(0);
  if (process.env.DETERMINISM_CONTROL_FAIL) throw new Error("cleanup failed");
});
test("a node:assert check", () => {
  assert.equal(value, value);
});
test.each([1, 2])("a repeated name", (step) => {
  expect(value + step).toBeGreaterThan(step);
});
