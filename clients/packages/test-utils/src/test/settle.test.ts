import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { fakeTimersStepWhenIdle, settle } from "../settle";

fakeTimersStepWhenIdle();

describe("fakeTimersStepWhenIdle", () => {
  it("runs a waiting test's timers in their order without real time", async () => {
    const fired: number[] = [];
    // Timers on the file's fake clock (fakeTimersStepWhenIdle).
    await new Promise<void>((resolve) => {
      // ast-grep-ignore: ts-test-timer
      setTimeout(() => fired.push(2), 2_000);
      // ast-grep-ignore: ts-test-timer
      setTimeout(() => {
        fired.push(1);
      }, 1_000);
      // ast-grep-ignore: ts-test-timer
      setTimeout(resolve, 3_000);
    });
    expect(fired).toEqual([1, 2]);
    expect(await settle(Promise.resolve("done"))).toBe("done");
  });

  it("fails real IO in a file whose timers step when it waits", () => {
    // A file outside the repository: reading the code and its modules is not IO.
    expect(() => readFileSync("/etc/hosts")).toThrow("Real IO (fs-read)");
  });
});
