import { test } from "node:test";
import assert from "node:assert/strict";
import { flakyTitles, summarize } from "./ci-timing-summary.mjs";

const job = (name, seconds, conclusion = "success") => ({
  name,
  conclusion,
  started_at: "2026-10-06T00:00:00Z",
  completed_at: new Date(Date.UTC(2026, 9, 6, 0, 0, seconds)).toISOString(),
});

test("job times are listed slowest first, with jobs over three minutes marked", () => {
  const summary = summarize([
    job("Unit Test", 140),
    job("Browser E2E Test", 250),
    { ...job("Apple iOS Build", 0, "skipped"), started_at: null },
  ]);
  const rows = summary.split("\n").filter((line) => line.startsWith("| ") && !line.startsWith("| Job") && !line.startsWith("| ---"));
  assert.deepEqual(rows, [
    "| Browser E2E Test | 4m10s ⚠️ over 3m | success |",
    "| Unit Test | 2m20s | success |",
  ]);
});

test("only the tests under Playwright's flaky heading are reported as flaky", () => {
  const titles = flakyTitles([
    {
      message: [
        "  1 failed",
        "    [app-shell] › a.spec.ts:3:1 › breaks every time",
        "  1 flaky",
        "    [electron-shell] › b.spec.ts:9:1 › passes on retry",
        "  20 passed (1.0m)",
      ].join("\n"),
    },
  ]);
  assert.deepEqual(titles, ["[electron-shell] › b.spec.ts:9:1 › passes on retry"]);
  const summary = summarize([job("Electron Shell E2E", 60)], new Map([["Electron Shell E2E", titles]]));
  assert.match(summary, /- Electron Shell E2E: \[electron-shell\] › b\.spec\.ts:9:1 › passes on retry/);
});
