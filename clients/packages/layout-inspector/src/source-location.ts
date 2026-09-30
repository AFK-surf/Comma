export const layoutInspectorSourceAttribute = "data-comma-source";

export type LayoutSourceLocation = {
  column: number;
  file: string;
  line: number;
};

export function formatLayoutSourceLocation(location: LayoutSourceLocation) {
  return `${location.file}:${location.line}:${location.column}`;
}

export function parseLayoutSourceLocation(
  value: string | null
): LayoutSourceLocation | undefined {
  if (!value) return undefined;
  const match = /^(.*):(\d+):(\d+)$/.exec(value);
  if (!match?.[1] || !match[2] || !match[3]) return undefined;

  const line = Number.parseInt(match[2], 10);
  const column = Number.parseInt(match[3], 10);
  if (!Number.isSafeInteger(line) || !Number.isSafeInteger(column)) {
    return undefined;
  }

  return {
    column,
    file: match[1],
    line,
  };
}
