import { useCommaLocale } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { normalizeUnixTimestampMs } from "../search/normalizeUnixTimestampMs";

/**
 * Time of day for today, with the date for older moments of a Task. `date`
 * decides instead when given: a list that already named the day leaves it out.
 */
export function useTimeLabel() {
  const locale = useCommaLocale();
  return (timestamp: number | undefined, date?: boolean) => {
    const ms = normalizeUnixTimestampMs(timestamp);
    if (ms === undefined) return "";
    const at = new Date(ms);
    const withDate =
      date ?? new Date(uiClock.now()).toDateString() !== at.toDateString();
    return new Intl.DateTimeFormat(locale, {
      hour: "2-digit",
      minute: "2-digit",
      ...(withDate ? { month: "numeric", day: "numeric" } : {}),
    }).format(at);
  };
}
