import type { CommaLocale } from "./locale";
import * as messages from "./paraglide/messages.js";

/** Shared projection-freshness vocabulary for Inbox rows and Task cards. */
export type ContentFreshness = "fresh" | "stale" | "unknown";

export function contentFreshnessLabel(
  freshness: ContentFreshness | undefined,
  locale: CommaLocale
): string | undefined {
  if (freshness === "stale") {
    return messages.tasks_freshness_stale(undefined, { locale });
  }
  if (freshness === "unknown") {
    return messages.tasks_freshness_unknown(undefined, { locale });
  }
  return undefined;
}
