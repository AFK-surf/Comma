/**
 * The Routine projection of a workspace with no connected sources. Home reads
 * it on every visit, and an unanswered read is a Routine problem toast over the
 * composer. Stubs for other surfaces answer with this quiet state.
 */
export const emptyRoutineEnvelope = {
  settings: {
    autoEnableNewSources: true,
    schedule: { enabled: true, hour: 8, minute: 0, timezone: "UTC" },
    sourceRevision: 1,
    sources: [],
    sourcesCheckedAt: "2026-01-01T00:00:00.000Z",
  },
  snapshot: null,
  state: "empty",
};
