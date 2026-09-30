import { describe, expect, it } from "vitest";
import { appendEvidence, redactEvidenceValue } from "../evidence-store";

describe("runtime workbench evidence store", () => {
  it("appends newest evidence first with stable metadata", () => {
    const entries = appendEvidence([], {
      channel: "comma:native:info",
      input: undefined,
      label: "native.info",
      output: { platform: "electron" },
      status: "success",
      type: "result",
    });

    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      channel: "comma:native:info",
      label: "native.info",
      status: "success",
      type: "result",
    });
    expect(entries[0]?.createdAt).toEqual(expect.any(String));
  });

  it("redacts raw bearer values and absolute paths", () => {
    expect(redactEvidenceValue("Bearer sk_agent_123")).toBe("Bearer [redacted]");
    expect(
      redactEvidenceValue("/Users/pengx17/Library/Application Support/Comma")
    ).toBe("[redacted-path]");
  });
});
