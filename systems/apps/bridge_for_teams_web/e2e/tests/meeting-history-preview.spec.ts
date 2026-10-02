import { expect, test } from "@playwright/test";

// Runs against the isolated meeting preview, not shared staging, with the
// React dashboard built into priv/static/bft. Start
// meeting_preparation_preview.exs with MEETING_PREVIEW_LOCALE=en.
const previewURL = process.env.MEETING_PREVIEW_URL;

test("meeting history opens existing source links and keeps preparation navigation", async ({ page }) => {
  test.skip(!previewURL, "Requires the local meeting preview fixture");
  await page.goto(previewURL!);
  await expect(page.getByRole("heading", { level: 1, name: "Upcoming meetings" })).toBeVisible();
  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await nav.getByRole("link", { name: "Past", exact: true }).click();
  await expect(page.getByRole("button", { name: /Stand-up · sample meeting/ })).toBeVisible();
  await expect(page.getByText("Private source must not appear")).toHaveCount(0);
  await page.getByRole("button", { name: /Stand-up · sample meeting/ }).click();
  const detail = page.getByRole("dialog", { name: "Stand-up · sample meeting" });
  await expect(detail.getByRole("link", { name: "Open recording in Slack" })).toHaveAttribute(
    "href", "https://sample.slack.com/files/UTEST/FRECORD",
  );
  await expect(detail.getByRole("link", { name: "Open Canvas in Slack" })).toHaveAttribute(
    "href", "https://sample.slack.com/docs/TTEST/FTEST",
  );
  await expect(page.getByText("Do not expose a content preview")).toHaveCount(0);
  await detail.getByRole("button", { name: "Close" }).click();
  await page.getByRole("button", { name: /Planning · sample meeting/ }).click();
  const planning = page.getByRole("dialog", { name: "Planning · sample meeting" });
  await expect(planning).toContainText("No recording was saved for this meeting.");
  await expect(planning.getByRole("link", { name: "Open recording in Slack" })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(planning).toHaveCount(0);
  await page.getByRole("button", { name: /Design sync · sample meeting/ }).click();
  await expect(page.getByRole("dialog")).toContainText(
    "The meeting is processing. No recording link is available yet.",
  );
  await page.getByRole("dialog").getByRole("button", { name: "Close" }).click();
  await nav.getByRole("link", { name: "Settings", exact: true }).first().click();
  await expect(page.getByRole("heading", { level: 1, name: "Preparation settings" })).toBeVisible();
  await expect(page.getByRole("checkbox", { name: "Send private reminders to all attendees" })).toBeVisible();
});
