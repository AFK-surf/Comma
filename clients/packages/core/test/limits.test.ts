import { expect, it } from "vitest";
import { CORE_LIMITS } from "../src/limits.ts";

// Tests lower these to reach a limit in a few reads; the product reads this many times.
it("gives up a Telegram login after 200 reads, Compute after 60 a visit, a briefing run after 45 failed", () => {
  expect(CORE_LIMITS).toEqual({
    telegramLoginReads: 200,
    computeReadsPerVisit: 60,
    briefingReadFailures: 45,
  });
});
