import { describe, expect, it } from "vitest";
import { isControlInteractive } from "../control-descriptors";

describe("runtime workbench control descriptors", () => {
  it("only treats ready controls as interactive", () => {
    expect(isControlInteractive({ status: "ready" })).toBe(true);
    expect(isControlInteractive({ status: "planned" })).toBe(false);
    expect(isControlInteractive({ status: "needs-capability" })).toBe(false);
    expect(isControlInteractive({ status: "disabled" })).toBe(false);
  });
});
