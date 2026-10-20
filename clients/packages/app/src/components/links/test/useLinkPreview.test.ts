import { describe, expect, it } from "vitest";
import { hasRecommendationLinkPreview } from "../useLinkPreview";

describe("hasRecommendationLinkPreview", () => {
  it("matches the server's rich link shapes and never Gmail", () => {
    for (const href of [
      "https://github.com/AFK-surf/Comma/pull/845",
      "https://github.com/AFK-surf/Comma/pull/845/files?x=1",
      "https://linear.app/comma/issue/COMMA-143",
      "https://linear.app/comma/issue/COMMA-143/fix-onboarding-crash",
      "https://www.notion.so/comma/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
      "https://notion.so/4b8e7d0d9f1a4ed89d6ba8d11080a812?pvs=4",
      "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
      "https://calendar.google.com/calendar/u/0/r/eventedit/ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
      "https://comma-local.slack.com/archives/C01234567/p1786900000000000",
      "https://comma-local.slack.com/archives/C01234567/p1786900000000000?thread_ts=1786900000.000200&cid=C01234567",
      "https://docs.google.com/document/d/comma-local-launch-brief/edit",
      "https://docs.google.com/spreadsheets/d/1AbC_dEf-9/edit#gid=0",
      "https://docs.google.com/presentation/d/1AbC_dEf-9/edit?usp=sharing",
      "https://docs.google.com/forms/d/1AbC_dEf-9/viewform",
      "https://drive.google.com/file/d/1AbC_dEf-9/view?usp=sharing",
      "https://drive.google.com/open?id=1AbC_dEf-9",
      "https://drive.google.com/open?usp=drive_link&id=1AbC_dEf-9",
      "https://outlook.office.com/mail/id/AAMkADk",
      "https://outlook.office365.com/calendar/item/AAMkADk",
    ]) {
      expect(hasRecommendationLinkPreview(href), href).toBe(true);
    }
    for (const href of [
      "https://github.com/AFK-surf/Comma/issues/845",
      "http://github.com/AFK-surf/Comma/pull/845",
      "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
      "https://calendar.google.com",
      "http://comma-local.slack.com/archives/C01234567/p1786900000000000",
      "https://comma-local.slack.com/archives/C01234567",
      "http://drive.google.com/file/d/1AbC_dEf-9/view",
      "https://drive.google.com/drive/folders/1AbC_dEf-9",
      // Published-form/spreadsheet URLs put a pseudo segment after /d/ — the
      // "e" must not pass as a drive file id (ids demand >= 10 chars).
      "https://docs.google.com/forms/d/e/1FAIpQLSfAbCdEf/viewform",
      "https://docs.google.com/spreadsheets/d/e/2PACX-1vRabc/pubhtml",
    ]) {
      expect(hasRecommendationLinkPreview(href), href).toBe(false);
    }
  });
});
