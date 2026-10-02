import { locale as bftLocale } from "./messages";

const locale = bftLocale === "zh_Hans" ? "zh-Hans" : "en";

const integerFormat = new Intl.NumberFormat(locale);
const compactFormat = new Intl.NumberFormat(locale, {
  notation: "compact",
  maximumFractionDigits: 1,
});
const timeFormat = new Intl.DateTimeFormat(locale, {
  hour: "numeric",
  minute: "2-digit",
});
const dateTimeFormat = new Intl.DateTimeFormat(locale, {
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});
const relativeFormat = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });

export const formatInteger = (value: number) => integerFormat.format(value);
export const formatCompact = (value: number) => compactFormat.format(value);

/** Wall-clock time of day (`3:45 PM`, `15:45`), or `undefined` for a bad timestamp. */
export function formatTime(iso: string) {
  const time = Date.parse(iso);
  return Number.isNaN(time) ? undefined : timeFormat.format(time);
}

/** Local date and time of a unix-millisecond instant (`Oct 1, 3:45 PM`). */
export const formatDateTime = (ms: number | null) =>
  ms === null ? "—" : dateTimeFormat.format(ms);

const relativeUnits: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 365 * 24 * 3600],
  ["month", 30 * 24 * 3600],
  ["week", 7 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
];

export function formatRelative(iso: string, now = Date.now()) {
  const time = Date.parse(iso);
  if (Number.isNaN(time)) return undefined;
  const seconds = Math.round((time - now) / 1000);
  for (const [unit, size] of relativeUnits) {
    if (Math.abs(seconds) >= size) {
      return relativeFormat.format(Math.round(seconds / size), unit);
    }
  }
  return relativeFormat.format(0, "second");
}

export function initials(name: string | null, email: string | null) {
  const words = (name ?? "").trim().split(/\s+/).filter(Boolean);
  if (words.length > 0) {
    return words
      .slice(0, 2)
      .map((word) => word[0]?.toUpperCase() ?? "")
      .join("");
  }
  return email?.trim()[0]?.toUpperCase() ?? "?";
}

/** `needs_review` -> `Needs review`; the fallback for values without a label. */
export function humanize(value: string) {
  const words = value.replace(/[_-]+/g, " ").trim();
  return words ? `${words[0]?.toUpperCase() ?? ""}${words.slice(1)}` : value;
}

const byteUnits = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

/** `17179869184` -> `16.0 GiB`, as devices report their memory. */
export function formatBytes(bytes: number) {
  const exponent = Math.min(
    Math.floor(Math.log(bytes) / Math.log(1024)),
    byteUnits.length - 1
  );
  return `${(bytes / 1024 ** exponent).toFixed(1)} ${byteUnits[exponent] ?? "B"}`;
}
