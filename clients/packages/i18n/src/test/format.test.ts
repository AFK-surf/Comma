import { describe, expect, it } from "vitest";
import { formatDateRange, formatRelativeDate, formatRelativeTime } from "../format";

const now = Date.UTC(2026, 7, 22, 12, 0, 0);
const day = 24 * 60 * 60_000;

describe("formatDateRange", () => {
  it("collapses the shared parts of a time range", () => {
    // Intl uses thin / narrow no-break spaces around the dash and before AM.
    const start = Date.UTC(2026, 7, 24, 9, 4);
    expect(
      formatDateRange(start, start + 45 * 60_000, "en", {
        hour: "numeric",
        minute: "2-digit",
        timeZone: "UTC",
      }).replaceAll(/\s/g, " ")
    ).toBe("9:04 – 9:49 AM");
  });
});

describe("formatRelativeDate", () => {
  it("stays relative today, names the adjacent days, and dates everything else", () => {
    // Day boundaries are the viewer's local ones, so anchor at local noon.
    const noon = new Date(2026, 7, 22, 12).getTime();
    expect(formatRelativeDate(noon - 6 * 60 * 60_000, "en", noon)).toBe("6h ago");
    expect(formatRelativeDate(noon + 5 * 60 * 60_000, "en", noon)).toBe("in 5h");
    expect(formatRelativeDate(noon - 26 * 60 * 60_000, "en", noon)).toBe("yesterday");
    expect(formatRelativeDate(noon + 26 * 60 * 60_000, "en", noon)).toBe("tomorrow");
    expect(formatRelativeDate(noon - 8 * day, "en", noon)).toBe("Aug 14");
    expect(formatRelativeDate(noon + 20 * day, "en", noon)).toBe("Sep 11");
    expect(formatRelativeDate(noon - 400 * day, "en", noon)).toBe("Jul 18, 2025");
    expect(formatRelativeDate(noon - 26 * 60 * 60_000, "zh-CN", noon)).toBe("昨天");
  });
});

describe("formatRelativeTime", () => {
  it("picks the largest unit the distance fills", () => {
    expect(formatRelativeTime(now - 8 * day, "en", now)).toBe("last wk.");
    expect(formatRelativeTime(now - 3 * day, "en", now)).toBe("3d ago");
    expect(formatRelativeTime(now - 5 * 60 * 60_000, "en", now)).toBe("5h ago");
    expect(formatRelativeTime(now - 20 * day, "en", now)).toBe("3w ago");
    expect(formatRelativeTime(now - 40 * day, "en", now)).toBe("last mo.");
    expect(formatRelativeTime(now + 2 * day, "en", now)).toBe("in 2d");
  });

  it("collapses anything under a minute to the locale's now", () => {
    expect(formatRelativeTime(now - 30_000, "en", now)).toBe("now");
    expect(formatRelativeTime(now, "zh-CN", now)).toBe("现在");
    expect(formatRelativeTime(now - 8 * day, "zh-CN", now)).toBe("上周");
  });
});
