export type WorkbenchEvidenceType =
  | "result"
  | "event"
  | "transport"
  | "security"
  | "activity";

export interface WorkbenchEvidenceEntry {
  id: string;
  createdAt: string;
  type: WorkbenchEvidenceType;
  label: string;
  status: "success" | "error" | "info";
  channel?: string | undefined;
  input?: unknown;
  output?: unknown;
  error?: unknown;
}

export function appendEvidence(
  entries: readonly WorkbenchEvidenceEntry[],
  entry: Omit<WorkbenchEvidenceEntry, "createdAt" | "id">
) {
  return [
    {
      ...entry,
      id: crypto.randomUUID(),
      createdAt: new Date().toISOString(),
      input: redactEvidenceValue(entry.input),
      output: redactEvidenceValue(entry.output),
      error: redactEvidenceValue(entry.error),
    },
    ...entries,
  ];
}

export function redactEvidenceValue(value: unknown): unknown {
  if (typeof value === "string") {
    if (/Bearer\s+\S+/i.test(value)) {
      return value.replace(/Bearer\s+\S+/i, "Bearer [redacted]");
    }

    if (value.startsWith("/Users/") || /^[A-Z]:\\/.test(value)) {
      return "[redacted-path]";
    }
  }

  if (Array.isArray(value)) {
    return value.map(redactEvidenceValue);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nestedValue]) => [
        key,
        /token|secret|authorization/i.test(key)
          ? "[redacted]"
          : redactEvidenceValue(nestedValue),
      ])
    );
  }

  return value;
}
