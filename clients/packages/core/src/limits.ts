// How many times the core reads something before it gives up. A core gets these values (`CoreOptions.limits`); a test
// can lower one to check what happens at the limit without the reads before it.

export interface CoreLimits {
  /** Reads of the Telegram connection while a login is under way; after the last one the login is a failure. */
  readonly telegramLoginReads: number;
  /** Reads of Compute while a workload prepares, per visit. */
  readonly computeReadsPerVisit: number;
  /** Failed reads of a briefing run the core accepts; the next failure makes the run unavailable. */
  readonly briefingReadFailures: number;
}

export const CORE_LIMITS: CoreLimits = {
  telegramLoginReads: 200,
  computeReadsPerVisit: 60,
  briefingReadFailures: 45,
};
