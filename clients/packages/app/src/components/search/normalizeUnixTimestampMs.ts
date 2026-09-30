const millisecondsPerSecond = 1_000;
const exclusiveUnixSecondsUpperBound = 10_000_000_000;

/** Normalizes the API's accepted Unix seconds or milliseconds representation. */
export function normalizeUnixTimestampMs(
  timestamp: number | undefined
): number | undefined {
  if (timestamp === undefined || !Number.isFinite(timestamp)) return undefined;
  return timestamp < exclusiveUnixSecondsUpperBound
    ? timestamp * millisecondsPerSecond
    : timestamp;
}
