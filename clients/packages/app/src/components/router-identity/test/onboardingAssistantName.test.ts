import { describe, expect, it } from "vitest";
import { onboardingAssistantName } from "../onboardingAssistantName";

describe("onboardingAssistantName", () => {
  it("calls an unnamed assistant Comma, never by its Router role", () => {
    expect(onboardingAssistantName(undefined)).toBe("Comma");
    expect(onboardingAssistantName("  ")).toBe("Comma");
    expect(onboardingAssistantName("Default workspace Router")).toBe("Comma");
  });

  it("uses the name the user gave, as written", () => {
    expect(onboardingAssistantName(" Atlas ")).toBe("Atlas");
    expect(onboardingAssistantName("小逗")).toBe("小逗");
  });
});
