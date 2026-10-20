import { deepEqual, notDeepEqual, equal, throws } from "node:assert/strict";
import { expect, test, vi } from "vitest";
import { observeAssertions } from "../assertion-record";

async function capture(run: () => unknown) {
  const events: string[] = [];
  const stop = observeAssertions((_, event) => events.push(event));
  try {
    await run();
  } finally {
    stop();
  }
  return events;
}

test("distinguishes different observations that pass the same assertion", async () => {
  const run = (value: number) => capture(() => expect(value).toBeGreaterThan(0));
  const original = await run(1);
  notDeepEqual(original, await run(999));
  deepEqual(original, await run(1));
});

test("records resolved values, negation and Chai assertions", async () => {
  const run = (value: number) =>
    capture(async () => {
      await expect(Promise.resolve(value)).resolves.toBeGreaterThan(0);
      expect(value).not.toBe(0);
      expect(value).to.be.above(0);
    });
  const original = await run(1);
  notDeepEqual(original, await run(999));
  deepEqual(original, await run(1));
});

test("records mock call arguments even when an asymmetric matcher accepts both", async () => {
  const run = (value: number) =>
    capture(() => {
      const sent = vi.fn();
      sent({ value });
      expect(sent).toHaveBeenCalledWith({ value: expect.any(Number) });
      sent.mockClear();
    });
  const original = await run(1);
  notDeepEqual(original, await run(999));
  deepEqual(original, await run(1));
});

test("records a custom matcher installed after recording starts", async () => {
  const run = (value: number) =>
    capture(async () => {
      expect.extend({
        async toBePositive(actual: number) {
          return { pass: actual > 0, message: () => "expected a positive number" };
        },
      });
      await (
        expect(value) as unknown as { toBePositive(): Promise<void> }
      ).toBePositive();
    });
  const original = await run(1);
  notDeepEqual(original, await run(999));
  deepEqual(original, await run(1));
});

test("retains long values and snapshots objects before later mutations", async () => {
  const run = (value: number) =>
    capture(() => {
      const list = [...Array.from({ length: 120 }, () => 1), value];
      expect(list).toHaveLength(121);
      expect("a".repeat(12_000) + value).toContain("a");
      list[120] = 0;
    });
  const original = await run(1);
  notDeepEqual(original, await run(999));
  deepEqual(original, await run(1));
});

test("does not call a getter or custom inspector while it records", async () => {
  let reads = 0;
  const value = {
    get effect() {
      reads += 1;
      return reads;
    },
    [Symbol.for("nodejs.util.inspect.custom")]() {
      reads += 1;
      return reads;
    },
  };
  await capture(() => expect(value).toBeTruthy());
  equal(reads, 0);
});

test("keeps matcher failures, rejections and inline snapshots", async () => {
  const events = await capture(async () => {
    throws(() => expect(1).toBe(2));
    await expect(Promise.reject("no")).rejects.toBe("no");
    expect({ ready: true }).toMatchInlineSnapshot(`
      {
        "ready": true,
      }
    `);
  });
  equal(events.length > 0, true);
});

test("keeps assertion order and restores matchers when the last listener stops", async () => {
  const run = (values: number[]) =>
    capture(() => values.forEach((value) => expect(value).toBeGreaterThan(0)));
  notDeepEqual(await run([1, 2]), await run([2, 1]));
  const left: string[] = [];
  const right: string[] = [];
  const stopLeft = observeAssertions((_, event) => left.push(event));
  const stopRight = observeAssertions((_, event) => right.push(event));
  expect(1).toBeGreaterThan(0);
  stopLeft();
  expect(2).toBeGreaterThan(0);
  stopRight();
  const count = right.length;
  expect(3).toBeGreaterThan(0);
  equal(right.length, count);
  equal(right.length, left.length * 2);
  deepEqual(await run([1]), await run([1]));
});

test("records platform values by what they hold, and class instances' data", async () => {
  class Draft {
    items: number[];
    constructor(value: number) {
      this.items = [value];
    }
  }
  const run = (value: number) =>
    capture(() => {
      expect(new URL(`https://example.test/${value}`)).toBeTruthy();
      expect(new URLSearchParams({ value: String(value) })).toBeTruthy();
      expect(new Headers({ value: String(value) })).toBeTruthy();
      expect(new Blob(["x".repeat(value)])).toBeTruthy();
      expect(new Draft(value)).toBeTruthy();
    });
  const original = await run(1);
  for (let index = 0; index < original.length; index += 1)
    notDeepEqual(original[index], (await run(2))[index]);
  deepEqual(original, await run(1));
});
