import { describe, expect, it } from "vitest";
import {
  createCoalescedAsyncRender,
  type CoalescedAsyncRenderInput,
} from "../coalescedAsyncRender";

function harness() {
  const requests: {
    input: CoalescedAsyncRenderInput;
    resolve(value: string): void;
    reject(error: Error): void;
  }[] = [];
  const results: string[] = [];
  const errors: unknown[] = [];
  const scheduler = createCoalescedAsyncRender({
    render: (input: CoalescedAsyncRenderInput) =>
      new Promise<string>((resolve, reject) => {
        requests.push({ input, resolve, reject });
      }),
    onResult: (value) => results.push(value),
    onError: (error) => errors.push(error),
  });
  const update = (source: string, scopeKey = "document:light:typescript") =>
    scheduler.update({ scopeKey, source });
  return { scheduler, requests, results, errors, update };
}

async function settle() {
  for (let turn = 0; turn < 6; turn += 1) await Promise.resolve();
}

describe("coalesced asynchronous Markdown block rendering", () => {
  it("publishes useful prefixes while a slow renderer coalesces a burst to one latest input", async () => {
    const h = harness();
    h.update("a");
    await settle();
    for (let count = 2; count <= 1_000; count += 1) h.update("a".repeat(count));
    await settle();
    expect(h.requests).toHaveLength(1);

    h.requests[0]!.resolve("highlighted a");
    await settle();
    expect(h.results).toEqual(["highlighted a"]);
    expect(h.requests).toHaveLength(2);
    expect(h.requests[1]!.input.source).toHaveLength(1_000);

    h.update("a".repeat(1_001));
    h.requests[1]!.resolve("highlighted 1000");
    await settle();
    expect(h.results).toEqual(["highlighted a", "highlighted 1000"]);
    expect(h.requests).toHaveLength(3);
    h.requests[2]!.resolve("highlighted 1001");
    await settle();
    expect(h.results.at(-1)).toBe("highlighted 1001");
    expect(h.requests).toHaveLength(3);
  });

  it.each([
    "other-document:light:typescript",
    "document:dark:typescript",
    "document:light:python",
  ])(
    "keeps old results out of changed render scope %s without overlapping work",
    async (scope) => {
      const h = harness();
      h.update("text");
      await settle();
      h.update("text continued", scope);
      await settle();
      expect(h.requests).toHaveLength(1);
      h.requests[0]!.resolve("old scope");
      await settle();
      expect(h.results).toEqual([]);
      expect(h.requests[1]!.input.scopeKey).toBe(scope);
      h.requests[1]!.resolve("new scope");
      await settle();
      expect(h.results).toEqual(["new scope"]);
    }
  );

  it("invalidates an earlier generation even when a replacement grows back to the same prefix", async () => {
    const h = harness();
    h.update("abc");
    await settle();
    h.update("x");
    h.update("abcdef");
    h.requests[0]!.resolve("obsolete abc");
    await settle();
    expect(h.results).toEqual([]);
    expect(h.requests).toHaveLength(2);
    expect(h.requests[1]!.input.source).toBe("abcdef");
    h.requests[1]!.resolve("current abcdef");
    await settle();
    expect(h.results).toEqual(["current abcdef"]);
  });

  it("skips obsolete errors and surfaces a latest-input failure once without retrying", async () => {
    const h = harness();
    h.update("a");
    await settle();
    h.update("ab");
    h.requests[0]!.reject(new Error("old prefix failure"));
    await settle();
    expect(h.errors).toEqual([]);
    const latestError = new Error("latest render unavailable");
    h.requests[1]!.reject(latestError);
    await settle();
    expect(h.errors).toEqual([latestError]);
    h.update("ab");
    await settle();
    expect(h.requests).toHaveLength(2);
  });

  it("does not publish or start pending work after the block unmounts", async () => {
    const h = harness();
    h.update("a");
    await settle();
    h.update("ab");
    h.scheduler.dispose();
    h.update("abc");
    h.requests[0]!.resolve("old response");
    await settle();
    expect(h.requests).toHaveLength(1);
    expect(h.results).toEqual([]);
    expect(h.errors).toEqual([]);
  });

  it("settles a synchronous renderer failure and accepts a later distinct input", async () => {
    const outputs: string[] = [];
    const errors: unknown[] = [];
    const error = new Error("worker postMessage unavailable");
    const scheduler = createCoalescedAsyncRender({
      render(input: CoalescedAsyncRenderInput) {
        if (input.source === "a") throw error;
        return Promise.resolve(input.source);
      },
      onResult: (value) => outputs.push(value),
      onError: (value) => errors.push(value),
    });
    scheduler.update({ scopeKey: "code", source: "a" });
    await settle();
    expect(errors).toEqual([error]);
    scheduler.update({ scopeKey: "code", source: "ab" });
    await settle();
    expect(outputs).toEqual(["ab"]);
  });
});
