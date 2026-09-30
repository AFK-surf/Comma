import { describe, expect, it } from "vitest";
import { meetingTaskRecoveryScenario } from "../../test-support/meeting-task-recovery";

describe("saved meeting recovery after capture cleanup", () => {
  for (const failure of ["entry", "snapshot", "register"] as const)
    it(`retries ${failure} failure after restart using the confirmed Drive copy`, async () => {
      expect(await meetingTaskRecoveryScenario(failure)).toMatchObject({
        saved: "ready",
        initialError: expect.any(String),
        scratchFiles: [],
        creates: 1,
        finalAction: "finalize",
        sameRecordingId: true,
        sameOccurrenceId: true,
        driveBytes: 364,
        retryStatus: "synced",
      });
    }, 20_000);
});
