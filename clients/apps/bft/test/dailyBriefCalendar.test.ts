import { describe, expect, it } from "vitest";
import { calendarDays } from "../src/dailyBriefCalendar";

describe("daily brief calendar days", () => {
  it("reads days separated by commas or spaces", () => {
    expect(calendarDays("2026-10-01, 2026-10-02，2026-10-08\n2026-10-09")).toEqual([
      "2026-10-01",
      "2026-10-02",
      "2026-10-08",
      "2026-10-09",
    ]);
    expect(calendarDays("  ")).toEqual([]);
  });

  it("refuses anything that is not a real day", () => {
    expect(calendarDays("10/01")).toBeUndefined();
    expect(calendarDays("2026-02-30")).toBeUndefined();
    expect(calendarDays("2026-13-01")).toBeUndefined();
  });
});
