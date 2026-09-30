import { describe, expect, test } from "bun:test";
import { requireSalixTemplateId, toolCallingAgent } from "./tool-calling.exp";

describe("tool-calling experiment", () => {
  test("creates agents from the configured Salix template", () => {
    expect(toolCallingAgent("router", "template-1", "worker-1")).toMatchObject({
      role: "router",
      template: "template-1",
    });
    expect(toolCallingAgent("worker", "template-1", "worker-1")).toMatchObject({
      role: "worker",
      ref: "worker-1",
      template: "template-1",
    });
  });

  test("rejects missing Salix template configuration", () => {
    expect(() => requireSalixTemplateId(undefined)).toThrow(
      "salix.templateId is required for the tool-calling experiment"
    );
  });
});
