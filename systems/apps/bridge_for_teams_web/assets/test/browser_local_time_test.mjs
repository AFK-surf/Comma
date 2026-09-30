import assert from "node:assert/strict";
import test from "node:test";

import { formatBrowserLocalTime } from "../js/browser_local_time.mjs";

test("formats the same instant in the browser-selected timezone", () => {
  const instant = Date.UTC(2026, 7, 31, 1, 52, 7);

  assert.equal(
    formatBrowserLocalTime(instant, "month-day-time", "en-US", "Asia/Singapore"),
    "08-31 09:52",
  );

  assert.equal(
    formatBrowserLocalTime(instant, "time-seconds", "en-US", "Asia/Singapore"),
    "09:52:07",
  );
});

test("uses the timezone's rules for each instant instead of a fixed offset", () => {
  const beforeDst = Date.UTC(2026, 2, 8, 6, 30, 0);
  const afterDst = Date.UTC(2026, 2, 8, 7, 30, 0);

  assert.equal(
    formatBrowserLocalTime(beforeDst, "time-seconds", "en-US", "America/New_York"),
    "01:30:00",
  );

  assert.equal(
    formatBrowserLocalTime(afterDst, "time-seconds", "en-US", "America/New_York"),
    "03:30:00",
  );
});
