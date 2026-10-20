// Fixed bug reports told to the sessions that reported them (feedback.rs's tests).
import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedNotice, tellFixed } from "../src/tools/feedback.ts";

test("a fixed report says where the fix is and whether this station has it", () => {
  const report = { id: "01", number: 12, title: "chat_post fails", version: 1340, parts: ["station"], thread: "EMBER/1.1" };
  const had = fixedNotice(report, "0.1.1342");
  assert.ok(had.includes('FB-12 "chat_post fails"'), had);
  assert.ok(had.includes("the station 0.1.1340 and later"), had);
  assert.ok(had.includes("This station runs 0.1.1342: it has the fix."), had);
  assert.ok(had.includes("(EMBER/1.1)"), had);
  assert.ok(fixedNotice(report, "0.1.1300").includes("once it is updated"));
  const live = fixedNotice({ number: 3, title: "t", version: 9, parts: ["cloud"] }, null);
  assert.ok(live.includes("live now") && !live.includes("This station"), live);
  const app = fixedNotice({ number: 4, title: "t", version: 9, parts: ["android", "web"] }, "0.1.1");
  assert.ok(app.includes("the Android app 0.1.9, the web app"), app);
  assert.ok(app.includes("An app gets it once it is updated"), app);
});

test("fixed reports are told to their sessions, then said told", async () => {
  const asked: string[][] = [];
  const fixed = async (told: string[]) => {
    asked.push(told);
    return told.length === 0
      ? { station: "0.1.1342", fixed: [
          { id: "A", number: 1, title: "one", version: 1340, parts: ["station"], session: "ember:C1:1.1", thread: "C1/1.1" },
          { id: "B", number: 2, title: "two", version: 1340, parts: ["cloud"], session: null },
        ] }
      : { fixed: [] };
  };
  const notices: [string, string][] = [];
  assert.equal(await tellFixed(fixed, (s, t) => void notices.push([s, t])), 2);
  assert.equal(notices.length, 1);
  assert.equal(notices[0]![0], "ember:C1:1.1");
  assert.ok(notices[0]![1].includes("FB-1"));
  assert.deepEqual(asked, [[], ["A", "B"]]);
});
