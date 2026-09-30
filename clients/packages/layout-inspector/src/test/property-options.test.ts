import { describe, expect, it } from "vitest";
import { formatOriginalOptionLabel } from "../property-options";
import type { AuthoredLayoutValue } from "../authored-values";

describe("formatOriginalOptionLabel", () => {
  it.each(
    (
      [
        {
          name: "shows the authored variable name instead of Original",
          value: {
            computed: "8px",
            confidence: "authored",
            expression: "var(--spacing-md)",
            variables: ["--spacing-md"],
          },
          restoring: false,
          expected: "--spacing-md · 8px",
        },
        {
          name: "shows variables used inside calc expressions",
          value: {
            computed: "32px",
            confidence: "authored",
            expression: "calc(var(--spacing) * 8)",
            variables: ["--spacing"],
          },
          restoring: false,
          expected: "--spacing · 32px",
        },
        {
          name: "keeps uncertainty for inferred variables",
          value: {
            computed: "12px",
            confidence: "inferred",
            variables: ["--space-large"],
          },
          restoring: false,
          expected: "≈ --space-large · 12px",
        },
        {
          name: "uses Original only when no variable is available",
          value: { computed: "270px", confidence: "computed", variables: [] },
          restoring: false,
          expected: "Original · 270px",
        },
        {
          name: "names the variable when restoring a preview",
          value: {
            computed: "8px",
            confidence: "authored",
            expression: "var(--spacing-md)",
            variables: ["--spacing-md"],
          },
          restoring: true,
          expected: "Restore · --spacing-md · 8px",
        },
      ] satisfies Array<{
        name: string;
        value: AuthoredLayoutValue;
        restoring: boolean;
        expected: string;
      }>
    ).map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { value, restoring, expected }) => {
    expect(formatOriginalOptionLabel(value, restoring)).toBe(expected);
  });
});
