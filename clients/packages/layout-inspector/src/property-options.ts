import type { AuthoredLayoutValue } from "./authored-values";

export function formatOriginalOptionLabel(
  value: AuthoredLayoutValue,
  restoring: boolean
) {
  const variables = Array.from(new Set(value.variables));
  if (variables.length > 0) {
    const confidence = value.confidence === "inferred" ? "≈ " : "";
    const variableNames = variables.join(" + ");
    const computed = value.computed ? ` · ${value.computed}` : "";
    return `${restoring ? "Restore · " : ""}${confidence}${variableNames}${computed}`;
  }

  const originalValue = value.expression ?? value.computed ?? "unset";
  return `${restoring ? "Restore original" : "Original"} · ${originalValue}`;
}
