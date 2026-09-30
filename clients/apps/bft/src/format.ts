import { locale as bftLocale } from "./messages";

const locale = bftLocale === "zh_Hans" ? "zh-Hans" : "en";

const integerFormat = new Intl.NumberFormat(locale);
const compactFormat = new Intl.NumberFormat(locale, {
  notation: "compact",
  maximumFractionDigits: 1,
});
const relativeFormat = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });

export const formatInteger = (value: number) => integerFormat.format(value);
export const formatCompact = (value: number) => compactFormat.format(value);

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
