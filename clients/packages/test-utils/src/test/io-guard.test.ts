import { execFile } from "node:child_process";
import { exists } from "node:fs";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

// The IO guard and the memory temporary directory (setup-node.ts) replace
// these functions; their promise forms stay the ones Node gives them.
describe("the functions the harness watches", () => {
  it("keep their own promise forms", () => {
    const custom = promisify.custom;
    for (const original of [execFile, exists, setTimeout])
      expect(promisify(original as (...args: never[]) => unknown)).toBe(
        (original as unknown as Record<symbol, unknown>)[custom]
      );
  });
});
