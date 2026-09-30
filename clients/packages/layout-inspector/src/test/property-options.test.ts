import { describe, expect, it } from "vitest";
import { formatOriginalOptionLabel } from "../property-options";

describe("formatOriginalOptionLabel", () => {
  it("shows the authored variable name instead of Original", () => {
    expect(
      formatOriginalOptionLabel(
        {
          computed: "8px",
          confidence: "authored",
          expression: "var(--spacing-md)",
          variables: ["--spacing-md"],
        },
        false
      )
    ).toBe("--spacing-md · 8px");
  });

  it("shows variables used inside calc expressions", () => {
    expect(
      formatOriginalOptionLabel(
        {
          computed: "32px",
          confidence: "authored",
          expression: "calc(var(--spacing) * 8)",
          variables: ["--spacing"],
        },
        false
      )
    ).toBe("--spacing · 32px");
  });

  it("keeps uncertainty for inferred variables", () => {
    expect(
      formatOriginalOptionLabel(
        {
          computed: "12px",
          confidence: "inferred",
          variables: ["--space-large"],
        },
        false
      )
    ).toBe("≈ --space-large · 12px");
  });

  it("uses Original only when no variable is available", () => {
    expect(
      formatOriginalOptionLabel(
        {
          computed: "270px",
          confidence: "computed",
          variables: [],
        },
        false
      )
    ).toBe("Original · 270px");
  });

  it("names the variable when restoring a preview", () => {
    expect(
      formatOriginalOptionLabel(
        {
          computed: "8px",
          confidence: "authored",
          expression: "var(--spacing-md)",
          variables: ["--spacing-md"],
        },
        true
      )
    ).toBe("Restore · --spacing-md · 8px");
  });
});
