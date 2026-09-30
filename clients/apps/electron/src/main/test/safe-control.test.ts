import { describe, expect, it, vi } from "vitest";
import { safelyRunControl } from "../safe-control";

describe("safelyRunControl", () => {
  it("reports synchronous control failures", () => {
    const onError = vi.fn();
    const error = new Error("sync failure");

    safelyRunControl(() => {
      throw error;
    }, onError);

    expect(onError).toHaveBeenCalledWith(error);
  });

  it("consumes and reports asynchronous control failures", async () => {
    const error = new Error("async failure");
    let report!: (error: unknown) => void;
    const reported = new Promise<unknown>((resolve) => {
      report = resolve;
    });

    safelyRunControl(() => Promise.reject(error), report);

    await expect(reported).resolves.toBe(error);
  });
});
