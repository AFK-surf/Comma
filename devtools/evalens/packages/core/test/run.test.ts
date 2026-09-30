import { describe, expect, test } from "bun:test";
import pino from "pino";
import type { z } from "zod";

import type { DatasetItem } from "@evalens/core/dataset";
import { executeRun, type RunDefinition, type RunResult } from "@evalens/core/run";
import type { RunWriterContract } from "@evalens/core/store/contracts";

type TestItem = DatasetItem<{ value: string }, { value: string }>;

const item: TestItem = {
  id: "one",
  input: { value: "input" },
  expected: { value: "expected" },
};

class TestRunWriter implements RunWriterContract {
  readonly runId = "019f8e50-0000-7000-8000-000000000001";
  readonly experimentName = "retry-test";
  committed?: RunResult<{ value: string }>;
  finished = false;

  createItemLogger() {
    return {
      logger: pino({ enabled: false }),
      flush: async () => undefined,
      async [Symbol.asyncDispose]() {},
    };
  }

  async commitItem<Result extends z.JSONType>(
    _itemId: string,
    result: RunResult<Result>,
    _itemDigest: string
  ): Promise<void> {
    this.committed = result as unknown as RunResult<{ value: string }>;
  }

  async finish(): Promise<void> {
    this.finished = true;
  }

  async [Symbol.asyncDispose]() {}
}

function definition(
  runItem: RunDefinition<TestItem, { value: string }, {}, {}>["runItem"]
): RunDefinition<TestItem, { value: string }, {}, {}> {
  return {
    name: "retry-test",
    metadata: { tags: [] },
    datasetLoader: () => ({ name: "retry-dataset", items: [item] }),
    runItem,
  };
}

describe("executeRun retries", () => {
  test("retries a failed item with exponential backoff before committing success", async () => {
    let attempts = 0;
    const writer = new TestRunWriter();

    const summary = await executeRun(
      definition(() => {
        attempts += 1;
        if (attempts < 3) throw new TypeError(`fetch failed: transient-${attempts}`);
        return { result: { value: "ok" }, trajectories: [] };
      }),
      {
        writer,
        dataset: { name: "retry-dataset", items: [item] },
        itemDigests: new Map([[item.id, "digest"]]),
        params: {},
        adapterConfig: {},
        retry: {
          maxRetries: 3,
          initialDelayMs: 1,
          maxDelayMs: 2,
          multiplier: 2,
        },
      }
    );

    expect(attempts).toBe(3);
    expect(summary).toEqual({ completedItemCount: 1, errorItemCount: 0 });
    expect(writer.committed?.status).toBe("completed");
    expect(writer.finished).toBe(true);
  });

  test("commits one error after the configured retry budget is exhausted", async () => {
    let attempts = 0;
    const writer = new TestRunWriter();

    const summary = await executeRun(
      definition(() => {
        attempts += 1;
        throw new TypeError(`fetch failed: still-down-${attempts}`);
      }),
      {
        writer,
        dataset: { name: "retry-dataset", items: [item] },
        itemDigests: new Map([[item.id, "digest"]]),
        params: {},
        adapterConfig: {},
        retry: {
          maxRetries: 2,
          initialDelayMs: 0,
          maxDelayMs: 0,
          multiplier: 2,
        },
      }
    );

    expect(attempts).toBe(3);
    expect(summary).toEqual({ completedItemCount: 0, errorItemCount: 1 });
    expect(writer.committed).toMatchObject({
      status: "error",
      error: "fetch failed: still-down-3",
    });
  });

  test("does not retry deterministic experiment failures", async () => {
    let attempts = 0;
    const writer = new TestRunWriter();

    const summary = await executeRun(
      definition(() => {
        attempts += 1;
        throw new AggregateError(
          [new Error("input exceeds the model context window")],
          "one parallel branch failed"
        );
      }),
      {
        writer,
        dataset: { name: "retry-dataset", items: [item] },
        itemDigests: new Map([[item.id, "digest"]]),
        params: {},
        adapterConfig: {},
        retry: {
          maxRetries: 12,
          initialDelayMs: 1,
          maxDelayMs: 1,
          multiplier: 2,
        },
      }
    );

    expect(attempts).toBe(1);
    expect(summary).toEqual({ completedItemCount: 0, errorItemCount: 1 });
    expect(writer.committed).toMatchObject({
      status: "error",
      error: "one parallel branch failed",
    });
  });
});
