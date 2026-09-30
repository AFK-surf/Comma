/**
 * How long a requested image preview may stay unresolved before the message
 * stops waiting for it. The image group reveals only once every preview has
 * settled, so a loader that never answers must not hide the ones that did.
 */
const CHAT_IMAGE_PREVIEW_SETTLE_DEADLINE_MS = 20_000;

/**
 * Starts a clock for each newly pending key, drops clocks for keys no longer
 * pending, and reports the keys that outlive the deadline. Returns the
 * timer's teardown, or nothing when no key is pending.
 */
export function schedulePreviewSettleDeadline(
  since: Map<string, number>,
  keys: string[],
  onExpired: (expired: string[]) => void
) {
  const now = Date.now();
  const stale = Array.from(since.keys()).filter((key) => !keys.includes(key));
  for (const key of stale) since.delete(key);
  for (const key of keys) {
    if (!since.has(key)) since.set(key, now);
  }
  if (keys.length === 0) return undefined;
  const earliest = Math.min(...keys.map((key) => since.get(key) ?? now));
  const timer = setTimeout(
    () => {
      const expiredBefore = Date.now() - CHAT_IMAGE_PREVIEW_SETTLE_DEADLINE_MS;
      const expired = keys.filter(
        (key) => (since.get(key) ?? Number.POSITIVE_INFINITY) <= expiredBefore
      );
      if (expired.length === 0) return;
      onExpired(expired);
    },
    Math.max(0, earliest + CHAT_IMAGE_PREVIEW_SETTLE_DEADLINE_MS - now)
  );
  return () => clearTimeout(timer);
}
