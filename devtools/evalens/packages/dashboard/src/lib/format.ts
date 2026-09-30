import { m } from "../paraglide/messages.js";
import { getLocale } from "../paraglide/runtime.js";

export function formatDate(value?: string): string {
  if (!value) return "-";
  return new Intl.DateTimeFormat(getLocale(), {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

export function formatDateTitle(value: string): string {
  const date = new Date(value);
  const zone = new Intl.DateTimeFormat(getLocale(), {
    timeZoneName: "long",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
  return `${date.toISOString()} UTC · ${zone}`;
}

export function formatTime(value: Date): string {
  return new Intl.DateTimeFormat(getLocale(), {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    fractionalSecondDigits: 3,
  }).format(value);
}

export function formatNumber(value: number, maximumFractionDigits = 3): string {
  return new Intl.NumberFormat(getLocale(), { maximumFractionDigits }).format(value);
}

export function formatPercent(value: number): string {
  return new Intl.NumberFormat(getLocale(), {
    style: "percent",
    maximumFractionDigits: 1,
  }).format(value);
}

export function formatDuration(milliseconds: number): string {
  if (milliseconds < 1000)
    return m.format_milliseconds({ value: formatNumber(milliseconds, 0) });
  return m.format_seconds({
    value: formatNumber(milliseconds / 1000, milliseconds < 10_000 ? 1 : 0),
  });
}

export function compactId(id: string): string {
  return id.length > 18 ? `${id.slice(0, 8)}...${id.slice(-6)}` : id;
}

export function middleEllipsis(value: string, maxLength = 24): string {
  if (value.length <= maxLength) return value;
  const leftLength = Math.ceil((maxLength - 1) / 2);
  const rightLength = Math.floor((maxLength - 1) / 2);
  return `${value.slice(0, leftLength)}…${value.slice(-rightLength)}`;
}

export function formatParam(value: unknown): string {
  if (typeof value === "string") return value;
  return JSON.stringify(value);
}
